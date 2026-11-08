// FaunaPulse — end-of-session dashboard.
//
// Three tabs since round 187 (Photos | Graphs | Setup — the old Overview tab
// was redundant with Setup and is gone: its dates/battery/storage rows lead
// the Setup tab, the visit count sits above the Graphs tab's timeline, the
// gallery export lives on the Photos tab, and Delete stayed only in the
// per-session menu of the session list (the Sessions screen since round 277)).
//
// Two loading stages, to stay fast even after a long, busy session:
//  1. Headline stats read cheaply from just the first and last lines of the
//     log (the session start/end records).
//  2. Graphs: a Gantt/phenology-style visit timeline (one lane per track id)
//     rendered up front — with the visit count, a visit-length histogram and
//     a per-session visits-by-hour chart (round 187) — plus, behind a
//     tap-to-expand "Extra graphs" section (round 148), phone temperature,
//     frames-per-second and power over time, each with its
//     average/median/min/max printed underneath. One full-log parse fills all
//     of them when the Graphs tab opens; the stats are derived live from the
//     per-sample records already in the log, so they work for past sessions
//     too.
//
// The screen's State class is large, so its methods live in `part` files under
// `session_summary/`, one per tab or job (the `part` lines below are the table
// of contents); the photo viewer and the chart painters are parts too. Each
// part file with State methods is an extension on the State class: it sees
// every private field, but it cannot declare fields or override lifecycle
// methods, so those stay here, with the getters. Constants that a part uses are
// file-level (`const` at the top level, after the class), because an extension
// cannot reach a class static without the class name.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/schedule_window.dart';
import '../models/session_config.dart';

import '../capture/crop_export.dart';
import '../capture/roi_capture.dart' show roiStreamSideFromLog;
import '../capture/roi_video.dart' show VideoClipTotals;
import '../models/field_notes.dart';
import '../session/location_fix.dart';
import '../logging/app_error_hooks.dart';
import '../logging/photo_box_matcher.dart';
import '../logging/session_log_index.dart';
import '../logging/device_storage.dart';
import '../logging/track_source.dart';
import '../logging/visit_stats.dart';
import '../widgets/mini_bar_chart.dart';
import '../widgets/session_tile.dart' show sessionDate, sessionTime;
import '../widgets/setting_help.dart';
import '../widgets/video_review_player.dart';
import '../widgets/home_button.dart';
import '../widgets/dialog_title.dart';
import '../postprocess/photo_keep.dart';
import '../postprocess/post_detector.dart' show PostBox, PostDetector;
import '../postprocess/video_detector.dart' show VideoDetector;
import '../postprocess/video_run_samples.dart';
import '../postprocess/video_tracker.dart' show KeepFramesSettings, VideoTracker;
import '../identification/identification_job.dart' show IdentificationJob;
import '../identification/identification_store.dart' show IdentificationPaths, LatestIdentification;
import 'identification_results_screen.dart';
import 'identification_screen.dart';
import 'video_analysis_screen.dart';

part 'session_summary/loading.dart';
part 'session_summary/setup_tab.dart';
part 'session_summary/gallery_export.dart';
part 'session_summary/video_tab.dart';
part 'session_summary/graphs_tab.dart';
part 'session_summary/photos_tab.dart';
part 'session_summary/photo_viewer.dart';
part 'session_summary/chart_painters.dart';

class SessionSummaryScreen extends StatefulWidget {
  final File logFile;

  /// Tab shown first (0 Photos, 1 Graphs, 2 Setup — round 187 order, the
  /// Overview tab is gone): the analysis screen's "Review photos before
  /// deleting" opens on the Photos tab (round 137), which is also the
  /// default landing.
  final int initialTabIndex;

  const SessionSummaryScreen({
    super.key,
    required this.logFile,
    this.initialTabIndex = 0,
  });

  @override
  State<SessionSummaryScreen> createState() => _SessionSummaryScreenState();
}

class _SessionSummaryScreenState extends State<SessionSummaryScreen> {
  // Visit-timeline (Gantt) show/hide. The timeline can be very tall with many
  // ids, so it can be collapsed; a floating button (shown only while the timeline
  // is on screen) toggles it without scrolling back to the top.
  final ScrollController _scroll = ScrollController();

  final GlobalKey _timelineKey = GlobalKey();

  bool _showTimeline = true;

  bool _timelineInView = false;

  /// The floating show/hide control only exists when the timeline is real
  /// AND tall enough to be worth collapsing (round 165, owner request):
  /// in no-AI sessions (motion/time-lapse — no track ids by design) the
  /// timeline area is just an explanatory note, and a "Hide timeline"
  /// button floating over it confused the user; with only a few lanes
  /// there is no scrolling problem for the button to solve either.
  static const int _timelineCollapseMinLanes = 10;

  bool get _timelineCollapsible => _spans.length > _timelineCollapseMinLanes;

  bool _extraGraphsExpanded = false;

  int _durationBinSeconds = 1;

  // "All session settings" disclosure on the Setup tab (round 187): the tab
  // leads with the short Overview block; the full settings record unfolds on
  // tap. Deliberately ephemeral (opens collapsed every time).
  bool _setupSettingsExpanded = false;

  // --- Stage 1: cheap headline stats (from first/last log lines) ---
  bool _loadingStats = true;

  String? _model;

  String? _accelerator;

  // The whole start-of-session record, kept so the settings section can list
  // every parameter the user configured (model, thresholds, tracker tuning, ROI,
  // sampling intervals, …). Cheap: it is the log's first line.
  Map<String, dynamic>? _startRec;

  int? _startMs;

  int? _endMs;

  bool _endedNormally = false;

  int? _uniqueTracks;

  /// The `guard_stop` record (round 296) when the recording stopped by itself
  /// before the battery or storage ran out, else null. Such a stop is clean, so
  /// "Ended normally" stays Yes; without this row the user could believe the
  /// session ran for its whole planned time.
  Map<String, dynamic>? _guardStop;

  /// Videos deleted to free storage and the space freed (round 236, from
  /// the `video_cleanup` records after the session's end).
  int _videosDeleted = 0;

  /// The clips of a recorded video session (round 239), from the log.
  VideoClipTotals _clipTotals = VideoClipTotals.none;

  /// Visits "Find visits" found in the clips of a live AI session, for
  /// comparison with the live AI's (round 241); null before it ran.
  int? _afterVisits;

  int _videosFreedBytes = 0;

  // Imported videos (round 229): the "Run AI on videos" settings, i.e. the
  // first `video_run_start` record of video_detections.jsonl. Null when the
  // videos were never analyzed.
  Map<String, dynamic>? _videoRun;

  // Battery state read cheaply from the start/end records: the battery percentage
  // at each (a rough independent check on the energy estimate) and whether the
  // phone was plugged in (which would invalidate the estimate).
  int? _startBatteryPct, _endBatteryPct;

  bool _chargingDuringSession = false;

  // The start/end records' own charging flags, kept for graph reloads.
  bool _chargingAtStartOrEnd = false;

  // --- Stage 2: graphs (full parse, on demand) ---
  bool _graphsRequested = false;

  bool _graphsLoading = false;

  final Map<int, (int first, int last)> _spans = {};

  /// Where [_spans] came from and, for visits found afterwards in the
  /// session's videos, their `post_track_start` record (round 229).
  TrackSource _trackSource = TrackSource.live;

  Map<String, dynamic>? _postTrackStart;

  /// Round 163 (perf review E5): ONE streaming parse of session.jsonl —
  /// built off the UI isolate by [SessionLogIndex.build] — serves graphs,
  /// photos, ROI history, diagnostics and track spans. The future is cached
  /// so however many tabs ask, the file is read once (twice when high-res
  /// box time-matching needs its second bounded pass). The cheap head/tail
  /// stats path ([_loadStats]) deliberately stays separate: the headline
  /// numbers must appear before this full parse finishes.
  Future<SessionLogIndex>? _indexFuture;

  Future<SessionLogIndex> get _logIndex =>
      _indexFuture ??= SessionLogIndex.build(widget.logFile);

  final List<(int ms, double v)> _temps = [];

  // Chip sensors (round 361): hottest CPU core and GPU, only on phones that let
  // the app read them; drawn on the temperature graph beside the battery line.
  final List<(int ms, double v)> _cpuTemps = [];
  final List<(int ms, double v)> _gpuTemps = [];

  // "Thermal headroom" 0..1+ (0 = cool, 1 = throttling threshold) — a direct
  // throttling signal, sampled alongside temperature.
  final List<(int ms, double v)> _headroom = [];

  final List<(int ms, double v)> _fps = [];

  // Inference time (ms) per second — the direct compute-throttle signal (it
  // climbs as the SoC downclocks, even when battery temperature looks flat).
  final List<(int ms, double v)> _infMs = [];

  // Round 346: memory in use by everything on the phone (GB) and the processor
  // cores this app kept busy, from the same readings as the temperature.
  final List<(int ms, double v)> _memUsedGb = [];
  final List<(int ms, double v)> _appCpuCores = [];

  // Instantaneous battery power (W) over the session (the W graph).
  final List<(int ms, double v)> _power = [];

  // Imported videos (round 232): the lists above hold the phone's state
  // while the AI ran on the videos instead, on the analysis clock of these
  // samples (video_detections.jsonl). Null when never measured.
  VideoRunSamples? _videoSamples;

  // The session's total energy (Wh) — integral of the power curve — plus the
  // average/min/max power, shown as numbers (no Wh graph).
  double? _energyTotalWh;

  double? _powerAvg, _powerMedian, _powerMin, _powerMax;

  int _totalSavedPhotos = 0;

  // How many of those are reference photos (gt_frames/, periodic clock).
  int _totalReferencePhotos = 0;

  bool _photosRequested = false;

  bool _photosLoading = false;

  // Round 209: how many photos the random sample holds (10 by default, the
  // user can pick 50, 100 or all = null). Kept so a reload after a post-hoc
  // cleanup restores the same view, not a fresh 10-photo sample.
  int? _photoSampleSize = _randomSampleCount;

  List<_PhotoSample> _photos = const [];

  // Round 209: the newest identification result of this session (null when
  // never identified) — shown under each photo in the viewer.
  LatestIdentification? _identification;

  /// The newest identification used visits found before the last "Find
  /// visits" (round 235): its answers are not shown on the frames.
  bool _identificationStale = false;

  // True while the photo viewer is zoomed in: the TabBarView and the Photos
  // ListView freeze so their drags can't steal the user's panning (round 89).
  bool _photoViewerZoomed = false;

  // --- ROI change history (round 109; full-line scan, lazy) ---
  // One entry per settled mid-session ROI change (`roi_update` records —
  // debounced to one per adjustment since round 109; older sessions may carry
  // one per drag tick, all shown). Loaded the first time the Settings tab
  // builds, so the cheap head/tail stats path stays untouched.
  bool _roiHistoryRequested = false;

  List<({int timeMs, int? sidePx, int? savesPx, String? source})> _roiHistory =
      const [];

  // Overview storage section (round 90): the session folder's on-disk size
  // and the phone's free storage, loaded once in initState.
  int? _sessionSizeBytes;

  StorageReading _storage = const StorageReading();

  // Gallery export (round 93): busy flag + progress ticks for the Photos
  // tab's "Copy photos" button (moved there from the retired Overview tab,
  // round 187).
  bool _galleryExportBusy = false;

  int _galleryExportDone = 0;

  int _galleryExportTotal = 0;

  // Round 239: the running copy is of video clips, not photos.
  bool _galleryExportVideos = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateTimelineInView);
    _init();
    _loadStorageInfo();
    _loadPostHoc();
    _loadVideoRun();
    _loadIdentification();
    _loadClipTotals();
  }

  // Post-hoc analysis results for this session (round 137): outcomes parsed
  // from post_detections.jsonl, the keep set at the analysis screen's saved
  // gap, and the ready-made box overlays / deletion marks for the Photos tab.
  List<PhotoOutcome>? _postOutcomes;

  Set<String> _postKeep = const {};

  double _postGapSeconds = 2.0;

  /// Round 179: the review-time tiny-box threshold (fraction of the photo
  /// side) the loaded outcomes were filtered with; audited on deletion.
  double _postMinBoxFrac = 0;

  Map<String, List<_DetBox>> _postBoxesByName = const {};

  Map<String, KeepDecision> _postDecisions = const {};

  Set<String> _postDeleteMarked = const {};

  bool _postDeleting = false;

  @override
  void dispose() {
    _scroll.removeListener(_updateTimelineInView);
    _scroll.dispose();
    super.dispose();
  }

  /// Battery percentage drop over the session, or null if not both known.
  int? get _batteryDrainPercent {
    final s = _startBatteryPct, e = _endBatteryPct;
    if (s == null || e == null) return null;
    return s - e;
  }

  /// "+3m 41s" offset of a log timestamp from the session start (empty when
  /// either time is unknown — the row then shows just the change itself).
  String _offsetLabel(int timeMs) {
    final start = _startMs;
    if (start == null || timeMs <= 0) return '';
    final s = ((timeMs - start) / 1000).round();
    if (s < 0) return '';
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '+${h}h ${m}m ${sec}s' : '+${m}m ${sec}s';
  }

  String get _durationLabel {
    if (_startMs == null || _endMs == null || _endMs! < _startMs!) {
      return 'unknown (no end record: crash or forced stop)';
    }
    return _hmsLabel(_endMs! - _startMs!);
  }

  /// Why the guard stopped the recording ("Yes: storage almost full (140 MB
  /// free, limit 200 MB)"), or null when it did not. The limits come from the
  /// saved settings (keys must match SessionConfig and the reasons
  /// guardStopReason returns).
  String? get _guardStopLabel {
    final g = _guardStop;
    if (g == null) return null;
    final free = g['free_storage_bytes'];
    final reserve = _setting('storageReserveMb');
    final level = g['battery_percent'];
    final limit = _setting('lowBatteryStopPercent');
    return switch (g['reason']) {
      'storage_low' =>
        'Yes: storage almost full (${free is num ? '${(free / (1024 * 1024)).round()} MB free' : 'free space unknown'}'
            '${reserve != null ? ', limit ${_numStr(reserve)} MB' : ''})',
      'low_battery' =>
        'Yes: battery low (${level is num ? '${level.round()} %' : 'level unknown'}'
            '${limit != null ? ', limit ${_numStr(limit)} %' : ''})',
      final r => 'Yes ($r)',
    };
  }

  /// "8% (from 74% to 66%)" or "unknown". (Android's battery % can be coarse/laggy,
  /// so it's shown only as a rough independent check on the energy estimate.)
  String get _batteryUsedLabel {
    final drop = _batteryDrainPercent;
    if (drop == null) return 'unknown';
    // Round 317: a level that rose (charger or power bank, the normal field
    // setup) printed as a negative use ("-5%"), which read like an error.
    if (drop < 0) {
      return 'none (it rose by ${-drop}% while charging, from '
          '$_startBatteryPct% to $_endBatteryPct%)';
    }
    return '$drop% (from $_startBatteryPct% to $_endBatteryPct%)';
  }

  /// Reads a configured setting from the start record, preferring the nested
  /// `config` block (the full configuration, logged from round 43 on) and falling
  /// back to a top-level key for sessions recorded before that block existed.
  /// Returns null when neither is present, so its row can be skipped.
  Object? _setting(String configKey, [String? topKey]) {
    final cfg = _startRec?['config'];
    if (cfg is Map && cfg[configKey] != null) return cfg[configKey];
    if (topKey != null) return _startRec?[topKey];
    return null;
  }

  /// True for sessions recorded in motion-only capture mode (detector never
  /// ran): zero detections/tracks is the mode working, not an empty session.
  /// Accepts both the round-97 enum key and the legacy round-95 bool.
  bool get _motionOnlySession =>
      _setting('captureTrigger') == 'motion' ||
      _setting('motionOnlyCapture') == true;

  /// True for time-lapse sessions (round 97) — clock-triggered photos, no
  /// detector, no motion check.
  bool get _timeLapseSession => _setting('captureTrigger') == 'timelapse';

  /// True for videos imported with "Import videos…" (round 227): no camera
  /// settings, and the AI runs afterwards ("Run AI on videos").
  bool get _importedVideoSession => _startRec?['source'] == 'imported_video';

  /// Time-lapse bursts recorded as video clips (round 238): a live camera
  /// session (its own temperature, fps and power records), but its clips are
  /// analysed afterwards like imported ones.
  bool get _recordedVideoSession =>
      _timeLapseSession && _setting('timeLapseSaveAs') == 'video';

  /// Either kind of video session: a Video tab, "Run AI on videos".
  bool get _videoSession => _importedVideoSession || _recordedVideoSession;

  /// A live AI session that also recorded the ROI as video (round 240): a
  /// Video tab with the live AI's boxes, its photos below the player.
  bool get _liveVideoSession => !_noAiSession && _setting('liveAiVideo') == true;

  /// The extra graphs show the phone while the AI ran on the videos (round
  /// 232) instead of during the recording: always for imported videos, and
  /// by choice for recorded bursts (round 239).
  bool get _showRunGraphs =>
      _importedVideoSession || ((_recordedVideoSession || _liveVideoSession) && _graphsOfAnalysis);

  bool _graphsOfAnalysis = false;

  /// Plain-language mode shown first in Setup's Overview. Sessions older
  /// than the capture-trigger setting were AI-detector sessions unless they
  /// carry the legacy motion-only flag handled above.
  String get _captureModeLabel => _importedVideoSession
      ? 'Imported videos (detection afterwards)'
      : _recordedVideoSession
      ? 'Time-lapse video bursts (detection afterwards)'
      : _timeLapseSession
      ? 'Time-lapse photo bursts (no live detection)'
      : _motionOnlySession
      ? 'Motion-triggered photos (no live detection)'
      : 'Live detection';

  bool get _noAiSession =>
      _motionOnlySession || _timeLapseSession || _importedVideoSession;

  /// The visits were found afterwards in the session's videos ("Find
  /// visits", round 229) rather than tracked live.
  bool get _visitsAfterwards => _trackSource == TrackSource.afterwards;

  /// A value of the `post_track_start` record (visits found afterwards).
  Object? _post(String key) => _postTrackStart?[key];

  /// Visits found afterwards in a motion or time-lapse session's photos
  /// (round 237) rather than in videos.
  bool get _visitsFromPhotos => _visitsAfterwards && _post('source') == 'photos';

  /// The tracker settings block of visits found afterwards.
  Map? get _postTracker => _post('tracker') as Map?;

  /// True only for sessions recorded with the short-lived round-148 build,
  /// where diagnostic logging was opt-in and off by default: those logs have
  /// no temperature/FPS/power records by design, so the Extra graphs section
  /// explains that instead of showing empty charts. Round 149 made the
  /// streams always-logged again and removed the toggle (only their display
  /// is opt-in, via this collapsed section), so every other session — older
  /// or newer — lacks the key (or has it `true`) and renders normally.
  bool get _diagnosticsOffSession => _setting('diagnosticsEnabled') == false;

  /// The tracker (ByteTrack) tuning block, from the `config` block or the
  /// top-level `tracker_params` (older sessions).
  Map? get _trackerParams {
    if (_visitsAfterwards) return _postTracker;
    final cfg = _startRec?['config'];
    if (cfg is Map && cfg['trackerParams'] is Map) {
      return cfg['trackerParams'] as Map;
    }
    final tp = _startRec?['tracker_params'];
    return tp is Map ? tp : null;
  }

  /// The tracker values really used, with its frame budgets: the start
  /// record's `tracker_params` (the live tracker's effective values), or the
  /// "Find track IDs" run's. Round 313: the summary read the frame budget from
  /// the stored settings, which always held the default 30.
  Map? get _usedTracker {
    if (_visitsAfterwards) return _postTracker;
    final tp = _startRec?['tracker_params'];
    return tp is Map ? tp : null;
  }

  /// The C-BIoU tuning block (round 105), only present when that algorithm
  /// was selectable when the session was recorded.
  Map? get _cbiouParams {
    if (_visitsAfterwards) return _postTracker;
    final cfg = _startRec?['config'];
    return (cfg is Map && cfg['cbiouParams'] is Map)
        ? cfg['cbiouParams'] as Map
        : null;
  }

  /// Which association algorithm produced this session's track ids:
  /// 'bytetrack' or 'cbiou'. Sessions recorded before round 105 carry no key
  /// — they were all ByteTrack.
  String get _trackerAlgorithm =>
      ((_visitsAfterwards ? _postTracker : null)?['algorithm'] ??
              _setting('trackerAlgorithm') ??
              (_startRec?['tracker_params'] is Map
                  ? (_startRec!['tracker_params'] as Map)['algorithm']
                  : null) ??
              'bytetrack')
          .toString();

  /// Formats a number without a needless trailing ".0".
  String _numStr(Object? v) {
    if (v is int) return v.toString();
    if (v is double) {
      return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
    }
    return v?.toString() ?? '';
  }

  /// "W × H px" from two values, or null if either is missing.
  String? _dims(Object? w, Object? h) {
    if (w is! num || h is! num) return null;
    return '${w.toInt()} × ${h.toInt()} px';
  }

  @override
  Widget build(BuildContext context) {
    // Three tabs keep the summary uncluttered: the saved-photo browser, the
    // graphs and the setup record each get their own page instead of one
    // very long scroll. The old Overview tab is gone (round 187, owner
    // request — it was redundant with Setup): its rows lead the Setup tab
    // now, the visit count sits above the Graphs timeline, and the gallery
    // export moved to Photos. "Setup" sits last (round 182: the settings
    // record is consulted least; the label avoids confusion with the live
    // settings sheet — these rows are the read-only record of what the
    // session ran with).
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTabIndex.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Session summary'),
          actions: const [HomeButton()],
          bottom: TabBar(
            tabs: [
              Tab(text: _videoTab ? 'Video' : 'Photos'),
              const Tab(text: 'Graphs'),
              const Tab(text: 'Setup'),
            ],
          ),
        ),
        body: _loadingStats
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                // Frozen while a photo is zoomed: the tab swipe would win the
                // horizontal drags the user means as photo panning. Tapping
                // the tab bar still switches tabs (physics gate user drags
                // only).
                physics: _photoViewerZoomed
                    ? const NeverScrollableScrollPhysics()
                    : null,
                children: [
                  _videoTab ? _videoReviewTab() : _photosTab(),
                  _graphsTab(),
                  _setupTab(),
                ],
              ),
      ),
    );
  }

  /// Tab content padding. The bottom term is 64 px of clearance for the
  /// Graphs tab's floating timeline button PLUS the system bottom inset:
  /// giving a ListView an EXPLICIT `padding` disables Flutter's automatic
  /// MediaQuery inset padding, and the app renders edge-to-edge (forced by
  /// targetSdk 36 on Android 15+), so without the inset the last rows sit
  /// under the system navigation/gesture bar (round 165 field bug — the
  /// recurring "cannot scroll to the last element" class; regression test
  /// pattern in test/fauna_pulse/summary_bottom_inset_test.dart).
  EdgeInsets get _tabPadding => EdgeInsets.fromLTRB(
    16,
    16,
    16,
    64 + MediaQuery.paddingOf(context).bottom,
  );

  /// Imported videos get a "Video" tab instead of "Photos" (round 231).
  /// Until the start record is read, a videos/ folder decides, so the tab
  /// label does not flip once loading is done.
  bool get _videoTab => _startRec == null ? _hasVideoFolder : _videoSession || _liveVideoSession;

  late final bool _hasVideoFolder = Directory(
    '${widget.logFile.parent.path}/videos',
  ).existsSync();

  /// The Video tab's player, for "Show in video" on a kept frame.
  final _videoPlayerKey = GlobalKey<VideoReviewPlayerState>();
}

// "Extra graphs" disclosure (round 148): the diagnostic graphs (temperature,
// FPS, inference time, power) sit behind a tap-to-expand header so the visit
// timeline — the main deliverable — is all a general user sees. Mirrors the
// camera screen's collapsible stats panel: a viewing preference persisted in
// SharedPreferences (not SessionConfig), collapsed by default.
const String _extraGraphsExpandedKey = 'extra_graphs_expanded';

// Visit-length histogram bin width in seconds (round 187). A viewing
// preference like the "Extra graphs" state (SharedPreferences, never
// SessionConfig — it changes how recorded data is displayed, not what is
// recorded), so the ecologist's preferred bin sticks across sessions.
const String _durationBinKey = 'summary_duration_bin_s';

const List<int> _durationBinChoices = [
  1, 2, 3, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, //
];

// --- Sample photos (round 187: auto-loaded, random) ---
// The tab shows up to [_randomSampleCount] RANDOM photos by default — a
// long session can hold thousands, and loading them all unasked would be
// slow. "Show all photos" loads everything (with a warning first when the
// session is large).
const int _randomSampleCount = 10;

const int _showAllWarnThreshold = 300;

const List<int> _sampleChoices = [_randomSampleCount, 50, 100];

/// Reads + parses post_detections.jsonl in a worker isolate. A TOP-LEVEL
/// sync wrapper on purpose (round 175, owner bug): inlined inside the
/// async [_loadPostHoc] the `Isolate.run` closure shared the method's
/// context, which holds the current Zone for the async machinery — and the
/// app runs inside `runZonedGuarded` (app_error_hooks), a CUSTOM Zone,
/// which is unsendable. `Isolate.run` then threw "Illegal argument in
/// isolate message" on every call and the catch swallowed it, so no green
/// post-hoc box ever rendered (broken since the round-163 move
/// off the UI isolate). Same shape as `SessionLogIndex.build`, which never
/// had the problem for exactly this reason. Regression test:
/// summary_posthoc_boxes_test.dart.
Future<List<PhotoOutcome>> _outcomesOffUi(String path) =>
    Isolate.run(() => photoOutcomesFromJsonl(File(path).readAsStringSync()));

String _hmsLabel(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '${h}h ${m}m ${sec}s' : '${m}m ${sec}s';
}

/// The timeline's note for motion and time-lapse photo sessions without
/// track IDs: they can still get them afterwards (round 317; the old note
/// said none were recorded, which read as never possible).
const _photosNoTrackIdsYet =
    'no detector ran while recording, so there are no track IDs yet. '
    '"Find animals in photos" (home screen, or the session\'s ⋮ menu on the '
    'Sessions screen) finds the animals in the photos, then "Find track IDs" '
    'there follows each one from photo to photo (if the photos are close '
    'enough in time).';

/// Normalizes a reported battery voltage (mV) to a single Li-ion cell voltage (V).
/// Some phones (e.g. several Xiaomi models) report the voltage of a 2-cell
/// battery in series (~7–9 V) while the charge counter is the pack capacity — so
/// `charge × voltage` would double the real energy (e.g. an impossible 38 Wh
/// phone battery). A single Li-ion cell tops out near 4.45 V, so any value well
/// above that is halved back into a sensible per-cell figure. Returns null if no
/// voltage was reported.
double? _singleCellVoltageV(int? mv) {
  if (mv == null || mv <= 0) return null;
  var v = mv / 1000.0;
  while (v > 4.6) {
    v /= 2; // 8.85 V → 4.42 V (handles the 2S series-voltage quirk)
  }
  return v;
}
