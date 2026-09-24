// FaunaPulse (round 227): "Run AI on videos", the video twin of "Run AI on
// photos" (analysis_screen.dart).
//
// The user picks a session with clips in `videos/` (imported from the home
// ⋮ menu), a detection model, how many frames per second to look at and the
// area to analyze; the clips then run through the detector on the phone
// (postprocess/video_detector.dart) while a panel shows the clip, position,
// speed and battery temperature. Results go to `video_detections.jsonl` in
// the session folder; a stopped or killed run continues where it left off.
//
// Area to analyze: the whole picture, or a square placed on the first frame
// (the live camera's region of interest, same numbers). A smaller insect is
// shrunk less before the model sees it, so small insects stay visible. When
// a session's clips differ in size, the square keeps the same position and
// size relative to each clip's width.
//
// Visits (round 228): once clips are analyzed, "Find visits" links the boxes
// into visits (postprocess/video_tracker.dart) and writes visits.csv and
// MOT files; it runs by itself after a finished analysis and can be repeated
// with other tracking settings in seconds. "Share results" zips them.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart' show formatBytes;
import '../models/model_catalog.dart';
import '../models/roi.dart';
import '../models/session_config.dart';
import '../postprocess/video_detector.dart';
import '../postprocess/video_tracker.dart';
import '../tracking/tracker.dart';
import '../widgets/numeric_setting_field.dart';
import '../widgets/preview_transform.dart';
import '../widgets/roi_mask.dart';
import '../widgets/roi_overlay.dart';
import '../widgets/setting_help.dart';
import '../widgets/temperature_gauge.dart';

/// Persisted settings of the video analysis (shared_preferences
/// `video_analysis_*`, like `analysis_*` for photos; not SessionConfig,
/// which is a recording's own settings). The square is not here: it belongs
/// to one session's videos and is read back from that session's last run.
class VideoAnalysisPrefs {
  String? modelId;
  double confidence;
  double iou;
  double analysisFps;
  double thermalLimitC;

  /// Visit tracking (round 228): the live camera's two seconds-based
  /// settings, kept apart so trying other values on videos never changes
  /// the camera. Algorithm and fine-tuning are the camera's.
  double occlusionSeconds;
  double minVisitSeconds;

  VideoAnalysisPrefs({
    this.modelId,
    this.confidence = 0.25,
    this.iou = 0.7,
    this.analysisFps = 15,
    this.thermalLimitC = 40,
    this.occlusionSeconds = 3.0,
    this.minVisitSeconds = 0.2,
  });

  static const _kModel = 'video_analysis_model';
  static const _kConf = 'video_analysis_confidence';
  static const _kIou = 'video_analysis_iou';
  static const _kFps = 'video_analysis_fps';
  static const _kThermal = 'video_analysis_thermal_limit_c';
  static const _kOcclusion = 'video_analysis_occlusion_s';
  static const _kMinVisit = 'video_analysis_min_visit_s';

  static Future<VideoAnalysisPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    return VideoAnalysisPrefs(
      modelId: p.getString(_kModel),
      confidence: p.getDouble(_kConf) ?? 0.25,
      iou: p.getDouble(_kIou) ?? 0.7,
      analysisFps: p.getDouble(_kFps) ?? 15,
      thermalLimitC: p.getDouble(_kThermal) ?? 40,
      occlusionSeconds: p.getDouble(_kOcclusion) ?? 3.0,
      minVisitSeconds: p.getDouble(_kMinVisit) ?? 0.2,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    if (modelId != null) {
      await p.setString(_kModel, modelId!);
    } else {
      await p.remove(_kModel);
    }
    await p.setDouble(_kConf, confidence);
    await p.setDouble(_kIou, iou);
    await p.setDouble(_kFps, analysisFps);
    await p.setDouble(_kThermal, thermalLimitC);
    await p.setDouble(_kOcclusion, occlusionSeconds);
    await p.setDouble(_kMinVisit, minVisitSeconds);
  }
}

/// One session folder with clips, and how far its analysis got.
class _VideoSession {
  final String name;
  final Directory dir;

  /// Clip file names in the order the analysis walks them.
  final List<String> clips;
  final int totalBytes;

  /// Clip lengths from the session log's `video_clip` records.
  final Map<String, int> lengthsMs;
  final Set<String> doneClips;

  /// Settings of the last run, or null when none ran yet.
  final Map<String, dynamic>? lastSettings;

  /// `time_ms` of the detection run's first record (see
  /// [PostTrackSummary.detectionsRunMs]).
  final int? detectionsRunMs;

  /// The last "Find visits", or null.
  final PostTrackSummary? visits;

  const _VideoSession(
    this.name,
    this.dir,
    this.clips,
    this.totalBytes,
    this.lengthsMs,
    this.doneClips,
    this.lastSettings,
    this.detectionsRunMs,
    this.visits,
  );

  int get totalMs => clips.fold(0, (s, c) => s + (lengthsMs[c] ?? 0));
}

class VideoAnalysisScreen extends StatefulWidget {
  /// Session folder to preselect (the finished import, or a home row).
  final String? initialSessionPath;

  /// Tests replace the sessions folder and the model list.
  final Directory? sessionsDir;
  final List<ModelEntry>? models;

  const VideoAnalysisScreen({super.key, this.initialSessionPath, this.sessionsDir, this.models});

  @override
  State<VideoAnalysisScreen> createState() => _VideoAnalysisScreenState();
}

class _VideoAnalysisScreenState extends State<VideoAnalysisScreen> {
  bool _loading = true;
  List<_VideoSession> _sessions = const [];
  List<ModelEntry> _models = const [];
  _VideoSession? _session;
  ModelEntry? _model;
  VideoAnalysisPrefs _prefs = VideoAnalysisPrefs();
  bool _useGpu = true;

  /// The analysed square, or null for the whole picture.
  Roi? _roi;

  /// First frame of the selected session's first clip, for the square.
  ({Uint8List jpeg, int width, int height})? _frame;
  String? _framePath;

  bool _running = false;
  bool _cancelRequested = false;
  bool _tracking = false;

  /// The camera's tracking algorithm, which "Find visits" uses too.
  TrackerAlgorithm _algorithm = TrackerAlgorithm.bytetrack;
  VideoProgress? _progress;

  /// Lengths (ms) of the clips this run walks, in its order: the progress
  /// bar and time estimate weigh clips by length.
  List<int> _runLengthsMs = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // A popped screen can't show progress; stop the run too.
    _cancelRequested = true;
    if (_running) WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await VideoAnalysisPrefs.load();
    final models = widget.models ?? await ModelCatalog.build();
    final appConfig = await SessionConfig.load();
    final sessions = await _scanSessions();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _models = models;
      _useGpu = appConfig.useGpu;
      _algorithm = appConfig.trackerAlgorithm;
      _sessions = sessions;
      _model = models.where((m) => m.id == prefs.modelId).firstOrNull ?? models.firstOrNull;
      _loading = false;
    });
    final initial = sessions.where((s) => s.dir.path == widget.initialSessionPath).firstOrNull;
    if (initial != null) _select(initial);
  }

  Future<List<_VideoSession>> _scanSessions() async {
    final found = <_VideoSession>[];
    try {
      var dir = widget.sessionsDir;
      if (dir == null) {
        final base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
        dir = Directory('${base.path}/sessions');
      }
      if (!dir.existsSync()) return found;
      for (final entity in dir.listSync().whereType<Directory>()) {
        final files = VideoDetector.clipsOf(entity);
        if (files.isEmpty) continue;
        found.add(await _readSession(entity, files));
      }
      // Newest first by folder modification time, like the photo screen.
      found.sort((a, b) => b.dir.statSync().modified.compareTo(a.dir.statSync().modified));
    } catch (e) {
      logSwallowed('video_analysis_scan', e);
    }
    return found;
  }

  static Future<_VideoSession> _readSession(Directory dir, List<File> files) async {
    final lengths = <String, int>{};
    final log = File('${dir.path}/session.jsonl');
    if (log.existsSync()) {
      final lines = log.openRead().transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.contains('"video_clip"')) continue;
        try {
          final rec = jsonDecode(line) as Map;
          final file = rec['file'] as String?;
          final ms = (rec['duration_ms'] as num?)?.toInt();
          if (rec['type'] == 'video_clip' && file != null && ms != null) lengths[file.split('/').last] = ms;
        } catch (_) {}
      }
    }
    var resume = const VideoResume(null, {}, {});
    int? runMs;
    final out = File('${dir.path}/${VideoDetector.outputFileName}');
    if (out.existsSync()) {
      // Only the run and clip-done records matter here; skipping the many
      // detection lines keeps the list quick.
      final lines = await out
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.contains('"video_run_start"') || l.contains('"video_clip_done"'))
          .toList();
      resume = VideoResume.parse(lines);
      for (final l in lines.where((l) => l.contains('"video_run_start"')).take(1)) {
        try {
          runMs = ((jsonDecode(l) as Map)['time_ms'] as num?)?.toInt();
        } catch (_) {}
      }
    }
    return _VideoSession(
      dir.path.split('/').last,
      dir,
      [for (final f in files) f.path.split('/').last],
      files.fold(0, (s, f) => s + f.lengthSync()),
      lengths,
      resume.doneClips,
      resume.settings,
      runMs,
      await VideoTracker.readSummary(dir),
    );
  }

  /// Selects [s] and takes over its last run's square, so "Continue" works
  /// without placing the square again.
  void _select(_VideoSession s) {
    final roi = s.lastSettings?['roi'];
    setState(() {
      _session = s;
      _roi = roi is List && roi.length == 3
          ? Roi(
              centerX: (roi[0] as num).toDouble(),
              centerY: (roi[1] as num).toDouble(),
              sideFraction: (roi[2] as num).toDouble(),
            )
          : null;
    });
    if (_roi != null) _loadFrame();
  }

  /// The first clip's first frame (cached per session).
  Future<({Uint8List jpeg, int width, int height})?> _loadFrame() async {
    final s = _session;
    if (s == null) return null;
    if (_framePath == s.dir.path && _frame != null) return _frame;
    try {
      final path = '${s.dir.path}/videos/${s.clips.first}';
      final info = await VideoFrameSource.info(path);
      final jpeg = await VideoFrameSource.thumbnail(path);
      if (info.width <= 0 || info.height <= 0) throw StateError('unknown picture size');
      final frame = (jpeg: jpeg, width: info.width, height: info.height);
      if (mounted && _session == s) {
        setState(() {
          _frame = frame;
          _framePath = s.dir.path;
        });
      }
      return frame;
    } catch (e) {
      logSwallowed('video_analysis_frame', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not show the first frame: $e')));
      }
      return null;
    }
  }

  Future<void> _editSquare() async {
    final frame = await _loadFrame();
    if (frame == null || !mounted) return;
    final roi = await Navigator.of(context).push<Roi>(
      MaterialPageRoute(
        builder: (_) => VideoSquareEditor(
          frameJpeg: frame.jpeg,
          frameWidth: frame.width,
          frameHeight: frame.height,
          initial: _roi ?? Roi.defaultRoi,
        ),
      ),
    );
    if (roi != null && mounted) setState(() => _roi = roi);
  }

  VideoRunConfig? get _config {
    final model = _model;
    if (model == null) return null;
    final roi = _roi;
    return VideoRunConfig(
      modelPath: model.id,
      modelName: model.name,
      confidence: _prefs.confidence,
      iou: _prefs.iou,
      useGpu: _useGpu,
      analysisFps: _prefs.analysisFps,
      roi: roi == null ? null : [roi.centerX, roi.centerY, roi.sideFraction],
    );
  }

  /// Plain names of the settings that differ from the session's last run.
  List<String> _changedSettings(_VideoSession s, VideoRunConfig config) {
    final last = s.lastSettings;
    if (last == null) return const [];
    const names = {
      'model': 'model',
      'confidence': 'confidence threshold',
      'iou': 'IoU threshold',
      'analysis_fps': 'frames per second',
      'roi': 'area',
      'max_side_px': 'picture size',
    };
    return [
      for (final e in config.identity.entries)
        if (jsonEncode(last[e.key]) != jsonEncode(e.value)) names[e.key] ?? e.key,
    ];
  }

  Future<bool> _confirmStartOver(_VideoSession s, List<String> changed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace the earlier results?'),
        content: Text(
          'These videos were analyzed before with other settings'
          '${changed.isEmpty ? '' : ' (changed: ${changed.join(', ')})'}. '
          'Results from two settings cannot be mixed, so analyzing again replaces the earlier ones '
          '(${s.doneClips.length} of ${s.clips.length} clips were finished).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Replace and start')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _start({bool startOver = false}) async {
    final session = _session;
    final config = _config;
    if (session == null || config == null || _running) return;
    final changed = _changedSettings(session, config);
    if (!startOver && changed.isNotEmpty) {
      if (!await _confirmStartOver(session, changed)) return;
      startOver = true;
    }
    _prefs.modelId = config.modelPath;
    await _prefs.save();

    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      _runLengthsMs = [
        for (final c in session.clips)
          if (startOver || !session.doneClips.contains(c)) session.lengthsMs[c] ?? 0,
      ];
    });
    await WakelockPlus.enable();

    VideoRunResult? result;
    String? failure;
    var askStartOver = false;
    final yolo = YOLO(modelPath: config.modelPath, task: YOLOTask.detect, useGpu: config.useGpu, useMultiInstance: true);
    try {
      await yolo.loadModel();
      var appVersion = '';
      try {
        final info = await PackageInfo.fromPlatform();
        appVersion = '${info.version}+${info.buildNumber}';
      } catch (e) {
        logSwallowed('video_analysis_app_info', e);
      }
      result = await VideoDetector(backend: NativeVideoBackend(yolo.instanceId)).run(
        session.dir,
        config: config,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        isCancelled: () => _cancelRequested,
        thermalLimitC: _prefs.thermalLimitC,
        appVersion: appVersion,
        startOver: startOver,
      );
    } on VideoSettingsChanged {
      // The file changed since the list was read; ask, then run again.
      askStartOver = true;
    } catch (e) {
      logSwallowed('video_analysis_run', e);
      failure = '$e';
    } finally {
      try {
        await yolo.dispose();
      } catch (e) {
        logSwallowed('video_analysis_yolo_dispose', e);
      }
      await WakelockPlus.disable();
    }

    if (!mounted) return;
    setState(() => _running = false);
    if (askStartOver) {
      if (await _confirmStartOver(session, const [])) await _start(startOver: true);
      return;
    }
    var message = failure != null
        ? 'Analysis failed: $failure'
        : result!.cancelled
        ? 'Stopped after ${result.framesAnalysed} frames in ${_fmtElapsed(result.elapsed)}; '
              'Continue picks up from there.'
        : 'Done: ${result.clipsDone} ${result.clipsDone == 1 ? 'clip' : 'clips'}, '
              '${result.framesAnalysed} frames in ${_fmtElapsed(result.elapsed)}'
              '${result.thermalPauses > 0 ? ', ${result.thermalPauses} heat pauses' : ''}'
              '${result.clipsFailed > 0 ? '. ${result.clipsFailed} could not be read; Continue tries them again' : ''}.';
    // Boxes alone are not visits yet: link them right away (seconds).
    if (failure == null && !result!.cancelled && result.clipsDone > 0) {
      message = '$message ${await _findVisits(session)}';
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh(session);
  }

  Future<void> _refresh(_VideoSession session) async {
    final sessions = await _scanSessions();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _session = sessions.where((s) => s.dir.path == session.dir.path).firstOrNull;
    });
  }

  /// Links the analyzed boxes of [session] into visits, off the screen's
  /// thread so it stays responsive. Returns the outcome in words.
  Future<String> _findVisits(_VideoSession session) async {
    setState(() => _tracking = true);
    await _prefs.save();
    String message;
    try {
      final config = (await SessionConfig.load()).copyWith(
        occlusionSeconds: _prefs.occlusionSeconds,
        minHitsSeconds: _prefs.minVisitSeconds,
      );
      final r = await _trackInBackground(session.dir.path, config);
      message =
          'Found ${r.visits} ${r.visits == 1 ? 'visit' : 'visits'} in ${r.clipsTracked} '
          '${r.clipsTracked == 1 ? 'clip' : 'clips'}.';
    } catch (e) {
      logSwallowed('video_find_visits', e);
      message = 'Finding visits failed: ${e is StateError ? e.message : e}';
    }
    if (mounted) setState(() => _tracking = false);
    return message;
  }

  Future<void> _onFindVisits() async {
    final s = _session;
    if (s == null || _running || _tracking) return;
    final message = await _findVisits(s);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh(s);
  }

  Future<void> _shareResults(_VideoSession s) async {
    final tmp = await getTemporaryDirectory();
    final path = await _zipInBackground(s.dir.path, '${tmp.path}/${s.name}_video_results.zip');
    if (!mounted) return;
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not pack the results.')));
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }

  // Static, so the background isolate carries only the path and settings.
  static Future<VideoTrackResult> _trackInBackground(String path, SessionConfig config) =>
      Isolate.run(() => VideoTracker.run(Directory(path), config));
  static Future<String?> _zipInBackground(String dir, String zip) =>
      Isolate.run(() => VideoTracker.writeResultsZip(dir, zip));

  /// Share of the run done, weighing clips by length.
  double? get _fraction {
    final p = _progress;
    if (p == null || p.clipCount == 0) return null;
    final total = _runLengthsMs.fold(0, (s, v) => s + v);
    if (total <= 0 || _runLengthsMs.length != p.clipCount) {
      final inClip = p.clipLengthS > 0 ? (p.clipPosS / p.clipLengthS).clamp(0.0, 1.0) : 0.0;
      return ((p.clipIndex + inClip) / p.clipCount).clamp(0.0, 1.0);
    }
    final before = _runLengthsMs.take(p.clipIndex).fold(0, (s, v) => s + v);
    return ((before + p.clipPosS * 1000) / total).clamp(0.0, 1.0);
  }

  String _eta() {
    final p = _progress;
    final f = _fraction;
    if (p == null || f == null || p.msPerFrame <= 0) return '';
    final totalS = _runLengthsMs.fold(0, (s, v) => s + v) / 1000;
    final leftS = totalS * (1 - f);
    // Phone videos rarely have more than 30 frames per second.
    final frames = leftS * min(_prefs.analysisFps, 30);
    final left = Duration(milliseconds: (frames * p.msPerFrame).round());
    return left.inMinutes > 0 ? ', ~${_fmtElapsed(left)} left' : ', ~${left.inSeconds} s left';
  }

  /// "2 h 5 min" / "3 min 07 s" / "42 s".
  static String _fmtElapsed(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes > 0) return '${d.inMinutes} min ${(d.inSeconds % 60).toString().padLeft(2, '0')} s';
    return '${d.inSeconds} s';
  }

  static String _mmss(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run AI on videos')),
      // SafeArea: without it the list's last lines sit under the system
      // navigation bar and can never be scrolled into view.
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  const HelpLabel(
                    label: 'Runs a detector over a session\'s videos, frame by frame (no camera involved).',
                    labelStyle: TextStyle(color: Colors.white70, fontSize: 13),
                    helperText:
                        'For videos imported from the home screen\'s ⋮ menu. There is no real-time limit, '
                        'so a bigger model than the live one can be used; it only takes longer.',
                  ),
                  const SizedBox(height: 16),
                  _sessionPicker(),
                  const SizedBox(height: 12),
                  _modelPicker(),
                  const SizedBox(height: 12),
                  _slider(
                    label: 'Confidence threshold: ${_prefs.confidence.toStringAsFixed(2)}',
                    help: 'Minimum score for a detection to count. 0.25 is the live camera\'s default.',
                    value: _prefs.confidence,
                    min: 0.05,
                    max: 0.95,
                    divisions: 18,
                    onChanged: (v) => setState(() => _prefs.confidence = double.parse(v.toStringAsFixed(2))),
                  ),
                  _slider(
                    label: 'Frames analyzed per second: ${_prefs.analysisFps.round()}',
                    help:
                        'How many pictures of each video second the AI looks at. 15 is what the live camera '
                        'analyzes, so results compare with live sessions. Fewer is faster, but an insect can '
                        'move far between two looks and be missed or counted twice. Most phone videos have '
                        '30 per second; asking for more than the video has changes nothing.',
                    value: _prefs.analysisFps,
                    min: 1,
                    max: 30,
                    divisions: 29,
                    onChanged: (v) => setState(() => _prefs.analysisFps = v.roundToDouble()),
                  ),
                  if (_session case final s? when s.totalMs > 0)
                    Text(
                      'About ${(s.totalMs / 1000 * min(_prefs.analysisFps, 30)).round()} frames for this session.',
                      style: helperTextStyle,
                    ),
                  const SizedBox(height: 12),
                  _areaSection(),
                  const SizedBox(height: 8),
                  FoldSection(
                    title: 'Advanced settings',
                    children: [
                      _slider(
                        label: 'IoU threshold: ${_prefs.iou.toStringAsFixed(2)}',
                        help: 'Overlap level at which two boxes merge into one. 0.7 is the live camera\'s default.',
                        value: _prefs.iou,
                        min: 0.05,
                        max: 0.95,
                        divisions: 18,
                        onChanged: (v) => setState(() => _prefs.iou = double.parse(v.toStringAsFixed(2))),
                      ),
                      NumericSettingField(
                        label: 'Pause above battery temperature',
                        value: _prefs.thermalLimitC,
                        min: 35,
                        max: 45,
                        decimals: 0,
                        unitSuffix: '°C',
                        onChanged: (v) {
                          setState(() => _prefs.thermalLimitC = v);
                          _prefs.save();
                        },
                        helperText:
                            'The run pauses when the battery reaches this and resumes 3 °C lower. A hot battery '
                            'ages faster, and a hot phone slows itself down anyway.',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_running) _progressPanel() else _startButton(),
                  const SizedBox(height: 12),
                  const Text(
                    'Long runs: keep the phone charging and set it aside; processing slows down if the '
                    'phone is used meanwhile. A stopped run continues where it left off.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  _visitsSection(),
                ],
              ),
      ),
    );
  }

  Widget _sessionPicker() {
    if (_sessions.isEmpty) {
      return const Text(
        'No sessions with videos yet. Import videos from the home screen\'s ⋮ menu.',
        style: TextStyle(color: Colors.white54),
      );
    }
    return DropdownButtonFormField<_VideoSession>(
      initialValue: _session,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Session', border: OutlineInputBorder()),
      items: [
        for (final s in _sessions)
          DropdownMenuItem(
            value: s,
            child: Text(
              '${s.name} (${s.clips.length} ${s.clips.length == 1 ? 'clip' : 'clips'}, '
              '${s.totalMs > 0 ? '${_fmtElapsed(Duration(milliseconds: s.totalMs))}, ' : ''}'
              '${formatBytes(s.totalBytes)}'
              '${s.doneClips.isNotEmpty ? ', ${s.doneClips.length} analyzed' : ''})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _running ? null : (s) => s == null ? null : _select(s),
    );
  }

  Widget _modelPicker() {
    return DropdownButtonFormField<ModelEntry>(
      initialValue: _model,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Detection model',
        border: OutlineInputBorder(),
        helperText: 'Models are added under camera Settings → AI (Import… / Download…).',
        helperMaxLines: 2,
      ),
      items: [
        for (final m in _models) DropdownMenuItem(value: m, child: Text(m.label, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: _running ? null : (m) => setState(() => _model = m),
    );
  }

  Widget _slider({
    required String label,
    required String help,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HelpLabel(label: label, labelStyle: const TextStyle(color: Colors.white), helperText: help),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: _running ? null : onChanged),
      ],
    );
  }

  Widget _areaSection() {
    final roi = _roi;
    final frame = _frame != null && _framePath == _session?.dir.path ? _frame : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HelpLabel(
          label: 'Area to analyze',
          labelStyle: TextStyle(color: Colors.white),
          helperText:
              'The whole picture suits videos filmed close to the flowers. If the flowers fill only part '
              'of the picture, place a square around them: insects outside it are ignored, and small '
              'insects are found more easily '
        ),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Whole picture')),
            ButtonSegment(value: true, label: Text('A square')),
          ],
          selected: {roi != null},
          onSelectionChanged: _running || _session == null
              ? null
              : (s) => s.first ? _editSquare() : setState(() => _roi = null),
        ),
        if (roi != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (frame != null)
                SizedBox(
                  height: 90,
                  child: AspectRatio(
                    aspectRatio: frame.width / frame.height,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(frame.jpeg, fit: BoxFit.fill, gaplessPlayback: true),
                        RoiMask(roi: roi, frameAspect: frame.width / frame.height),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  frame == null
                      ? 'Square of ${(roi.sideFraction * 100).round()}% of the picture width.'
                      : 'Square of ${snapToMultipleOf32(roi.sideFraction * frame.width)} × '
                            '${snapToMultipleOf32(roi.sideFraction * frame.width)} px.',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(onPressed: _running ? null : _editSquare, child: const Text('Change…')),
            ],
          ),
        ],
      ],
    );
  }

  Widget _startButton() {
    final s = _session;
    final config = _config;
    final changed = s == null || config == null ? const <String>[] : _changedSettings(s, config);
    final pending = s == null ? 0 : s.clips.where((c) => !s.doneClips.contains(c)).length;
    final allDone = s != null && pending == 0 && changed.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: s == null || config == null || allDone ? null : _start,
          icon: const Icon(Icons.play_arrow),
          label: Text(
            s == null
                ? 'Pick a session to analyze'
                : allDone
                ? 'All clips analyzed with these settings'
                : changed.isNotEmpty
                ? 'Analyze again with these settings'
                : s.doneClips.isNotEmpty
                ? 'Continue ($pending of ${s.clips.length} clips left)'
                : 'Analyze ${s.clips.length} ${s.clips.length == 1 ? 'clip' : 'clips'}',
          ),
        ),
        if (s != null && s.doneClips.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Text(
            'The boxes found are saved in the session folder (video_detections.jsonl).',
            style: helperTextStyle,
          ),
        ],
      ],
    );
  }

  /// "Visits": tracking settings, Find visits, the last result and Share.
  /// Shown once at least one clip is analyzed.
  Widget _visitsSection() {
    final s = _session;
    if (s == null || s.doneClips.isEmpty) return const SizedBox.shrink();
    final v = s.visits;
    final busy = _running || _tracking;
    final stale = v != null &&
        (v.detectionsRunMs != s.detectionsRunMs ||
            v.clips.length != s.doneClips.length ||
            !v.clips.every(s.doneClips.contains));
    final changed = v != null &&
        (v.occlusionSeconds != _prefs.occlusionSeconds ||
            v.minHitsSeconds != _prefs.minVisitSeconds ||
            v.algorithm != _algorithm.name);
    const amber = TextStyle(color: Colors.amber, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        const HelpLabel(
          label: 'Visits',
          labelStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          helperText:
              'Follows each insect from frame to frame, as the live camera does, so one insect seen in '
              'many frames counts as one visit. Takes seconds and can be repeated with other settings '
              'without analyzing the videos again.',
        ),
        const SizedBox(height: 8),
        NumericSettingField(
          label: 'Occlusion tolerance',
          value: _prefs.occlusionSeconds,
          min: 0.2,
          max: 10,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect can vanish (e.g. behind a petal) and keep its number. Longer: fewer '
              'visits split in two; too long: two visitors can merge into one. Keep it well above the '
              'time between two analyzed frames. Default 3 s, as on the live camera.',
          onChanged: (x) {
            setState(() => _prefs.occlusionSeconds = x);
            _prefs.save();
          },
        ),
        NumericSettingField(
          label: 'Minimum visit length',
          value: _prefs.minVisitSeconds,
          min: 0,
          max: 2,
          decimals: 1,
          unitSuffix: 's',
          helperText:
              'How long an insect must be seen before it counts as a visit; shorter sightings are '
              'dropped as noise. Default 0.2 s, as on the live camera.',
          onChanged: (x) {
            setState(() => _prefs.minVisitSeconds = x);
            _prefs.save();
          },
        ),
        Text(
          'Tracking method: ${_algorithm == TrackerAlgorithm.cbiou ? 'C-BIoU' : 'ByteTrack'}, chosen under '
          'camera Settings → AI → Visit tracking → Advanced.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: busy ? null : _onFindVisits,
          icon: const Icon(Icons.timeline),
          label: Text(_tracking ? 'Finding visits…' : v == null ? 'Find visits' : 'Find visits again'),
        ),
        if (v != null) ...[
          const SizedBox(height: 8),
          Text(
            '${v.visits} ${v.visits == 1 ? 'visit' : 'visits'} in ${v.clips.length} of ${s.clips.length} clips '
            '(occlusion tolerance ${v.occlusionSeconds.toStringAsFixed(1)} s, minimum visit '
            '${v.minHitsSeconds.toStringAsFixed(1)} s).',
          ),
          if (stale)
            const Text('The videos were analyzed further or again since: find visits again to include that.', style: amber)
          else if (changed)
            const Text('Settings changed: find visits again to use them.', style: amber),
          const SizedBox(height: 4),
          const Text(
            'Saved in the session folder: visits.csv (one row per visit), mot/ (every box, for annotation '
            'tools) and post_tracks.jsonl.',
            style: helperTextStyle,
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _shareResults(s),
            icon: const Icon(Icons.share),
            label: const Text('Share results'),
          ),
        ],
      ],
    );
  }

  Widget _progressPanel() {
    final p = _progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: _fraction, minHeight: 6),
        const SizedBox(height: 8),
        if (p == null)
          const Text('Loading the model…', textAlign: TextAlign.center)
        else ...[
          Text('Clip ${p.clipIndex + 1} of ${p.clipCount}: ${p.clip}', overflow: TextOverflow.ellipsis),
          Text(
            '${_mmss(p.clipPosS)} of ${_mmss(p.clipLengthS)} · ${p.framesAnalysed} frames'
            '${p.msPerFrame > 0 ? ' · ${p.msPerFrame.round()} ms per frame${_eta()}' : ''}',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          if (p.note.isNotEmpty) Text('Paused: ${p.note}', style: const TextStyle(color: Colors.amber, fontSize: 13)),
          if (p.tempC != null)
            ...temperatureGauge(p.tempC!, _prefs.thermalLimitC, paused: p.note.isNotEmpty, limitWhere: 'under Advanced settings'),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
          icon: const Icon(Icons.stop),
          label: Text(_cancelRequested ? 'Stopping…' : 'Stop'),
        ),
      ],
    );
  }
}

/// Full-screen page to place the analysed square on a video's first frame.
/// Pops the chosen [Roi] with its side snapped to a multiple of 32 video
/// pixels (as the live camera's square), or null when left with Back.
class VideoSquareEditor extends StatefulWidget {
  final Uint8List frameJpeg;

  /// Upright size of the video in pixels.
  final int frameWidth;
  final int frameHeight;
  final Roi initial;

  const VideoSquareEditor({
    super.key,
    required this.frameJpeg,
    required this.frameWidth,
    required this.frameHeight,
    required this.initial,
  });

  @override
  State<VideoSquareEditor> createState() => _VideoSquareEditorState();
}

class _VideoSquareEditorState extends State<VideoSquareEditor> {
  late Roi _roi = widget.initial.copyClamped(frameAspect: _aspect);

  double get _aspect => widget.frameWidth / widget.frameHeight;

  /// Largest square that fits the picture, and the smallest the box allows
  /// (5% of the width), both on the 32-pixel grid.
  int get _maxPx => max(32, min(widget.frameWidth, widget.frameHeight) ~/ 32 * 32);
  int get _minPx => min(_maxPx, max(32, (0.05 * widget.frameWidth / 32).ceil() * 32));
  int get _sidePx => snapToMultipleOf32(_roi.sideFraction * widget.frameWidth).clamp(_minPx, _maxPx);

  @override
  Widget build(BuildContext context) {
    final steps = (_maxPx - _minPx) ~/ 32;
    return Scaffold(
      appBar: AppBar(title: const Text('Area to analyze')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  final picture = PreviewTransform(
                    widget: Size(c.maxWidth, c.maxHeight),
                    frameAspect: _aspect,
                  ).rectToScreen(const Rect.fromLTRB(0, 0, 1, 1));
                  return Stack(
                    children: [
                      Positioned.fromRect(
                        rect: picture,
                        child: Image.memory(widget.frameJpeg, fit: BoxFit.fill, gaplessPlayback: true),
                      ),
                      Positioned.fill(child: RoiMask(roi: _roi, frameAspect: _aspect)),
                      Positioned.fill(
                        child: RoiOverlay(
                          roi: _roi,
                          frameAspect: _aspect,
                          onChanged: (r) => setState(() => _roi = r),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Square: $_sidePx × $_sidePx px of the ${widget.frameWidth} × ${widget.frameHeight} video',
                    textAlign: TextAlign.center,
                  ),
                  if (steps > 0)
                    Slider(
                      value: _sidePx.toDouble(),
                      min: _minPx.toDouble(),
                      max: _maxPx.toDouble(),
                      divisions: steps,
                      onChanged: (v) => setState(
                        () => _roi = _roi.copyClamped(sideFraction: v / widget.frameWidth, frameAspect: _aspect),
                      ),
                    ),
                  const Text(
                    'Drag the square onto the flowers; pinch or use the slider to resize. The first frame '
                    'of the first clip is shown.',
                    style: helperTextStyle,
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      _roi.snapSideToGrid(sourceWidth: widget.frameWidth, maxSidePx: _maxPx, frameAspect: _aspect),
                    ),
                    child: const Text('Use this square'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
