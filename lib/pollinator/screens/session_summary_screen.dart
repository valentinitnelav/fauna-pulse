// Pollinator Monitor — end-of-session dashboard.
//
// Two stages, to stay fast even after a long, busy session:
//  1. Headline numbers shown immediately — unique insect count, session length,
//     model used, and where the data was saved. These are read cheaply from just
//     the first and last lines of the log (the session start/end records).
//  2. Graphs: a Gantt/phenology-style visit timeline (one lane per track id),
//     phone temperature, frames-per-second and power over time, each with its
//     average/median/min/max printed underneath. These require reading the whole
//     log, so they compute automatically only when the "Compute graphs
//     automatically" setting is on (default); otherwise the user taps a
//     "Generate graphs" button. Either way the stats are derived live from the
//     per-sample records already in the log, so they work for past sessions too.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/session_config.dart';

import '../capture/crop_export.dart';
import '../logging/app_error_hooks.dart';
import '../logging/device_storage.dart';

class SessionSummaryScreen extends StatefulWidget {
  final File logFile;

  const SessionSummaryScreen({super.key, required this.logFile});

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

  // Battery state read cheaply from the start/end records: the battery percentage
  // at each (a rough independent check on the energy estimate) and whether the
  // phone was plugged in (which would invalidate the estimate).
  int? _startBatteryPct, _endBatteryPct;
  bool _chargingDuringSession = false;

  // --- Stage 2: graphs (full parse, on demand) ---
  bool _graphsRequested = false;
  bool _graphsLoading = false;
  final Map<int, (int first, int last)> _spans = {};

  /// Widens track [id]'s first/last-seen span to include time [t].
  void _extendSpan(int? t, int? id) {
    if (id == null || t == null) return;
    final cur = _spans[id];
    _spans[id] = cur == null
        ? (t, t)
        : (cur.$1 < t ? cur.$1 : t, cur.$2 > t ? cur.$2 : t);
  }

  final List<(int ms, double v)> _temps = [];
  // "Thermal headroom" 0..1+ (0 = cool, 1 = throttling threshold) — a direct
  // throttling signal, sampled alongside temperature.
  final List<(int ms, double v)> _headroom = [];
  final List<(int ms, double v)> _fps = [];
  // Inference time (ms) per second — the direct compute-throttle signal (it
  // climbs as the SoC downclocks, even when battery temperature looks flat).
  final List<(int ms, double v)> _infMs = [];
  // Instantaneous battery power (W) over the session (the W graph).
  final List<(int ms, double v)> _power = [];
  // The session's total energy (Wh) — integral of the power curve — plus the
  // average/min/max power, shown as numbers (no Wh graph).
  double? _energyTotalWh;
  double? _powerAvg, _powerMedian, _powerMin, _powerMax;

  // --- Sample photos (full parse, on demand) ---
  int _sampleCount = 5;
  int _totalSavedPhotos = 0;
  bool _photosRequested = false;
  bool _photosLoading = false;
  List<_PhotoSample> _photos = const [];

  // True while the photo viewer is zoomed in: the TabBarView and the Photos
  // ListView freeze so their drags can't steal the user's panning (round 89).
  bool _photoViewerZoomed = false;

  // Overview storage section (round 90): the session folder's on-disk size
  // and the phone's free storage, loaded once in initState.
  int? _sessionSizeBytes;
  StorageReading _storage = const StorageReading();

  // Gallery export (round 93): busy flag + progress ticks for the Overview
  // "Export photos to Gallery" button. While busy, Delete is disabled too —
  // deleting the folder mid-copy would only produce confusing "failed" counts.
  bool _galleryExportBusy = false;
  int _galleryExportDone = 0;
  int _galleryExportTotal = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateTimelineInView);
    _init();
    _loadStorageInfo();
  }

  /// Loads the Overview's storage section: the session folder's total size
  /// (same scan as the home history list, so the numbers match) and the
  /// phone's free storage (same source as the recording screen's readout).
  Future<void> _loadStorageInfo() async {
    final size = await folderSizeBytes(widget.logFile.parent);
    final storage = await DeviceStorage.read();
    if (mounted) {
      setState(() {
        _sessionSizeBytes = size;
        _storage = storage;
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_updateTimelineInView);
    _scroll.dispose();
    super.dispose();
  }

  /// Tracks whether the visit-timeline section is currently within the viewport,
  /// so the floating show/hide button appears only while it's on screen and
  /// vanishes once the user scrolls to other graphs.
  void _updateTimelineInView() {
    final ctx = _timelineKey.currentContext;
    bool visible = false;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final screenH = MediaQuery.of(context).size.height;
        // Visible if any part of the timeline overlaps the screen.
        visible = bottom > 80 && top < screenH - 40;
      }
    }
    if (visible != _timelineInView) {
      setState(() => _timelineInView = visible);
    }
  }

  /// Loads the cheap headline stats first, then — if the user's "Compute graphs
  /// automatically" setting is on — kicks off the full graph computation so the
  /// graphs appear without a button press.
  Future<void> _init() async {
    await _loadStats();
    if (!mounted) return;
    final cfg = await SessionConfig.load();
    if (mounted && cfg.autoComputeGraphs && !_graphsRequested) {
      _loadGraphs();
    }
  }

  /// Reads only the head and tail of the file to get the start/end records,
  /// avoiding a full scan of a potentially huge log.
  Future<void> _loadStats() async {
    try {
      final raf = await widget.logFile.open();
      try {
        final len = await raf.length();
        // Head: the first record is the session start.
        final headLen = min(8192, len);
        final head = await raf.read(headLen);
        for (final l in utf8.decode(head, allowMalformed: true).split('\n')) {
          if (l.contains('"start_of_session"')) {
            final rec = _tryDecode(l);
            _startRec = rec;
            _model = rec?['model_path'] as String?;
            _accelerator = rec?['accelerator'] as String?;
            _startMs = (rec?['time_ms'] as num?)?.toInt();
            _startBatteryPct = (rec?['battery_percent'] as num?)?.toInt();
            _readChargingFlag(rec);
            break;
          }
        }
        // Tail: the last record (if any) is the session end.
        final tailLen = min(16384, len);
        await raf.setPosition(len - tailLen);
        final tail = await raf.read(tailLen);
        final tailLines = utf8
            .decode(tail, allowMalformed: true)
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        for (final l in tailLines.reversed) {
          if (l.contains('"end_of_session"')) {
            final rec = _tryDecode(l);
            _endedNormally = rec?['ended_normally'] == true;
            _endMs = (rec?['time_ms'] as num?)?.toInt();
            _uniqueTracks = (rec?['unique_track_count'] as num?)?.toInt();
            _endBatteryPct = (rec?['battery_percent'] as num?)?.toInt();
            _readChargingFlag(rec);
            break;
          }
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      // Leave defaults; the file may be empty or truncated by a crash.
      logSwallowed('summary_stats_scan', e);
    }
    if (mounted) setState(() => _loadingStats = false);
  }

  Map<String, dynamic>? _tryDecode(String line) {
    try {
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      // Deliberately silent (B7-reviewed): a line truncated by a crash is
      // expected in an append-only log, and this runs per line.
      return null;
    }
  }

  /// Notes whether the phone was plugged in (from a start/end record's nested
  /// `thermal` block) — if it was, the energy estimate isn't meaningful.
  void _readChargingFlag(Map<String, dynamic>? rec) {
    final th = rec?['thermal'];
    if (th is! Map) return;
    if (th['is_charging'] == true) _chargingDuringSession = true;
  }

  /// Battery percentage drop over the session, or null if not both known.
  int? get _batteryDrainPercent {
    final s = _startBatteryPct, e = _endBatteryPct;
    if (s == null || e == null) return null;
    return s - e;
  }

  /// Full parse for the graphs: visit spans per track, temperature and FPS series.
  Future<void> _loadGraphs() async {
    setState(() {
      _graphsRequested = true;
      _graphsLoading = true;
    });
    // Raw battery samples gathered from the `power` records, post-processed below
    // into the power/energy series (so we can correct for per-device current units).
    final raw = <_PowerSample>[];
    try {
      final lines = await widget.logFile.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final rec = _tryDecode(line);
        if (rec == null) continue;
        final t = (rec['time_ms'] as num?)?.toInt();
        switch (rec['type']) {
          // 'detection': one line per track (sessions ≤ round 68).
          // 'detections': one line per frame with a `tracks` array (round 69+).
          case 'detection':
            _extendSpan(t, (rec['track_id'] as num?)?.toInt());
            break;
          case 'detections':
            final tracks = rec['tracks'];
            if (tracks is List) {
              for (final entry in tracks) {
                if (entry is Map) {
                  _extendSpan(t, (entry['track_id'] as num?)?.toInt());
                }
              }
            }
            break;
          case 'thermal':
            if (t == null) break;
            final temp = (rec['battery_temp_c'] as num?)?.toDouble();
            if (temp != null) _temps.add((t, temp));
            final hr = (rec['thermal_headroom'] as num?)?.toDouble();
            if (hr != null) _headroom.add((t, hr));
            // Older sessions logged FPS inside the thermal record; keep reading it
            // so their graphs still work alongside the newer dedicated 'fps' records.
            final f = (rec['fps'] as num?)?.toDouble();
            if (f != null) _fps.add((t, f));
            break;
          case 'fps':
            if (t == null) break;
            // Both fields estimate the detector's results/second; prefer
            // `pipeline_fps` because in sessions recorded before round 85 the
            // native `fps` EMA blended motion-gate sleep gaps in and read near
            // zero for the whole wake window (session_127: 0.5–5 logged vs ~10
            // real), while pipeline_fps stayed ≈ true. Post-r85 the two agree;
            // older sessions only carry `fps`.
            final f = ((rec['pipeline_fps'] ?? rec['fps']) as num?)?.toDouble();
            if (f != null) _fps.add((t, f));
            // Newer sessions also carry the inference time here; older ones don't.
            final inf = (rec['inf_ms'] as num?)?.toDouble();
            if (inf != null) _infMs.add((t, inf));
            break;
          case 'power':
            if (t == null) break;
            raw.add(
              _PowerSample(
                ms: t,
                currentUa: (rec['battery_current_ua'] as num?)?.toInt(),
                voltageMv: (rec['battery_voltage_mv'] as num?)?.toInt(),
                chargeUah: (rec['charge_counter_uah'] as num?)?.toInt(),
                loggedW: (rec['power_w'] as num?)?.toDouble(),
                isCharging: rec['is_charging'] as bool?,
              ),
            );
            break;
        }
      }
      _buildEnergySeries(raw);
      // If the start/end weren't found from head/tail (rare), fall back here.
      if (_spans.isNotEmpty) {
        _startMs ??= _spans.values.map((s) => s.$1).reduce(min);
        _endMs ??= _spans.values.map((s) => s.$2).reduce(max);
      }
      _uniqueTracks ??= _spans.length;
    } catch (e) {
      // Leave whatever parsed; a truncated line just stops the scan.
      logSwallowed('summary_graphs_scan', e);
    }
    if (mounted) setState(() => _graphsLoading = false);
  }

  /// Turns the raw battery samples into the power (W) and cumulative-energy (Wh)
  /// series. Two device quirks are handled:
  ///  - Some phones (notably Samsung) report the instantaneous current in
  ///    milliamps even though Android specifies microamps — that made power read
  ///    ~1000× too low (≈0 W). We detect this from the *magnitude* of the readings
  ///    (see below), which works even when the charge counter never moves.
  ///  - Some phones (notably Xiaomi) report a 2-cell *series* voltage (~8.8 V);
  ///    [_singleCellVoltageV] normalizes that so power/energy aren't doubled.
  void _buildEnergySeries(List<_PowerSample> raw) {
    // Battery-terminal readings only measure the PHONE's consumption while it
    // is discharging: plugged in, the sensor sees the charging current (or ~0
    // once the battery is full and the charger carries the load). Any charging
    // anywhere in the session — per-sample flags (round 84), or the start/end
    // flags already read by [_readChargingFlag] (the only signal on older logs
    // whose power records lack `is_charging`) — invalidates the whole series,
    // so nothing is built and no misleading W/Wh number can surface. The
    // Graphs tab shows an explanatory note instead.
    if (raw.any((s) => s.isCharging == true)) _chargingDuringSession = true;
    if (_chargingDuringSession) return;
    if (raw.length < 2) return;

    // Average single-cell voltage (V) across the session, used wherever a
    // per-sample voltage is missing. Falls back to a nominal Li-ion cell (3.85 V).
    final volts = raw
        .map((s) => _singleCellVoltageV(s.voltageMv))
        .whereType<double>()
        .toList();
    final avgV = volts.isEmpty
        ? 3.85
        : volts.reduce((a, b) => a + b) / volts.length;
    double voltAt(_PowerSample s) => _singleCellVoltageV(s.voltageMv) ?? avgV;

    // Decide whether the current readings are microamps (the spec) or milliamps
    // (some phones) purely from their magnitude. A phone actively recording draws
    // roughly 0.1–3 A, i.e. 100,000–3,000,000 as µA but only 100–3,000 as mA — a
    // clean ~10× gap — so a typical |reading| below 10,000 means milliamps. Using
    // the median makes this robust to the odd zero/spike, and (unlike the previous
    // charge-counter calibration) it still works when the charge counter is stuck.
    double currentScale = 1.0; // assume microamps
    final curUaAbs =
        raw
            .map((s) => s.currentUa)
            .whereType<int>()
            .map((ua) => ua.abs())
            .where((ua) => ua > 0)
            .toList()
          ..sort();
    if (curUaAbs.isNotEmpty) {
      final median = curUaAbs[curUaAbs.length ~/ 2];
      if (median < 10000) currentScale = 1000.0; // readings are in mA, not µA
    }

    // Per-sample power (W). Prefer the (scale-corrected) instantaneous current ×
    // voltage; otherwise derive it from the charge-counter drop since the last
    // sample; otherwise fall back to the value logged at capture time.
    final pts = <(int, double)>[];
    for (var i = 0; i < raw.length; i++) {
      final s = raw[i];
      double? w;
      if (s.currentUa != null && s.currentUa! != 0) {
        w = (s.currentUa!.abs() * currentScale / 1e6) * voltAt(s);
      } else if (i > 0 && s.chargeUah != null && raw[i - 1].chargeUah != null) {
        final dtH = (s.ms - raw[i - 1].ms) / 3600000.0;
        final dropAh = (raw[i - 1].chargeUah! - s.chargeUah!) / 1e6;
        if (dtH > 0) w = (dropAh / dtH) * voltAt(s);
      }
      w ??= s.loggedW;
      if (w != null && w >= 0) pts.add((s.ms, w));
    }
    if (pts.isEmpty) return;

    // A light 3-point moving average smooths the jitter from coarse current /
    // charge-counter steps, so the line is readable without hiding the trend.
    for (var i = 0; i < pts.length; i++) {
      final lo = i == 0 ? 0 : i - 1;
      final hi = i == pts.length - 1 ? i : i + 1;
      var sum = 0.0;
      for (var k = lo; k <= hi; k++) {
        sum += pts[k].$2;
      }
      _power.add((pts[i].$1, sum / (hi - lo + 1)));
    }

    // Average / median / min / max power across the session (reported as numbers).
    final ws = _power.map((e) => e.$2).toList();
    _powerAvg = ws.reduce((a, b) => a + b) / ws.length;
    _powerMin = ws.reduce(min);
    _powerMax = ws.reduce(max);
    _powerMedian = _seriesStats(_power)?.median;

    // Total energy used (Wh) = the integral of the power curve (trapezoid:
    // W × hours = Wh). We integrate the (fine, per-sample) power rather than read
    // the charge counter directly, because on several phones the charge counter
    // updates in big coarse steps — or not at all over a short session (one test
    // phone's counter never moved in 6 minutes) — whereas the power integral is
    // always available and, cross-checked against the charge drop, just as accurate.
    double wh = 0;
    for (var i = 1; i < _power.length; i++) {
      final dtH = (_power[i].$1 - _power[i - 1].$1) / 3600000.0;
      if (dtH <= 0) continue;
      wh += (_power[i].$2 + _power[i - 1].$2) / 2.0 * dtH;
    }
    _energyTotalWh = wh;
  }

  /// Parses the log for saved ROI photos and the detection boxes recorded
  /// against each one, then samples [_sampleCount] of them spread evenly across
  /// the session, so the user can eyeball whether detections look right.
  Future<void> _loadPhotos({bool all = false}) async {
    setState(() {
      _photosRequested = true;
      _photosLoading = true;
    });
    // Map each saved JPEG (in file order) to the boxes logged against it, plus
    // the metadata shown under each photo: capture time, the track ids visible
    // in it, and the ROI pixel resolution in effect when it was saved. All of
    // this is read straight from the session log — no image decoding needed.
    final order = <String>[];
    final byFile = <String, List<_DetBox>>{};
    final byFileTracks = <String, Set<int>>{}; // unique track ids per photo
    final byFileConf =
        <String, Map<int, double>>{}; // per photo: track id -> confidence
    final byFileTime = <String, int>{}; // capture time (ms since epoch)
    final byFileRes = <String, (int, int)>{}; // ROI (width_px, height_px)
    // The ROI pixel size is logged in the start record and again on every ROI
    // edit; carry the most-recent value forward so each photo gets the size that
    // applied when it was captured.
    int? curRoiW, curRoiH;
    try {
      final lines = await widget.logFile.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final isRoiSource =
            line.contains('"start_of_session"') ||
            line.contains('"roi_update"');
        // Batched frame records ("detections", round 69+) and legacy
        // per-track records ("detection", ≤ round 68).
        final isDetection =
            line.contains('"detections"') || line.contains('"detection"');
        final isCapture = line.contains('"type":"capture"');
        if (!isRoiSource && !isDetection && !isCapture) continue;
        final rec = _tryDecode(line);
        if (rec == null) continue;
        if (isRoiSource) {
          final roi = rec['roi'];
          if (roi is Map) {
            final w = (roi['width_px'] as num?)?.toInt();
            final h = (roi['height_px'] as num?)?.toInt();
            if (w != null) curRoiW = w;
            if (h != null) curRoiH = h;
          }
          continue;
        }
        if (isCapture) {
          // The capture record carries the EXACT saved side (crop snapping +
          // target cap applied) — it overrides the ROI-geometry estimate set
          // when the photo was scheduled, so the browser shows the file's
          // true resolution (round 64; older logs lack this and keep the
          // estimate).
          final file = rec['file'] as String?;
          final px = (rec['saved_px'] as num?)?.toInt();
          if (file != null && px != null && px > 0) byFileRes[file] = (px, px);
          continue;
        }
        // Joins one tracked insect's entry to a photo. Shared by both record
        // shapes. Only the tracks whose time-lapse step was DUE carry the
        // `jpeg` filename in the log; [frameJpeg] passes that filename to the
        // OTHER tracks of the same frame record, so every insect visible in
        // the photo gets its box drawn (round 86) — jpeg-carrying entries are
        // marked as the photo's trigger and drawn in a distinct color.
        void addEntry(
          Map<String, dynamic> entry,
          int timeMs, {
          String? frameJpeg,
        }) {
          final own = entry['jpeg'] as String?;
          final jpeg = own ?? frameJpeg;
          if (jpeg == null || jpeg.isEmpty) return;
          if (!byFile.containsKey(jpeg)) {
            order.add(jpeg);
            byFile[jpeg] = [];
            byFileTracks[jpeg] = <int>{};
            byFileTime[jpeg] = timeMs;
            if (curRoiW != null && curRoiH != null) {
              byFileRes[jpeg] = (curRoiW, curRoiH);
            }
          }
          final tid = (entry['track_id'] as num?)?.toInt();
          if (tid != null) byFileTracks[jpeg]!.add(tid);
          // The detector confidence (0..1) for this track, logged with every
          // detection — no extra cost, it's already in the record.
          final conf = (entry['confidence'] as num?)?.toDouble();
          if (tid != null && conf != null) {
            (byFileConf[jpeg] ??= <int, double>{})[tid] = conf;
          }
          final box = entry['box_in_roi'];
          if (box is Map) {
            final confLabel = conf != null
                ? '  ${conf.toStringAsFixed(2)}'
                : '';
            byFile[jpeg]!.add(
              _DetBox(
                left: (box['left'] as num?)?.toDouble() ?? 0,
                top: (box['top'] as num?)?.toDouble() ?? 0,
                right: (box['right'] as num?)?.toDouble() ?? 0,
                bottom: (box['bottom'] as num?)?.toDouble() ?? 0,
                label: '#${tid ?? '?'} ${entry['class_name'] ?? ''}$confLabel'
                    .trim(),
                triggered: own != null,
              ),
            );
          }
        }

        final timeMs = (rec['time_ms'] as num?)?.toInt() ?? 0;
        if (rec['type'] == 'detections') {
          final tracks = rec['tracks'];
          if (tracks is List) {
            // The frame's shared photo filename (one photo per frame at most):
            // handed to the entries that lack their own, so co-detected
            // insects appear on the photo too. Legacy per-track 'detection'
            // records (≤ round 68) can't be regrouped into frames, so they
            // keep showing trigger boxes only.
            String? frameJpeg;
            for (final e in tracks) {
              if (e is Map<String, dynamic> && e['jpeg'] is String) {
                frameJpeg = e['jpeg'] as String;
                break;
              }
            }
            for (final e in tracks) {
              if (e is Map<String, dynamic>) {
                addEntry(e, timeMs, frameJpeg: frameJpeg);
              }
            }
          }
        } else {
          addEntry(rec, timeMs);
        }
      }
    } catch (e) {
      // Use whatever parsed.
      logSwallowed('summary_photos_scan', e);
    }

    // Builds a fully-populated sample for a given file name (joins all the
    // per-photo maps gathered above).
    _PhotoSample sampleFor(String name, File file) {
      final ids = (byFileTracks[name] ?? const <int>{}).toList()..sort();
      return _PhotoSample(
        file: file,
        name: name,
        boxes: byFile[name] ?? const [],
        trackIds: ids,
        trackConf: byFileConf[name] ?? const <int, double>{},
        captureMs: byFileTime[name] ?? 0,
        width: byFileRes[name]?.$1,
        height: byFileRes[name]?.$2,
      );
    }

    // Either every saved photo (in order) or an even sample across the session.
    final dir = widget.logFile.parent.path;
    final picked = <_PhotoSample>[];
    if (order.isNotEmpty) {
      if (all) {
        for (final name in order) {
          final file = File('$dir/roi_frames/$name');
          if (file.existsSync()) picked.add(sampleFor(name, file));
        }
      } else {
        final n = _sampleCount.clamp(1, order.length);
        for (var i = 0; i < n; i++) {
          final idx = n == 1 ? 0 : ((i * (order.length - 1)) / (n - 1)).round();
          final name = order[idx];
          // Captures are written to the session's roi_frames/ subfolder; the log
          // stores just the file name.
          final file = File('$dir/roi_frames/$name');
          if (file.existsSync()) picked.add(sampleFor(name, file));
        }
      }
    }
    if (mounted) {
      setState(() {
        _totalSavedPhotos = order.length;
        _photos = picked;
        _photosLoading = false;
      });
    }
  }

  String get _durationLabel {
    if (_startMs == null || _endMs == null || _endMs! < _startMs!) {
      return 'unknown (no end record — crash/forced stop)';
    }
    final s = ((_endMs! - _startMs!) / 1000).round();
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '${h}h ${m}m ${sec}s' : '${m}m ${sec}s';
  }

  /// "8% (from 74% to 66%)" or "unknown". (Android's battery % can be coarse/laggy,
  /// so it's shown only as a rough independent check on the energy estimate.)
  String get _batteryUsedLabel {
    final drop = _batteryDrainPercent;
    if (drop == null) return 'unknown';
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

  /// The tracker (ByteTrack) tuning block, from the `config` block or the
  /// top-level `tracker_params` (older sessions).
  Map? get _trackerParams {
    final cfg = _startRec?['config'];
    if (cfg is Map && cfg['trackerParams'] is Map) {
      return cfg['trackerParams'] as Map;
    }
    final tp = _startRec?['tracker_params'];
    return tp is Map ? tp : null;
  }

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

  /// A bold sub-header inside the settings card.
  Widget _subhead(String s) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Text(
      s,
      style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: Color(0xFFFFCA28),
        fontSize: 13,
      ),
    ),
  );

  /// All settings the user configured at the start of this session, grouped and
  /// shown so the details of a past run can be recalled at a glance. Read entirely
  /// from the start record (no extra file work). Rows whose value wasn't recorded
  /// (e.g. settings added after an older session) are simply omitted.
  List<Widget> _settingsSection() {
    const header = Text(
      'Session settings',
      style: TextStyle(fontWeight: FontWeight.bold),
    );
    if (_startRec == null) {
      return const [
        header,
        SizedBox(height: 4),
        Text(
          'No start record found, so the settings could not be read.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ];
    }

    final rows = <Widget>[];
    // Adds a label/value row only when [value] is non-null (and non-empty text).
    void add(String label, Object? value, {String suffix = ''}) {
      if (value == null) return;
      final text = value is bool
          ? (value ? 'Yes' : 'No')
          : value is num
          ? _numStr(value)
          : value.toString();
      if (text.isEmpty) return;
      rows.add(_stat(label, '$text$suffix'));
    }

    // --- Model & detection ---
    rows.add(_subhead('Model & detection'));
    add('Model', _setting('modelPath', 'model_path'));
    add('Task', _setting('task', 'task'));
    add('GPU requested', _setting('useGpu', 'use_gpu'));
    add('CPU threads (0 = automatic)', _setting('cpuThreads', 'cpu_threads'));
    add('Inference engine used', _accelerator);
    add(
      'Confidence threshold',
      _setting('confidenceThreshold', 'confidence_threshold'),
    );
    add('IoU threshold', _setting('iouThreshold', 'iou_threshold'));
    final infFps = _setting('inferenceFps', 'inference_fps');
    add(
      'Inference rate cap',
      infFps == null
          ? null
          : (infFps is num && infFps == 0
                ? 'uncapped (max)'
                : '${_numStr(infFps)} /s'),
    );

    // --- Heat management ---
    // Only for sessions that recorded these fields (config block, round 44+).
    if (_setting('autoThrottle') != null ||
        _setting('motionGateEnabled') != null) {
      rows.add(_subhead('Heat management'));
      // Camera hardware rate cap (round 82) — distinct from the inference cap.
      final camFps = _setting('cameraFpsCap');
      add(
        'Camera frame rate cap',
        camFps == null
            ? null
            : (camFps is num && camFps == 0
                  ? 'device default'
                  : '${_numStr(camFps)} /s'),
      );
      add('Auto-throttle', _setting('autoThrottle'));
      add('Min inference rate', _setting('minInferenceFps'), suffix: ' /s');
      add('Throttle duty target', _setting('throttleDutyTarget'));
      // Motion gate (round 58+): detector sleeps while nothing moves in the ROI.
      add('Motion gate', _setting('motionGateEnabled'));
      if (_setting('motionGateEnabled') == true) {
        add('Gate pixel sensitivity', _setting('motionGatePixelDelta'));
        final area = _setting('motionGateAreaFraction');
        add('Gate trigger area', area is num ? area * 100 : null, suffix: ' %');
        add(
          'Gate wake duration',
          _setting('motionGateWakeSeconds'),
          suffix: ' s',
        );
        add(
          'Gate grid resolution',
          _setting('motionGateGridSize'),
          suffix: ' cells',
        );
        add(
          'Gate idle check rate',
          _setting('motionGateIdleFps'),
          suffix: ' fps',
        );
      }
    }

    // --- Photos & capture ---
    rows.add(_subhead('Photos & capture'));
    add(
      'Output folder',
      _setting('folderName') ?? widget.logFile.parent.path.split('/').last,
    );
    add(
      'Photo step interval',
      _setting('stepSeconds', 'step_seconds'),
      suffix: ' s',
    );
    add(
      'Photo capture duration',
      _setting('durationSeconds', 'duration_seconds'),
      suffix: ' s',
    );
    add('Photo source mode', _setting('captureMode'));
    add('Saved photo side', _setting('targetRoiSavedPx'), suffix: ' px');
    // Crop-and-export 1:1 lock (round 91) — only sessions recorded since then
    // carry the key (add() skips null).
    add('Square export crops', _setting('cropSquareLock'));
    // Rows below only appear for sessions recorded with older configs.
    add('Min saved photo side', _setting('minRoiSavedPx'), suffix: ' px');
    final maxSaved = _setting('maxRoiSavedPx');
    add(
      'Max saved photo side',
      maxSaved is num && maxSaved == 0 ? 'no cap (native)' : maxSaved,
      suffix: maxSaved is num && maxSaved == 0 ? '' : ' px',
    );
    if (_setting('captureMode') == null) {
      add('Full-resolution photos', _setting('fullResPhotos'));
    }
    add(
      'Camera resolution',
      _dims(
        _startRec?['camera_full_width_px'],
        _startRec?['camera_full_height_px'],
      ),
    );
    add(
      'Stream resolution (requested)',
      _dims(_setting('streamWidth'), _setting('streamHeight')),
    );
    add(
      'Analysis frame',
      _dims(
        _startRec?['analysis_frame_width_px'],
        _startRec?['analysis_frame_height_px'],
      ),
    );
    final roi = _startRec?['roi'];
    if (roi is Map) {
      add('Initial ROI', _dims(roi['width_px'], roi['height_px']));
    }
    final focus = _startRec?['focus_mode'];
    if (focus != null) {
      final fv = _startRec?['focus_value'];
      add(
        'Focus mode',
        fv is num ? '$focus (${fv.toStringAsFixed(2)})' : focus,
      );
    }

    // --- Session & sampling ---
    rows.add(_subhead('Session & sampling'));
    add(
      'Max session length',
      _setting('sessionMinutes', 'session_minutes'),
      suffix: ' min',
    );
    add(
      'FPS sample interval',
      _setting('fpsSampleSeconds', 'fps_sample_seconds'),
      suffix: ' s',
    );
    add(
      'Temperature sample interval',
      _setting('thermalSampleSeconds', 'thermal_sample_seconds'),
      suffix: ' s',
    );
    add(
      'Power sample interval',
      _setting('powerSampleSeconds', 'power_sample_seconds'),
      suffix: ' s',
    );

    // --- Tracking (ByteTrack) ---
    // Labels here mirror the AI-tab settings exactly so the same knob is never
    // called two different things. The user sets occlusion tolerance and min
    // hits in *seconds*; the tracker uses *frames*, so we show the seconds the
    // user chose and, where available, the derived frame count in parentheses.
    final tp = _trackerParams;
    rows.add(_subhead('Tracking (ByteTrack)'));
    add('Occlusion tolerance', _setting('occlusionSeconds'), suffix: ' s');
    // Min hits: prefer the seconds the user set (newer sessions); fall back to
    // the raw frame count logged by older sessions.
    final minHitsSeconds = _setting('minHitsSeconds');
    if (minHitsSeconds != null) {
      add('Min hits to confirm', minHitsSeconds, suffix: ' s');
    } else if (tp != null) {
      add('Min hits to confirm', tp['minHitsToConfirm'], suffix: ' frames');
    }
    if (tp != null) {
      add('Match overlap (IoU)', tp['matchThresh']);
      add('Low-score association', tp['lowMatchThresh']);
      add('Velocity smoothing', tp['velocitySmoothing']);
      // The frame-count buffers actually used by the tracker (derived from the
      // seconds above at the session's frame rate). High-score threshold is
      // recorded but not user-editable in the AI tab.
      add('Occlusion buffer (derived)', tp['trackBuffer'], suffix: ' frames');
      add('High-score threshold', tp['highThresh']);
    }

    return [
      header,
      const SizedBox(height: 4),
      const Text(
        'Everything chosen at the start of this session, so the run can be '
        'reproduced or recalled later.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Four tabs keep the summary uncluttered: headline numbers, the full
    // settings record, the saved-photo browser, and the graphs each get their
    // own page instead of one very long scroll.
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Session summary'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Settings'),
              Tab(text: 'Photos'),
              Tab(text: 'Graphs'),
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
                  _overviewTab(),
                  _settingsTab(),
                  _photosTab(),
                  _graphsTab(),
                ],
              ),
      ),
    );
  }

  static const _tabPadding = EdgeInsets.fromLTRB(16, 16, 16, 64);

  /// Headline numbers: the quick "how did it go" read.
  Widget _overviewTab() {
    // Same date/time formats as the home history list: yyyy-mm-dd, hh:mm:ss.
    final start = _startMs != null
        ? DateTime.fromMillisecondsSinceEpoch(_startMs!)
        : null;
    final end = _endMs != null
        ? DateTime.fromMillisecondsSinceEpoch(_endMs!)
        : null;
    // A session can run past midnight: the end then carries its own date so
    // the bare time isn't ambiguous.
    final endLabel = end == null
        ? 'unknown'
        : (start != null && _dateOnly(end) != _dateOnly(start))
        ? '${_dateOnly(end)}, ${_timeOnly(end)}'
        : _timeOnly(end);
    return ListView(
      padding: _tabPadding,
      children: [
        _stat(
          'Unique insects (track ids)',
          _uniqueTracks?.toString() ?? 'unknown',
        ),
        _stat('Date', start != null ? _dateOnly(start) : 'unknown'),
        _stat('Start time', start != null ? _timeOnly(start) : 'unknown'),
        _stat('End time', endLabel),
        _stat('Session duration', _durationLabel),
        _stat('Model', _model ?? 'unknown'),
        if (_accelerator != null && _accelerator!.isNotEmpty)
          _stat('Inference engine', _accelerator!),
        _stat(
          'Ended normally',
          _endedNormally ? 'Yes' : 'No (crash / forced stop)',
        ),
        _stat('Battery used', _batteryUsedLabel),
        if (_chargingDuringSession)
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 6),
            child: Text(
              '⚠ The phone was plugged in during (part of) this session, so '
              'the power/energy graph is hidden — the battery sensor would '
              'measure charging, not consumption. Measure unplugged.',
              style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
            ),
          ),
        _stat('Saved to', widget.logFile.parent.path),
        // --- Storage & cleanup (round 90) ---
        const Divider(height: 32, color: Colors.white24),
        _stat(
          'Session storage',
          _sessionSizeBytes != null
              ? formatBytes(_sessionSizeBytes!)
              : 'measuring…',
        ),
        _stat(
          'Phone storage free',
          _storage.freeGb != null
              ? '${_storage.isLow ? '⚠ ' : ''}'
                    '${_storage.freeGb!.toStringAsFixed(1)} GB'
              : 'unknown',
        ),
        const SizedBox(height: 12),
        // --- Export photos to the phone's own Gallery app (round 93) ---
        if (_galleryExportBusy) ...[
          LinearProgressIndicator(
            value: _galleryExportTotal == 0
                ? null
                : _galleryExportDone / _galleryExportTotal,
          ),
          const SizedBox(height: 4),
          Text(
            'Exporting photo $_galleryExportDone of $_galleryExportTotal…',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
        ],
        Center(
          child: FilledButton.tonalIcon(
            onPressed: _galleryExportBusy
                ? null
                : _confirmExportPhotosToGallery,
            icon: const Icon(Icons.photo_library),
            label: const Text('Export photos to Gallery'),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: _galleryExportBusy ? null : _confirmDeleteSession,
            icon: const Icon(Icons.delete_forever),
            label: const Text('Delete session'),
          ),
        ),
      ],
    );
  }

  /// The calendar date, e.g. `2026-06-22` — same format as the home list.
  String _dateOnly(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  /// The wall-clock time of day, `hh:mm:ss` — same format as the home list.
  String _timeOnly(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  /// Asks for confirmation, then deletes the WHOLE session folder (log,
  /// metadata, photos, diagnostic files) and leaves the summary. The home
  /// list rescans on return, and the recording screen's free-storage readout
  /// polls the OS, so both show the freed space without extra plumbing.
  Future<void> _confirmDeleteSession() async {
    final size = _sessionSizeBytes != null
        ? ' (${formatBytes(_sessionSizeBytes!)})'
        : '';
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(
          'This permanently deletes the whole session$size from the phone — '
          'the data log, all metadata and every saved photo. '
          'This cannot be undone.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.logFile.parent.delete(recursive: true);
    } catch (e) {
      logSwallowed('session_delete', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete the session.')),
        );
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// Lists the session's saved photos, asks for confirmation (count + the
  /// extra storage the copies will take), then copies them into the phone's
  /// own Gallery app as one album under Pictures/PollinatorMonitor. Copies
  /// only — the session folder keeps its originals and the data log stays in
  /// the private session folder. The photo list comes from the real
  /// `roi_frames/` folder on disk, not from the log, so crash-ended sessions
  /// (whose log may be missing its tail) still export every file.
  Future<void> _confirmExportPhotosToGallery() async {
    final dir = Directory('${widget.logFile.parent.path}/roi_frames');
    final files = <File>[];
    var bytes = 0;
    try {
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is File && e.path.toLowerCase().endsWith('.jpg')) {
            files.add(e);
            bytes += await e.length();
          }
        }
      }
    } catch (e) {
      logSwallowed('gallery_export_scan', e);
    }
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This session has no saved photos to export.'),
        ),
      );
      return;
    }
    // File names embed the capture time in milliseconds, so sorting by path
    // puts the photos in capture order.
    files.sort((a, b) => a.path.compareTo(b.path));
    final album = galleryAlbumName(
      widget.logFile.parent.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Export ${files.length} photos to Gallery?'),
        content: Text(
          'Copies every saved photo of this session into the phone\'s '
          'Gallery app, as the album "Pictures/PollinatorMonitor/$album". '
          'The copies take about ${formatBytes(bytes)} of extra storage; '
          'the originals stay in the session folder. Photos already '
          'exported are skipped, so re-running is safe.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Export',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _runGalleryExport(files, album);
  }

  /// Runs the chunked copy with a progress bar, then reports the counts.
  /// `exportPhotosToGallery` never throws (failures are counted and logged),
  /// so the try/finally only guarantees the busy flag resets.
  Future<void> _runGalleryExport(List<File> files, String album) async {
    setState(() {
      _galleryExportBusy = true;
      _galleryExportDone = 0;
      _galleryExportTotal = files.length;
    });
    GalleryExportResult res;
    try {
      res = await exportPhotosToGallery(
        files,
        album,
        onProgress: (done, total) {
          if (mounted) setState(() => _galleryExportDone = done);
        },
      );
    } finally {
      if (mounted) setState(() => _galleryExportBusy = false);
    }
    if (!mounted) return;
    final msg = !res.supported
        ? 'Export to Gallery needs Android 10 or newer — this phone runs an '
              'older Android. The photos are still on the phone in the '
              'session folder (reachable over USB).'
        : 'Exported ${res.exported} photos to Gallery ▸ '
              'Pictures/PollinatorMonitor/$album.'
              '${res.skipped > 0 ? ' ${res.skipped} were already there.' : ''}'
              '${res.failed > 0 ? ' ${res.failed} failed — try again.' : ''}';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Every parameter the user chose at session start (from the log's config
  /// block), grouped — its own tab so the overview stays scannable.
  Widget _settingsTab() =>
      ListView(padding: _tabPadding, children: _settingsSection());

  Widget _photosTab() => ListView(
    padding: _tabPadding,
    // Frozen while a photo is zoomed: the list's vertical drag otherwise
    // wins vertical/diagonal photo pans and scrolls the viewer away.
    physics: _photoViewerZoomed ? const NeverScrollableScrollPhysics() : null,
    children: _photoSection(),
  );

  Widget _graphsTab() {
    // Recompute timeline visibility after this frame lays out, so the floating
    // button appears even before the first scroll if the timeline starts visible.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateTimelineInView(),
    );
    return Stack(
      children: [
        ListView(
          controller: _scroll,
          padding: _tabPadding,
          children: [
            if (!_graphsRequested)
              Center(
                child: FilledButton.icon(
                  icon: const Icon(Icons.insights),
                  label: const Text('Generate graphs'),
                  onPressed: _loadGraphs,
                ),
              )
            else if (_graphsLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else
              ..._graphs(),
          ],
        ),
        // Floating show/hide for the (potentially very tall) visit
        // timeline — only while that section is on screen.
        if (_timelineInView)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: FilledButton.tonalIcon(
                icon: Icon(
                  _showTimeline ? Icons.unfold_less : Icons.unfold_more,
                ),
                label: Text(_showTimeline ? 'Hide timeline' : 'Show timeline'),
                onPressed: () => setState(() => _showTimeline = !_showTimeline),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _graphs() => [
    const Text(
      'Visit timeline (each lane is one insect)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 4),
    const Text(
      'Time runs left → right across the session. A bar shows when an insect was '
      'on the flower; overlapping bars were on it at the same time.',
      style: TextStyle(color: Colors.white70, fontSize: 12),
    ),
    const SizedBox(height: 12),
    _timeline(),
    const SizedBox(height: 28),
    const Text(
      'Phone temperature over the session (°C)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    _series(_temps, const Color(0xFFFF7043), '°'),
    _statsText(_temps, decimals: 1, unit: '°C'),
    if (_headroom.length >= 2) ...[
      const SizedBox(height: 28),
      const Text(
        'Thermal headroom (0 = cool → 1 = throttling)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'How close the phone is to slowing itself down to cool off, from the '
        'chip/skin sensors. 0 = cool, 1 = the throttling point (may briefly exceed '
        '1). When this nears 1 the phone throttles and the FPS drops — a faster, '
        'more comparable signal than battery temperature.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_headroom, const Color(0xFFEF5350), ''),
    ] else ...[
      const SizedBox(height: 12),
      const Text(
        'Thermal headroom: not reported by this phone (common on many devices — '
        'e.g. the Xiaomi here). This is not a bug. Use the Temperature and '
        'Inference-time graphs as the throttle indicators on this device.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
    ],
    const SizedBox(height: 28),
    const Text(
      'Detector FPS over the session',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    _series(_fps, const Color(0xFF66BB6A), ''),
    _statsText(_fps, decimals: 1, unit: ' fps'),
    if (_infMs.length >= 2) ...[
      const SizedBox(height: 28),
      const Text(
        'Inference time over the session (ms) — throttle signal',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'Milliseconds the model takes per frame. It climbs when the chip slows '
        'itself to cool off (thermal throttling) — often before battery '
        'temperature moves — which is what makes the FPS above drop. Read it '
        'against the FPS and temperature graphs on the same left→right time axis.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_infMs, const Color(0xFF42A5F5), ' ms'),
      _statsText(_infMs, decimals: 1, unit: ' ms'),
    ],
    const SizedBox(height: 28),
    const Text(
      'Power draw over the session (W)',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 4),
    if (_chargingDuringSession)
      const Text(
        'Not shown: the phone was plugged in during (part of) this session. '
        'The battery sensor then measures charging current — not what the '
        'phone consumes — so a power or energy estimate would be wrong. '
        'Record a full session on battery to see this graph.',
        style: TextStyle(color: Color(0xFFFFB74D), fontSize: 12),
      )
    else ...[
      const Text(
        'Watts (W) = how fast energy is being used right now '
        '(battery current × voltage). Higher = more drain.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 12),
      _series(_power, const Color(0xFFFFCA28), 'W'),
      if (_powerAvg != null) ...[
        const SizedBox(height: 8),
        Text(
          'Average power ${_powerAvg!.toStringAsFixed(2)} W '
          '(median ${_powerMedian!.toStringAsFixed(2)} W; '
          'min ${_powerMin!.toStringAsFixed(2)}, max ${_powerMax!.toStringAsFixed(2)} W). '
          'Total energy this session ≈ ${_energyTotalWh!.toStringAsFixed(2)} Wh '
          '(= average power × duration); battery level dropped $_batteryUsedLabel.',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ],
  ];

  /// A small grey line printed under a graph with the series' average, median,
  /// minimum and maximum — the same shape of summary the power graph already
  /// shows. [decimals] controls the precision and [unit] is appended to every
  /// number (e.g. "°C", " fps"). Returns an empty box when there are no samples.
  Widget _statsText(
    List<(int ms, double v)> points, {
    required int decimals,
    String unit = '',
  }) {
    final s = _seriesStats(points);
    if (s == null) return const SizedBox.shrink();
    String f(double v) => '${v.toStringAsFixed(decimals)}$unit';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Average ${f(s.mean)} (median ${f(s.median)}); '
        'min ${f(s.min)}, max ${f(s.max)}.',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  List<Widget> _photoSection() {
    return [
      const Text(
        'Sample saved photos (with detection boxes)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'Pick how many ROI photos to preview, spread evenly across the session. '
        'Each is shown with the detection boxes recorded for it, so you can check '
        'the results make visual sense. Swipe left/right to step through them.',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
      const SizedBox(height: 4),
      // Box-color legend (round 86): a photo shows EVERY insect detected in
      // the frame that scheduled it, not only the one(s) whose time-lapse
      // step was due.
      const Text.rich(
        TextSpan(
          style: TextStyle(color: Colors.white70, fontSize: 12),
          children: [
            TextSpan(
              text: '■ ',
              style: TextStyle(color: _BoxPainter.triggerColor),
            ),
            TextSpan(text: 'insect whose photo schedule triggered this shot'),
            TextSpan(text: '   '),
            TextSpan(
              text: '■ ',
              style: TextStyle(color: _BoxPainter.coDetectedColor),
            ),
            TextSpan(text: 'other insect detected in the same frame'),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          const Text('Photos: ', style: TextStyle(color: Colors.white70)),
          Expanded(
            child: Slider(
              value: _sampleCount.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_sampleCount',
              onChanged: (v) => setState(() => _sampleCount = v.round()),
            ),
          ),
          Text('$_sampleCount', style: const TextStyle(color: Colors.white)),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _photosLoading ? null : () => _loadPhotos(),
            child: const Text('Show'),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: _photosLoading ? null : () => _loadPhotos(all: true),
            child: const Text('All'),
          ),
        ],
      ),
      if (_photosRequested && !_photosLoading)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Showing ${_photos.length} of $_totalSavedPhotos saved photo'
            '${_totalSavedPhotos == 1 ? '' : 's'} this session.',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
      if (_photosLoading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_photosRequested && _photos.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No saved photos found for this session.',
            style: TextStyle(color: Colors.white70),
          ),
        )
      else if (_photos.isNotEmpty)
        _PhotoViewer(
          photos: _photos,
          onZoomChanged: (z) {
            if (mounted && z != _photoViewerZoomed) {
              setState(() => _photoViewerZoomed = z);
            }
          },
        ),
    ];
  }

  Widget _timeline() {
    if (_spans.isEmpty ||
        _startMs == null ||
        _endMs == null ||
        _endMs! <= _startMs!) {
      return Center(
        key: _timelineKey,
        child: const Text('No visits recorded.'),
      );
    }
    final ids = _spans.keys.toList()
      ..sort((a, b) => _spans[a]!.$1.compareTo(_spans[b]!.$1));
    // Collapsed: a short placeholder (keyed so the floating toggle still tracks
    // visibility), so a long Gantt no longer forces lots of scrolling.
    if (!_showTimeline) {
      return Container(
        key: _timelineKey,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Visit timeline hidden — ${ids.length} insect'
          '${ids.length == 1 ? '' : 's'}. Use the button below to show it.',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }
    final laneHeight = ids.length > 120
        ? 8.0
        : ids.length > 40
        ? 14.0
        : 26.0;
    const axisHeight = 28.0;
    return SizedBox(
      key: _timelineKey,
      height: ids.length * laneHeight + axisHeight,
      child: CustomPaint(
        size: Size.infinite,
        painter: _GanttPainter(
          ids: ids,
          spans: _spans,
          startMs: _startMs!,
          endMs: _endMs!,
          laneHeight: laneHeight,
          axisHeight: axisHeight,
          showLabels: laneHeight >= 14.0,
        ),
      ),
    );
  }

  Widget _series(List<(int ms, double v)> points, Color color, String unit) {
    if (points.length < 2 ||
        _startMs == null ||
        _endMs == null ||
        _endMs! <= _startMs!) {
      return const Center(child: Text('Not enough samples.'));
    }
    return SizedBox(
      height: 160,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SeriesPainter(
          points: points,
          startMs: _startMs!,
          endMs: _endMs!,
          color: color,
          unit: unit,
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

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

/// One raw battery reading from a `power` log record, before unit correction.
class _PowerSample {
  final int ms;
  final int?
  currentUa; // instantaneous current (µA per spec; mA on some phones)
  final int? voltageMv; // battery voltage (mV)
  final int? chargeUah; // remaining charge counter (µAh) — spec-reliable units
  final double?
  loggedW; // power computed at capture time (last-resort fallback)
  final bool? isCharging; // plugged in at sample time (null on older logs)
  const _PowerSample({
    required this.ms,
    required this.currentUa,
    required this.voltageMv,
    required this.chargeUah,
    required this.loggedW,
    required this.isCharging,
  });
}

/// One detection box, in ROI-normalized (0..1) coordinates — which is exactly
/// the coordinate space of the saved square ROI photo, so the rect maps onto the
/// image directly.
class _DetBox {
  final double left, top, right, bottom;
  final String label;

  /// True when this insect's time-lapse schedule is what triggered the photo;
  /// false for insects that simply happened to be detected in the same frame.
  final bool triggered;
  const _DetBox({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.label,
    required this.triggered,
  });
}

class _PhotoSample {
  final File file;

  /// The JPEG file name, exactly as recorded in the session log.
  final String name;
  final List<_DetBox> boxes;

  /// Unique track ids whose detections appear in this photo (sorted ascending).
  final List<int> trackIds;

  /// Detector confidence (0..1) per track id visible in this photo.
  final Map<int, double> trackConf;

  /// When the photo was captured, in milliseconds since the Unix epoch.
  final int captureMs;

  /// ROI pixel size when the photo was saved (square crop, so width == height).
  /// Null if no ROI record preceded the photo in the log.
  final int? width;
  final int? height;

  const _PhotoSample({
    required this.file,
    required this.name,
    required this.boxes,
    required this.trackIds,
    required this.trackConf,
    required this.captureMs,
    required this.width,
    required this.height,
  });
}

/// A swipeable viewer: one saved ROI photo per page with its detection boxes
/// overlaid. The photo is a square ROI crop, so boxes (normalized to the ROI)
/// overlay directly on a 1:1 image.
class _PhotoViewer extends StatefulWidget {
  final List<_PhotoSample> photos;

  /// Fires when the viewer enters/leaves zoom mode. The parent must freeze
  /// its OWN scrollables on it (the tab ListView and the TabBarView): they
  /// sit above the photo in the gesture arena and otherwise win most drags —
  /// vertical pans scrolled the page away and horizontal pans switched tabs,
  /// which is why zoomed panning felt broken even after round 88 froze the
  /// inner PageView.
  final ValueChanged<bool> onZoomChanged;
  const _PhotoViewer({required this.photos, required this.onZoomChanged});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  final _controller = PageController();
  int _page = 0;

  /// Detection boxes + labels overlay on/off (round 87, top-right tool button).
  bool _showBoxes = true;

  /// Whether the zoom slider is unfolded under the magnifier button.
  bool _zoomSliderOpen = false;

  /// Current page's zoom factor. Kept in sync with pinch gestures (via the
  /// transform controller's listener) so the slider thumb follows two-finger
  /// zooming too.
  double _scale = 1.0;

  /// True while the current photo is zoomed in: page-swiping is disabled so a
  /// one-finger drag pans the photo, and the zoom-mode chip is shown.
  bool get _zoomed => _scale > 1.01;

  /// Crop-and-export mode (round 91): a one-finger drag draws an export
  /// rectangle instead of panning/swiping, so the same scrollables must be
  /// frozen as in zoom mode.
  bool _cropMode = false;

  /// Where the current crop drag started, in the photo's own ("scene")
  /// coordinates — 0..[_viewerSide] on each axis, independent of zoom/pan.
  Offset? _cropDragStartScene;

  /// The drawn crop rectangle in scene coordinates; null while none is set.
  Rect? _cropSceneRect;

  /// The rectangle as it was when a MOVE drag started (drag began inside the
  /// box); null while drawing a new box instead. Moving shifts this original
  /// by the drag delta, so the size — and an enforced 1:1 — never changes.
  Rect? _cropMoveOriginRect;

  /// Mirrors [SessionConfig.cropSquareLock] (loaded in [initState]); the
  /// "1:1" chip in the crop bar writes it back, so the chip and the Settings
  /// switch are one and the same setting.
  bool _cropSquareLock = false;

  /// True while a crop is being cut/saved/shared, to debounce the buttons.
  bool _cropBusy = false;

  /// True whenever one-finger drags must NOT reach the surrounding
  /// scrollables (zoomed panning, or crop-rectangle drawing).
  bool get _scrollFrozen => _zoomed || _cropMode;

  /// Last freeze state reported to [widget.onZoomChanged], so the parent is
  /// only rebuilt on actual mode changes, not on every pinch step.
  bool _lastNotifiedFrozen = false;

  void _notifyFreeze() {
    if (_scrollFrozen == _lastNotifiedFrozen) return;
    _lastNotifiedFrozen = _scrollFrozen;
    widget.onZoomChanged(_scrollFrozen);
  }

  @override
  void initState() {
    super.initState();
    SessionConfig.load().then((c) {
      if (mounted) setState(() => _cropSquareLock = c.cropSquareLock);
    });
  }

  static const double _maxZoom = 8.0;

  /// One transform per page: PageView keeps neighbouring pages alive during a
  /// swipe, so a single shared controller would visibly zoom the incoming
  /// photo as well.
  final Map<int, TransformationController> _transforms = {};

  /// Side (logical px) of the square viewer area, captured at build time —
  /// the zoom slider needs it to keep the viewport centre fixed while scaling.
  double _viewerSide = 320;

  @override
  void dispose() {
    // If disposed mid-zoom (e.g. photos reloaded), unfreeze the parent's
    // scrollables — post-frame, because the parent may be rebuilding now.
    if (_lastNotifiedFrozen) {
      final notify = widget.onZoomChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => notify(false));
    }
    _controller.dispose();
    for (final c in _transforms.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _transformFor(int page) =>
      _transforms.putIfAbsent(page, () {
        final c = TransformationController();
        // Mirror pinch zooming into [_scale] so the slider follows the fingers.
        c.addListener(() {
          if (page != _page) return;
          final s = c.value.getMaxScaleOnAxis();
          // Also rebuild on pure pans while a crop rectangle is on screen:
          // the rectangle is glued to the photo, so its viewport position
          // depends on the whole transform, not just the scale.
          if ((s - _scale).abs() > 0.01 ||
              (_cropMode && _cropSceneRect != null)) {
            setState(() => _scale = s);
            _notifyFreeze();
          }
        });
        return c;
      });

  /// Applies zoom factor [s] around the point currently at the viewport
  /// centre — so slider zooming doesn't jump away from an insect the user
  /// pinch-panned to — clamping the pan so the photo keeps covering the
  /// viewport (InteractiveViewer only enforces its boundary during gestures,
  /// not for programmatic transforms).
  void _setZoom(double s) {
    s = s.clamp(1.0, _maxZoom);
    final c = _transformFor(_page);
    final centre = Offset(_viewerSide / 2, _viewerSide / 2);
    final scene = c.toScene(centre);
    final minT = _viewerSide - _viewerSide * s; // ≤ 0
    final tx = (centre.dx - scene.dx * s).clamp(minT, 0.0);
    final ty = (centre.dy - scene.dy * s).clamp(minT, 0.0);
    c.value = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
    setState(() => _scale = s);
    _notifyFreeze();
  }

  /// Pans the zoomed view one step in the given direction (each unit = a
  /// third of the viewport) — the button fallback for panning, so moving
  /// around never depends on winning a drag gesture. Clamped like [_setZoom].
  void _nudge(double dxDir, double dyDir) {
    final c = _transformFor(_page);
    final s = c.value.getMaxScaleOnAxis();
    if (s <= 1.01) return;
    final step = _viewerSide / 3;
    final t = c.value.getTranslation();
    final minT = _viewerSide - _viewerSide * s; // ≤ 0
    // "Look right" = content slides left = translation decreases.
    final tx = (t.x - dxDir * step).clamp(minT, 0.0);
    final ty = (t.y - dyDir * step).clamp(minT, 0.0);
    c.value = Matrix4.diagonal3Values(s, s, 1)..setTranslationRaw(tx, ty, 0);
  }

  /// One small arrow key of the pan pad shown while zoomed.
  Widget _padButton(IconData icon, VoidCallback onTap) => SizedBox(
    width: 32,
    height: 32,
    child: IconButton(
      padding: EdgeInsets.zero,
      icon: Icon(icon),
      color: Colors.white,
      iconSize: 22,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    ),
  );

  /// One round translucent tool button for the viewer's top-right column;
  /// [active] tints the icon so the state is visible at a glance.
  Widget _toolButton({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: IconButton(
      icon: Icon(icon),
      color: active ? const Color(0xFF00E5FF) : Colors.white70,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onTap,
    ),
  );

  /// Normalized (0..1) form of the current crop rectangle, or null.
  Rect? get _cropNormRect => _cropSceneRect == null
      ? null
      : normalizedRect(_cropSceneRect!, _viewerSide);

  /// Real pixel size of the current crop on the SAVED photo (not the screen),
  /// or null when the photo's size isn't in the log.
  (int, int)? _cropPxSize() {
    final norm = _cropNormRect;
    final p = widget.photos[_page];
    if (norm == null || p.width == null || p.height == null) return null;
    return ((norm.width * p.width!).round(), (norm.height * p.height!).round());
  }

  /// The crop rectangle mapped from scene to on-screen (viewport) coordinates
  /// for painting. The transform is a uniform scale + translation
  /// (InteractiveViewer without rotation), so the mapping is scale-and-shift.
  Rect? _viewportCropRect(int page) {
    final r = _cropSceneRect;
    if (r == null) return null;
    final m = _transformFor(page).value;
    final s = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    return Rect.fromLTRB(
      r.left * s + t.x,
      r.top * s + t.y,
      r.right * s + t.x,
      r.bottom * s + t.y,
    );
  }

  /// End of a crop drag: drop a rectangle that would come out below
  /// [kMinCropSidePx] on the saved photo — almost certainly a stray tap, and
  /// too small to identify anything from anyway. (A MOVE drag keeps its
  /// already-validated size, so it always passes.)
  void _finishCropDrag() {
    _cropDragStartScene = null;
    _cropMoveOriginRect = null;
    final r = _cropSceneRect;
    if (r == null) return;
    final p = widget.photos[_page];
    final px = min(p.width ?? 1024, p.height ?? 1024);
    if (r.width / _viewerSide * px < kMinCropSidePx ||
        r.height / _viewerSide * px < kMinCropSidePx) {
      setState(() => _cropSceneRect = null);
    }
  }

  /// Flips the 1:1 lock and persists it via [SessionConfig]. The config is
  /// re-loaded first so only this field changes even if settings were edited
  /// since this screen opened. A live rectangle is dropped: silently
  /// reshaping it would misrepresent what the user drew.
  Future<void> _setCropSquareLock(bool v) async {
    setState(() {
      _cropSquareLock = v;
      _cropDragStartScene = null;
      _cropMoveOriginRect = null;
      _cropSceneRect = null;
    });
    final cfg = await SessionConfig.load();
    await cfg.copyWith(cropSquareLock: v).save();
  }

  /// Cuts the drawn rectangle out of the ORIGINAL saved JPEG (never the
  /// screen — screen pixels are already downscaled) on a background isolate,
  /// then saves it to the Gallery or opens the share sheet.
  Future<void> _exportCrop({required bool share}) async {
    final norm = _cropNormRect;
    if (norm == null || _cropBusy) return;
    final p = widget.photos[_page];
    setState(() => _cropBusy = true);
    String msg;
    try {
      final cropped = await cropJpegNormRect(p.file, norm);
      if (cropped == null) {
        msg =
            'Crop failed — the box is too small (under $kMinCropSidePx px) '
            'or the photo could not be read.';
      } else {
        final name = cropExportName(p.name);
        if (share) {
          await shareCrop(cropped.jpeg, name);
          msg =
              '${cropped.width} × ${cropped.height} px crop handed to the '
              'share sheet.';
        } else {
          // Fallback dir (older Android / MediaStore failure): keep the crop
          // with its session, next to roi_frames/.
          final res = await saveCropToGallery(
            cropped.jpeg,
            name,
            fallbackDir: Directory('${p.file.parent.parent.path}/crops'),
          );
          msg = res == null
              ? 'Saving the crop failed.'
              : 'Saved ${cropped.width} × ${cropped.height} px crop to '
                    '${res.location}.';
        }
      }
    } catch (e) {
      logSwallowed('crop_export', e);
      msg = 'Crop export failed: $e';
    } finally {
      if (mounted) setState(() => _cropBusy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  /// Action bar under the viewer while crop mode is on: the 1:1 lock chip,
  /// the crop's real pixel size (from the saved file, not the screen — the
  /// honest number that decides whether an identification app has enough
  /// detail), and the Save / Share actions.
  Widget _cropBar() {
    final size = _cropPxSize();
    final hasRect = _cropSceneRect != null;
    final String label;
    if (!hasRect) {
      label = 'Drag a box around the insect';
    } else if (size == null) {
      label = 'Crop set';
    } else {
      final tiny = size.$1 < 100 || size.$2 < 100;
      label = 'Crop: ${size.$1} × ${size.$2} px${tiny ? '  ⚠ tiny' : ''}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          FilterChip(
            label: const Text('1:1'),
            selected: _cropSquareLock,
            visualDensity: VisualDensity.compact,
            tooltip:
                'Force the crop box to a square (same setting as in '
                'Settings → Summary)',
            onSelected: _setCropSquareLock,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip:
                'Save the crop to the phone Gallery '
                '(Pictures/PollinatorMonitor)',
            color: Colors.white,
            onPressed: hasRect && !_cropBusy
                ? () => _exportCrop(share: false)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip:
                'Share the crop to another app '
                '(e.g. Google Lens, iNaturalist)',
            color: Colors.white,
            onPressed: hasRect && !_cropBusy
                ? () => _exportCrop(share: true)
                : null,
          ),
        ],
      ),
    );
  }

  /// A round translucent ‹ / › photo-navigation button; greyed out at the
  /// ends of the gallery. Navigating first resets the zoom, so the page
  /// transition never slides a zoomed crop around.
  Widget _navButton(IconData icon, bool enabled, int toPage) => Container(
    decoration: const BoxDecoration(
      color: Colors.black54,
      shape: BoxShape.circle,
    ),
    child: IconButton(
      icon: Icon(icon),
      color: enabled ? Colors.white : Colors.white24,
      iconSize: 24,
      visualDensity: VisualDensity.compact,
      onPressed: enabled
          ? () {
              if (_zoomed) _setZoom(1);
              _controller.animateToPage(
                toPage,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              );
            }
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        // Capped height (not a full-width square) so the viewer doesn't dominate
        // the page or trap the vertical scroll past it.
        SizedBox(
          height: 320,
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewerSide = min(constraints.maxWidth, 320.0);
              return Stack(
                children: [
                  PageView.builder(
                    controller: _controller,
                    itemCount: widget.photos.length,
                    // While zoomed, one-finger drags must PAN the photo — but
                    // the PageView competes for the same horizontal drag and
                    // usually wins (this is what made panning after a pinch
                    // feel broken, round 88). So page-swiping is disabled in
                    // zoom mode (and in crop mode, where a drag draws the
                    // export box); the ‹ › buttons (which first reset the
                    // zoom) are the way to change photo.
                    physics: _scrollFrozen
                        ? const NeverScrollableScrollPhysics()
                        : null,
                    onPageChanged: (i) {
                      final old = _page;
                      setState(() {
                        _page = i;
                        _scale = 1;
                        // A crop rectangle belongs to one photo: drop it when
                        // leaving (crop mode itself stays on).
                        _cropDragStartScene = null;
                        _cropMoveOriginRect = null;
                        _cropSceneRect = null;
                      });
                      // Gallery convention: zoom belongs to one photo — reset
                      // it when leaving.
                      _transforms[old]?.value = Matrix4.identity();
                      _notifyFreeze();
                    },
                    itemBuilder: (_, i) {
                      final p = widget.photos[i];
                      // The saved ROI crop is square, and the boxes are normalized to it.
                      // Pin the image AND the overlay to the SAME square box (AspectRatio
                      // 1) so the boxes map 1:1 onto the visible photo. Previously the
                      // painter filled the whole non-square 320-tall area while the image
                      // was letterboxed inside it, so the boxes landed off the photo (they
                      // appeared to flash and vanish). Positioned.fill keeps the overlay
                      // exactly the image's size across the relayout when the file decodes,
                      // and gaplessPlayback stops the image blanking on rebuild.
                      return Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Two-finger pinch zooms/pans (InteractiveViewer);
                              // double-tap resets to 1×. The box overlay sits
                              // INSIDE the transformed child so it scales/pans
                              // with the photo and stays glued to the insects.
                              GestureDetector(
                                onDoubleTap: () => _setZoom(1),
                                child: InteractiveViewer(
                                  transformationController: _transformFor(i),
                                  maxScale: _maxZoom,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.file(
                                        p.file,
                                        fit: BoxFit.contain,
                                        gaplessPlayback: true,
                                      ),
                                      if (_showBoxes)
                                        Positioned.fill(
                                          child: CustomPaint(
                                            // The page's own zoom factor: stroke
                                            // width and label size are divided by
                                            // it inside the painter so they keep a
                                            // constant ON-SCREEN thickness while
                                            // the photo underneath scales up.
                                            painter: _BoxPainter(
                                              p.boxes,
                                              _transformFor(
                                                i,
                                              ).value.getMaxScaleOnAxis(),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              // Crop mode (round 91): a drag layer ABOVE the
                              // viewer wins every one-finger drag and draws
                              // the export rectangle. Points are converted to
                              // the photo's scene coordinates immediately
                              // (toScene), so the rectangle stays glued to the
                              // insect however the view is zoomed or panned.
                              if (_cropMode && i == _page)
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (d) {
                                    final scene = _transformFor(
                                      i,
                                    ).toScene(d.localPosition);
                                    final r = _cropSceneRect;
                                    final scale = _transformFor(
                                      i,
                                    ).value.getMaxScaleOnAxis();
                                    // Starting INSIDE the existing box (with
                                    // a finger-friendly margin, in on-screen
                                    // pixels) MOVES it; anywhere else redraws.
                                    final moving =
                                        r != null &&
                                        r.inflate(12 / scale).contains(scene);
                                    setState(() {
                                      _cropDragStartScene = scene;
                                      _cropMoveOriginRect = moving ? r : null;
                                      if (!moving) _cropSceneRect = null;
                                    });
                                  },
                                  onPanUpdate: (d) {
                                    final a = _cropDragStartScene;
                                    if (a == null) return;
                                    final scene = _transformFor(
                                      i,
                                    ).toScene(d.localPosition);
                                    setState(() {
                                      final origin = _cropMoveOriginRect;
                                      _cropSceneRect = origin != null
                                          ? moveSceneRect(
                                              origin,
                                              scene - a,
                                              _viewerSide,
                                            )
                                          : sceneRectForDrag(
                                              a,
                                              scene,
                                              _viewerSide,
                                              square: _cropSquareLock,
                                            );
                                    });
                                  },
                                  onPanEnd: (_) => _finishCropDrag(),
                                  child: CustomPaint(
                                    painter: _CropRectPainter(
                                      _viewportCropRect(i),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  // Tool column, fixed at the viewer's top-right corner (it
                  // does not swipe or zoom with the photo).
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _toolButton(
                          icon: Icons.crop_din,
                          tooltip: 'Show/hide detection boxes',
                          active: _showBoxes,
                          onTap: () => setState(() => _showBoxes = !_showBoxes),
                        ),
                        _toolButton(
                          icon: Icons.crop,
                          tooltip:
                              'Crop & export: drag a box around an insect, '
                              'then save it to the Gallery or share it to an '
                              'identification app (zoom in first if needed)',
                          active: _cropMode,
                          onTap: () {
                            setState(() {
                              _cropMode = !_cropMode;
                              _cropDragStartScene = null;
                              _cropMoveOriginRect = null;
                              _cropSceneRect = null;
                            });
                            _notifyFreeze();
                          },
                        ),
                        _toolButton(
                          icon: Icons.zoom_in,
                          tooltip:
                              'Zoom: slider here, or pinch with two fingers; '
                              'double-tap the photo to reset',
                          active: _zoomSliderOpen,
                          onTap: () => setState(
                            () => _zoomSliderOpen = !_zoomSliderOpen,
                          ),
                        ),
                        if (_zoomSliderOpen)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  '${_scale.toStringAsFixed(1)}×',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                  ),
                                ),
                                SizedBox(
                                  height: 140,
                                  width: 40,
                                  child: RotatedBox(
                                    quarterTurns: 3,
                                    child: Slider(
                                      value: _scale.clamp(1.0, _maxZoom),
                                      min: 1,
                                      max: _maxZoom,
                                      onChanged: _setZoom,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // ‹ › photo navigation, vertically centred on the edges.
                  // Always present: while zoomed they are the ONLY way to
                  // change photo (swiping then pans instead).
                  Positioned(
                    left: 4,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _navButton(
                        Icons.chevron_left,
                        _page > 0,
                        _page - 1,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: _navButton(
                        Icons.chevron_right,
                        _page < widget.photos.length - 1,
                        _page + 1,
                      ),
                    ),
                  ),
                  // Crop-mode chip (takes priority over the zoom chip: in
                  // crop mode a drag draws the box, whatever the zoom is).
                  if (_cropMode)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _cropSceneRect == null
                              ? 'Crop: drag a box around the insect'
                              : 'Crop: drag inside the box to move it, '
                                    'outside to redraw',
                          style: const TextStyle(
                            color: _CropRectPainter.color,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    )
                  // Zoom-mode chip: makes the mode switch visible — while it
                  // shows, a one-finger drag moves the zoomed photo and the
                  // ‹ › buttons (or a double-tap) leave the mode.
                  else if (_zoomed)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Zoom ${_scale.toStringAsFixed(1)}× — drag to move, '
                          '‹ › or double-tap to exit',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  // Pan pad (round 89): button fallback for moving the
                  // zoomed view, so panning never depends on winning a drag
                  // gesture against the surrounding scrollables.
                  if (_zoomed)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _padButton(
                              Icons.keyboard_arrow_up,
                              () => _nudge(0, -1),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _padButton(
                                  Icons.keyboard_arrow_left,
                                  () => _nudge(-1, 0),
                                ),
                                _padButton(
                                  Icons.keyboard_arrow_down,
                                  () => _nudge(0, 1),
                                ),
                                _padButton(
                                  Icons.keyboard_arrow_right,
                                  () => _nudge(1, 0),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        if (_cropMode) ...[_cropBar(), const SizedBox(height: 8)],
        Text(
          'Photo ${_page + 1} / ${widget.photos.length}'
          '  •  ${widget.photos[_page].boxes.length} detection'
          '${widget.photos[_page].boxes.length == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _infoPanel(widget.photos[_page]),
      ],
    );
  }

  /// Per-photo metadata read from the session log: resolution, the track ids
  /// visible in it, the capture time, and the file name.
  Widget _infoPanel(_PhotoSample p) {
    final res = (p.width != null && p.height != null)
        // ROI crops are square, so "short × wide" is the same number twice; we
        // still compute min/max in case a future non-square crop is logged.
        ? '${p.width! < p.height! ? p.width : p.height} × '
              '${p.width! < p.height! ? p.height : p.width} px'
        : 'unknown';
    final ids = p.trackIds.isEmpty
        ? 'none'
        : p.trackIds.map((e) => '#$e').join(', ');
    // One "#id Conf.: 0.xy" entry per track visible in this photo.
    final conf = p.trackIds.isEmpty
        ? 'n/a'
        : p.trackIds
              .map(
                (e) => p.trackConf[e] != null
                    ? '#$e Conf.: ${p.trackConf[e]!.toStringAsFixed(2)}'
                    : '#$e Conf.: —',
              )
              .join(', ');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Resolution', res),
          _infoRow('Track IDs', ids),
          _infoRow('Confidence', conf),
          _infoRow('Captured', _formatStamp(p.captureMs)),
          _infoRow('File', p.name),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ],
    ),
  );

  /// Capture time as hh:mm:ss:milliseconds (local time), e.g. 14:07:32:481.
  String _formatStamp(int ms) {
    if (ms <= 0) return 'unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    final msPart = d.millisecond.toString().padLeft(3, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}:$msPart';
  }
}

/// Draws ROI-normalized detection boxes (0..1) over the displayed square photo.
class _BoxPainter extends CustomPainter {
  final List<_DetBox> boxes;

  /// Zoom factor of the enclosing InteractiveViewer. The painter draws in the
  /// photo's (pre-zoom) coordinates, so stroke width and label size are
  /// divided by this to keep a constant ON-SCREEN thickness at any zoom —
  /// otherwise an 8× zoom turns the 2 px border into a fat 16 px band and the
  /// label into a banner covering the insect.
  final double zoom;
  _BoxPainter(this.boxes, [this.zoom = 1]);

  /// Box color of the insect(s) whose time-lapse schedule triggered the photo
  /// (the color all boxes used before round 86).
  static const triggerColor = Color(0xFF00E5FF);

  /// Box color of insects that were detected in the same frame but did not
  /// trigger the photo themselves.
  static const coDetectedColor = Color(0xFFFFC107);

  @override
  void paint(Canvas canvas, Size size) {
    for (final b in boxes) {
      final color = b.triggered ? triggerColor : coDetectedColor;
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / zoom;
      final rect = Rect.fromLTRB(
        b.left * size.width,
        b.top * size.height,
        b.right * size.width,
        b.bottom * size.height,
      );
      canvas.drawRect(rect, stroke);
      if (b.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: b.label,
            style: TextStyle(
              color: Colors.black,
              fontSize: 11 / zoom,
              backgroundColor: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(rect.left, (rect.top - 13 / zoom).clamp(0, size.height)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) =>
      old.boxes != boxes || old.zoom != zoom;
}

/// Draws the crop-export rectangle. It paints in VIEWPORT coordinates (the
/// rectangle is re-mapped from the photo's scene coordinates every build, see
/// [_PhotoViewerState._viewportCropRect]) so it stays glued to the photo while
/// zooming/panning, and dims everything outside so the kept region is obvious.
class _CropRectPainter extends CustomPainter {
  final Rect? rect;
  _CropRectPainter(this.rect);

  static const color = Color(0xFFFF9100);

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(r),
    );
    canvas.drawPath(outside, Paint()..color = Colors.black38);
    canvas.drawRect(
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Four-arrow "move" glyph just inside the top-right corner: the visual
    // cue that a drag starting inside the box MOVES it (clamped to the
    // canvas so it stays visible when that corner is panned off-screen).
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.open_with.codePoint),
        style: const TextStyle(
          fontFamily: 'MaterialIcons',
          fontSize: 16,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (r.right - tp.width - 3).clamp(0.0, size.width - tp.width),
        (r.top + 3).clamp(0.0, size.height - tp.height),
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _CropRectPainter old) => old.rect != rect;
}

/// Mean, median, min and max of a time series' values (the `ms` timestamps are
/// ignored). Median is the middle value of the sorted samples (the average of
/// the two middle ones for an even count) — a robust "typical" value that, unlike
/// the mean, isn't pulled by a few extreme spikes. Pure Dart (just a sort), so no
/// extra dependency. Returns null for an empty series.
({double mean, double median, double min, double max})? _seriesStats(
  List<(int ms, double v)> points,
) {
  if (points.isEmpty) return null;
  final vals = [for (final p in points) p.$2]..sort();
  final n = vals.length;
  final mean = vals.reduce((a, b) => a + b) / n;
  final median = n.isOdd ? vals[n ~/ 2] : (vals[n ~/ 2 - 1] + vals[n ~/ 2]) / 2;
  return (mean: mean, median: median, min: vals.first, max: vals.last);
}

/// "Nice number" rounding (Heckbert's algorithm) used to pick human-friendly axis
/// steps: it snaps [x] to the nearest 1, 2 or 5 × 10ⁿ. With [round] true it picks
/// the closest nice value; with it false it picks the smallest nice value ≥ [x].
/// This is why the axes land on round numbers (e.g. 0, 5, 10, 15) instead of
/// awkward fractions (e.g. 0, 2.5, 5).
double _niceNum(double x, {required bool round}) {
  if (x <= 0) return 1;
  final exp = (log(x) / ln10).floor();
  final f = x / pow(10, exp);
  double nf;
  if (round) {
    nf = f < 1.5
        ? 1
        : f < 3
        ? 2
        : f < 7
        ? 5
        : 10;
  } else {
    nf = f <= 1
        ? 1
        : f <= 2
        ? 2
        : f <= 5
        ? 5
        : 10;
  }
  return nf * pow(10, exp).toDouble();
}

/// One labelled tick on the time (X) axis: [ms] is the offset from session start.
class _TimeTick {
  final double ms;
  final String label;
  const _TimeTick(this.ms, this.label);
}

/// Builds readable, round time ticks across a session of [totalMs] milliseconds.
/// It chooses the unit (seconds / minutes / hours / days) so the session spans at
/// least a few whole units — so you never see an awkward step like "0.5 h" — and
/// places ticks at nice round multiples (e.g. every 2 min, or every 5 h).
List<_TimeTick> _timeTicks(double totalMs) {
  if (totalMs <= 0) return const [_TimeTick(0, '0 s')];
  const units = <(double, String)>[
    (1000.0, 's'),
    (60000.0, 'min'),
    (3600000.0, 'h'),
    (86400000.0, 'd'),
  ];
  // Largest unit that still gives ≥ 3 whole units across the session.
  var unitMs = units.first.$1;
  var suffix = units.first.$2;
  for (final u in units) {
    if (totalMs / u.$1 >= 3) {
      unitMs = u.$1;
      suffix = u.$2;
    } else {
      break;
    }
  }
  final totalUnits = totalMs / unitMs;
  var step = _niceNum(totalUnits / 5, round: true); // aim for ~5 ticks
  if (step < 1) step = 1; // never a fractional unit step
  final ticks = <_TimeTick>[];
  for (var v = 0.0; v <= totalUnits + step * 1e-3; v += step) {
    ticks.add(_TimeTick(v * unitMs, '${v.toStringAsFixed(0)} $suffix'));
  }
  return ticks;
}

/// A nice value (Y) axis: rounded min/max bounds and a round step, so the
/// horizontal gridlines sit on readable numbers that comfortably cover the data
/// (with a little headroom) instead of just min/mid/max.
({double niceMin, double niceMax, double step}) _niceValueAxis(
  double lo,
  double hi,
) {
  if (hi - lo < 1e-9) hi = lo + 1; // flat series: give it a unit of room
  final range = _niceNum(hi - lo, round: false);
  final step = _niceNum(range / 4, round: true); // ~4 intervals (5 lines)
  final niceMin = (lo / step).floor() * step;
  final niceMax = (hi / step).ceil() * step;
  return (niceMin: niceMin, niceMax: niceMax, step: step);
}

/// Decimal places suited to a (possibly small) axis step, so tiny ranges (e.g.
/// energy in fractions of a watt-hour) still read clearly while whole-number
/// steps show no needless ".0".
int _decimalsFor(double step) {
  if (step >= 1) return 0;
  return (-(log(step) / ln10)).ceil().clamp(1, 4);
}

/// Gantt timeline: one labelled lane per track id with a bar from first to last
/// sighting, end-dots, and a time axis (seconds/minutes/hours) along the bottom.
class _GanttPainter extends CustomPainter {
  final List<int> ids;
  final Map<int, (int first, int last)> spans;
  final int startMs;
  final int endMs;
  final double laneHeight;
  final double axisHeight;
  final bool showLabels;

  _GanttPainter({
    required this.ids,
    required this.spans,
    required this.startMs,
    required this.endMs,
    required this.laneHeight,
    required this.axisHeight,
    this.showLabels = true,
  });

  static const double _gutter = 44.0;

  @override
  void paint(Canvas canvas, Size size) {
    final totalMs = (endMs - startMs).toDouble();
    final plotLeft = _gutter;
    final plotWidth = size.width - _gutter;
    final plotBottom = size.height - axisHeight;

    double xForMs(int ms) => plotLeft + ((ms - startMs) / totalMs) * plotWidth;

    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final barPaint = Paint()..color = const Color(0xFF00E5FF);
    final dotPaint = Paint()..color = const Color(0xFFFFEB3B);

    for (final tk in _timeTicks(totalMs)) {
      final x = plotLeft + (tk.ms / totalMs) * plotWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), axisPaint);
      _text(
        canvas,
        tk.label,
        Offset(x + 2, plotBottom + 6),
        Colors.white54,
        10,
      );
    }

    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final span = spans[id]!;
      final yCenter = i * laneHeight + laneHeight / 2;
      if (showLabels) {
        _text(canvas, '#$id', Offset(4, yCenter - 7), Colors.white70, 11);
      }
      final barHalf = (laneHeight * 0.35).clamp(1.5, 5.0);
      final x1 = xForMs(span.$1);
      final x2 = xForMs(span.$2);
      final barRect = Rect.fromLTRB(
        x1,
        yCenter - barHalf,
        (x2 - x1) < 2 ? x1 + 2 : x2,
        yCenter + barHalf,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(barRect, const Radius.circular(2)),
        barPaint,
      );
      if (showLabels) {
        canvas.drawCircle(Offset(x1, yCenter), 3, dotPaint);
        canvas.drawCircle(Offset(x2, yCenter), 3, dotPaint);
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _GanttPainter old) =>
      old.ids != ids || old.startMs != startMs || old.endMs != endMs;
}

/// A simple time series (temperature or FPS) drawn as a line, y-axis auto-scaled.
class _SeriesPainter extends CustomPainter {
  final List<(int ms, double v)> points;
  final int startMs;
  final int endMs;
  final Color color;
  final String unit;

  _SeriesPainter({
    required this.points,
    required this.startMs,
    required this.endMs,
    required this.color,
    required this.unit,
  });

  static const double _gutter = 44.0;
  static const double _axisHeight = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    final totalMs = (endMs - startMs).toDouble();
    final plotLeft = _gutter;
    final plotWidth = size.width - _gutter;
    final plotBottom = size.height - _axisHeight;

    var lo = points.first.$2, hi = points.first.$2;
    for (final p in points) {
      lo = min(lo, p.$2);
      hi = max(hi, p.$2);
    }
    // Round the value (Y) axis to readable bounds + step (e.g. 0,10,20,30,40,50
    // for temperature), with headroom, instead of just min/mid/max.
    final ax = _niceValueAxis(lo, hi);
    final vrange = (ax.niceMax - ax.niceMin) == 0
        ? 1.0
        : ax.niceMax - ax.niceMin;
    final vdec = _decimalsFor(ax.step);

    double xForMs(int ms) => plotLeft + ((ms - startMs) / totalMs) * plotWidth;
    double yForV(double v) =>
        plotBottom - ((v - ax.niceMin) / vrange) * plotBottom;

    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    // Horizontal gridlines at the round value steps.
    for (var v = ax.niceMin; v <= ax.niceMax + ax.step * 1e-3; v += ax.step) {
      final y = yForV(v);
      canvas.drawLine(Offset(plotLeft, y), Offset(size.width, y), axisPaint);
      _text(
        canvas,
        '${v.toStringAsFixed(vdec)}$unit',
        Offset(2, y - 6),
        Colors.white54,
        10,
      );
    }
    // Dim vertical gridlines at the SAME round time ticks (and same _gutter) as
    // the Gantt timeline, so every graph lines up on the X (time) axis — a visual
    // cue that they share one timeline, not just matching ticks.
    for (final tk in _timeTicks(totalMs)) {
      final x = plotLeft + (tk.ms / totalMs) * plotWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), axisPaint);
      _text(
        canvas,
        tk.label,
        Offset(x + 2, plotBottom + 4),
        Colors.white54,
        10,
      );
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    // A hole in the series (e.g. the motion gate kept the detector asleep, so
    // no inference samples were logged for that stretch — round 77) must show
    // as a gap, not as a straight bridge that looks like data. Any pause much
    // longer than the series' median sampling interval breaks the line.
    final gaps = <int>[
      for (var i = 1; i < points.length; i++) points[i].$1 - points[i - 1].$1,
    ]..sort();
    final medianGapMs = gaps.isEmpty ? 0 : gaps[gaps.length ~/ 2];
    final breakMs = max(3000, medianGapMs * 3);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = xForMs(points[i].$1);
      final y = yForV(points[i].$2);
      final startsSegment = i == 0 || points[i].$1 - points[i - 1].$1 > breakMs;
      startsSegment ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, linePaint);
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter old) =>
      old.points != points || old.startMs != startMs || old.endMs != endMs;
}
