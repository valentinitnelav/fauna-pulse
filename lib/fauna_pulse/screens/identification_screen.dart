// FaunaPulse (round 208): "Identify organisms" for one session.
//
// Pre-flight (model + label pack, crop count, time estimate, settings),
// then the run with progress, then a completion card that leads to the
// results screen. The heavy lifting lives in identification/*; this screen
// only wires the native embedder (ImageEmbedder) into the job, keeps the
// screen awake and shows progress. Long runs are meant for a plugged-in
// phone indoors (plan section 11.12).
//
// Round 235: when the visits of a video session were found again since the
// stored crops were made, "Re-score with this name list" is hidden (the crops
// carry the old visit numbers) and a note says the next run starts over.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../identification/crop_worker.dart';
import '../identification/identification_assets.dart';
import '../identification/identification_choice.dart';
import '../identification/identification_job.dart';
import '../identification/identification_store.dart';
import '../identification/label_pack.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_thermal.dart';
import '../postprocess/video_frame_keeper.dart';
import '../postprocess/video_tracker.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/setting_help.dart';
import '../widgets/temperature_gauge.dart';
import '../widgets/home_button.dart';
import '../widgets/dialog_title.dart';
import 'identification_choice_fields.dart';
import 'identification_results_screen.dart';
import 'models_screen.dart';
import 'video_analysis_screen.dart';
import '../logging/thermal_pause.dart' show kDefaultPauseTempC;

/// Crops timed by "Test speed" (round 247; was 8, the job's batch size, which the owner found
/// arbitrary). Any count works: the model runs one crop at a time.
const int kSpeedTestCrops = 10;

class IdentificationScreen extends StatefulWidget {
  final Directory sessionDir;

  /// Round 274: opened by "Also identify them" on a Find screen: the run
  /// starts by itself once the crops are counted, and a finished run opens
  /// the results.
  final bool autoStart;

  const IdentificationScreen({super.key, required this.sessionDir, this.autoStart = false});

  @override
  State<IdentificationScreen> createState() => _IdentificationScreenState();
}

class _IdentificationScreenState extends State<IdentificationScreen> {
  IdentifyPrefs? _prefs;

  /// The model and name list (round 274: shared with the Find screens'
  /// "Also identify them").
  IdentificationChoice _choice = IdentificationChoice();
  File? get _model => _choice.model;
  File? get _pack => _choice.pack;
  Map<String, dynamic>? get _packHeader => _choice.packHeader;
  int? _plannedCrops;
  int? _plannedTracks;
  // Round 256: kept video frames not saved yet have no crops (the planner
  // skips missing photos), so the pre-flight says so.
  KeptFramesStatus _kept = KeptFramesStatus.none;
  int? _trackIdsFound;
  double? _msPerCrop;
  List<File> _summaries = const [];
  ThermalReading? _thermal;

  bool _running = false;
  bool _loadingModel = false;
  bool _cancel = false;
  IdentifyProgress? _progress;
  IdentifyResult? _result;
  String? _error;
  DateTime? _runStarted;
  // Round 250: when the first crop started (the time-left estimate leaves the model loading
  // out) and how long the whole run took, model loading included (the "Elapsed" clock).
  DateTime? _embedStarted;
  Duration? _runTook;
  Timer? _ticker;
  String _accelerator = '';
  // Round 211: why the GPU was not used (null when it was, or was not asked for).
  String? _accelNote;
  bool _testingSpeed = false;
  String? _speedResult;

  /// While "Test speed" runs: the share of timed crops done (0 = not counting yet) and what it
  /// is doing (round 247).
  (double, String)? _speedProgress;
  // Round 251: scrolls the speed test's progress and result into view when they start below
  // the screen's edge.
  final _speedKey = GlobalKey();

  void _showSpeed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _speedKey.currentContext;
      if (c == null || !c.mounted) return;
      Scrollable.ensureVisible(
        c,
        duration: const Duration(milliseconds: 250),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  /// The stored crops carry visit numbers of an earlier "Find visits" run.
  bool _visitsChanged = false;

  String get _sessionName => widget.sessionDir.path.split('/').last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await IdentifyPrefs.load();
    final choice = await IdentificationChoice.load(modelName: prefs.modelName, packName: prefs.packName);
    ThermalReading? thermal;
    try {
      thermal = await DeviceThermal.read();
    } catch (e) {
      logSwallowed('identify_thermal_probe', e);
    }
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _choice = choice;
      _thermal = thermal;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
    await _plan();
    await _checkVisits();
    await _loadSpeed();
    if (widget.autoStart && mounted && _model != null && _pack != null && (_plannedCrops ?? 0) > 0) await _start();
  }

  Future<void> _checkVisits() async {
    final m = _model;
    final changed = m != null && await IdentificationJob.cropsOutdated(widget.sessionDir, m.path.split('/').last);
    if (mounted) setState(() => _visitsChanged = changed);
  }

  Future<void> _plan() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final tasks = await IdentificationJob.planSession(
        widget.sessionDir,
        maxCropsPerTrack: prefs.maxCropsPerTrack,
      );
      final tracks = <int>{for (final t in tasks) if (t.trackId != null) t.trackId!};
      final kept = await VideoFrameKeeper.status(widget.sessionDir);
      final found = kept.total > 0 ? (await VideoTracker.readSummary(widget.sessionDir))?.visits : null;
      if (!mounted) return;
      setState(() {
        _plannedCrops = tasks.length;
        _plannedTracks = tracks.length;
        _kept = kept;
        _trackIdsFound = found;
      });
    } catch (e) {
      logSwallowed('identify_plan', e);
      if (mounted) setState(() => _plannedCrops = 0);
    }
  }

  /// Opens this session on the Video screen (to save the remaining kept
  /// frames), then counts the crops again.
  Future<void> _openVideoScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VideoAnalysisScreen(initialSessionPath: widget.sessionDir.path)),
    );
    if (!mounted) return;
    await _plan();
    await _checkVisits();
  }

  Future<void> _loadSpeed() async {
    final m = _model;
    if (m == null) return;
    final prefs = await IdentifyPrefs.load();
    final name = m.path.split('/').last;
    // Stored by the last run of this model on this phone.
    final sp = await SharedPreferences.getInstance();
    final v = sp.getDouble(IdentifyPrefs.msPerCropKey(name));
    if (!mounted) return;
    setState(() {
      _msPerCrop = v;
      _prefs ??= prefs;
    });
  }

  bool get _isClassList => _choice.isClassList;

  /// Why [model] and the chosen pack cannot run together, before anything is
  /// loaded (round 266); null when they may. The embedding size is checked
  /// again once the model is loaded.
  String? _pairingProblem(String modelName) {
    final h = _packHeader;
    if (h == null) return null;
    final owner = '${h['model_id']}';
    if (_isClassList && owner != stemOf(modelName)) {
      return 'The class list ${h['pack_id']} belongs to the model $owner.tflite. Choose that model, '
          'or a label pack for $modelName.';
    }
    return null;
  }

  /// Round 267: files are added and deleted on the AI models screen. On
  /// return the lists are re-read; a chosen file that was deleted falls back
  /// to the first one, and a model's class list is chosen with it.
  Future<void> _manageModels() async {
    await openModelsScreen(context);
    await _choice.reload();
    if (!mounted) return;
    setState(() {});
    await _checkVisits();
    await _loadSpeed();
  }

  Future<void> _savePrefs() async {
    final p = _prefs;
    if (p == null) return;
    p.modelName = _model?.path.split('/').last;
    p.packName = _pack?.path.split('/').last;
    await p.save();
  }

  /// Round 213: the resume key (photo, track, box) does not see the crop
  /// margin (nor, round 262, the crop shape), so stored vectors cut another
  /// way would silently be reused. Asks the user to keep them or recompute
  /// everything. Returns null when cancelled, true = start over.
  Future<bool?> _confirmCropSettings(IdentifyPrefs prefs, String modelName) async {
    // Crops of visits found again since are redone anyway (round 235).
    if (await IdentificationJob.cropsOutdated(widget.sessionDir, modelName)) return true;
    final stored = await IdentificationJob.storedIndex(widget.sessionDir, modelName);
    if (stored == null || stored.records.isEmpty || stored.margin == null) return false;
    if ((stored.margin! - prefs.margin).abs() < 1e-6 && stored.squareCrops == prefs.squareCrops) return false;
    if (!mounted) return null;
    String how(bool square, double margin) =>
        '${square ? 'square' : 'box-shaped'} with a margin of ${margin.toStringAsFixed(2)}';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Crop settings changed'), onClose: () => Navigator.of(ctx).pop(null)),
        content: Text(
          'The ${stored.records.length} stored crops of this session were cut '
          '${how(stored.squareCrops, stored.margin!)}; the settings are now '
          '${how(prefs.squareCrops, prefs.margin)}. '
          'Keep the stored crops (fast; only new photos use the new settings) or recompute all of '
          'them with the model (slow, like a first run)?',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep stored crops')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Recompute all crops')),
        ],
      ),
    );
  }

  Future<void> _start() async {
    final model = _model, pack = _pack, prefs = _prefs;
    if (model == null || pack == null || prefs == null) return;
    final problem = _pairingProblem(model.path.split('/').last);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    await _savePrefs();
    final restart = await _confirmCropSettings(prefs, model.path.split('/').last);
    if (restart == null || !mounted) return;
    setState(() {
      _running = true;
      _loadingModel = true;
      _cancel = false;
      _error = null;
      _result = null;
      _progress = null;
      _runStarted = DateTime.now();
      _embedStarted = null;
      _runTook = null;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    await WakelockPlus.enable();
    final modelName = model.path.split('/').last;
    IdentifyResult? result;
    try {
      final info = await ImageEmbedder.load(
        model.path,
        useGpu: prefs.useGpu,
        cpuThreads: prefs.cpuThreads,
        normalize: !_isClassList, // a classifier's raw class scores (round 266)
      );
      final packDim = (_packHeader?['dim'] as num?)?.toInt();
      if (packDim != null && packDim != info.dim) {
        throw Exception(
          'The name list ${pack.path.split('/').last} was made for a model that gives $packDim numbers '
          'per crop; ${model.path.split('/').last} gives ${info.dim}. Choose the name list made for this model.',
        );
      }
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _accelerator = info.accelerator;
        _accelNote = info.accelerationNote;
      });
      final pinfo = await PackageInfo.fromPlatform();
      final job = IdentificationJob(
        embed: (List<Uint8List> rgb) async {
          final b = await ImageEmbedder.embed(rgb);
          return [for (var i = 0; i < b.count; i++) Float32List.fromList(b.vector(i))];
        },
      );
      result = await job.run(
        widget.sessionDir,
        settings: IdentifyRunSettings(
          modelName: modelName,
          modelId: stemOf(modelName),
          packName: pack.path.split('/').last,
          inputSize: info.inputWidth,
          dim: info.dim,
          accelerator: info.accelerator,
          margin: prefs.margin,
          squareCrops: prefs.squareCrops,
          minCropPx: prefs.minCropPx,
          maxCropsPerTrack: prefs.maxCropsPerTrack,
          tau: prefs.tau,
          noneThreshold: prefs.noneThreshold,
          thermalLimitC: prefs.thermalLimitC,
          targetRank: prefs.targetRank,
          mergeVisits: prefs.mergeVisits,
          mergeGapS: prefs.mergeGapS,
          mergeSizeTol: prefs.mergeSizeTol,
          mergeMinCos: prefs.mergeMinCos,
          flagMinDurationS: prefs.flagMinDurationS,
          flagMinDetections: prefs.flagMinDetections,
          flagMinDetConf: prefs.flagMinDetConf,
          flagMinOrderP: prefs.flagMinOrderP,
          dropFactor: prefs.dropFactor,
          extra: {
            'use_gpu': prefs.useGpu,
            'cpu_threads': prefs.cpuThreads,
            'cpu_threads_used': ?info.cpuThreads,
            // Round 242: why the GPU was not used, and how closely it matched the CPU.
            'gpu_note': ?info.accelerationNote,
            'gpu_agreement': ?info.gpuAgreement,
          },
        ),
        packFile: pack,
        appVersion: '${pinfo.version}+${pinfo.buildNumber}',
        restart: restart,
        isCancelled: () => _cancel,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            if (p.stage == 'embedding') _embedStarted ??= DateTime.now();
          });
        },
      );
      if (result.embedded > 0) {
        final sp = await SharedPreferences.getInstance();
        final wallMs = result.elapsed.inMilliseconds / result.embedded;
        await sp.setDouble(IdentifyPrefs.msPerCropKey(modelName), wallMs);
        _msPerCrop = wallMs;
      }
    } catch (e) {
      logSwallowed('identify_start', e);
      _error = plainError(e);
    } finally {
      try {
        await ImageEmbedder.close();
      } catch (e) {
        logSwallowed('identify_close', e);
      }
      await WakelockPlus.disable();
      _ticker?.cancel();
    }
    _runTook = DateTime.now().difference(_runStarted!);
    if (!mounted) return;
    setState(() {
      _running = false;
      _loadingModel = false;
      _result = result;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
    await _checkVisits();
    // Round 274: the one-Start path ends on the results (newest summary first).
    if (widget.autoStart && mounted && result != null && !result.cancelled && _error == null) _openResults();
  }

  Widget _buttonNote(String name, String text) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Text.rich(
      TextSpan(children: [
        TextSpan(text: '$name: ', style: const TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: text),
      ]),
      style: helperTextStyle,
    ),
  );

  /// Round 211: measures the real speed of the current model + GPU/thread
  /// settings on this phone with a handful of the session's own crops, so the
  /// user can compare settings instead of trusting the switch labels. Nothing
  /// is written.
  Future<void> _testSpeed() async {
    final model = _model, prefs = _prefs;
    if (model == null || prefs == null) return;
    await _savePrefs();
    setState(() {
      _testingSpeed = true;
      _speedResult = null;
      _speedProgress = (0, 'Loading the model (up to half a minute the first time)…');
    });
    _showSpeed();
    // Round 247: 10 crops, one per call, so the screen can count them (the model runs one crop
    // at a time anyway; the job's batches of 8 only group the calls).
    const n = kSpeedTestCrops;
    try {
      final tasks = await IdentificationJob.planSession(widget.sessionDir, maxCropsPerTrack: prefs.maxCropsPerTrack);
      final info = await ImageEmbedder.load(model.path, useGpu: prefs.useGpu, cpuThreads: prefs.cpuThreads);
      if (mounted) setState(() => _speedProgress = (0, 'Cutting the crops…'));
      final rgb = <Uint8List>[];
      for (final t in tasks) {
        if (rgb.length >= n) break;
        final bytes = await File('${widget.sessionDir.path}/roi_frames/${t.source}').readAsBytes();
        final res = await cropBatch(
          CropBatchArgs(
            jpegBytes: bytes,
            requests: [CropRequest(t.key, t.left, t.top, t.right, t.bottom)],
            margin: prefs.margin,
            square: prefs.squareCrops,
            minCropPx: prefs.minCropPx,
            outSize: info.inputWidth,
          ),
        );
        for (final r in res) {
          if (r.rgb != null) rgb.add(r.rgb!);
        }
      }
      if (rgb.isEmpty) throw Exception('no crops large enough to test');
      if (mounted) setState(() => _speedProgress = (0, 'Warm-up crop (not timed)…'));
      await ImageEmbedder.embed([rgb.first]); // warm-up (first run pays one-off costs)
      final sw = Stopwatch()..start();
      for (var i = 0; i < rgb.length; i++) {
        if (mounted) {
          final left = i == 0 ? '' : ', about ${(sw.elapsedMilliseconds / i * (rgb.length - i) / 1000).ceil()} s left';
          setState(() => _speedProgress = (i / rgb.length, 'Crop ${i + 1} of ${rgb.length}$left'));
        }
        await ImageEmbedder.embed([rgb[i]]);
      }
      final sPerCrop = sw.elapsedMilliseconds / rgb.length / 1000;
      final auto = prefs.cpuThreads == 0, used = info.cpuThreads;
      final threads = used == null ? (auto ? 'automatic' : '${prefs.cpuThreads}') : '${auto ? 'automatic: ' : ''}$used';
      final agree = info.gpuAgreement;
      _speedResult =
          '${sPerCrop.toStringAsFixed(2)} s per crop on the ${info.accelerator}'
          '${info.accelerator == 'CPU' ? ' ($threads threads)' : ''}, ${rgb.length} crop${rgb.length == 1 ? '' : 's'} after a warm-up'
          '${rgb.length < n ? ' (only ${rgb.length} of this session\'s crops reach the "Smallest box" of ${prefs.minCropPx} px)' : ''}.'
          '${info.accelerator == 'GPU' && agree != null ? '\nThe GPU matched the CPU on a test picture (agreement ${agree.toStringAsFixed(4)}).' : ''}'
          '${info.accelerationNote != null ? '\nGPU not used: ${gpuNoteText(info.accelerationNote!)}.' : ''}';
      _accelNote = info.accelerationNote;
    } catch (e) {
      logSwallowed('identify_speed_test', e);
      _speedResult = 'Speed test failed: ${plainError(e)}';
    } finally {
      try {
        await ImageEmbedder.close();
      } catch (e) {
        logSwallowed('identify_close', e);
      }
    }
    if (mounted) {
      setState(() {
        _testingSpeed = false;
        _speedProgress = null;
      });
      _showSpeed();
    }
  }

  /// Scores the stored embeddings again with the selected pack (no model run).
  Future<void> _rescore() async {
    final model = _model, pack = _pack, prefs = _prefs;
    if (model == null || pack == null || prefs == null) return;
    await _savePrefs();
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _runTook = null;
      _progress = const IdentifyProgress(stage: 'scoring', done: 0, total: 0, avgMs: 0);
    });
    try {
      final pinfo = await PackageInfo.fromPlatform();
      final modelName = model.path.split('/').last;
      final summary = await IdentificationJob.scoreSession(
        widget.sessionDir,
        modelName: modelName,
        modelId: stemOf(modelName),
        packFile: pack,
        settings: {
          ...prefs.toJson(),
          'model': modelName,
          'pack': pack.path.split('/').last,
        },
        appVersion: '${pinfo.version}+${pinfo.buildNumber}',
      );
      _result = IdentifyResult(
        planned: 0,
        embedded: 0,
        skipped: 0,
        failed: 0,
        resumedDone: 0,
        thermalPauses: 0,
        elapsed: Duration.zero,
        cancelled: false,
        summary: summary,
      );
    } catch (e) {
      logSwallowed('identify_rescore', e);
      _error = plainError(e);
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
  }

  bool get _hasEmbeddings {
    final m = _model;
    if (m == null) return false;
    return IdentificationPaths(widget.sessionDir)
        .embeddingsJsonl(stemOf(m.path.split('/').last))
        .existsSync();
  }

  String _fmtDuration(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min ${d.inSeconds % 60} s';
    return '${d.inSeconds} s';
  }

  void _openResults([File? summary]) {
    final s = summary ?? (_summaries.isNotEmpty ? _summaries.first : null);
    if (s == null) return;
    final name = s.path.split('/').last; // summary_<pack>.json
    final packStem = name.substring('summary_'.length, name.length - '.json'.length);
    final paths = IdentificationPaths(widget.sessionDir);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IdentificationResultsScreen(
          sessionDir: widget.sessionDir,
          tracksJson: paths.tracksJson(packStem),
          summaryJson: s,
          tracksCsv: paths.tracksCsv(packStem),
        ),
      ),
    );
  }

  Future<void> _shareCsv() async {
    final s = _summaries.isNotEmpty ? _summaries.first : null;
    if (s == null) return;
    final name = s.path.split('/').last;
    final packStem = name.substring('summary_'.length, name.length - '.json'.length);
    final csv = IdentificationPaths(widget.sessionDir).tracksCsv(packStem);
    if (!csv.existsSync()) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(csv.path)]));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      // Two rows (round 210): one row ellipsised the session name away.
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Identify organisms'),
            Text(_sessionName, style: const TextStyle(fontSize: 13, color: Colors.white70), overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: const [HomeButton()],
      ),
      // SafeArea + bottom padding (round 209): the app is edge-to-edge, so an
      // explicitly padded ListView otherwise hides its last row (the end of
      // the unfolded Advanced settings) under the system navigation bar.
      body: SafeArea(
        child: prefs == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  if (_running) ..._progressSection() else ...[
                    ..._filesSection(prefs),
                    const Divider(height: 32, color: Colors.white24),
                    ..._preflightSection(prefs),
                    if (_result != null || _error != null) ...[
                      const Divider(height: 32, color: Colors.white24),
                      ..._completionSection(),
                    ],
                    const Divider(height: 32, color: Colors.white24),
                    _advancedSection(prefs),
                  ],
                ],
              ),
      ),
    );
  }

  List<Widget> _filesSection(IdentifyPrefs prefs) => [
    IdentificationChoiceFields(
      choice: _choice,
      onManage: _testingSpeed ? null : _manageModels,
      onChanged: (modelChanged) {
        setState(() {});
        if (modelChanged) {
          _loadSpeed();
          _checkVisits();
        }
      },
    ),
  ];

  /// Round 256: kept video frames that are not saved yet (the Video screen
  /// was left while saving) have no photo, so their track IDs are missing.
  List<Widget> _unsavedFramesNote() {
    final k = _kept;
    if (k.remaining <= 0 && k.noVideo <= 0) return const [];
    final found = _trackIdsFound;
    final without = found == null ? 0 : found - (_plannedTracks ?? 0);
    const amber = TextStyle(color: Colors.amber, fontSize: 12);
    return [
      if (k.remaining > 0) ...[
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Only ${k.saved} of ${k.total} kept frames of the videos are saved'
            '${without > 0 ? ', so $without of $found track IDs have no photo to identify yet' : ''}. '
            'Save the remaining frames on the Video screen first.',
            style: amber,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _running ? null : _openVideoScreen,
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Open the Video screen'),
          ),
        ),
      ],
      if (k.noVideo > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${k.noVideo} kept ${k.noVideo == 1 ? 'frame' : 'frames'} can no longer be saved: '
            'the video is gone from the session folder.',
            style: helperTextStyle,
          ),
        ),
    ];
  }

  List<Widget> _preflightSection(IdentifyPrefs prefs) {
    final crops = _plannedCrops;
    final estimate = (crops != null && _msPerCrop != null)
        ? Duration(milliseconds: (crops * _msPerCrop!).round())
        : null;
    final plugged = _thermal?.isPlugged == true || _thermal?.isCharging == true;
    final ready = _model != null && _pack != null && (crops ?? 0) > 0;
    return [
      const HelpLabel(
        label: 'Run',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Every saved photo of every tracked insect is cut out around its detector box (a square '
            'unless switched off under Advanced settings) and run through '
            'the model. The crops of one track ID are then combined into ONE answer: the model '
            'describes each crop in a vector of numbers, then they are averaged (a crop the model is sure about counts '
            'more, crops it is far less sure about are left out) and the average is classified once, so '
            'photos that agree reinforce each other (not a vote per photo), giving a probability per '
            'rank. Track IDs '
            'are not joined unless "Merge consecutive track IDs" is on (Advanced settings). '
            'Identification runs on this phone with the chosen model and name list; no image '
            'or data is sent anywhere. The run can take minutes to hours, can be cancelled and '
            'resumed at any time, and pauses when the battery gets warmer than the temperature '
            'set under Advanced settings. Plug the phone in for long runs.',
      ),
      const SizedBox(height: 6),
      Text(
        crops == null
            ? 'Counting crops…'
            : '$crops crops from ${_plannedTracks ?? 0} track ID${_plannedTracks == 1 ? '' : 's'}'
                  '${estimate == null ? '' : ' — about ${_fmtDuration(estimate)} on this phone'}',
        style: const TextStyle(color: Colors.white),
      ),
      if (crops == 0 && _kept.remaining == 0)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'No crops to identify: this session has no photos with tracked insects '
            '(sessions without detection need "Find animals in photos" first).',
            style: helperTextStyle,
          ),
        ),
      ..._unsavedFramesNote(),
      if (!plugged)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('The phone is not plugged in.', style: TextStyle(color: Colors.amber, fontSize: 12)),
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: ready && !_testingSpeed ? _start : null,
            icon: const Icon(Icons.biotech),
            label: Text(_hasEmbeddings ? 'Continue / re-run' : 'Start'),
          ),
          OutlinedButton.icon(
            onPressed: ready && !_testingSpeed ? _testSpeed : null,
            icon: const Icon(Icons.speed),
            label: Text(_testingSpeed ? 'Testing…' : 'Test speed'),
          ),
          if (_hasEmbeddings && _pack != null && !_visitsChanged)
            OutlinedButton.icon(
              onPressed: _rescore,
              icon: const Icon(Icons.refresh),
              label: const Text('Re-score with this name list'),
            ),
          if (_summaries.isNotEmpty)
            FilledButton.icon(
              onPressed: () => _openResults(),
              icon: const Icon(Icons.table_rows_outlined),
              label: const Text('View results'),
            ),
        ],
      ),
      // Round 251: the speed test's progress and result right under the buttons (owner: below the
      // button notes they were off-screen, so it looked as if nothing happened).
      if (_speedProgress != null || _speedResult != null)
        Column(
          key: _speedKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_speedProgress case (final value, final text)?) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: value == 0 ? null : value),
              const SizedBox(height: 4),
              Text('Testing speed: $text', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
            if (_speedResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_speedResult!, style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
      if (_visitsChanged)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'The track IDs were found again since the last run, so its stored results no longer match '
            'them. Continue / re-run starts over.',
            style: TextStyle(color: Colors.amber, fontSize: 12),
          ),
        ),
      // Round 218: one line per visible button (owner: too many buttons
      // without saying what each does).
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buttonNote(
              _hasEmbeddings ? 'Continue / re-run' : 'Start',
              _hasEmbeddings
                  ? 'runs the model only on photos that have no stored result yet (new photos, or after '
                        'lowering "Smallest box"), then recomputes the results; with nothing new it takes '
                        'seconds.'
                  : 'runs the model on every photo of every track ID (the slow step), then computes the '
                        'results.',
            ),
            _buttonNote(
              'Test speed',
              'times the model on $kSpeedTestCrops of this session\'s crops with the current GPU and thread '
                  'settings, counting them as it goes; writes nothing. Seconds with a GPU, a few minutes '
                  'on an older phone\'s CPU. It times the model alone: a full run also loads the model, '
                  'reads the photos and combines the results ("Last run" shows both).',
            ),
            if (_hasEmbeddings && _pack != null && !_visitsChanged)
              _buttonNote(
                'Re-score with this name list',
                'recomputes the results from the stored model outputs without running the model: use it '
                    'after changing the name list or any threshold, merge or flag setting (seconds).',
              ),
            if (_summaries.isNotEmpty) _buttonNote('View results', 'opens the newest results of this session.'),
          ],
        ),
      ),
    ];
  }

  List<Widget> _progressSection() {
    final p = _progress;
    final elapsed = _runStarted == null ? Duration.zero : DateTime.now().difference(_runStarted!);
    final total = p?.total ?? 0;
    final done = p?.done ?? 0;
    Duration? remaining;
    final cropping = _embedStarted == null ? null : DateTime.now().difference(_embedStarted!);
    if (p != null && cropping != null && done > 0 && total > done && p.stage != 'scoring') {
      remaining = Duration(milliseconds: (cropping.inMilliseconds / done * (total - done)).round());
    }
    final stageText = _loadingModel
        ? 'Loading the model (the first time can take a minute)…'
        : switch (p?.stage) {
            'planning' => 'Planning crops…',
            'embedding' => 'Identifying crops on the $_accelerator…'
                '${_accelNote != null ? ' (GPU not used: $_accelNote)' : ''}',
            'paused' => 'Paused: ${p!.note}',
            'scoring' => 'Combining crops per track ID and writing results…',
            'done' => 'Finishing…',
            _ => 'Starting…',
          };
    return [
      Text(stageText, style: const TextStyle(color: Colors.white, fontSize: 16)),
      const SizedBox(height: 12),
      LinearProgressIndicator(
        value: (p == null || total == 0 || p.stage == 'scoring' || _loadingModel) ? null : done / total,
      ),
      const SizedBox(height: 8),
      if (p != null && total > 0)
        Text('$done of $total crops (counted per photo: a photo with several insects adds several crops at once)',
            style: const TextStyle(color: Colors.white)),
      Text('Elapsed ${_fmtDuration(elapsed)}'
          '${remaining == null ? '' : ' — about ${_fmtDuration(remaining)} left'}'
          '${p != null && p.avgMs > 0 ? ' — the model takes ${(p.avgMs / 1000).toStringAsFixed(2)} s per crop' : ''}',
          style: helperTextStyle),
      if (p?.tempC != null)
        ...temperatureGauge(p!.tempC!, _prefs?.thermalLimitC ?? kDefaultPauseTempC, paused: p.stage == 'paused', limitWhere: 'under Advanced settings'),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _cancel ? null : () => setState(() => _cancel = true),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(_cancel ? 'Stopping after this photo…' : 'Cancel (keeps what is done)'),
        ),
      ),
    ];
  }

  /// Round 250: where the run's time went, so the per-crop speed can be checked against the
  /// total (the model's own time, as "Test speed" and the progress line report it).
  String _modelShare(IdentifyResult r) {
    if (r.embedded == 0 || r.modelTime == Duration.zero) return '';
    final ms = r.modelTime.inMilliseconds;
    final all = ms < 60000 ? '${(ms / 1000).toStringAsFixed(1)} s' : _fmtDuration(r.modelTime);
    return ' The model itself took ${(ms / r.embedded / 1000).toStringAsFixed(2)} s per crop ($all in all); '
        'loading it, reading the photos and combining the results took the rest.';
  }

  List<Widget> _completionSection() {
    final r = _result;
    final s = r?.summary;
    return [
      const Text('Last run', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 6),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      if (r != null) ...[
        if (r.cancelled) const Text('Cancelled — progress is kept; Continue resumes.', style: TextStyle(color: Colors.amber)),
        Text(
          '${r.embedded} crops identified now (${r.resumedDone} done earlier, ${r.skipped} skipped, '
          '${r.failed} failed, ${r.thermalPauses} heat pauses) in ${_fmtDuration(_runTook ?? r.elapsed)}'
          '${r.embedded > 0 ? ' on the $_accelerator' : ''}.${_modelShare(r)}',
          style: const TextStyle(color: Colors.white),
        ),
        if (r.embedded > 0 && _accelNote != null)
          Text('GPU not used: ${gpuNoteText(_accelNote!)}.', style: const TextStyle(color: Colors.amber, fontSize: 12)),
        if (s != null) ...[
          const SizedBox(height: 6),
          Text(
            '${s['tracks_total']} track IDs: '
            '${(s['by_identified_rank'] as Map).entries.map((e) => '${e.value} to ${e.key}').join(', ')}'
            '${s['unidentified'] != 0 ? ', ${s['unidentified']} unidentified' : ''}'
            '${(s['no_organism'] ?? 0) != 0 ? ', ${s['no_organism']} no organism' : ''}.',
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _openResults(),
                icon: const Icon(Icons.table_rows_outlined),
                label: const Text('View results'),
              ),
              OutlinedButton.icon(
                onPressed: _shareCsv,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share results (CSV file)'),
              ),
            ],
          ),
        ],
      ],
    ];
  }

  /// Applies one settings change: rebuild (so the number box shows the typed
  /// value when it loses focus, round 210 bug) and persist right away.
  void _edit(VoidCallback change) {
    setState(change);
    _savePrefs();
  }

  Widget _advancedSection(IdentifyPrefs prefs) {
    return ExpansionTile(
      title: const Text('Advanced settings', style: TextStyle(color: Colors.white)),
      subtitle: const Text('Saved as you change them', style: helperTextStyle),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        HelpSwitchTile(
          title: 'Use the GPU when it can run the model',
          value: prefs.useGpu,
          onChanged: (v) => _edit(() => prefs.useGpu = v),
          helperText:
              'Runs the model on the phone\'s graphics processor (GPU) when it can. On a Xiaomi Mi 11 '
              'Lite 5G (a 2021 mid-range phone) that took 0.27 s per crop instead of 2.6 s on the CPU, so a large session is '
              'identified about ten times faster. GPUs differ between phones and Android versions: '
              'the first time a model runs on this phone\'s GPU, the app compares its result on a '
              'test picture with the CPU\'s and keeps the GPU only when they agree. When the GPU '
              'cannot compile the model, does not match the CPU or runs out of memory, the app uses '
              'the CPU and says why after loading. "Test speed" shows what this phone does. '
              'Off = CPU only.',
        ),
        NumericSettingField(
          label: 'CPU threads (0 = automatic)',
          value: prefs.cpuThreads.toDouble(),
          min: 0,
          max: 8,
          isInt: true,
          onChanged: (v) => _edit(() => prefs.cpuThreads = v.round()),
          helperText:
              'How many processor cores the model may use on the CPU. 0 = automatic, which uses 2: '
              'on the phones it was tested on, that was almost twice as fast as 1. 4 was about a quarter faster '
              'again but keeps twice as many cores busy, so the phone warms up sooner (which '
              'triggers the pause). "Test speed" shows the real effect of a value on this phone.',
        ),
        HelpSwitchTile(
          title: 'Square crops',
          value: prefs.squareCrops,
          onChanged: (v) => _edit(() => prefs.squareCrops = v),
          helperText:
              'The model always looks at a square picture. On: the detector box is widened to a '
              'square on its longer side, so the insect keeps its shape and the extra room shows '
              'the flower around it. Off: only the box (plus the margin below) is cut out and '
              'stretched to the square, so the insect fills the picture but looks squeezed when '
              'the box is long and thin (BioCLIP learned from photos squeezed by up to about 4:3, '
              'so Off suits roughly square boxes). On by default: it keeps the shape and suits '
              'models trained on square crops; which works better on pollinator photos is not yet '
              'tested. After a change, the next run asks whether to recompute the stored crops.',
        ),
        NumericSettingField(
          label: 'Crop margin',
          value: prefs.margin,
          min: 0,
          max: 0.5,
          decimals: 2,
          onChanged: (v) => _edit(() => prefs.margin = v),
          helperText:
              'Extra border added on every side of the detector box, as a share of the box\'s '
              'longer side (0.05 = 5 % of it), because legs, antennae and wings stick out by an '
              'amount that depends on the insect\'s size. Default 0: the model sees the box itself, '
              'with as little flower or background as possible (with "Square crops" on, the square '
              'already adds some along the shorter side). Raise it if legs, antennae or wings look '
              'cut off (the cyan box on a track ID\'s photo in the results shows what was cut out). '
              'After a change, the next run asks whether to recompute the crops already stored for '
              'this session.',
        ),
        NumericSettingField(
          label: 'Smallest box to identify',
          value: prefs.minCropPx.toDouble(),
          min: 16,
          max: 512,
          isInt: true,
          unitSuffix: 'px',
          onChanged: (v) {
            _edit(() => prefs.minCropPx = v.round());
            _plan();
          },
          helperText:
              'Boxes smaller than this (longer side, in photo pixels) are skipped. Default 48: the '
              'model looks at every crop at 224 px, so a smaller box is enlarged more than 4 times '
              'and is mostly blur. On the default 1024 px photos, 48 px is an insect about 5 % of '
              'the photo side; 96 px would skip every insect under a tenth of it. Each track ID '
              'uses its largest boxes first (see "Crops per track ID"), so this mainly decides '
              'whether insects that stay small in every photo get an answer at all.',
        ),
        NumericSettingField(
          label: 'Crops per track ID (0 = all)',
          value: prefs.maxCropsPerTrack.toDouble(),
          min: 0,
          max: 100,
          isInt: true,
          onChanged: (v) {
            _edit(() => prefs.maxCropsPerTrack = v.round());
            _plan();
          },
          helperText:
              'Upper limit per track ID: when a track ID has more photos than this, only its LARGEST '
              'boxes are kept. How many photos a track ID has '
              'comes from the session\'s photo schedule (e.g.: the live detection default, one photo every 1 s for '
              '10 s, so about 10 per track ID); with that default the limit of 10 rarely removes '
              'anything and only bounds the runtime for long bursts. Set 0 to use all photos.',
        ),
        NumericSettingField(
          label: 'Ignore crops far less sure than the best (factor)',
          value: prefs.dropFactor,
          min: 1,
          max: 100,
          decimals: 0,
          onChanged: (v) => _edit(() => prefs.dropFactor = v),
          helperText:
              'A crop whose Species conf. is below the surest crop\'s divided by this factor is left out '
              'of the combined answer (it still appears in the crops table, marked "left out"). '
              '1 = every crop counts. The default of 10 is a FaunaPulse rule of thumb, not yet tested '
              'on representative data.',
        ),
        NumericSettingField(
          label: 'Confidence needed to call a rank identified',
          value: prefs.tau,
          min: 0.5,
          max: 0.99,
          decimals: 2,
          onChanged: (v) => _edit(() => prefs.tau = v),
          helperText:
              'The model gives every name in the name list a probability (they add up to 100 %); '
              'a family\'s probability is the sum of its species, and so on up to kingdom. Going '
              'from kingdom down to species, the deepest rank whose probability still reaches this '
              'value is reported as the answer. Deeper ranks are still listed in the results, with '
              'their lower probabilities, as suggestions to verify.',
        ),
        NumericSettingField(
          label: '"No organism" threshold',
          value: prefs.noneThreshold,
          min: 0.1,
          max: 0.9,
          decimals: 2,
          onChanged: (v) => _edit(() => prefs.noneThreshold = v),
          helperText:
              'The name list also contains a few "none of these" entries (flower, leaf, shadow, empty '
              'background). When their summed probability is above this, the track ID is reported as '
              '"no organism": the detector most likely fired on nothing.',
        ),
        NumericSettingField(
          label: 'Pause above battery temperature',
          value: prefs.thermalLimitC,
          min: 35,
          max: 45,
          decimals: 0,
          unitSuffix: '°C',
          onChanged: (v) => _edit(() => prefs.thermalLimitC = v),
          helperText: 'The run pauses when the battery reaches this and resumes 3 °C lower.',
        ),
        HelpSwitchTile(
          title: 'Merge consecutive track IDs',
          value: prefs.mergeVisits,
          onChanged: (v) => _edit(() => prefs.mergeVisits = v),
          helperText:
              'Off: every track ID stays on its own. On: when a track ID ends and a new one starts within '
              'the gap below, the two are joined into one track ID (and identified again from all their '
              'photos) if they pass three checks: a compatible identification (same taxon on the same '
              'path, e.g. Apidae then Bombus), a similar appearance (the model\'s image embeddings, the '
              'strongest signal) and a similar box size (a loose guard). Helps when the tracker lost an '
              'insect for a moment and gave it a new id. Track IDs that overlap in time are never '
              'joined (two insects at once). Changes the track ID count, so it is off by default; the CSV '
              'lists the joined ids.',
        ),
        if (prefs.mergeVisits) ...[
          NumericSettingField(
            label: 'Largest gap between joined track IDs',
            value: prefs.mergeGapS,
            min: 0.5,
            max: 120,
            decimals: 1,
            unitSuffix: 's',
            onChanged: (v) => _edit(() => prefs.mergeGapS = v),
            helperText:
                'Time from the end of one track ID to the start of the next. Check also what is set for the '
                'live tracker\'s own continuity buffer (its occlusion setting, 3 s by default). Longer gaps '
                'risk joining two different insects of the same species: the appearance check cannot '
                'tell individuals apart, only the time gap can.',
          ),
          NumericSettingField(
            label: 'Appearance similarity needed',
            value: prefs.mergeMinCos,
            min: 0.5,
            max: 0.99,
            decimals: 2,
            onChanged: (v) => _edit(() => prefs.mergeMinCos = v),
            helperText:
                'Cosine similarity (0 to 1) between the two track IDs\' combined image embeddings: 1 = the '
                'model sees the same thing. Same species usually scores 0.8 to 0.95, different families '
                'well below. 0.85 is a cautious default; lower it if fragments of one insect stay apart.',
          ),
          NumericSettingField(
            label: 'Box size may differ by up to',
            value: prefs.mergeSizeTol * 100,
            min: 0,
            max: 100,
            decimals: 0,
            unitSuffix: '%',
            onChanged: (v) => _edit(() => prefs.mergeSizeTol = v / 100),
            helperText:
                'Mean box side of each track ID, as a fraction of the ROI, compared as a percentage of the '
                'larger one. A loose guard on purpose (wings, distance and ROI-edge cuts change box size); '
                '100 % switches the check off.',
          ),
        ],
        const SizedBox(height: 8),
        const HelpLabel(
          label: 'Suspect track IDs (flags only, nothing is deleted)',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'Very short track IDs are often false detections (a moving petal, a shadow, a video '
              'artefact), and a weak identification makes that more likely. A track ID is flagged '
              '"suspect" when it is SHORT (below the duration OR the detections below) AND weakly '
              'supported (detector confidence below the threshold, order-level probability below the '
              'threshold, or "no organism"). Suspect track IDs are hidden from the results table by default '
              '(a switch shows them) and stay in the CSV with a "suspect" column, so you can check the '
              'thresholds on your own data in R or Python.',
        ),
        NumericSettingField(
          label: 'Short: duration below',
          value: prefs.flagMinDurationS,
          min: 0,
          max: 60,
          decimals: 1,
          unitSuffix: 's',
          onChanged: (v) => _edit(() => prefs.flagMinDurationS = v),
          helperText: 'From the first to the last detection of the track ID. 0 = never short by duration.',
        ),
        NumericSettingField(
          label: 'Short: detections below',
          value: prefs.flagMinDetections.toDouble(),
          min: 0,
          max: 100,
          isInt: true,
          onChanged: (v) => _edit(() => prefs.flagMinDetections = v.round()),
          helperText: 'Detector frames the track ID appeared in. 0 = never short by count.',
        ),
        NumericSettingField(
          label: 'Weak: detector confidence below',
          value: prefs.flagMinDetConf,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (v) => _edit(() => prefs.flagMinDetConf = v),
          helperText: 
              'If the mean confidence of the live detector over the track ID\'s crops '
              'is below this, the track ID is flagged as weak. '
        ),
        NumericSettingField(
          label: 'Weak: order probability below',
          value: prefs.flagMinOrderP,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (v) => _edit(() => prefs.flagMinOrderP = v),
          helperText:
              'If the identification\'s probability at ORDER rank (e.g. Diptera) '
              'is below this, the track ID is flagged as weak. '
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DropdownButtonFormField<String>(
            initialValue: prefs.targetRank,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'CSV file only: rank of the "pred" columns'),
            items: [for (final r in kRankNames.skip(3)) DropdownMenuItem(value: r, child: Text(r))],
            onChanged: (v) {
              if (v != null) _edit(() => prefs.targetRank = v);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            // Round 247 (owner: unclear what this does, and "default is family" next to genus).
            'Changes nothing in the app: the results on screen always show every rank. It only '
            'matters for the CSV file of the results (tracks_<name list>.csv): its columns pred, '
            'pred_prob_weighted, pred_prob_mean and pred_imgs give the answer at ONE rank, as the '
            'insect-detect-post tool of Maximilian Sittinger does, so the files of both can be '
            'compared; this picks that rank. All ranks are in the bioclip_<rank> and p_<rank> columns '
            'anyway. The names follow that tool; the formulas are FaunaPulse\'s (certainty-weighted mean '
            'and plain mean of the crops\' probabilities). '
            '${prefs.targetRank == 'family' ? 'Family is the app\'s default.' : 'You chose ${prefs.targetRank}; the app\'s default is family.'}',
            style: helperTextStyle,
          ),
        ),
      ],
    );
  }
}

/// Plain-language error text (strips the "Exception: " prefix).
String plainError(Object e) => '$e'.replaceFirst('Exception: ', '').replaceFirst('PlatformException', 'Error');
