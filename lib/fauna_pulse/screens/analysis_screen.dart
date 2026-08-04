// FaunaPulse — post-hoc analysis setup + progress screen (round 135).
//
// Reached from the home screen ("Analyze saved photos"): the user picks one
// recorded session, a detection model (any bundled/imported one — typically a
// higher-resolution model than the live default) and thresholds, then the
// photos in the session's `roi_frames/` run through the detector while a
// progress bar counts up. Results land in `post_detections.jsonl` inside the
// session folder (see postprocess/post_detector.dart, which also makes runs
// resumable after an interruption).
//
// Processing happens at full speed with no real-time constraint. The screen
// holds a wakelock (keeps the screen on) for the duration; long runs are best
// done indoors with the phone charging.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../capture/roi_capture.dart' show probeJpegSize;
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_catalog.dart';
import '../models/session_config.dart';
import '../postprocess/photo_keep.dart';
import '../postprocess/post_detector.dart';
import '../postprocess/sahi.dart';
import '../postprocess/sahi_profile.dart';
import '../widgets/duration_setting_field.dart';
import '../widgets/numeric_setting_field.dart';
import 'session_summary_screen.dart';

/// One analyzable session folder. Counts come in TWO units (round 172):
/// [photoCount]/[donePhotoCount] are PHOTOS (capture moments — a high-res
/// photo and its `_live.jpg` companion count as one, exactly like the session
/// summary's Photos tab), while [fileCount]/[doneFileCount] are the JPEG
/// FILES the analysis driver actually walks (both pair members are analyzed
/// since round 137). Labels must say which unit they show — a 63-photo
/// high-res session has 126 files, and displaying the file count as "photos"
/// was the round-172 owner-reported bug. [live] says how the session captured
/// its photos (AI-free motion/time-lapse sessions are this screen's target).
class _AnalyzableSession {
  final String name;
  final Directory dir;
  final int photoCount;
  final int fileCount;
  final int donePhotoCount;
  final int doneFileCount;
  final LiveSessionInfo? live;
  const _AnalyzableSession(
    this.name,
    this.dir,
    this.photoCount,
    this.fileCount,
    this.donePhotoCount,
    this.doneFileCount,
    this.live,
  );

  /// Short capture-mode tag for the session dropdown.
  String get modeTag => switch (live?.captureTrigger) {
    'motion' => 'motion',
    'timelapse' => 'time-lapse',
    'detector' => 'AI live',
    _ => '?',
  };
}

class AnalysisScreen extends StatefulWidget {
  /// Optional session folder to preselect (e.g. long-press on a home row).
  final String? initialSessionPath;

  const AnalysisScreen({super.key, this.initialSessionPath});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  // Last-used analysis settings, remembered app-wide (like the report email —
  // never part of SessionConfig: these describe a post-hoc job, not a session).
  static const _prefModel = 'analysis_model';
  static const _prefConf = 'analysis_confidence';
  static const _prefIou = 'analysis_iou';
  static const _prefKeepGap = 'analysis_keep_gap';
  static const _prefSahiEnabled = 'analysis_sahi_enabled';
  static const _prefSahiTilePx = 'analysis_sahi_tile_px';
  static const _prefSahiOverlapPct = 'analysis_sahi_overlap_pct';
  static const _prefSahiFullPass = 'analysis_sahi_full_pass';
  static const _prefSahiMergeIou = 'analysis_sahi_merge_iou';
  static const _prefSahiMinBoxPct = 'analysis_sahi_min_box_pct';

  bool _loading = true;
  List<_AnalyzableSession> _sessions = const [];
  List<ModelEntry> _models = const [];
  _AnalyzableSession? _session;
  ModelEntry? _model;
  double _confidence = 0.25;
  double _iou = 0.7;

  /// Cleanup: "keep neighbours within this many seconds of a detection".
  double _keepGap = 2.0;
  List<PhotoOutcome>? _outcomes;

  /// The `min_box_frac` the last analysis run itself filtered with (round
  /// 179): the live tiny-box slider below can only act ABOVE it, because
  /// smaller boxes were never recorded — the cleanup section hints when the
  /// slider is set below this. Null = no SAHI filter recorded.
  double? _lastRunMinBoxFrac;
  bool _cleanupBusy = false;

  // SAHI tiling (round 139) — all persisted except the per-run force flag.
  bool _sahiEnabled = false;
  int _sahiTilePx = 0; // 0 = auto (the model's own input size)
  double _sahiOverlapPct = 25;
  bool _sahiFullPass = true;
  double _sahiMergeIou = 0.5;
  double _sahiMinBoxPct = 0; // 0 = off; % of photo side, tile boxes only (r141)

  /// Per-run choice (deliberately not persisted): process photos that were
  /// already analyzed, so a session can be re-run with a different model or
  /// tiling settings — the newest record per photo wins downstream.
  bool _forceReanalyze = false;

  /// First-photo pixel size of the selected session (cached per folder) —
  /// feeds the tiling preview ("2×2 tiles + full frame = 5 passes").
  final Map<String, (int, int)?> _photoDimsCache = {};

  // Run state. [_cancelRequested] is polled between photos by the driver.
  bool _running = false;
  bool _cancelRequested = false;
  int _done = 0;
  int _total = 0;
  double _avgMs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // A popped screen can't show progress; stop the batch too.
    _cancelRequested = true;
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final models = await ModelCatalog.build();
    final sessions = await _scanSessions();
    if (!mounted) return;
    final savedModel = prefs.getString(_prefModel);
    setState(() {
      _sessions = sessions;
      _models = models;
      _confidence = prefs.getDouble(_prefConf) ?? 0.25;
      _iou = prefs.getDouble(_prefIou) ?? 0.7;
      _keepGap = prefs.getDouble(_prefKeepGap) ?? 2.0;
      _sahiEnabled = prefs.getBool(_prefSahiEnabled) ?? false;
      _sahiTilePx = prefs.getInt(_prefSahiTilePx) ?? 0;
      _sahiOverlapPct = prefs.getDouble(_prefSahiOverlapPct) ?? 25;
      _sahiFullPass = prefs.getBool(_prefSahiFullPass) ?? true;
      _sahiMergeIou = prefs.getDouble(_prefSahiMergeIou) ?? 0.5;
    _sahiMinBoxPct = prefs.getDouble(_prefSahiMinBoxPct) ?? 0;
      _model = models.where((m) => m.id == savedModel).firstOrNull ??
          models.firstOrNull;
      _session = widget.initialSessionPath != null
          ? sessions
                .where((s) => s.dir.path == widget.initialSessionPath)
                .firstOrNull
          : null;
      _loading = false;
    });
    _loadOutcomes();
    _loadPhotoDims();
  }

  /// Reads the selected session's first photo size (background isolate; the
  /// result is cached per folder) for the tiling preview line.
  Future<void> _loadPhotoDims() async {
    final session = _session;
    if (session == null || _photoDimsCache.containsKey(session.dir.path)) {
      if (mounted) setState(() {});
      return;
    }
    (int, int)? dims;
    try {
      final framesDir = Directory('${session.dir.path}/roi_frames');
      final first = framesDir.existsSync()
          ? framesDir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.toLowerCase().endsWith('.jpg'))
                .fold<File?>(
                  null,
                  (best, f) =>
                      best == null || f.path.compareTo(best.path) < 0 ? f : best,
                )
          : null;
      if (first != null) {
        dims = await probeJpegSize(await first.readAsBytes());
      }
    } catch (e) {
      logSwallowed('analysis_photo_dims', e);
    }
    _photoDimsCache[session.dir.path] = dims;
    if (mounted) setState(() {});
  }

  SahiOptions get _sahiOptions => SahiOptions(
    enabled: _sahiEnabled,
    tileSidePx: _sahiTilePx,
    overlapFrac: _sahiOverlapPct / 100,
    fullImagePass: _sahiFullPass,
    mergeIou: _sahiMergeIou,
    minBoxFrac: _sahiMinBoxPct / 100,
  );

  /// (Re)parses the selected session's post_detections.jsonl so the cleanup
  /// section can size keep/delete counts. Null when there are no results yet.
  Future<void> _loadOutcomes() async {
    final session = _session;
    if (session == null || session.doneFileCount == 0) {
      setState(() => _outcomes = null);
      return;
    }
    List<PhotoOutcome>? outcomes;
    double? lastRunMinBox;
    try {
      final f = File('${session.dir.path}/${PostDetector.outputFileName}');
      if (f.existsSync()) {
        final content = await f.readAsString();
        // Only photos still on disk count — a previous cleanup's deleted
        // photos keep their records but must not skew the numbers.
        outcomes = photoOutcomesFromJsonl(content)
            .where(
              (o) => File(
                '${session.dir.path}/roi_frames/${o.name}',
              ).existsSync(),
            )
            .toList();
        // Round 179: what the analysis itself already filtered out — the
        // live tiny-box slider can't go below this (boxes never recorded).
        lastRunMinBox = lastSahiMinBoxFrac(content);
      }
    } catch (e) {
      logSwallowed('analysis_outcomes_load', e);
    }
    if (mounted) {
      setState(() {
        _outcomes = outcomes;
        _lastRunMinBoxFrac = lastRunMinBox;
      });
    }
  }

  /// Same sessions folder the home screen lists, but with photo counts.
  Future<List<_AnalyzableSession>> _scanSessions() async {
    final found = <_AnalyzableSession>[];
    try {
      final base =
          (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/sessions');
      if (!await dir.exists()) return found;
      for (final entity in dir.listSync()) {
        if (entity is! Directory) continue;
        if (!File('${entity.path}/session.jsonl').existsSync()) continue;
        final framesDir = Directory('${entity.path}/roi_frames');
        final names = framesDir.existsSync()
            ? framesDir
                  .listSync()
                  .whereType<File>()
                  .map((f) => f.path.split('/').last)
                  .where((n) => n.toLowerCase().endsWith('.jpg'))
            : const Iterable<String>.empty();
        final photos = selectPhotoNames(names);
        final outFile = File(
          '${entity.path}/${PostDetector.outputFileName}',
        );
        final done = outFile.existsSync()
            ? processedNamesFromJsonl(await outFile.readAsString())
            : const <String>{};
        // The start record's config says how the photos were triggered and
        // which model the session had — only the log's head is read (cheap),
        // same trick as the home list.
        LiveSessionInfo? live;
        try {
          final raf = File('${entity.path}/session.jsonl').openSync();
          final head = utf8.decode(
            raf.readSync(8192),
            allowMalformed: true,
          );
          raf.closeSync();
          live = liveSessionInfoFromLogHead(head);
        } catch (e) {
          logSwallowed('analysis_session_head', e);
        }
        found.add(
          _AnalyzableSession(
            entity.path.split('/').last,
            entity,
            photoUnitCount(photos),
            photos.length,
            analyzedPhotoUnitCount(photos, done),
            photos.where(done.contains).length,
            live,
          ),
        );
      }
      // Newest first by folder modification time, like the home list feel.
      found.sort(
        (a, b) => b.dir
            .statSync()
            .modified
            .compareTo(a.dir.statSync().modified),
      );
    } catch (e) {
      logSwallowed('analysis_session_scan', e);
    }
    return found;
  }

  Future<void> _start() async {
    final session = _session;
    final model = _model;
    if (session == null || model == null || _running) return;

    // Remember the choices for next time.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefModel, model.id);
    await prefs.setDouble(_prefConf, _confidence);
    await prefs.setDouble(_prefIou, _iou);

    setState(() {
      _running = true;
      _cancelRequested = false;
      _done = 0;
      // FILE units: the driver walks every JPEG (both members of a high-res/
      // live pair), and its progress callback reports in the same unit.
      _total = _forceReanalyze
          ? session.fileCount
          : session.fileCount - session.doneFileCount;
      _avgMs = 0;
    });
    await WakelockPlus.enable();

    PostRunResult? result;
    String? failure;
    // The live screen's engine preference (GPU with CPU fallback) applies to
    // batch inference too.
    final appConfig = await SessionConfig.load();
    final yolo = YOLO(modelPath: model.id, useGpu: appConfig.useGpu);
    try {
      await yolo.loadModel();
      final info = await PackageInfo.fromPlatform();
      // Round 156 (perf review D3): the annotated JPEG the plugin renders per
      // predict call is never shown here (boxes are drawn from coordinates),
      // so skip its render + encode — once per photo, once per SAHI tile.
      Future<Map<String, dynamic>> base(Uint8List bytes) => yolo.predict(
            bytes,
            confidenceThreshold: _confidence,
            iouThreshold: _iou,
            includeAnnotatedImage: false,
          );
      // SAHI (round 139): tiling is a pure wrapper around the plain
      // predictor — the driver and all downstream logic see merged boxes.
      // The phase profile (round 168, perf review E6 step 1) collects where a
      // SAHI run's time goes; it is written into the post_end record.
      final modelInputPx = model.inputSize ?? 640;
      final profile = _sahiEnabled ? SahiPhaseProfile() : null;
      final detector = PostDetector(
        predict: _sahiEnabled
            ? sahiPredictFn(
                base: base,
                // Round 177 (perf review E6): the native one-call tiled path
                // (decode once, crop + infer per tile natively) replaces the
                // pure-Dart tile pipeline that measured 83-86% of a SAHI
                // run's wall time; sahiPredictFn falls back to the Dart path
                // automatically on any native failure.
                tiledPredict: (bytes, tiles, fullPass) => yolo.predictTiled(
                  bytes,
                  tiles: tiles,
                  fullPass: fullPass,
                  confidenceThreshold: _confidence,
                  iouThreshold: _iou,
                ),
                options: _sahiOptions,
                modelInputPx: modelInputPx,
                profile: profile,
              )
            : base,
      );
      result = await detector.run(
        session.dir,
        config: PostRunConfig(
          modelPath: model.id,
          modelName: model.name,
          confidence: _confidence,
          iou: _iou,
          useGpu: appConfig.useGpu,
          sahi: _sahiEnabled ? _sahiOptions.toJson(modelInputPx) : null,
        ),
        force: _forceReanalyze,
        appVersion: '${info.version}+${info.buildNumber}',
        phaseProfile: profile,
        isCancelled: () => _cancelRequested,
        onProgress: (done, total, avgMs) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _avgMs = avgMs;
          });
        },
      );
    } catch (e) {
      logSwallowed('analysis_run', e);
      failure = '$e';
    } finally {
      try {
        await yolo.dispose();
      } catch (e) {
        logSwallowed('analysis_yolo_dispose', e);
      }
      await WakelockPlus.disable();
    }

    if (!mounted) return;
    setState(() => _running = false);
    // The total wall time (round 168): shown here and logged as `elapsed_ms`
    // in the post_end record, so the user learns what a run of this session
    // costs — SAHI multiplies inferences per photo, and this is the honest
    // bottom line of that choice.
    final message = failure != null
        ? 'Analysis failed: $failure'
        : result!.cancelled
        ? 'Stopped — ${result.processed} files analyzed '
              'in ${_fmtElapsed(result.elapsed)} (resumable).'
        : 'Done: ${result.processed} files analyzed '
              'in ${_fmtElapsed(result.elapsed)}'
              '${result.failed > 0 ? ', ${result.failed} failed' : ''}'
              '${result.skippedDone > 0 ? ' (${result.skippedDone} were already done)' : ''}.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    // Refresh the per-session done counts.
    final sessions = await _scanSessions();
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _session = sessions
            .where((s) => s.dir.path == session.dir.path)
            .firstOrNull;
      });
      await _loadOutcomes();
    }
  }

  String _eta() {
    if (_avgMs <= 0 || _done == 0) return '…';
    final remaining = Duration(
      milliseconds: ((_total - _done) * _avgMs).round(),
    );
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return m > 0 ? '~$m min ${s.toString().padLeft(2, '0')} s left' : '~$s s left';
  }

  /// "2 h 5 min" / "3 min 07 s" / "42 s" — the finished run's wall time for
  /// the completion message (round 168).
  String _fmtElapsed(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes > 0) {
      return '${d.inMinutes} min ${(d.inSeconds % 60).toString().padLeft(2, '0')} s';
    }
    return '${d.inSeconds} s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyze saved photos')),
      // SafeArea: without it the list's last lines sit under the system
      // navigation/gesture bar and can never be scrolled into view.
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                const Text(
                  'Runs a detector over the photos a finished session saved — '
                  'no camera involved. A bigger model than the live one can be '
                  'used: there is no real-time limit, only processing time.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                _sessionPicker(),
                if (_detectorSessionNotice() case final notice?) ...[
                  const SizedBox(height: 10),
                  notice,
                ],
                const SizedBox(height: 12),
                _modelPicker(),
                const SizedBox(height: 12),
                _thresholdSlider(
                  label: 'Confidence threshold',
                  help: 'Minimum score for a detection to count.',
                  value: _confidence,
                  onChanged: (v) => setState(() => _confidence = v),
                ),
                _thresholdSlider(
                  label: 'IoU threshold',
                  help: 'Overlap level at which two boxes merge into one.',
                  value: _iou,
                  onChanged: (v) => setState(() => _iou = v),
                ),
                _sahiSection(),
                if (_session != null && _session!.doneFileCount > 0)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _forceReanalyze,
                    onChanged: _running
                        ? null
                        : (v) =>
                              setState(() => _forceReanalyze = v ?? false),
                    title: const Text(
                      'Re-analyze photos already done',
                      style: TextStyle(fontSize: 14),
                    ),
                    subtitle: const Text(
                      'Run every photo again — for trying another model or '
                      'tiling settings. The newest result per photo wins.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),
                if (_running) _progressPanel() else _startButton(),
                if (!_running && _outcomes != null) ...[
                  const SizedBox(height: 20),
                  _cleanupSection(),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Long runs: keep the phone charging and set it aside — '
                  'processing slows down if the phone is used meanwhile. '
                  'A stopped run resumes where it left off.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
      ),
    );
  }

  Widget _sessionPicker() {
    if (_sessions.isEmpty) {
      return const Text(
        'No recorded sessions with photos found.',
        style: TextStyle(color: Colors.white54),
      );
    }
    return DropdownButtonFormField<_AnalyzableSession>(
      initialValue: _session,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Session',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final s in _sessions)
          DropdownMenuItem(
            value: s,
            child: Text(
              // Photo units first (the same count the session summary shows);
              // the live-copy surplus is disclosed separately so the file
              // total stays explainable (round 172).
              '${s.name} [${s.modeTag}] — ${s.photoCount} photos'
              '${_sessionExtras(s)}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _running
          ? null
          : (s) {
              setState(() => _session = s);
              _loadOutcomes();
              _loadPhotoDims();
            },
    );
  }

  /// Parenthesized dropdown extras: "(+63 live copies)", "(12 analyzed)", or
  /// both joined with a comma. Empty for the common no-pair, nothing-done case.
  String _sessionExtras(_AnalyzableSession s) {
    final extras = <String>[
      if (s.fileCount != s.photoCount)
        '+${s.fileCount - s.photoCount} live copies',
      if (s.donePhotoCount > 0) '${s.donePhotoCount} analyzed',
    ];
    return extras.isEmpty ? '' : ' (${extras.join(', ')})';
  }

  /// Shown for sessions that already ran the detector live: re-analysis with
  /// the SAME model would only repeat what the session did, and better models
  /// are easier to run on a computer after copying the photos over USB.
  Widget? _detectorSessionNotice() {
    final live = _session?.live;
    if (live == null || !live.usedDetectorLive) return null;
    final sameModel = _model != null && _model!.id == live.modelPath;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'This session already ran AI live (model: '
        '${(live.modelPath ?? 'unknown').split('/').last}). Analyzing saved '
        'photos mainly helps motion / time-lapse sessions, where no AI ran '
        'during capture.'
        '${sameModel ? '\n\nRe-analysis with the SAME model is disabled — it would only repeat the live result. Pick a different model, or copy the photos to a computer for heavier processing.' : ''}',
        style: const TextStyle(fontSize: 12.5, color: Colors.white70),
      ),
    );
  }

  Widget _modelPicker() {
    return DropdownButtonFormField<ModelEntry>(
      initialValue: _model,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Detection model',
        border: OutlineInputBorder(),
        helperText:
            'Models are added under camera Settings → AI (Import… / Download…).',
        helperMaxLines: 2,
      ),
      items: [
        for (final m in _models)
          DropdownMenuItem(
            value: m,
            child: Text(m.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _running ? null : (m) => setState(() => _model = m),
    );
  }

  Widget _thresholdSlider({
    required String label,
    required String help,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(2)}'),
        Slider(
          value: value,
          min: 0.05,
          max: 0.95,
          divisions: 18,
          onChanged: _running ? null : onChanged,
        ),
        Text(help, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
      ],
    );
  }

  /// Advanced tiled-analysis (SAHI) section: master switch + every tiling
  /// parameter, with a live preview of the grid/cost for the selected
  /// session's photos. Persisted via `analysis_sahi_*` prefs.
  Widget _sahiSection() {
    Future<void> save() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSahiEnabled, _sahiEnabled);
      await prefs.setInt(_prefSahiTilePx, _sahiTilePx);
      await prefs.setDouble(_prefSahiOverlapPct, _sahiOverlapPct);
      await prefs.setBool(_prefSahiFullPass, _sahiFullPass);
      await prefs.setDouble(_prefSahiMergeIou, _sahiMergeIou);
      await prefs.setDouble(_prefSahiMinBoxPct, _sahiMinBoxPct);
    }

    final modelPx = _model?.inputSize ?? 640;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(
        'Small-insect tiling (SAHI)${_sahiEnabled ? ' — ON' : ''}',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: const Text(
        'Cuts each photo into overlapping tiles at model scale so tiny '
        'insects are not shrunk away. Slower; worth trying when the model '
        'input is much smaller than the photos.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _sahiEnabled,
          onChanged: _running
              ? null
              : (v) async {
                  setState(() => _sahiEnabled = v);
                  await save();
                },
          title: const Text(
            'Use tiled analysis',
            style: TextStyle(fontSize: 14),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            _sahiPreviewText(),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        NumericSettingField(
          label: 'Tile size',
          value: _sahiTilePx.toDouble(),
          min: 0,
          max: 2048,
          isInt: true,
          unitSuffix: 'px',
          helperText:
              '0 = automatic: the model\'s own input size (now $modelPx px). '
              'Larger tiles = fewer passes but more downscaling per tile.',
          onChanged: (v) async {
            setState(() => _sahiTilePx = v.round());
            await save();
          },
        ),
        const SizedBox(height: 8),
        NumericSettingField(
          label: 'Tile overlap',
          value: _sahiOverlapPct,
          min: 0,
          max: 50,
          isInt: true,
          unitSuffix: '%',
          helperText:
              'Neighbouring tiles share this much, so an insect on a tile '
              'border appears whole in one of them.',
          onChanged: (v) async {
            setState(() => _sahiOverlapPct = v);
            await save();
          },
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _sahiFullPass,
          onChanged: _running
              ? null
              : (v) async {
                  setState(() => _sahiFullPass = v);
                  await save();
                },
          title: const Text(
            'Also run the whole-photo pass',
            style: TextStyle(fontSize: 14),
          ),
          subtitle: const Text(
            'Catches insects larger than one tile (one extra inference).',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        NumericSettingField(
          label: 'Duplicate-merge overlap',
          value: _sahiMergeIou,
          min: 0.1,
          max: 0.9,
          decimals: 2,
          helperText:
              'Overlap level at which boxes from different tiles count as '
              'the SAME insect and merge. Measured against the smaller box, '
              'so a partial box sitting inside a bigger one merges away. '
              '0.5 is the standard.',
          onChanged: (v) async {
            setState(() => _sahiMergeIou = v);
            await save();
          },
        ),
        const SizedBox(height: 8),
        NumericSettingField(
          label: 'Ignore tiny tile boxes',
          value: _sahiMinBoxPct,
          min: 0,
          max: 20,
          decimals: 1,
          unitSuffix: '%',
          helperText:
              '0 = off. Ignores detections whose box is narrower than this '
              'percentage of the photo side in either direction — catches '
              'background specks and the thin sliver boxes tiling produces '
              'at tile borders. Since round 179 this also applies LIVE to '
              'existing results: after a run, move it and watch the cleanup '
              'numbers below re-derive instantly (no re-analysis). Tip: '
              'analyze with 0% so every box stays recorded and tunable.',
          onChanged: (v) async {
            setState(() => _sahiMinBoxPct = v);
            await save();
          },
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// "1024×1024 px photos, 640 px tiles, 25% overlap → 2×2 tiles + full
  /// frame = 5 passes" — recomputed from the selected session's first photo.
  String _sahiPreviewText() {
    final session = _session;
    final dims = session == null ? null : _photoDimsCache[session.dir.path];
    final tile = _sahiOptions.effectiveTileSide(_model?.inputSize ?? 640);
    if (dims == null) {
      return 'Photo size not read yet — the tile grid adapts to each photo '
          'automatically.';
    }
    final tiles = planTiles(dims.$1, dims.$2, tile, _sahiOverlapPct / 100);
    if (tiles.length <= 1) {
      return '${dims.$1}×${dims.$2} px photos fit in one $tile px tile — '
          'tiling adds nothing here; only the whole-photo pass would run.';
    }
    final cols = tiles.map((t) => t.left).toSet().length;
    final rows = tiles.map((t) => t.top).toSet().length;
    final passes = tiles.length + (_sahiFullPass ? 1 : 0);
    return '${dims.$1}×${dims.$2} px photos, $tile px tiles, '
        '${_sahiOverlapPct.round()}% overlap → $cols×$rows tiles'
        '${_sahiFullPass ? ' + whole photo' : ''} = $passes passes '
        '≈ $passes× processing time. Expect a few extra kept photos '
        '(better recall, slightly more false alarms — the safe direction '
        'for cleanup).';
  }

  Widget _startButton() {
    final session = _session;
    // Photo units on the button (matching the dropdown and the summary); the
    // file total is appended only when a session has live copies, so the
    // running panel's file-based progress stays explainable.
    final pending = session == null
        ? 0
        : _forceReanalyze
        ? session.photoCount
        : session.photoCount - session.donePhotoCount;
    final pendingFiles = session == null
        ? 0
        : _forceReanalyze
        ? session.fileCount
        : session.fileCount - session.doneFileCount;
    final filesSuffix = pendingFiles != pending ? ' ($pendingFiles files)' : '';
    final nothingToDo = session != null && pendingFiles == 0;
    // An AI-live session must not be re-run with the very model it already
    // used — that can only reproduce the live result.
    final sameModelAsLive =
        session != null &&
        (session.live?.usedDetectorLive ?? false) &&
        _model != null &&
        _model!.id == session.live!.modelPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed:
              (session == null || _model == null || nothingToDo || sameModelAsLive)
              ? null
              : _start,
          icon: const Icon(Icons.play_arrow),
          label: Text(
            session == null
                ? 'Pick a session to analyze'
                : nothingToDo
                ? 'All photos already analyzed (tick re-analyze to redo)'
                : sameModelAsLive
                ? 'Same model as the live session — pick another'
                : _forceReanalyze
                ? 'Re-analyze $pending photos$filesSuffix'
                : 'Analyze $pending photos$filesSuffix',
          ),
        ),
      ],
    );
  }

  /// Storage triage over the analysis results: keep photos with a detection
  /// (plus their close-in-time neighbours — a missed detection between two
  /// hits is most likely the same insect) and offer to delete the rest.
  Widget _cleanupSection() {
    final session = _session;
    final recorded = _outcomes;
    if (session == null || recorded == null || recorded.isEmpty) {
      return const SizedBox.shrink();
    }
    // Round 179 (owner idea): the "Ignore tiny tile boxes" threshold applies
    // LIVE over the recorded boxes — moving it re-derives every number and
    // the delete plan below instantly, a sensitivity analysis over one run
    // instead of a re-analysis per value. It can only act on recorded boxes:
    // when the analysis itself already filtered (hint below), lower values
    // change nothing. setState on the field triggers this rebuild.
    final outcomes = applyMinBoxFrac(recorded, _sahiMinBoxPct / 100);
    final keep = keepNames(outcomes, (_keepGap * 1000).round());
    final plan = planCleanup(session.dir, outcomes, keep);
    final withBoxes = outcomes.where((o) => o.hasBoxes == true).length;
    final kept = keep.length;
    final deleted = outcomes.length - kept;
    // Integer percents that provably sum to 100: one is rounded, the other
    // is its complement (never two independent roundings).
    final keptPct = outcomes.isEmpty ? 0 : (kept * 100 / outcomes.length).round();
    final deletedPct = 100 - keptPct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Photo cleanup',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          // File units throughout this section: the cleanup keeps/deletes
          // FILES (a high-res/live pair moves as one but counts as two files).
          'Of ${outcomes.length} analyzed files, $withBoxes contain a '
          'detection'
          '${_sahiMinBoxPct > 0 ? ' (ignoring boxes narrower than ${_sahiMinBoxPct.toStringAsFixed(1)}% of the photo)' : ''}'
          '. With a ${formatKeepWindow(_keepGap)} keep window: '
          '$kept kept ($keptPct%), $deleted deleted ($deletedPct%).',
          style: const TextStyle(fontSize: 13),
        ),
        // Round 179: values below what the analysis itself filtered with
        // cannot act — those boxes were never recorded.
        if (_lastRunMinBoxFrac case final rec?
            when rec > 0 && _sahiMinBoxPct / 100 < rec)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'The analysis itself already removed boxes narrower than '
              '${(rec * 100).toStringAsFixed(1)}% — to filter less than '
              'that, re-analyze with "Ignore tiny tile boxes" at 0%.',
              style: TextStyle(color: Colors.amber.shade200, fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        DurationSettingField(
          label: 'Keep time-window around a detection',
          valueSeconds: _keepGap,
          minSeconds: 0,
          maxSeconds: 3600,
          helperText:
              'Photos within this time of a detection are kept too — bridges '
              'photos where the detector missed an insect that is still '
              'there. Up to 60 minutes; type the number, pick s/min.',
          onChanged: (v) async {
            if (_cleanupBusy) return;
            setState(() => _keepGap = v);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble(_prefKeepGap, v);
          },
        ),
        const SizedBox(height: 10),
        // Review before deleting: the summary's Photos tab draws the post-hoc
        // boxes and marks the photos this cleanup would remove.
        OutlinedButton.icon(
          onPressed: _cleanupBusy
              ? null
              : () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SessionSummaryScreen(
                        logFile: File('${session.dir.path}/session.jsonl'),
                        initialTabIndex: 2, // Photos tab
                      ),
                    ),
                  );
                  // Photos can be deleted from the summary too — re-derive.
                  await _loadOutcomes();
                },
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Review photos before deleting'),
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
          onPressed: (plan.deleteNames.isEmpty || _cleanupBusy)
              ? null
              : () => _confirmCleanup(session, plan),
          icon: const Icon(Icons.delete_outline),
          label: Text(
            plan.deleteNames.isEmpty
                ? 'Nothing to delete'
                : 'Delete ${plan.deleteNames.length} files '
                      '(${formatBytes(plan.deleteBytes)})…',
          ),
        ),
      ],
    );
  }

  Future<void> _confirmCleanup(
    _AnalyzableSession session,
    CleanupPlan plan,
  ) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete photos without detections?'),
        content: Text(
          'This permanently deletes ${plan.deleteNames.length} files '
          '(${formatBytes(plan.deleteBytes)}) from "${session.name}" — the '
          'ones with no detection and no detection nearby. '
          '${plan.keepCount} files stay. The session log keeps its records; '
          'this cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete ${plan.deleteNames.length}',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _cleanupBusy = true);
    final deleted = await runCleanup(
      session.dir,
      plan,
      gapSeconds: _keepGap,
      minBoxFrac: _sahiMinBoxPct / 100,
    );
    if (!mounted) return;
    setState(() => _cleanupBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $deleted files.')),
    );
    // Photo counts changed; rescan and re-derive the cleanup numbers.
    final sessions = await _scanSessions();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _session = sessions
          .where((s) => s.dir.path == session.dir.path)
          .firstOrNull;
    });
    await _loadOutcomes();
  }

  Widget _progressPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: _total == 0 ? null : _done / _total,
          minHeight: 6,
        ),
        const SizedBox(height: 8),
        Text(
          // "files", not "photos": a high-res/live pair is two analyzed files
          // but one photo, and this counter walks files (round 172).
          '$_done / $_total files'
          '${_avgMs > 0 ? ' — ${_avgMs.round()} ms/file, ${_eta()}' : ''}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _cancelRequested
              ? null
              : () => setState(() => _cancelRequested = true),
          icon: const Icon(Icons.stop),
          label: Text(_cancelRequested ? 'Stopping…' : 'Stop'),
        ),
      ],
    );
  }
}
