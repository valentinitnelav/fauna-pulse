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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';
import '../models/model_catalog.dart';
import '../models/session_config.dart';
import '../postprocess/post_detector.dart';

/// One analyzable session folder: its name, folder, how many photos it holds
/// (companion `_live.jpg` duplicates already excluded) and how many of those
/// an earlier run has already processed.
class _AnalyzableSession {
  final String name;
  final Directory dir;
  final int photoCount;
  final int doneCount;
  const _AnalyzableSession(this.name, this.dir, this.photoCount, this.doneCount);
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

  bool _loading = true;
  List<_AnalyzableSession> _sessions = const [];
  List<ModelEntry> _models = const [];
  _AnalyzableSession? _session;
  ModelEntry? _model;
  double _confidence = 0.25;
  double _iou = 0.7;

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
      _model = models.where((m) => m.id == savedModel).firstOrNull ??
          models.firstOrNull;
      _session = widget.initialSessionPath != null
          ? sessions
                .where((s) => s.dir.path == widget.initialSessionPath)
                .firstOrNull
          : null;
      _loading = false;
    });
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
        found.add(
          _AnalyzableSession(
            entity.path.split('/').last,
            entity,
            photos.length,
            photos.where(done.contains).length,
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
              '${s.name} — ${s.photoCount} photos'
              '${s.doneCount > 0 ? ' (${s.doneCount} analyzed)' : ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _running ? null : (s) => setState(() => _session = s),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: (session == null || _model == null || nothingToDo)
              ? null
              : _start,
          icon: const Icon(Icons.play_arrow),
          label: Text(
            session == null
                ? 'Pick a session to analyze'
                : nothingToDo
                ? 'All photos already analyzed'
                : 'Analyze $pending photos',
          ),
        ),
      ],
    );
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
