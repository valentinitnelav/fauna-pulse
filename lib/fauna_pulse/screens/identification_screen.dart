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
//
// Round 319: the run itself lives in identification/identification_run.dart, so a Find screen
// can start it while the app is in the background (no page is built then); this page shows the
// run of its session.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../identification/crop_worker.dart';
import '../identification/identification_assets.dart';
import '../identification/identification_choice.dart';
import '../identification/identification_job.dart';
import '../identification/identification_run.dart';
import '../identification/identification_store.dart';
import '../identification/identify_wait_note.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_thermal.dart';
import '../postprocess/video_frame_keeper.dart';
import '../postprocess/video_tracker.dart';
import '../widgets/setting_help.dart';
import '../widgets/temperature_gauge.dart';
import '../widgets/home_button.dart';
import '../widgets/dialog_title.dart';
import 'identification_choice_fields.dart';
import 'identification_results_screen.dart';
import 'identify_settings_fields.dart';
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
  /// Round 319: the Find screen starts that run itself (IdentificationRun.autoStart) and this
  /// page shows it; the page starts one only when that run did not (a question to ask first).
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

  /// Round 319: the run this page shows (started here, or by a Find screen); the last one stays
  /// after its end. The model lock (one native model) is IdentificationRun.takeModel.
  IdentificationRun? _run;
  bool _loaded = false;

  IdentifyProgress? _progress;
  IdentifyResult? _result;
  String? _error;
  DateTime? _runStarted;
  // Round 250: how long the whole run took, model loading included (the "Elapsed" clock).
  Duration? _runTook;
  Timer? _ticker;
  String _accelerator = '';
  // Round 211: why the GPU was not used (null when it was, or was not asked for).
  String? _accelNote;
  bool _testingSpeed = false;
  // True from the tap on Start until _running is set: _start first saves the settings and reads
  // the stored crops (slow for a big session), and a second tap in that gap started a second
  // job that shared the one native model and wrote the same files.
  bool _starting = false;
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
    // A run of this session that goes on, or ended while the app was in the background.
    final going = IdentificationRun.of(widget.sessionDir);
    if (going != null) _attach(going);
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // Back during a run: stop the job at its next check, as the Cancel button does. Without
    // this the model kept embedding with no screen (heat, battery). The run still closes the
    // model and the screen-on lock; it keeps what is done.
    _run?.removeListener(_onRun);
    _run?.cancel();
    super.dispose();
  }

  /// Shows [r] from now on (no setState: also called from initState).
  void _attach(IdentificationRun r) {
    _run = r;
    _running = true;
    _result = null;
    _error = null;
    _runTook = null;
    _accelNote = null; // a speed test's, until this run has loaded its model
    _copyRun(r);
    r.addListener(_onRun);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _copyRun(IdentificationRun r) {
    _loadingModel = r.loadingModel;
    _progress = r.progress;
    _runStarted = r.started;
    if (r.accelerator.isNotEmpty) {
      _accelerator = r.accelerator;
      _accelNote = r.accelNote;
    }
  }

  void _onRun() {
    final r = _run;
    if (r == null || !mounted) return;
    if (!r.finished) {
      setState(() => _copyRun(r));
      return;
    }
    r.removeListener(_onRun);
    _ticker?.cancel();
    if (r.declined) {
      // Nothing was loaded (nothing to identify, or a question first): the page does it.
      setState(() {
        _run = null;
        _running = false;
        _loadingModel = false;
      });
      if (_loaded) _autoStart();
      return;
    }
    _runEnded(r);
  }

  Future<void> _runEnded(IdentificationRun r) async {
    r.seen();
    final result = r.result;
    setState(() {
      _copyRun(r);
      _running = false;
      _loadingModel = false;
      _result = result;
      _error = r.failure == null ? null : plainError(r.failure!);
      _runTook = r.took;
      if (r.msPerCrop != null) _msPerCrop = r.msPerCrop;
      _summaries = IdentificationPaths(widget.sessionDir).existingSummaries();
    });
    await _checkVisits();
    // Round 274: the one-Start path ends on the results (newest summary first). Not when crops
    // failed: the results then miss them (all of them when the model was lost), and the user
    // must see the warning in "Last run" to press Start again.
    if (widget.autoStart && mounted && result != null && !result.cancelled && result.failed == 0 && _error == null) {
      _openResults();
    }
  }

  Future<void> _autoStart() async {
    if (widget.autoStart && mounted && _run == null && _model != null && _pack != null && (_plannedCrops ?? 0) > 0) {
      await _start();
    }
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
    if (!mounted) return;
    _loaded = true;
    final r = _run;
    if (r == null) {
      await _autoStart();
    } else if (r.finished && _running) {
      _onRun(); // it ended before this page was shown
    }
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
    // The video settings' Identification card edits the same stored values
    // (round 313): read them again, or this screen's next save would write
    // its old copy back and the next run would use it.
    final fresh = await IdentifyPrefs.load();
    if (!mounted) return;
    // The model and name list chosen here stay.
    fresh.modelName = _prefs?.modelName ?? fresh.modelName;
    fresh.packName = _prefs?.packName ?? fresh.packName;
    setState(() => _prefs = fresh);
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
    final known = await cropSettingsRestart(widget.sessionDir, prefs, modelName);
    if (known != null) return known;
    final stored = await IdentificationJob.storedIndex(widget.sessionDir, modelName);
    if (stored == null || stored.margin == null) return false;
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
    if (model == null || pack == null || prefs == null || _running || _starting) return;
    final problem = pairingProblem(_choice, model.path.split('/').last);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => _starting = true);
    final bool? restart;
    try {
      await _savePrefs();
      restart = await _confirmCropSettings(prefs, model.path.split('/').last);
    } finally {
      // No await between here and `_running = true` below, so no second tap fits in between.
      if (mounted) setState(() => _starting = false);
    }
    if (restart == null || !mounted) return;
    final run = IdentificationRun.start(
      widget.sessionDir,
      model: model,
      pack: pack,
      packHeader: _packHeader,
      isClassList: _isClassList,
      prefs: prefs,
      restart: restart,
    );
    setState(() => _attach(run));
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
    if (model == null || prefs == null || _running || _starting) return;
    await _savePrefs();
    setState(() {
      _testingSpeed = true;
      _speedResult = null;
      _speedProgress = (0, 'Loading the model (the first time on this phone can take up to a minute)…');
    });
    _showSpeed();
    // Round 247: 10 crops, one per call, so the screen can count them (the model runs one crop
    // at a time anyway; the job's batches of 8 only group the calls).
    const n = kSpeedTestCrops;
    final freeModel = await IdentificationRun.takeModel(); // a run left going by Back ends first
    try {
      final tasks = await IdentificationJob.planSession(widget.sessionDir, maxCropsPerTrack: prefs.maxCropsPerTrack);
      final info = await ImageEmbedder.load(model.path, useGpu: prefs.useGpu, cpuThreads: prefs.cpuThreads);
      if (mounted) setState(() => _speedProgress = (0, 'Cutting the crops…'));
      final rgb = <Uint8List>[];
      for (final t in tasks) {
        if (rgb.length >= n) break;
        final bytes = await File('${widget.sessionDir.path}/roi_frames/${t.source}').readAsBytes();
        final List<CropResult> res;
        try {
          res = await cropBatch(
            CropBatchArgs(
              jpegBytes: bytes,
              requests: [CropRequest(t.key, t.left, t.top, t.right, t.bottom)],
              margin: prefs.margin,
              square: prefs.squareCrops,
              minCropPx: prefs.minCropPx,
              outSize: info.inputWidth,
            ),
          );
        } catch (e) {
          // A photo that cannot be read is left out; the speed test only needs a few crops.
          logSwallowed('identify_speed_crop', e);
          continue;
        }
        for (final r in res) {
          if (r.rgb != null) rgb.add(r.rgb!);
        }
      }
      if (rgb.isEmpty) {
        throw Exception(
          'No photo of this session has a box of at least "Smallest box to identify" (${prefs.minCropPx} px). '
          'Lower that value under Advanced settings, or test another session.',
        );
      }
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
          '${rgb.length < n ? ' (only ${rgb.length} of this session\'s crops reach the "Smallest box to identify" of ${prefs.minCropPx} px)' : ''}.'
          '${info.accelerator == 'GPU' && agree != null ? '\nThe GPU gave the same answers as the CPU on a test picture, so the GPU is used.' : ''}'
          '${info.accelerationNote != null ? '\nGPU not used: ${gpuNoteText(info.accelerationNote!)}' : ''}';
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
      freeModel();
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
    // Back (or the Home button, which uses maybePop) during a run used to close the page with no
    // word while the job went on unseen. Same question as Find animals in videos; "Stop and
    // leave" pops, and dispose cancels the run, so the job stops after the current crop.
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveIfConfirmed();
      },
      child: _screen(),
    );
  }

  Future<void> _leaveIfConfirmed() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Identification is still running'), onClose: () => Navigator.pop(ctx, false)),
        content: const Text(
          'Leaving stops the identification after the current photo. What is done is kept; '
          'Start continues where it left off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop and leave')),
        ],
      ),
    );
    // Navigator.pop ignores PopScope, so this leaves even while canPop is false. If the run ended
    // while the dialog was open, leaving is still what the user asked for.
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Widget _screen() {
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
        // Saved at once (round 313: before, only a run or another edit saved
        // the choice, and leaving the screen lost it).
        _savePrefs();
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
            '${without > 0 ? ', so $without of $found track ID${found == 1 ? '' : 's'} ${without == 1 ? 'has' : 'have'} no photo to identify yet' : ''}. '
            'Save the remaining frames on "Find animals in videos" first.',
            style: amber,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _running ? null : _openVideoScreen,
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Open Find animals in videos'),
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
            'The app cuts each saved photo of a track ID around the insect (a crop) and the model names '
            'the crops of one track ID together: one answer per track ID, with a confidence for every '
            'rank. Photos that agree make the answer stronger. Everything runs on this phone; no picture '
            'or data is sent anywhere. A run can take minutes to hours; you can cancel it and continue '
            'later, and it pauses when the battery is warmer than set under Advanced settings. Plug the '
            'phone in for long runs.',
      ),
      const SizedBox(height: 6),
      Text(
        crops == null
            ? 'Counting crops…'
            : '$crops crop${crops == 1 ? '' : 's'} from ${_plannedTracks ?? 0} track ID${_plannedTracks == 1 ? '' : 's'}'
                  '${estimate == null ? '' : ' (about ${_fmtDuration(estimate)} on this phone, plus any heat pauses)'}',
        style: const TextStyle(color: Colors.white),
      ),
      if (crops == 0 && _kept.remaining == 0)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'No crops to identify: this session has no photos of tracked animals. If it was recorded '
            'without a detection model, first run "Find animals in photos" (for videos: "Find animals '
            'in videos") from the session\'s ⋮ menu.',
            style: helperTextStyle,
          ),
        ),
      ..._unsavedFramesNote(),
      if (!plugged)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('The phone is not plugged in.', style: TextStyle(color: Colors.amber, fontSize: 12)),
        ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(kKeepOnScreenIdentifyText, style: helperTextStyle),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: ready && !_testingSpeed && !_starting ? _start : null,
            icon: const Icon(Icons.biotech),
            label: Text(_hasEmbeddings ? 'Continue / re-run' : 'Start'),
          ),
          OutlinedButton.icon(
            onPressed: ready && !_testingSpeed && !_starting ? _testSpeed : null,
            icon: const Icon(Icons.speed),
            label: Text(_testingSpeed ? 'Testing…' : 'Test speed'),
          ),
          if (_hasEmbeddings && _pack != null && !_visitsChanged)
            OutlinedButton.icon(
              onPressed: _rescore,
              icon: const Icon(Icons.refresh),
              label: const Text('Update results'),
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
            'Track IDs were found again after the last identification, so its results no longer fit '
            'them. "Continue / re-run" will identify all photos again from the start (this takes as '
            'long as a first run).',
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
              _visitsChanged
                  ? 'runs the model again on the photos of every track ID (the slow step), then computes '
                        'the results.'
                  : _hasEmbeddings
                  ? 'runs the model only on photos that have no stored result yet (new photos, or after '
                        'lowering "Smallest box to identify"), then recomputes the results; with nothing new '
                        'it takes seconds.'
                  : 'runs the model on the photos of every track ID (up to "Crops per track ID", largest '
                        'boxes first; the slow step), then computes the results.',
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
                'Update results',
                'recomputes the results in seconds from the stored model answers, without running the '
                    'model again: use it after changing the name list or any threshold, merge or suspect '
                    'setting.',
              ),
            if (_summaries.isNotEmpty) _buttonNote('View results', 'opens the newest results of this session.'),
          ],
        ),
      ),
    ];
  }

  List<Widget> _progressSection() {
    final p = _progress;
    final stopping = _run?.cancelRequested ?? false;
    final elapsed = _runStarted == null ? Duration.zero : DateTime.now().difference(_runStarted!);
    final total = p?.total ?? 0;
    final done = p?.done ?? 0;
    Duration? remaining;
    // Round 319, part 2: from the job's time on the crops, which leaves the model loading and the
    // heat pauses out (with the pauses it grew while the run waited, at the same crop count).
    if (p != null && done > 0 && total > done && p.stage != 'scoring') {
      remaining = Duration(milliseconds: (p.activeMs / done * (total - done)).round());
    }
    final stageText = _loadingModel
        ? 'Loading the model (the first time on this phone can take up to a minute)…'
        : switch (p?.stage) {
            'planning' => 'Planning crops…',
            // Round 319: one short line; the reason is shown once, below.
            'embedding' => 'Identifying crops on the $_accelerator${_accelNote != null ? ' (GPU not used, see below)' : ''}…',
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
        Text('$done of $total crop${total == 1 ? '' : 's'} (counted per photo: a photo with several insects adds several crops at once)',
            style: const TextStyle(color: Colors.white)),
      Text('Elapsed ${_fmtDuration(elapsed)}'
          '${remaining == null ? '' : ', about ${_fmtDuration(remaining)} left'}.'
          '${p != null && p.avgMs > 0 ? ' The model takes ${(p.avgMs / 1000).toStringAsFixed(2)} s per crop.' : ''}',
          style: helperTextStyle),
      if (!_loadingModel && _accelNote != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('GPU not used: ${gpuNoteText(_accelNote!)}', style: const TextStyle(color: Colors.amber, fontSize: 12)),
        ),
      if (p?.tempC != null)
        ...temperatureGauge(p!.tempC!, _prefs?.thermalLimitC ?? kDefaultPauseTempC, paused: p.stage == 'paused', limitWhere: 'Advanced settings'),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(kKeepOnScreenIdentifyText, style: helperTextStyle),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: stopping ? null : () => _run?.cancel(),
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(stopping ? 'Stopping after this photo…' : 'Cancel (keeps what is done)'),
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

  /// The red lines after a run with crops that failed (round 319, decision D5). Round 319, part
  /// 2: photos that could not be read are counted apart from model errors, and get no "tries
  /// them again": the store counts them as done, so a re-run leaves them out.
  List<String> _failedLines(IdentifyResult r) {
    final button = _hasEmbeddings ? 'Continue / re-run' : 'Start';
    final total = r.embedded + r.failed;
    final modelErrors = r.failed - r.unreadable;
    return [
      if (modelErrors > 0 && r.embedded == 0)
        'No crop could be identified: the model stopped with an error '
            '${r.unreadable > 0 ? 'for every photo it could read' : 'each time'}. Press "$button" to '
            'try again. If it fails again, delete the model on the "Download & import models" screen and '
            'download it again.'
      else if (modelErrors == 1)
        '1 of $total crop${total == 1 ? '' : 's'} could not be identified (the model stopped with an error). It is missing '
            'from the results. "$button" tries it again.'
      else if (modelErrors > 1)
        '$modelErrors of $total crops could not be identified (the model stopped with an error). They '
            'are missing from the results. "$button" tries them again.',
      if (r.unreadable == 1)
        '1 of $total crop${total == 1 ? '' : 's'} could not be identified because its photo could not be read (the file may be '
            'damaged). It is missing from the results.'
      else if (r.unreadable > 1)
        '${r.unreadable} of $total crops could not be identified because their photos could not be read '
            '(the files may be damaged). They are missing from the results.',
    ];
  }

  List<Widget> _completionSection() {
    final r = _result;
    final s = r?.summary;
    return [
      const Text('Last run', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 6),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      if (r != null) ...[
        if (r.cancelled)
          Text(
            'Cancelled (progress is kept). "${_hasEmbeddings ? 'Continue / re-run' : 'Start'}" goes on from here.',
            style: const TextStyle(color: Colors.amber),
          ),
        // The store does not count a failed crop as done (EmbeddingIndex.parse), so the next run
        // tries it again; without this line a run that lost its model looked finished.
        if (r.failed > 0 && !r.cancelled)
          for (final line in _failedLines(r)) Text(line, style: const TextStyle(color: Colors.redAccent)),
        Text(
          '${r.embedded} crop${r.embedded == 1 ? '' : 's'} identified now (${r.resumedDone} done earlier, '
          '${r.skipped} skipped, ${r.failed} failed, ${r.thermalPauses} heat pause${r.thermalPauses == 1 ? '' : 's'}) '
          'in ${_fmtDuration(_runTook ?? r.elapsed)}'
          '${r.embedded > 0 ? ' on the $_accelerator' : ''}.${_modelShare(r)}',
          style: const TextStyle(color: Colors.white),
        ),
        if (r.embedded > 0 && _accelNote != null)
          Text('GPU not used: ${gpuNoteText(_accelNote!)}', style: const TextStyle(color: Colors.amber, fontSize: 12)),
        if (s != null) ...[
          const SizedBox(height: 6),
          Text(trackSummaryLine(s), style: const TextStyle(color: Colors.white)),
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
      // Round 308: shared with the Identification card of the video settings.
      children: [IdentifySettingsFields(prefs: prefs, onEdit: _edit, onCropCountChanged: _plan)],
    );
  }
}

/// Round 319, part 3: the chained identification that Android ended while it waited for the app
/// or loaded in the background (its note, [IdentifyWaitNote]) starts again here, on its Identify
/// page, as the Find screens start it. For any other run that Android ended (round 320), or when
/// the app was closed during that start too, one line says how to continue. Nothing happens while
/// an identification goes on.
Future<void> resumeWaitingIdentification(BuildContext context) async {
  if (_resuming || IdentificationRun.busy) return;
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
  _resuming = true;
  try {
    final w = await IdentifyWaitNote.takeOnOpen();
    if (w == null || !context.mounted) return;
    if (!w.start) {
      final name = w.sessionDir.path.split('/').last;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'The identification of "$name" stopped when FaunaPulse was closed. To continue: on the Sessions '
            'screen, tap ⋮ next to this session, then "Identify organisms". It goes on where it stopped.',
          ),
          duration: const Duration(seconds: 10),
          showCloseIcon: true,
        ),
      );
      return;
    }
    IdentificationRun.autoStart(w.sessionDir, chain: w.chain, attempts: 1);
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => IdentificationScreen(sessionDir: w.sessionDir, autoStart: true)),
      ),
    );
  } finally {
    _resuming = false;
  }
}

bool _resuming = false;

/// Calls [resumeWaitingIdentification] once the first frame is shown and each time the app comes
/// to the front. Home holds one: it lies under every other page while the app runs.
class WaitingIdentificationWatch with WidgetsBindingObserver {
  WaitingIdentificationWatch(this._context);

  final BuildContext _context;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void stop() => WidgetsBinding.instance.removeObserver(this);

  void _check() {
    if (_context.mounted) unawaited(resumeWaitingIdentification(_context));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }
}

/// The "Last run" line of track IDs by rank, from the results summary. Round 319: with no
/// identified rank the old line read "0 track IDs: ." or "3 track IDs: , 3 unidentified.".
String trackSummaryLine(Map<String, dynamic> s) {
  final total = s['tracks_total'] ?? 0;
  final parts = [
    for (final e in ((s['by_identified_rank'] as Map?) ?? const {}).entries) '${e.value} to ${e.key}',
    if ((s['unidentified'] ?? 0) != 0) '${s['unidentified']} unidentified',
    if ((s['no_organism'] ?? 0) != 0) '${s['no_organism']} no organism',
  ];
  return '$total track ID${total == 1 ? '' : 's'}${parts.isEmpty ? '' : ': ${parts.join(', ')}'}.';
}

/// Plain-language error text (strips the "Exception: " prefix). Round 317:
/// only at the start: replaceFirst anywhere turned "FileSystemException: …"
/// into "FileSystem…".
String plainError(Object e) => '$e'.replaceFirst(RegExp('^Exception: '), '').replaceFirst('PlatformException', 'Error');
