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

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';
import '../models/model_catalog.dart';
import '../models/session_config.dart';
import '../postprocess/photo_keep.dart';
import '../postprocess/post_detector.dart';

/// One analyzable session folder: its name, folder, how many photos it holds
/// (companion `_live.jpg` duplicates already excluded), how many of those an
/// earlier run has already processed, and how the session captured its photos
/// ([live] — AI-free motion/time-lapse sessions are this screen's real target).
class _AnalyzableSession {
  final String name;
  final Directory dir;
  final int photoCount;
  final int doneCount;
  final LiveSessionInfo? live;
  const _AnalyzableSession(
    this.name,
    this.dir,
    this.photoCount,
    this.doneCount,
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
  bool _cleanupBusy = false;

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
  }

  /// (Re)parses the selected session's post_detections.jsonl so the cleanup
  /// section can size keep/delete counts. Null when there are no results yet.
  Future<void> _loadOutcomes() async {
    final session = _session;
    if (session == null || session.doneCount == 0) {
      setState(() => _outcomes = null);
      return;
    }
    List<PhotoOutcome>? outcomes;
    try {
      final f = File('${session.dir.path}/${PostDetector.outputFileName}');
      if (f.existsSync()) {
        // Only photos still on disk count — a previous cleanup's deleted
        // photos keep their records but must not skew the numbers.
        outcomes = photoOutcomesFromJsonl(await f.readAsString())
            .where(
              (o) => File(
                '${session.dir.path}/roi_frames/${o.name}',
              ).existsSync(),
            )
            .toList();
      }
    } catch (e) {
      logSwallowed('analysis_outcomes_load', e);
    }
    if (mounted) setState(() => _outcomes = outcomes);
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
            photos.length,
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
      _total = session.photoCount - session.doneCount;
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
      final detector = PostDetector(
        predict: (bytes) => yolo.predict(
          bytes,
          confidenceThreshold: _confidence,
          iouThreshold: _iou,
        ),
      );
      result = await detector.run(
        session.dir,
        config: PostRunConfig(
          modelPath: model.id,
          modelName: model.name,
          confidence: _confidence,
          iou: _iou,
          useGpu: appConfig.useGpu,
        ),
        appVersion: '${info.version}+${info.buildNumber}',
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
    final message = failure != null
        ? 'Analysis failed: $failure'
        : result!.cancelled
        ? 'Stopped — ${result.processed} photos analyzed (resumable).'
        : 'Done: ${result.processed} photos analyzed'
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analyze saved photos')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
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
              '${s.name} [${s.modeTag}] — ${s.photoCount} photos'
              '${s.doneCount > 0 ? ' (${s.doneCount} analyzed)' : ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _running
          ? null
          : (s) {
              setState(() => _session = s);
              _loadOutcomes();
            },
    );
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

  Widget _startButton() {
    final session = _session;
    final pending = session == null
        ? 0
        : session.photoCount - session.doneCount;
    final nothingToDo = session != null && pending == 0;
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
                ? 'All photos already analyzed'
                : sameModelAsLive
                ? 'Same model as the live session — pick another'
                : 'Analyze $pending photos',
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
    final outcomes = _outcomes;
    if (session == null || outcomes == null || outcomes.isEmpty) {
      return const SizedBox.shrink();
    }
    final keep = keepNames(outcomes, (_keepGap * 1000).round());
    final plan = planCleanup(session.dir, outcomes, keep);
    final withBoxes = outcomes.where((o) => o.hasBoxes == true).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Photo cleanup',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          'Of ${outcomes.length} analyzed photos, $withBoxes contain a '
          'detection; keeping those plus neighbours within '
          '${_keepGap.toStringAsFixed(1)} s = ${plan.keepCount} photos kept.',
          style: const TextStyle(fontSize: 13),
        ),
        Slider(
          value: _keepGap,
          min: 0,
          max: 10,
          divisions: 20,
          label: '${_keepGap.toStringAsFixed(1)} s',
          onChanged: _cleanupBusy
              ? null
              : (v) => setState(() => _keepGap = v),
          onChangeEnd: (v) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble(_prefKeepGap, v);
          },
        ),
        const Text(
          'Keep neighbours within this many seconds of a detection — bridges '
          'photos where the detector missed an insect that is still there.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
          onPressed: (plan.deleteNames.isEmpty || _cleanupBusy)
              ? null
              : () => _confirmCleanup(session, plan),
          icon: const Icon(Icons.delete_outline),
          label: Text(
            plan.deleteNames.isEmpty
                ? 'Nothing to delete'
                : 'Delete ${plan.deleteNames.length} photos '
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
          'This permanently deletes ${plan.deleteNames.length} photos '
          '(${formatBytes(plan.deleteBytes)}) from "${session.name}" — the '
          'ones with no detection and no detection nearby. '
          '${plan.keepCount} photos stay. The session log keeps its records; '
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
    final deleted = await runCleanup(session.dir, plan, gapSeconds: _keepGap);
    if (!mounted) return;
    setState(() => _cleanupBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $deleted photos.')),
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
          '$_done / $_total photos'
          '${_avgMs > 0 ? ' — ${_avgMs.round()} ms/photo, ${_eta()}' : ''}',
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
