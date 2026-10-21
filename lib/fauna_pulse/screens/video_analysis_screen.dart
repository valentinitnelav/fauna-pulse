// FaunaPulse (round 227): "Run AI on videos", the video twin of "Run AI on
// photos" (analysis_screen.dart).
//
// The user picks a session with clips in `videos/` (imported with "Import
// videos…", on this screen since round 277), a detection model, how many frames per second to look at and the
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
//
// Kept frames (round 234): "Find visits" also picks frames to keep for each
// visit (the first, then one every N s for up to M s: the live camera's
// photo rule) and the phone saves them from the clips into roi_frames/
// (postprocess/video_frame_keeper.dart), so the session's Video tab shows
// them and identification can run on them. Round 235: how many are saved
// (and their size) is read for the selected session only.
//
// Free storage (round 236): once the visits are found, the clips without any
// visit, or all clips, can be deleted (postprocess/clip_cleanup.dart). The
// session stays on this screen: "Find visits" still runs from the saved
// boxes, only analyzing a deleted clip again is not possible.
//
// Round 308 (owner): every number to tune (detection, track IDs, and the
// identification when "Also identify them" is on) sits on its own screen,
// "Detection, track ID and identification settings" (video_tuning_screen.dart),
// reachable before the first run; the tracker settings there are the
// videos' own, apart from the camera's. One main button does what is due:
// analyze, else find the track IDs again, else identify.
//
// Round 309 (owner): under the track ID results the videos play with their
// boxes and track IDs (widgets/video_review_player.dart, as on the session's
// Video tab), to judge a run before changing the settings and running again.
// The player is left out while the screen is busy, so it never plays while
// the detector or the frame saving reads the videos.

import 'dart:async';
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
import 'package:video_player/video_player.dart';

import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart' show formatBytes;
import '../logging/past_sessions.dart' show sessionsRoot;
import '../identification/identification_choice.dart';
import '../models/model_catalog.dart';
import '../models/model_choice_keys.dart';
import '../models/roi.dart';
import '../models/session_config.dart';
import '../postprocess/clip_cleanup.dart';
import '../postprocess/video_detector.dart';
import '../postprocess/video_frame_keeper.dart';
import '../postprocess/video_tracker.dart';
import '../tracking/byte_track.dart';
import '../tracking/c_biou_track.dart';
import '../tracking/tracker.dart';
import '../widgets/preview_transform.dart';
import '../widgets/roi_mask.dart';
import '../widgets/roi_overlay.dart';
import '../widgets/screen_on.dart';
import '../widgets/setting_help.dart';
import '../widgets/temperature_gauge.dart';
import '../widgets/video_review_player.dart';
import '../widgets/video_speed_chips.dart';
import '../widgets/video_timeline_bar.dart';
import '../widgets/home_button.dart';
import '../widgets/dialog_title.dart';
import '../logging/thermal_pause.dart' show kDefaultPauseTempC;
import 'identification_choice_fields.dart';
import 'identification_screen.dart';
import 'models_screen.dart';
import 'video_import_screen.dart' show pickAndImportVideos;
import 'video_tuning_screen.dart';

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
  /// the camera. Minimum track length 1 s since round 256 (was the camera's
  /// 0.2 s, which at 5 frames per second is a single detection).
  double occlusionSeconds;
  double minVisitSeconds;

  /// Round 308 (owner): the tracker itself is the videos' own too: the
  /// algorithm and both algorithms' values (stored as their JSON), starting
  /// from the app's defaults, not from the camera's values.
  TrackerAlgorithm trackerAlgorithm;
  ByteTrackParams trackerParams;
  CBiouParams cbiouParams;

  /// How often the phone's temperature, power and speed are logged during a
  /// run (round 232), seconds.
  double sampleSeconds;

  /// Kept frames per visit (round 234): on/off, and the live camera's photo
  /// rule (first frame, then one every [keepStepSeconds] for up to
  /// [keepDurationSeconds]); separate from the camera's for the same reason
  /// as the tracking settings.
  bool keepFrames;
  double keepStepSeconds;
  double keepDurationSeconds;

  VideoAnalysisPrefs({
    this.modelId,
    this.confidence = 0.25,
    this.iou = 0.7,
    this.analysisFps = kDefaultVideoAnalysisFps,
    this.thermalLimitC = kDefaultPauseTempC,
    this.occlusionSeconds = 3.0,
    this.minVisitSeconds = 1.0,
    this.sampleSeconds = 10,
    this.keepFrames = true,
    this.keepStepSeconds = 1.0,
    this.keepDurationSeconds = 10.0,
    this.trackerAlgorithm = TrackerAlgorithm.bytetrack,
    this.trackerParams = const ByteTrackParams(),
    this.cbiouParams = const CBiouParams(),
  });

  /// The rule "Find visits" keeps frames by, or null when off.
  KeepFramesSettings? get keep =>
      keepFrames ? KeepFramesSettings(stepSeconds: keepStepSeconds, durationSeconds: keepDurationSeconds) : null;

  /// [base] (the app's other settings) with the tracker "Find track IDs" uses
  /// on videos: exactly the values on the settings screen (round 313: no
  /// floor; the screen warns when New-track confidence is close to the
  /// confidence the videos were analyzed at).
  SessionConfig trackerConfig(SessionConfig base) => base.copyWith(
    occlusionSeconds: occlusionSeconds,
    minHitsSeconds: minVisitSeconds,
    trackerAlgorithm: trackerAlgorithm,
    trackerParams: trackerParams,
    cbiouParams: cbiouParams,
  );

  /// The chosen algorithm's values as "Find track IDs" logs them.
  Map<String, dynamic> get trackerJson {
    final c = trackerConfig(const SessionConfig());
    return trackerAlgorithm == TrackerAlgorithm.cbiou ? c.cbiouParams.toJson() : c.trackerParams.toJson();
  }

  double get newTrackConfidence => (trackerJson['highThresh'] as num).toDouble();

  static const _kModel = kVideoAnalysisModelPref;
  static const _kConf = 'video_analysis_confidence';
  static const _kIou = 'video_analysis_iou';
  static const _kFps = 'video_analysis_fps';
  static const _kThermal = 'video_analysis_thermal_limit_c';
  static const _kOcclusion = 'video_analysis_occlusion_s';
  static const _kMinVisit = 'video_analysis_min_visit_s';
  static const _kSample = 'video_analysis_sample_s';
  static const _kKeep = 'video_analysis_keep_frames';
  static const _kKeepStep = 'video_analysis_keep_step_s';
  static const _kKeepDuration = 'video_analysis_keep_duration_s';
  static const _kTracker = 'video_analysis_tracker';
  static const _kByteTrack = 'video_analysis_bytetrack';
  static const _kCbiou = 'video_analysis_cbiou';

  static Future<VideoAnalysisPrefs> load() async {
    final p = await SharedPreferences.getInstance();
    Map<String, dynamic> json(String key) {
      try {
        return (jsonDecode(p.getString(key) ?? '{}') as Map).cast<String, dynamic>();
      } catch (_) {
        return const {};
      }
    }

    // getDouble/getBool throw when a key holds another type (an int written by
    // a future version, a hand-edited or damaged prefs file), and that would
    // keep "Find animals in videos" from opening for good. Read the raw value,
    // fall back per key, and clamp to the ranges of the boxes in
    // video_tuning_screen.dart (keep both in sync) so a 0 FPS or 0 s keep step
    // never reaches the analysis.
    double d(String key, double def, double lo, double hi) {
      final v = p.get(key);
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : def;
    }

    // fromJson casts each field; a wrong-typed field inside valid JSON throws
    // after json() has returned, so guard the whole parse.
    T params<T>(T Function(Map<String, dynamic>) parse, String key, T def) {
      try {
        return parse(json(key));
      } catch (_) {
        return def;
      }
    }

    final keep = p.get(_kKeep);
    final model = p.get(_kModel);
    final tracker = p.get(_kTracker);
    return VideoAnalysisPrefs(
      modelId: model is String ? model : null,
      confidence: d(_kConf, 0.25, 0.05, 0.95),
      iou: d(_kIou, 0.7, 0.05, 0.95),
      analysisFps: d(_kFps, kDefaultVideoAnalysisFps, 1, 30),
      thermalLimitC: d(_kThermal, kDefaultPauseTempC, 35, 45),
      occlusionSeconds: d(_kOcclusion, 3.0, 0.2, 10),
      minVisitSeconds: d(_kMinVisit, 1.0, 0, 2),
      sampleSeconds: d(_kSample, 10, 5, 60),
      keepFrames: keep is bool ? keep : true,
      keepStepSeconds: d(_kKeepStep, 1.0, 0.1, 10),
      keepDurationSeconds: d(_kKeepDuration, 10.0, 1, 300),
      trackerAlgorithm: TrackerAlgorithm.values.asNameMap()[tracker is String ? tracker : null] ?? TrackerAlgorithm.bytetrack,
      trackerParams: params(ByteTrackParams.fromJson, _kByteTrack, const ByteTrackParams()),
      cbiouParams: params(CBiouParams.fromJson, _kCbiou, const CBiouParams()),
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
    await p.setDouble(_kSample, sampleSeconds);
    await p.setBool(_kKeep, keepFrames);
    await p.setDouble(_kKeepStep, keepStepSeconds);
    await p.setDouble(_kKeepDuration, keepDurationSeconds);
    await p.setString(_kTracker, trackerAlgorithm.name);
    await p.setString(_kByteTrack, jsonEncode(trackerParams.toJson()));
    await p.setString(_kCbiou, jsonEncode(cbiouParams.toJson()));
  }
}

/// One session folder with clips, and how far its analysis got.
class _VideoSession {
  final String name;
  final Directory dir;

  /// Clip file names in the order the analysis walks them.
  final List<String> clips;
  final int totalBytes;

  /// Clips the session had (imported or analyzed) whose file is gone, most
  /// often deleted to free storage (round 236).
  final Set<String> missingClips;

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

  /// Clips recorded by the app as time-lapse video bursts (round 239): each
  /// is already the camera's ROI square.
  final bool recorded;

  /// Clips recorded while the live AI ran (round 240): the session's visits
  /// stay the live AI's; the ones found here are for comparison (round 241).
  final bool liveAi;

  /// Round 243: clips that cannot be read because the app stopped while
  /// recording them (VideoDetector.isReadableVideo); left out of [clips].
  final List<String> cutOff;
  final int cutOffBytes;

  /// Upright picture size per clip, from the `video_clip` records (clips
  /// without one are missing): the default square of a session never
  /// analysed, and the clips the square editor can play (round 273).
  final Map<String, (int, int)> clipSizes;

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
    this.missingClips, {
    this.recorded = false,
    this.liveAi = false,
    this.cutOff = const [],
    this.cutOffBytes = 0,
    this.clipSizes = const {},
  });

  int get allClipCount => clips.length + missingClips.length;

  int get totalMs => clips.fold(0, (s, c) => s + (lengthsMs[c] ?? 0));

  int get firstClipWidth => clipSizes[clips.firstOrNull]?.$1 ?? 0;
  int get firstClipHeight => clipSizes[clips.firstOrNull]?.$2 ?? 0;
}

class VideoAnalysisScreen extends StatefulWidget {
  /// Session folder to preselect (the finished import, or a home row).
  final String? initialSessionPath;

  /// Tests replace the sessions folder, the model list and the phone's
  /// video decoder for saving kept frames.
  final Directory? sessionsDir;
  final List<ModelEntry>? models;
  final FrameSaveBackend? frameSaveBackend;

  /// Tests replace the identification models and name lists (round 274).
  final IdentificationChoice? identificationChoice;

  const VideoAnalysisScreen({
    super.key,
    this.initialSessionPath,
    this.sessionsDir,
    this.models,
    this.frameSaveBackend,
    this.identificationChoice,
  });

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

  /// "Also identify them" (round 274) and its model and name list.
  IdentificationChoice _idChoice = IdentificationChoice();
  bool _alsoIdentify = false;

  /// The analysed square, or null for the whole picture.
  Roi? _roi;

  /// First frame of the selected session's first clip, for the square.
  ({Uint8List jpeg, int width, int height})? _frame;
  String? _framePath;

  bool _running = false;

  /// Between the Start tap and [_running] (dialog and settings save); part
  /// of [_busy] so the buttons stay locked in that gap.
  bool _starting = false;
  bool _cancelRequested = false;
  bool _tracking = false;

  /// Saving kept frames from the clips (round 234), and how far it got.
  bool _keeping = false;
  ({int done, int total})? _keepProgress;

  /// How many of the selected session's kept frames are saved; read for
  /// that session only, so the list opens quickly (round 235).
  KeptFramesStatus _kept = KeptFramesStatus.none;

  /// The selected session's clips without any visit (round 236), and a
  /// deletion in progress.
  ClipCleanupPlan? _withoutVisits;
  bool _deleting = false;

  VideoProgress? _progress;

  /// Lengths (ms) of the clips this run walks, in its order: the progress
  /// bar and time estimate weigh clips by length.
  List<int> _runLengthsMs = const [];

  /// The player under the results (round 309); a new key for each session
  /// gives another session a player of its own.
  var _playerKey = GlobalKey<VideoReviewPlayerState>();

  /// Where that player was before the screen went busy: the one built afterwards starts there.
  VideoReviewView? _playerView;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // A popped screen can't show progress; stop the run too.
    _cancelRequested = true;
    ScreenOn.release(this);
    super.dispose();
  }

  /// Round 309: no clip of the player under the results plays on behind
  /// another screen, a question or a run.
  void _pausePlayer() => _playerKey.currentState?.pause();

  /// Round 309: the player before a change of the session's data, for [_refresh]. It is left out
  /// while the screen is busy, so where it was is kept for the player built after it.
  VideoReviewPlayerState? _playerBeforeChange() {
    final p = _playerKey.currentState;
    _playerView = p?.view ?? _playerView;
    return p;
  }

  Future<void> _load() async {
    final prefs = await VideoAnalysisPrefs.load();
    final models = widget.models ?? await ModelCatalog.build();
    final appConfig = await SessionConfig.load();
    final sessions = await _scanSessions();
    final (idChoice, alsoIdentify) = await AlsoIdentify.load(widget.identificationChoice);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _models = models;
      _idChoice = idChoice;
      _alsoIdentify = alsoIdentify;
      _useGpu = appConfig.useGpu;
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
      dir ??= await sessionsRoot();
      if (!dir.existsSync()) return found;
      for (final entity in dir.listSync().whereType<Directory>()) {
        final files = VideoDetector.clipsOf(entity);
        // A session whose clips were all deleted keeps its boxes (round 236).
        if (files.isEmpty && !File('${entity.path}/${VideoDetector.outputFileName}').existsSync()) continue;
        // One damaged session is left out here, not every session after it
        // (the outer catch would end the whole scan).
        try {
          found.add(await _readSession(entity, files));
        } catch (e) {
          logSwallowed('video_analysis_scan_session', e);
        }
      }
      // Newest first by folder modification time, like the photo screen.
      found.sort((a, b) => b.dir.statSync().modified.compareTo(a.dir.statSync().modified));
    } catch (e) {
      logSwallowed('video_analysis_scan', e);
    }
    return found;
  }

  static Future<_VideoSession> _readSession(Directory dir, List<File> allFiles) async {
    final files = allFiles.where(VideoDetector.isReadableVideo).toList();
    final cutOff = allFiles.where((f) => !files.contains(f)).toList();
    final records = await VideoDetector.clipRecordsFromLog(dir);
    final lengths = {
      for (final e in records.entries)
        if (e.value['duration_ms'] case final num ms) e.key: ms.toInt(),
    };
    var resume = const VideoResume(null, {}, {});
    int? runMs;
    final out = File('${dir.path}/${VideoDetector.outputFileName}');
    if (out.existsSync()) {
      // Only the run and clip-done records matter here; skipping the many
      // detection lines keeps the list quick.
      final lines = await out
          .openRead()
          // allowMalformed: one torn multi-byte letter must not hide the session.
          .transform(const Utf8Decoder(allowMalformed: true))
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
      {...lengths.keys, ...resume.doneClips}.difference({for (final f in allFiles) f.path.split('/').last}),
      // Recorded clips carry their burst (round 238) or live segment (round 240) number.
      recorded: records.values.any((r) => r.containsKey('burst') || r.containsKey('segment')),
      liveAi: records.values.any((r) => r.containsKey('segment')),
      cutOff: [for (final f in cutOff) f.path.split('/').last],
      cutOffBytes: cutOff.fold(0, (s, f) => s + f.lengthSync()),
      clipSizes: {
        for (final e in records.entries)
          if ((e.value['width'], e.value['height']) case (final num w, final num h)) e.key: (w.toInt(), h.toInt()),
      },
    );
  }

  /// Selects [s] and takes over its last run's square, so "Continue" works
  /// without placing the square again. A session never analysed starts on
  /// the largest square in the middle (round 273), as the detector looks at a
  /// square picture like the camera's square.
  void _select(_VideoSession s) {
    final roi = s.lastSettings?['roi'];
    setState(() {
      if (_session?.dir.path != s.dir.path) {
        _kept = KeptFramesStatus.none;
        _withoutVisits = null;
        _playerKey = GlobalKey();
        _playerView = null;
      }
      _session = s;
      _roi = s.lastSettings == null
          ? Roi.largestCentredSquare(s.firstClipWidth, s.firstClipHeight)
          : roi is List && roi.length == 3
          ? Roi(
              centerX: (roi[0] as num).toDouble(),
              centerY: (roi[1] as num).toDouble(),
              sideFraction: (roi[2] as num).toDouble(),
            )
          : null;
    });
    if (_roi != null) _loadFrame();
    _loadSelected();
  }

  /// What only the selected session needs: its kept frames and its clips
  /// without visits.
  Future<void> _loadSelected() async {
    final s = _session;
    if (s == null) return;
    final kept = await VideoFrameKeeper.status(s.dir);
    final withoutVisits = await ClipCleanup.planWithoutVisits(s.dir);
    if (mounted && _session?.dir.path == s.dir.path) {
      setState(() {
        _kept = kept;
        _withoutVisits = withoutVisits;
      });
    }
  }

  /// The first clip's first frame (cached per session).
  Future<({Uint8List jpeg, int width, int height})?> _loadFrame() async {
    final s = _session;
    if (s == null) return null;
    if (_framePath == s.dir.path && _frame != null) return _frame;
    if (s.clips.isEmpty) return null;
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

  /// The clips the square editor plays: the first clip, then every other clip
  /// of the same picture size (the square is placed on that picture).
  List<String> _squareClips(_VideoSession s) {
    if (s.clips.isEmpty) return const [];
    final size = s.clipSizes[s.clips.first];
    return [
      for (final c in s.clips)
        if (c == s.clips.first || (size != null && s.clipSizes[c] == size)) '${s.dir.path}/videos/$c',
    ];
  }

  Future<void> _editSquare() async {
    _pausePlayer();
    final s = _session;
    final frame = await _loadFrame();
    if (s == null || frame == null || !mounted) return;
    final roi = await Navigator.of(context).push<Roi>(
      MaterialPageRoute(
        builder: (_) => VideoSquareEditor(
          frameJpeg: frame.jpeg,
          frameWidth: frame.width,
          frameHeight: frame.height,
          // From "Whole picture": the proposed square again.
          initial: _roi ?? Roi.largestCentredSquare(frame.width, frame.height) ?? Roi.defaultRoi,
          videoPaths: _squareClips(s),
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
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(const Text('Replace the earlier results?'), onClose: () => Navigator.of(ctx).pop(false)),
        content: Text(
          'These videos were analyzed before with other settings'
          '${changed.isEmpty ? '' : ' (changed: ${changed.join(', ')})'}. '
          'Results from two settings cannot be mixed, so analyzing again replaces the earlier ones '
          '(${s.doneClips.length} of ${s.allClipCount} clips were finished).'
          '${s.missingClips.isEmpty ? '' : ' ${s.missingClips.length} ${s.missingClips.length == 1 ? 'clip was' : 'clips were'} '
                'deleted: their boxes and track IDs go too, and they cannot be analyzed again.'}',
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
    if (session == null || config == null || _busy) return;
    // _running is set only after the settings are saved (14 separate disk
    // writes on Android, tens to hundreds of ms); _starting closes that gap
    // so a quick second tap cannot start a second run on the same
    // video_detections.jsonl. The finally clears it on every early return;
    // on the normal path _running takes over with no await in between.
    setState(() => _starting = true);
    _pausePlayer();
    final player = _playerBeforeChange();
    try {
      final changed = _changedSettings(session, config);
      if (!startOver && changed.isNotEmpty) {
        if (!await _confirmStartOver(session, changed)) return;
        startOver = true;
      }
      _prefs.modelId = config.modelPath;
      await _prefs.save();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    // The screen may have closed during the save: start nothing then.
    if (!mounted) return;

    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = null;
      _runLengthsMs = [
        for (final c in session.clips)
          if (startOver || !session.doneClips.contains(c)) session.lengthsMs[c] ?? 0,
      ];
    });
    ScreenOn.hold(this);
    // Round 309: the player under the results closes its video first (it is left out while busy).
    if (_playerKey.currentState != null) await WidgetsBinding.instance.endOfFrame;

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
        sampleEvery: Duration(seconds: _prefs.sampleSeconds.round()),
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
      ScreenOn.release(this);
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
    var found = false;
    if (failure == null && !result!.cancelled && result.clipsDone > 0) {
      final r = await _findVisits(session);
      message = '$message ${r.message}';
      found = r.ok && r.trackIds > 0;
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh(session, player);
    if (found) await _identifyAfter(session);
  }

  /// Round 274: one Start from the boxes to the names, once the kept frames
  /// (what identification names) are all saved; round 308: also after
  /// finding the track IDs again.
  Future<void> _identifyAfter(_VideoSession ran) async {
    // Round 309: not when another session was picked meanwhile.
    if (_identify && _kept.remaining == 0 && mounted && _session?.dir.path == ran.dir.path) {
      if (_session case final s?) await _openIdentify(s);
    }
  }

  /// "Also identify them" can run: switched on, a model with a name list
  /// chosen, kept frames on, and not a live detection session (its track IDs
  /// are named from the session's ⋮ menu).
  bool get _identify =>
      _alsoIdentify && _idChoice.ready && _prefs.keepFrames && !(_session?.liveAi ?? false);

  /// Opens Identify organisms on [s], which starts by itself and ends on the
  /// results; the model and name list chosen here are remembered for it.
  Future<void> _openIdentify(_VideoSession s) async {
    _pausePlayer();
    await _idChoice.save();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => IdentificationScreen(sessionDir: s.dir, autoStart: true)),
    );
    if (!mounted) return;
    // Another model may have been chosen there, and Identify's own "Download
    // & import models" may have added or deleted detection models (round 312).
    final (choice, _) = await AlsoIdentify.load(widget.identificationChoice);
    if (mounted) setState(() => _idChoice = choice);
    await _reloadModels();
  }

  Widget _alsoIdentifySection() {
    if (_session?.liveAi ?? false) {
      return const Text(
        'To name the live track IDs: "Identify organisms" in the session\'s ⋮ menu.',
        style: helperTextStyle,
      );
    }
    return AlsoIdentifySection(
      value: _alsoIdentify,
      onChanged: _busy
          ? null
          : (v) {
              setState(() => _alsoIdentify = v);
              AlsoIdentify.save(v);
            },
      blockedReason: _prefs.keepFrames
          ? null
          : 'Needs "Keep frames of each track ID" (in "Detection, track ID and identification settings" below): '
                'identification names the saved frames.',
      choice: _idChoice,
      onChoiceChanged: (_) => setState(() {}),
      onManage: _busy ? null : _manageModels,
    );
  }

  /// Reads [session] again after a change. Round 309: so does the player under
  /// the results, when it is still [player], the one from before the change
  /// (it stops a clip whose video was deleted); a player built anew meanwhile
  /// (it is left out while the screen is busy) has read the change already.
  Future<void> _refresh(_VideoSession session, [VideoReviewPlayerState? player]) async {
    final sessions = await _scanSessions();
    if (!mounted) return;
    // Round 309: the session selected now, as the list is usable again while this reads: another
    // session picked there meanwhile stays picked (with its own player).
    final path = _session?.dir.path ?? session.dir.path;
    setState(() {
      _sessions = sessions;
      _session = sessions.where((s) => s.dir.path == path).firstOrNull;
    });
    await _loadSelected();
    final now = _playerKey.currentState;
    if (now != null && identical(now, player)) await now.reload();
  }

  bool get _busy => _running || _starting || _tracking || _keeping || _deleting;

  /// Links the analyzed boxes of [session] into visits, off the screen's
  /// thread so it stays responsive, then saves the frames kept for them.
  /// Returns the outcome in words, whether the track IDs were found, and how
  /// many (round 312: none means nothing to identify).
  Future<({String message, bool ok, int trackIds})> _findVisits(_VideoSession session) async {
    setState(() => _tracking = true);
    await _prefs.save();
    String message;
    var keptFrames = 0;
    var ok = false;
    var trackIds = 0;
    try {
      // Round 308: the videos' own tracker settings on the app's other ones.
      final config = _prefs.trackerConfig(await SessionConfig.load());
      final r = await _trackInBackground(session.dir.path, config, _keepFor(session));
      keptFrames = r.keptFrames;
      ok = true;
      trackIds = r.visits;
      message =
          'Found ${r.visits} ${r.visits == 1 ? 'track ID' : 'track IDs'} in ${r.clipsTracked} '
          '${r.clipsTracked == 1 ? 'clip' : 'clips'}.';
    } catch (e) {
      logSwallowed('video_find_track_ids', e);
      message = 'Finding track IDs failed: ${e is StateError ? e.message : e}';
    }
    // Round 256: show the new track IDs, and under them the saving progress
    // with its Stop button, before the frames are saved; a first run showed
    // neither until every frame was saved, so the screen looked idle. Round
    // 308: also without kept frames, so the main button never offers the
    // track IDs just found as still to find.
    if (ok && mounted) await _refresh(session);
    if (!mounted) return (message: message, ok: ok, trackIds: trackIds);
    setState(() => _tracking = false);
    if (keptFrames > 0) message = '$message ${await _saveKeptFrames(session)}';
    if (ok && trackIds == 0 && _identify) message = '$message Nothing to identify.';
    return (message: message, ok: ok, trackIds: trackIds);
  }

  /// [identify]: then "Also identify them" too; not for the clips analyzed
  /// so far while others are left.
  Future<void> _onFindVisits({bool identify = true}) async {
    final s = _session;
    if (s == null || _busy) return;
    final player = _playerBeforeChange();
    final r = await _findVisits(s);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    await _refresh(s, player);
    if (r.ok && r.trackIds > 0 && identify) await _identifyAfter(s);
  }

  /// Saves the kept frames of [session] that are not saved yet, from the
  /// clips; a stopped run continues where it left off. Returns the outcome
  /// in words.
  Future<String> _saveKeptFrames(_VideoSession session) async {
    setState(() {
      _keeping = true;
      _cancelRequested = false;
      _keepProgress = null;
    });
    ScreenOn.hold(this);
    // Round 309: the player under the results closes its video before the frames are read from it.
    if (_playerKey.currentState != null) await WidgetsBinding.instance.endOfFrame;
    String message;
    try {
      final r = await VideoFrameKeeper(backend: widget.frameSaveBackend ?? const NativeFrameSaveBackend()).run(
        session.dir,
        onProgress: (done, total) {
          if (mounted) setState(() => _keepProgress = (done: done, total: total));
        },
        isCancelled: () => _cancelRequested,
      );
      final lost = r.failed + r.missing;
      message = r.cancelled
          ? 'Stopped after saving ${r.saved} ${r.saved == 1 ? 'frame' : 'frames'}; '
                '"Save the remaining frames" continues.'
          : 'Saved ${r.saved} ${r.saved == 1 ? 'frame' : 'frames'} in ${_fmtElapsed(r.elapsed)}'
                '${lost > 0 ? '; $lost could not be read from their video' : ''}.';
    } catch (e) {
      logSwallowed('video_keep_frames_run', e);
      message = 'Saving the frames failed: $e';
    } finally {
      ScreenOn.release(this);
    }
    if (mounted) {
      setState(() {
        _keeping = false;
        _keepProgress = null;
      });
    }
    return message;
  }

  Future<void> _onSaveKeptFrames() async {
    final s = _session;
    if (s == null || _busy) return;
    final player = _playerBeforeChange();
    final message = await _saveKeptFrames(s);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh(s, player);
  }

  Future<void> _shareResults(_VideoSession s) async {
    _pausePlayer();
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
  /// The kept-frames rule for [s]; none for a live AI session (round 241):
  /// its `roi_frames/` holds the live photos, which stay the session's own.
  KeepFramesSettings? _keepFor(_VideoSession s) => s.liveAi ? null : _prefs.keep;

  static Future<VideoTrackResult> _trackInBackground(String path, SessionConfig config, KeepFramesSettings? keep) =>
      Isolate.run(() => VideoTracker.run(Directory(path), config, keep: keep));
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
    // Round 256: leaving stops a run (dispose), and kept frames not saved
    // are silently missing from Identify organisms, so ask first.
    return PopScope(
      canPop: !(_running || _keeping),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveIfConfirmed();
      },
      child: _screen(),
    );
  }

  /// Asked when leaving during a run; "Stop and leave" pops the screen,
  /// whose dispose stops the run.
  Future<void> _leaveIfConfirmed() async {
    final keeping = _keeping;
    final p = _keepProgress;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(Text(keeping ? 'Frames are still being saved' : 'The detector is still running'), onClose: () => Navigator.pop(ctx, false)),
        content: Text(
          keeping
              ? 'Leaving stops saving the kept frames${p == null ? '' : ' (${p.done} of ${p.total} done)'}. '
                    'Identify organisms can only use saved frames; "Save the remaining frames" '
                    'continues later.'
              : 'Leaving stops the analysis. A stopped run continues where it left off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stop and leave')),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Widget _screen() {
    return Scaffold(
      appBar: AppBar(title: const FitTitle('Find animals in videos'), actions: const [HomeButton()]),
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
                        'For imported videos and video bursts. There is no real-time limit, '
                        'so a bigger model than the live one can be used; it only takes longer.',
                  ),
                  const SizedBox(height: 16),
                  _sessionPicker(),
                  const SizedBox(height: 12),
                  _modelPicker(),
                  const SizedBox(height: 12),
                  // Round 273: the proposed square stays in view, to accept
                  // or change; every number to tune is one tap away below
                  // (round 308: on its own screen).
                  _areaSection(),
                  const SizedBox(height: 8),
                  _alsoIdentifySection(),
                  const SizedBox(height: 8),
                  _tuningEntry(),
                  const SizedBox(height: 16),
                  if (_running) _progressPanel() else _startButton(),
                  const SizedBox(height: 12),
                  const Text(
                    'Long runs: keep the phone charging and set it aside; processing slows down if the '
                    'phone is used meanwhile. A stopped run continues where it left off.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  _visitsSection(),
                  // Round 309: last, so its height changing (loading, left out while busy) never
                  // moves what is above it.
                  _watchSection(),
                ],
              ),
      ),
    );
  }

  /// Round 277: videos are imported here too (also with the home screen's
  /// "Import videos…"); the new session is chosen once the import is done.
  Future<void> _importVideos() async {
    _pausePlayer();
    final before = {for (final s in _sessions) s.dir.path};
    final imported = await pickAndImportVideos(context);
    final sessions = await _scanSessions();
    if (!mounted) return;
    setState(() => _sessions = sessions);
    final added = sessions.where((s) => imported != null ? s.dir.path == imported : !before.contains(s.dir.path));
    if (added.isNotEmpty) _select(added.first);
  }

  Widget _importButton(String label) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: _busy ? null : _importVideos,
      icon: const Icon(Icons.video_library_outlined, size: 18),
      label: Text(label),
    ),
  );

  Widget _sessionPicker() {
    if (_sessions.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('No sessions with videos yet.', style: TextStyle(color: Colors.white54)),
          _importButton('Import videos…'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_sessionDropdown(), _importButton('Import other videos…')],
    );
  }

  Widget _sessionDropdown() {
    return DropdownButtonFormField<_VideoSession>(
      initialValue: _session,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Session', border: OutlineInputBorder()),
      items: [
        for (final s in _sessions)
          DropdownMenuItem(
            value: s,
            child: Text(
              '${s.name} (${s.allClipCount} ${s.allClipCount == 1 ? 'clip' : 'clips'}, '
              '${s.missingClips.isEmpty ? '' : '${s.missingClips.length} deleted, '}'
              '${s.totalMs > 0 ? '${_fmtElapsed(Duration(milliseconds: s.totalMs))}, ' : ''}'
              '${formatBytes(s.totalBytes)}'
              '${s.doneClips.isNotEmpty ? ', ${s.doneClips.length} analyzed' : ''})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: _busy ? null : (s) => s == null ? null : _select(s),
    );
  }

  Widget _modelPicker() {
    // Round 268: no model ships with the app.
    if (_models.isEmpty) {
      return NoModelNotice(identification: false, onGet: _busy ? null : _manageModels);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<ModelEntry>(
          initialValue: _model,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Detection model', border: OutlineInputBorder()),
          items: [
            for (final m in _models) DropdownMenuItem(value: m, child: Text(m.label, overflow: TextOverflow.ellipsis)),
          ],
          // Saved at once (round 313: before, only Start saved it).
          onChanged: _running
              ? null
              : (m) {
                  setState(() => _model = m);
                  _prefs.modelId = m?.id;
                  unawaited(_prefs.save());
                },
        ),
        manageModelsButton(onPressed: _busy ? null : _manageModels),
      ],
    );
  }

  /// Round 267: models are added and deleted on the AI models screen;
  /// re-reads the list on return and keeps the choice when it still exists.
  Future<void> _manageModels() async {
    _pausePlayer();
    await openModelsScreen(context);
    if (widget.identificationChoice == null) await AlsoIdentify.reload(_idChoice);
    await _reloadModels();
  }

  /// Re-reads the detection models, keeping the choice when it still exists.
  Future<void> _reloadModels() async {
    final models = widget.models ?? await ModelCatalog.build();
    if (!mounted) return;
    setState(() {
      _models = models;
      _model = models.where((m) => m.id == _model?.id).firstOrNull ?? models.firstOrNull;
    });
  }

  /// Width in pixels of the selected session's picture: from the loaded
  /// first frame, else from its first clip's log record; null when unknown.
  int? get _pictureWidth {
    final frame = _frame != null && _framePath == _session?.dir.path ? _frame : null;
    if (frame != null) return frame.width;
    final w = _session?.firstClipWidth ?? 0;
    return w > 0 ? w : null;
  }

  /// "square 480 × 480 px", "whole picture" (round 273).
  String _areaShort() {
    final roi = _roi;
    if (roi == null) return 'whole picture';
    final w = _pictureWidth;
    if (w == null) return 'square of ${(roi.sideFraction * 100).round()}% of the picture width';
    final px = snapToMultipleOf32(roi.sideFraction * w);
    return 'square $px × $px px';
  }

  /// Round 308: what a run uses now, one line per card of the settings
  /// screen, so the values stay in view while their controls are a tap away.
  List<String> _tuningSummary() {
    final p = _prefs;
    final live = _session?.liveAi ?? false;
    final model = _idChoice.model?.path.split('/').last;
    final list = _idChoice.pack?.path.split('/').last;
    // Round 313: with the videos deleted nothing can be analyzed again, so
    // the line shows what the saved boxes were found with.
    final gone = _videosGone(_session);
    final last = _session?.lastSettings;
    final conf = gone ? ((last?['confidence'] as num?)?.toDouble() ?? p.confidence) : p.confidence;
    final fps = gone ? ((last?['analysis_fps'] as num?)?.toDouble() ?? p.analysisFps) : p.analysisFps;
    final iou = gone ? ((last?['iou'] as num?)?.toDouble() ?? p.iou) : p.iou;
    return [
      'Detection: confidence ${conf.toStringAsFixed(2)}, ${fps.round()} frames per second, '
          'IoU ${iou.toStringAsFixed(2)}${gone ? ' (as analyzed; the videos were deleted)' : ''}',
      'Track IDs: ${p.trackerAlgorithm == TrackerAlgorithm.cbiou ? 'C-BIoU' : 'ByteTrack'}, new-track confidence '
          '${p.newTrackConfidence.toStringAsFixed(2)}, occlusion ${p.occlusionSeconds.toStringAsFixed(1)} s, minimum '
          '${p.minVisitSeconds.toStringAsFixed(1)} s${live ? '' : ', keep frames ${p.keepFrames ? 'on' : 'off'}'}',
      live
          ? 'Identification: from the session\'s ⋮ menu (a live detection session)'
          : !p.keepFrames
          ? 'Identification: off, needs "Keep frames of each track ID"'
          : !_alsoIdentify
          ? 'Identification: off'
          : !_idChoice.ready
          ? 'Identification: on, but no model with a name list chosen'
          : 'Identification: on, $model with $list',
    ];
  }

  /// The way to the settings screen, with the values in use (round 308).
  Widget _tuningEntry() {
    final busy = _busy;
    return Material(
      color: Colors.white10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : _openTuning,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Icon(Icons.tune, color: busy ? Colors.white38 : Colors.white70),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Detection, track ID and identification settings',
                      style: TextStyle(color: busy ? Colors.white38 : Colors.white, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    for (final line in _tuningSummary()) Text(line, style: helperTextStyle),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: busy ? Colors.white24 : Colors.white54),
            ],
          ),
        ),
      ),
    );
  }

  /// The session's videos were deleted after an analysis: its boxes stay, but
  /// nothing can be analyzed again.
  bool _videosGone(_VideoSession? s) => s != null && s.clips.isEmpty && s.lastSettings != null;

  Future<void> _openTuning() async {
    _pausePlayer();
    final s = _session;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoTuningScreen(
          prefs: _prefs,
          totalMs: s?.totalMs ?? 0,
          // With the videos still there, a changed rate means a new analysis
          // at it; without them, the track IDs keep the last run's rate.
          analysedFps: s != null && s.clips.isEmpty ? (s.lastSettings?['analysis_fps'] as num?)?.toDouble() : null,
          // The confidence the saved boxes were found at: the lowest score the
          // tracker gets, for the New-track note (round 313).
          analysedConfidence: s != null && s.doneClips.isNotEmpty
              ? (s.lastSettings?['confidence'] as num?)?.toDouble()
              : null,
          videosGone: _videosGone(s),
          liveAi: s?.liveAi ?? false,
          // Frames of deleted videos are never removed.
          keptSaved: s != null && s.clips.isNotEmpty ? _kept.saved : 0,
          alsoIdentify: _alsoIdentify,
          identifyModel: _idChoice.ready ? _idChoice.model?.path.split('/').last : null,
          identifyList: _idChoice.ready ? _idChoice.pack?.path.split('/').last : null,
        ),
      ),
    );
    // The settings were changed in place and saved there.
    if (mounted) setState(() {});
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
              'The detector looks at a square picture, as with the camera\'s square. The largest square in '
              'the middle of the video is proposed; a video that is already square, such as the clips the app '
              'records, is used whole. "Change…" plays the video fast, so you see whether the camera or the '
              'flowers move and the square still covers them. If the flowers fill only part of the picture, a '
              'smaller square around them helps: insects outside it are ignored, and small insects are found '
              'more easily. "Whole picture" also includes the edges.',
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
        if (_session?.recorded ?? false)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'These clips were recorded by the app as the camera\'s square, so the whole picture '
              'is that square. A smaller square analyzes only part of it.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        if (roi != null) ...[
          const SizedBox(height: 8),
          // The whole first frame with the square, the rest darker: what the
          // detector will look at. A tap opens the editor, as "Change…".
          if (frame != null)
            GestureDetector(
              onTap: _running ? null : _editSquare,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
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
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_areaShort().replaceFirst('square', 'Square')}.',
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

  /// Round 308: one main button for what is due next. Clips to analyze
  /// (pending, or analyzed with other detection settings) come first; then
  /// track IDs that are missing, out of date or found with other settings;
  /// then, with "Also identify them", the names (round 274: also after the
  /// videos were deleted, from the kept frames).
  Widget _startButton() {
    final s = _session;
    final config = _config;
    final changed = s == null || config == null ? const <String>[] : _changedSettings(s, config);
    final pending = s == null ? 0 : s.clips.where((c) => !s.doneClips.contains(c)).length;
    final analyze = s != null && s.clips.isNotEmpty && (pending > 0 || changed.isNotEmpty);
    final due = s != null && s.doneClips.isNotEmpty && (s.visits == null || _stale(s) || _trackChanged(s));
    final track = !analyze && due;
    // With clips left (a stopped run, or a clip that cannot be read), the
    // clips analyzed so far still get their track IDs, e.g. to free storage
    // during a long run in several parts.
    final trackSoFar = pending > 0 && due;
    // Round 312: only when track IDs were found (their frames are what is named).
    final identifyOnly =
        !analyze && !track && _identify && s != null && s.doneClips.isNotEmpty && (s.visits?.visits ?? 0) > 0;
    final and = _identify ? ' and identify' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _busy || s == null
              ? null
              : analyze
              ? (config == null ? null : _start)
              : track
              ? _onFindVisits
              : identifyOnly
              ? () => _openIdentify(s)
              : null,
          icon: Icon(
            track || _tracking
                ? Icons.timeline
                : identifyOnly
                ? Icons.biotech
                : Icons.play_arrow,
          ),
          label: Text(
            s == null
                ? 'Pick a session to analyze'
                : _tracking
                ? 'Finding track IDs…'
                : analyze
                ? (changed.isNotEmpty
                      ? 'Analyze again with these settings'
                      : s.doneClips.isNotEmpty
                      ? 'Continue ($pending of ${s.clips.length} clips left)'
                      : 'Analyze ${s.clips.length} ${s.clips.length == 1 ? 'clip' : 'clips'}$and')
                : track
                ? (s.visits == null ? 'Find track IDs$and' : 'Find track IDs again with these settings$and')
                : identifyOnly
                ? 'Identify the animals found'
                : s.clips.isEmpty
                ? (s.cutOff.isNotEmpty && s.doneClips.isEmpty ? 'No clip can be read' : 'The videos were deleted')
                : 'All clips analyzed with these settings',
          ),
        ),
        if (_identify && (analyze || track))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              analyze
                  ? 'Then the track IDs are found, their frames saved, the animals identified and the results opened.'
                  : 'Then their frames are saved, the animals identified and the results opened.',
              style: helperTextStyle,
            ),
          ),
        if (trackSoFar)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _onFindVisits(identify: false),
              icon: const Icon(Icons.timeline, size: 18),
              label: const Text('Find track IDs for the clips analyzed so far'),
            ),
          ),
        // The Track IDs card's warning, also here where the buttons that do
        // it are (frames of deleted videos stay).
        if (s != null && due && !s.liveAi && !_prefs.keepFrames && _kept.saved > 0 && s.clips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'With "Keep frames of each track ID" off, finding the track IDs again removes the ${_kept.saved} '
              'frames saved before; they can be saved again from the videos later.',
              style: const TextStyle(color: Colors.amber, fontSize: 13),
            ),
          ),
        if (s != null && s.cutOff.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            '${s.cutOff.length} ${s.cutOff.length == 1 ? 'clip was' : 'clips were'} cut off: the app stopped '
            'while recording ${s.cutOff.length == 1 ? 'it' : 'them'} (battery, the system or a forced stop), so '
            'the file was never finished and cannot be read. Left out here.',
            style: const TextStyle(color: Colors.amber, fontSize: 13),
          ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
            onPressed: _busy ? null : () async => _confirmDeleteClips(s, await ClipCleanup.planCutOff(s.dir)),
            icon: const Icon(Icons.broken_image_outlined),
            label: Text(
              'Delete ${s.cutOff.length == 1 ? 'the cut-off clip' : 'the ${s.cutOff.length} cut-off clips'} '
              '(${formatBytes(s.cutOffBytes)})…',
            ),
          ),
        ],
        if (s != null && s.doneClips.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'The boxes found are saved in the session folder (video_detections.jsonl).'
            '${s.clips.isEmpty ? ' The videos were deleted to free storage, so they cannot be analyzed '
                      'again; the track IDs can still be found again from the saved boxes.' : ''}',
            style: helperTextStyle,
          ),
        ],
      ],
    );
  }

  /// The analysis went further or was done again since the track IDs were
  /// found, so they leave some of it out.
  static bool _stale(_VideoSession s) {
    final v = s.visits;
    return v != null &&
        (v.detectionsRunMs != s.detectionsRunMs ||
            v.clips.length != s.doneClips.length ||
            !v.clips.every(s.doneClips.contains));
  }

  /// The track ID settings differ from those the track IDs were found with.
  bool _trackChanged(_VideoSession s) {
    final v = s.visits;
    if (v == null) return false;
    final logged = v.trackerValues;
    return v.occlusionSeconds != _prefs.occlusionSeconds ||
        v.minHitsSeconds != _prefs.minVisitSeconds ||
        v.algorithm != _prefs.trackerAlgorithm.name ||
        // Round 308: "New-track confidence" and the fine-tuning, the videos'
        // own since then; a value an older run did not log does not count.
        trackerUserValues(_prefs.trackerJson).entries.any((e) => logged.containsKey(e.key) && logged[e.key] != e.value) ||
        v.keep != _keepFor(s);
  }

  /// "Track IDs": the last result, the kept frames, Share and Free storage
  /// (round 308: the settings and the button to find them are above).
  Widget _visitsSection() {
    final s = _session;
    final v = s?.visits;
    if (s == null || s.doneClips.isEmpty || v == null) return const SizedBox.shrink();
    final busy = _busy;
    final kept = _kept;
    final stale = _stale(s);
    const amber = TextStyle(color: Colors.amber, fontSize: 13);
    // With clips left, the main button continues the analysis; the one under
    // it finds the track IDs.
    final again = s.clips.any((c) => !s.doneClips.contains(c))
        ? '"Find track IDs for the clips analyzed so far" above'
        : 'the button above';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        const HelpLabel(
          label: 'Track IDs',
          labelStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          helperText:
              'Follows each insect from frame to frame, as the live camera does, so one insect seen in '
              'many frames counts as one track ID. Takes seconds and can be repeated with other settings '
              'without analyzing the videos again.',
        ),
        if (s.liveAi)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'These clips were recorded while live detection ran. The track IDs found here are for '
              'comparison: the session\'s Video tab shows them next to live detection\'s ("Live detection | '
              'Detection afterwards"), while the session\'s track IDs, graphs and dashboard stay live detection\'s.',
              style: helperTextStyle,
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '${v.visits} ${v.visits == 1 ? 'track ID' : 'track IDs'} in ${v.clips.length} of ${s.allClipCount} clips '
          '(occlusion tolerance ${v.occlusionSeconds.toStringAsFixed(1)} s, minimum track '
          '${v.minHitsSeconds.toStringAsFixed(1)} s).',
        ),
        if (stale)
          Text(
            'The videos were analyzed further or again since: $again finds the track IDs again to include that.',
            style: amber,
          )
        else if (_trackChanged(s))
          Text('Settings changed: $again finds the track IDs again with them.', style: amber),
        ..._keptFramesStatus(kept),
        const SizedBox(height: 4),
        Text(
          'Saved in the session folder: track_ids.csv (one row per track ID), mot/ (every box, for annotation '
          'tools)${kept.total > 0 ? ', roi_frames/ (the kept frames)' : ''} and post_tracks.jsonl.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          onPressed: busy ? null : () => _shareResults(s),
          icon: const Icon(Icons.share),
          label: const Text('Share results'),
        ),
        ..._freeStorage(s, stale: stale),
      ],
    );
  }

  /// "Watch the results" (round 309, owner): the analysed videos with their
  /// boxes and track IDs, under the track ID results and Free storage. Left
  /// out while the screen is busy: its video is closed before the detector or
  /// the frame saving opens one (one video read at a time), and a clip being
  /// deleted never plays.
  Widget _watchSection() {
    final s = _session;
    if (s == null || s.doneClips.isEmpty || s.clips.isEmpty || _busy) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        const HelpLabel(
          label: 'Watch the results',
          labelStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          helperText:
              'Plays the analyzed videos with the detector\'s boxes and track IDs, so you can decide whether '
              'to change the settings and run again; after a new run it opens at the same clip and moment, '
              'to compare. Tap the video to pause or play; sound is off unless you switch it on. Boxes show '
              'only on analyzed frames, so at high speed they can lag behind a fast insect. The player is '
              'hidden while the screen is busy, so the phone works on one video at a time.',
        ),
        const Text(
          'The videos with the boxes and track IDs found. If insects are missed or counted twice, change the '
          'settings above and run again.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 8),
        VideoReviewPlayer(key: _playerKey, sessionDir: s.dir, live: s.liveAi, embedded: true, startAt: _playerView),
      ],
    );
  }

  /// "Free storage" (round 236): deleting the clips without any visit, or
  /// all clips, once the visits are found.
  List<Widget> _freeStorage(_VideoSession s, {required bool stale}) {
    final busy = _busy;
    final none = _withoutVisits;
    final pending = s.clips.where((c) => !s.doneClips.contains(c)).length;
    // Clips left first: finding the track IDs again does not lift that.
    final String? allBlocked = pending > 0
        ? 'Analyze every clip first ($pending left).'
        : stale
        ? 'Find track IDs again first: the track IDs do not include the latest analysis yet.'
        : _kept.remaining > 0
        ? 'Save the remaining kept frames first: they cannot be saved without the videos.'
        : null;
    return [
      const Divider(height: 32),
      const HelpLabel(
        label: 'Free storage',
        labelStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        helperText:
            'The videos take most of the space. Once the track IDs are found and the frames you want '
            'are saved, the videos can go: the boxes the detector found, the track IDs and the kept frames '
            'stay, so "Find track IDs" can run again with other settings. What is lost: playing a '
            'deleted clip, analyzing it again (for example with another square or model) and '
            'keeping other frames from it. Keep the videos if you may want any of that; copies on '
            'a computer are the safest.',
      ),
      const SizedBox(height: 4),
      Text(
        s.clips.isEmpty
            ? 'All ${s.allClipCount} videos were deleted.'
            : 'Videos: ${s.clips.length} ${s.clips.length == 1 ? 'clip' : 'clips'}, ${formatBytes(s.totalBytes)}'
                  '${s.missingClips.isEmpty ? '' : ' (${s.missingClips.length} deleted before)'}.',
      ),
      if (s.clips.isNotEmpty) ...[
        const SizedBox(height: 6),
        if (none != null && !none.isEmpty && !stale)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
            onPressed: busy ? null : () => _confirmDeleteClips(s, none),
            icon: const Icon(Icons.delete_outline),
            label: Text(
              'Delete ${none.deleteNames.length} ${none.deleteNames.length == 1 ? 'clip' : 'clips'} '
              'without any track ID (${formatBytes(none.deleteBytes)})…',
            ),
          )
        else if (none != null && !stale)
          const Text('Every analyzed clip has at least one track ID.', style: helperTextStyle),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade300),
          onPressed: busy || allBlocked != null
              ? null
              : () async => _confirmDeleteClips(s, await ClipCleanup.planAll(s.dir)),
          icon: const Icon(Icons.delete_sweep_outlined),
          label: Text(
            'Delete ${s.clips.length == 1 ? 'the only clip' : 'all ${s.clips.length} clips'}, keep the saved frames '
            '(${formatBytes(s.totalBytes)})…',
          ),
        ),
        if (allBlocked != null) Text(allBlocked, style: helperTextStyle),
      ],
    ];
  }

  Future<void> _confirmDeleteClips(_VideoSession s, ClipCleanupPlan plan) async {
    if (plan.isEmpty) return;
    _pausePlayer();
    final player = _playerBeforeChange();
    final n = plan.deleteNames.length;
    final all = plan.mode == ClipCleanup.modeAll;
    final cut = plan.mode == ClipCleanup.modeCutOff;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        actionsOverflowDirection: VerticalDirection.up,
        title: DialogTitle(
          Text(
            all
                ? 'Delete all videos?'
                : cut
                ? 'Delete the cut-off ${n == 1 ? 'clip' : 'clips'}?'
                : 'Delete the clips without any track ID?',
          ),
          onClose: () => Navigator.of(ctx).pop(false),
        ),
        content: SingleChildScrollView(
          child: Text(
            'This permanently deletes $n ${n == 1 ? 'video' : 'videos'} '
            '(${formatBytes(plan.deleteBytes)})${all ? '' : ': ${plan.deleteNames.join(', ')}'}. '
            '${cut ? '${n == 1 ? 'It was' : 'They were'} never finished, so nothing in ${n == 1 ? 'it' : 'them'} can be read; the rest of the session stays. ' : 'The boxes the detector found, the track IDs and the kept frames stay, so the track IDs can '
                      'be found again with other settings. The deleted clips can no longer be played, analyzed again or give other frames. '}'
            'This cannot be undone.',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete $n', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _deleting = true);
    final deleted = await ClipCleanup.run(s.dir, plan);
    if (!mounted) return;
    setState(() => _withoutVisits = null); // read again below
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted $deleted ${deleted == 1 ? 'video' : 'videos'}, ${formatBytes(plan.deleteBytes)} freed.')),
    );
    // Round 309: busy until the session is read again, or the player under the results would come
    // back for a moment with the clips just deleted.
    await _refresh(s, player);
    if (mounted) setState(() => _deleting = false);
  }

  /// "Frames saved: X of Y", the saving progress and Stop, or the button
  /// that saves the rest.
  List<Widget> _keptFramesStatus(KeptFramesStatus kept) {
    final p = _keepProgress;
    if (_keeping) {
      return [
        const SizedBox(height: 8),
        LinearProgressIndicator(value: p == null || p.total == 0 ? null : p.done / p.total, minHeight: 6),
        const SizedBox(height: 4),
        Text(p == null ? 'Saving the kept frames…' : 'Saving the kept frames: ${p.done} of ${p.total}'),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
          icon: const Icon(Icons.stop),
          label: Text(_cancelRequested ? 'Stopping…' : 'Stop'),
        ),
      ];
    }
    if (kept.total == 0) return const [];
    return [
      const SizedBox(height: 4),
      Text('Kept frames saved: ${kept.saved} of ${kept.total} (${formatBytes(kept.bytes)}).'),
      if (kept.noVideo > 0)
        Text(
          '${kept.noVideo} ${kept.noVideo == 1 ? 'frame' : 'frames'} can no longer be saved: '
          'their video is gone from the session folder.',
          style: const TextStyle(color: Colors.amber, fontSize: 13),
        ),
      if (kept.remaining > 0) ...[
        const SizedBox(height: 4),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _onSaveKeptFrames,
          icon: const Icon(Icons.photo_library_outlined),
          label: Text('Save the remaining ${kept.remaining} ${kept.remaining == 1 ? 'frame' : 'frames'}'),
        ),
      ],
    ];
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
            ...temperatureGauge(
              p.tempC!,
              _prefs.thermalLimitC,
              paused: p.note.isNotEmpty,
              limitWhere: 'in "Detection, track ID and identification settings"',
            ),
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

/// Full-screen page to place the analysed square on a video. Pops the chosen
/// [Roi] with its side snapped to a multiple of 32 video pixels (as the live
/// camera's square), or null when left with Back.
///
/// Round 273: the clip plays under the square (muted, looping, 4× at first,
/// up to 10×), so camera or flower movement over the whole video shows before
/// the square is placed. [videoPaths] are the session's clips of the same
/// picture size, the first clip first. Until the player is ready, or when the
/// phone cannot play the clip, the first frame ([frameJpeg]) is shown.
class VideoSquareEditor extends StatefulWidget {
  final Uint8List frameJpeg;

  /// Upright size of the video in pixels.
  final int frameWidth;
  final int frameHeight;
  final Roi initial;
  final List<String> videoPaths;

  const VideoSquareEditor({
    super.key,
    required this.frameJpeg,
    required this.frameWidth,
    required this.frameHeight,
    required this.initial,
    this.videoPaths = const [],
  });

  @override
  State<VideoSquareEditor> createState() => _VideoSquareEditorState();
}

class _VideoSquareEditorState extends State<VideoSquareEditor> {
  late Roi _roi = widget.initial.copyClamped(frameAspect: _aspect);

  VideoPlayerController? _video;
  int _clip = 0;
  double _speed = 4;
  String? _playError;

  /// The position the time bar's marker shows (ms).
  final _posMs = ValueNotifier<int>(0);

  /// Counts clip openings: a slow one that finishes after the next started
  /// is dropped.
  int _opening = 0;

  double get _aspect => widget.frameWidth / widget.frameHeight;

  /// Largest square that fits the picture, and the smallest the box allows
  /// (5% of the width), both on the 32-pixel grid.
  int get _maxPx => max(32, largestSquareSidePx(widget.frameWidth, widget.frameHeight));
  int get _minPx => min(_maxPx, max(32, (0.05 * widget.frameWidth / 32).ceil() * 32));
  int get _sidePx => snapToMultipleOf32(_roi.sideFraction * widget.frameWidth).clamp(_minPx, _maxPx);

  @override
  void initState() {
    super.initState();
    if (widget.videoPaths.isNotEmpty) _openClip(0);
  }

  @override
  void dispose() {
    _opening++;
    _video?.removeListener(_onValue);
    _video?.dispose();
    _keepAwake(false);
    _posMs.dispose();
    super.dispose();
  }

  Future<void> _openClip(int index) async {
    final opening = ++_opening;
    final old = _video;
    old?.removeListener(_onValue);
    setState(() {
      _clip = index;
      _video = null;
      _playError = null;
    });
    _keepAwake(false);
    await old?.dispose();
    final c = VideoPlayerController.file(
      File(widget.videoPaths[index]),
      // No audio focus: music the user is listening to keeps playing.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await c.initialize();
      await c.setVolume(0);
      await c.setLooping(true);
      await c.setPlaybackSpeed(_speed);
      await c.play();
    } catch (e) {
      logSwallowed('video_square_open', e);
      await c.dispose();
      if (mounted && opening == _opening) setState(() => _playError = '$e');
      return;
    }
    if (!mounted || opening != _opening) {
      await c.dispose();
      return;
    }
    c.addListener(_onValue);
    setState(() => _video = c);
    _onValue();
  }

  /// The screen stays on while the clip plays (the Android player does not
  /// keep it on by itself), as in the session's Video tab; the time bar's
  /// marker follows the position.
  void _onValue() {
    final v = _video?.value;
    _keepAwake(v?.isPlaying ?? false);
    _posMs.value = v?.position.inMilliseconds ?? 0;
  }

  /// Round 309: a hold of its own ([ScreenOn]), so it never switches off one a run needs.
  void _keepAwake(bool on) => on ? ScreenOn.hold(this) : ScreenOn.release(this);

  void _togglePlay() {
    final c = _video;
    if (c == null) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _video?.setPlaybackSpeed(speed);
  }

  /// Clip choice (several clips), play/pause with the time bar, and the
  /// speeds shared with the session's Video tab.
  List<Widget> _playerControls() {
    final c = _video;
    final n = widget.videoPaths.length;
    return [
      if (n > 1)
        DropdownButton<int>(
          isExpanded: true,
          value: _clip,
          items: [
            for (var i = 0; i < n; i++)
              DropdownMenuItem(
                value: i,
                child: Text('Clip ${i + 1} of $n: ${widget.videoPaths[i].split('/').last}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (i) => i == null || i == _clip ? null : _openClip(i),
        ),
      if (_playError != null)
        const Text('This phone could not play this clip; its first frame is shown.', style: helperTextStyle)
      else if (c != null)
        Row(
          children: [
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (_, v, _) => IconButton(
                tooltip: v.isPlaying ? 'Pause' : 'Play',
                onPressed: _togglePlay,
                icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
            ),
            // Round 307: the Video tab's time bar, without stretches or marks (grey, with the marker).
            Expanded(
              child: VideoTimelineBar(
                controller: c,
                positionMs: _posMs,
                onSeek: (ms) => c.seekTo(Duration(milliseconds: ms)),
              ),
            ),
          ],
        ),
      VideoSpeedChips(speed: _speed, onChanged: _setSpeed),
      const SizedBox(height: 4),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final steps = (_maxPx - _minPx) ~/ 32;
    return Scaffold(
      appBar: AppBar(title: const Text('Area to analyze'), actions: const [HomeButton()]),
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
                      if (_video case final video?) Positioned.fromRect(rect: picture, child: VideoPlayer(video)),
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
                  if (widget.videoPaths.isNotEmpty) ..._playerControls(),
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
                  Text(
                    widget.videoPaths.isEmpty
                        ? 'Drag the square onto the flowers; pinch or use the slider to resize. The first frame '
                              'of the first clip is shown.'
                        : 'Drag the square onto the flowers; pinch or use the slider to resize. The video plays '
                              'fast (4×, up to 10×), so you see whether the camera or the flowers move during it '
                              'and the square still covers them.',
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
