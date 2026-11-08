// FaunaPulse, session summary screen:
// reading the session folder (log, photos, videos, identification results).
//
// A `part` of session_summary_screen.dart: that screen's State class is split into
// extensions, one file per part of the screen, so each file stays readable
// while the private fields stay shared (Dart privacy is per library, and a
// part file belongs to the main file's library). Fields, getters and the
// lifecycle overrides stay in the main file; part files hold methods only.
//
// The extensions below are the State's own code, so calling setState here is
// correct; the analyzer cannot tell an extension from outside code.
// ignore_for_file: invalid_use_of_protected_member

part of '../session_summary_screen.dart';

extension _SummaryLoading on _SessionSummaryScreenState {
  Future<void> _loadClipTotals() async {
    try {
      final t = await VideoClipTotals.read(widget.logFile.parent);
      final after = await VideoTracker.readSummary(widget.logFile.parent);
      if (!mounted) return;
      setState(() {
        if (t.count + t.skippedBursts > 0) _clipTotals = t;
        _afterVisits = after?.visits;
      });
    } catch (e) {
      logSwallowed('summary_clip_totals', e);
    }
  }

  /// Reads the video analysis settings from the head of
  /// video_detections.jsonl (round 229). Its first record is enough: a
  /// continued run keeps the same box settings, and starting over rewrites
  /// the file.
  Future<void> _loadVideoRun() async {
    final f = File(
      '${widget.logFile.parent.path}/${VideoDetector.outputFileName}',
    );
    if (!f.existsSync()) return;
    try {
      final head = await f
          .openRead(0, 8192)
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final rec = _tryDecode(head.split('\n').first);
      if (rec?['type'] == 'video_run_start' && mounted) {
        setState(() => _videoRun = rec);
      }
    } catch (e) {
      logSwallowed('summary_video_run_load', e);
    }
  }

  /// Reads the compact per-visit list of the newest `summary_<pack>.json`
  /// (round 209); called again after the Identify screen closes.
  Future<void> _loadIdentification() async {
    LatestIdentification? id;
    var stale = false;
    try {
      id = await LatestIdentification.load(widget.logFile.parent);
      // Round 235: visits found again since use other numbers.
      stale = id?.visitsRunId != null &&
          id!.visitsRunId != await IdentificationJob.currentVisitsRunId(widget.logFile.parent);
    } catch (e) {
      logSwallowed('summary_identification_load', e);
    }
    if (mounted) {
      setState(() {
        _identification = id;
        _identificationStale = stale;
      });
    }
  }

  /// Loads (or reloads after a cleanup) the post-hoc analysis results, if any.
  Future<void> _loadPostHoc() async {
    try {
      final f = File(
        '${widget.logFile.parent.path}/${PostDetector.outputFileName}',
      );
      if (!f.existsSync()) return;
      final prefs = await SharedPreferences.getInstance();
      final gap = prefs.getDouble('analysis_keep_gap') ?? 2.0;
      // Round 179: the review-time tiny-box threshold the analysis screen
      // tunes — applied here too, so the green boxes, keep chips, deletion
      // marks and counts in this review match the cleanup numbers over there.
      final minBoxPct = prefs.getDouble('analysis_sahi_min_box_pct') ?? 0;
      // Round 163 (E5): read + parse the (possibly large) results file off
      // the UI isolate; only the outcome list is copied back.
      final parsed = await _outcomesOffUi(f.path);
      // Only photos still on disk — earlier cleanups keep their records.
      final outcomes = applyMinBoxFrac(parsed, minBoxPct / 100)
          .where(
            (o) => File(
              '${widget.logFile.parent.path}/roi_frames/${o.name}',
            ).existsSync(),
          )
          .toList();
      final decisions = keepDecisions(outcomes, (gap * 1000).round());
      final keep = decisions.keys.toSet();
      final boxes = <String, List<_DetBox>>{};
      for (final o in outcomes) {
        if (o.boxes.isEmpty) continue;
        boxes[o.name] = [
          for (final PostBox b in o.boxes)
            _DetBox(
              left: b.left,
              top: b.top,
              right: b.right,
              bottom: b.bottom,
              label: '${b.className} ${(b.confidence * 100).round()}%',
              triggered: false,
              postHoc: true,
            ),
        ];
      }
      if (!mounted) return;
      setState(() {
        _postOutcomes = outcomes;
        _postKeep = keep;
        _postGapSeconds = gap;
        _postMinBoxFrac = minBoxPct / 100;
        _postBoxesByName = boxes;
        _postDecisions = decisions;
        _postDeleteMarked = {
          for (final o in outcomes)
            if (!keep.contains(o.name)) o.name,
        };
      });
    } catch (e) {
      logSwallowed('summary_posthoc_load', e);
    }
  }

  /// Loads the Setup tab's storage rows: the session folder's total size
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

  /// Loads the cheap headline stats first, then kicks off the full graph
  /// computation so the visit timeline appears without a button press (round
  /// 148: always — the timeline is the main deliverable, and the same single
  /// log parse also fills whatever diagnostic series the session recorded).
  /// Also restores the "Extra graphs" expanded/collapsed viewing preference.
  Future<void> _init() async {
    SharedPreferences.getInstance().then((p) {
      final expanded = p.getBool(_extraGraphsExpandedKey) ?? false;
      final bin = p.getInt(_durationBinKey);
      if (mounted &&
          (expanded != _extraGraphsExpanded ||
              (bin != null && _durationBinChoices.contains(bin)))) {
        setState(() {
          _extraGraphsExpanded = expanded;
          if (bin != null && _durationBinChoices.contains(bin)) {
            _durationBinSeconds = bin;
          }
        });
      }
    });
    await _loadStats();
    if (mounted && !_graphsRequested) _loadGraphs();
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
        _videosDeleted = _videosFreedBytes = 0;
        _guardStop = null;
        for (final l in tailLines) {
          // Written just before `end_of_session`, so it is always in the tail.
          if (l.contains('"guard_stop"')) _guardStop = _tryDecode(l) ?? _guardStop;
          if (!l.contains('"video_cleanup"')) continue;
          final rec = _tryDecode(l);
          _videosDeleted += (rec?['clips'] as List?)?.length ?? 0;
          _videosFreedBytes += (rec?['freed_bytes'] as num?)?.toInt() ?? 0;
        }
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
  /// `is_plugged` (round 188) catches the power-bank case Android reports as
  /// NOT_CHARGING with a full battery: plugged, but `is_charging` false —
  /// the charger then carries the load and the sensor reads ~nothing, so the
  /// series must be invalidated on either flag.
  void _readChargingFlag(Map<String, dynamic>? rec) {
    final th = rec?['thermal'];
    if (th is! Map) return;
    if (th['is_charging'] == true || th['is_plugged'] == true) {
      _chargingDuringSession = _chargingAtStartOrEnd = true;
    }
  }

  /// Fills the graphs from the shared [SessionLogIndex] (round 163, E5):
  /// visit spans per track, temperature/FPS/inference series, and the power
  /// samples the energy series derives from. The parse itself — previously a
  /// full `readAsLines()` right here on the UI isolate — happens once, off
  /// the UI isolate, for all tabs together.
  Future<void> _loadGraphs() async {
    setState(() {
      _graphsRequested = true;
      _graphsLoading = true;
    });
    try {
      final index = await _logIndex;
      _spans.addAll(index.trackSpans);
      _trackSource = index.trackSource;
      _postTrackStart = index.postTrackStart;
      if (_showRunGraphs) {
        final samples = await VideoRunSamples.read(
          File('${widget.logFile.parent.path}/${VideoDetector.outputFileName}'),
        );
        _videoSamples = samples;
        if (samples != null) {
          _temps.addAll(samples.temps);
          _cpuTemps.addAll(samples.cpuTemps);
          _gpuTemps.addAll(samples.gpuTemps);
          _headroom.addAll(samples.headroom);
          _fps.addAll(samples.framesPerS);
          _infMs.addAll(samples.detectMs);
          _memUsedGb.addAll(samples.memUsedGb);
          _appCpuCores.addAll(samples.appCpuCores);
          _buildEnergySeries(samples.power, maxStepMs: samples.runGapMs);
        }
      } else {
        _temps.addAll(index.temps);
        _cpuTemps.addAll(index.cpuTemps);
        _gpuTemps.addAll(index.gpuTemps);
        _headroom.addAll(index.headroom);
        _fps.addAll(index.fps);
        _infMs.addAll(index.infMs);
        _memUsedGb.addAll(index.memUsedGb);
        _appCpuCores.addAll(index.appCpuCores);
        _buildEnergySeries(index.powerSamples);
      }
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
  /// Steps of [maxStepMs] or more (the gap between two video analysis runs)
  /// are neither smoothed across nor counted as energy.
  void _buildEnergySeries(List<IndexedPowerSample> raw, {int? maxStepMs}) {
    // Battery-terminal readings only measure the PHONE's consumption while it
    // is discharging: plugged in, the sensor sees the charging current (or ~0
    // once the battery is full and the charger carries the load). Any charging
    // anywhere in the session — per-sample flags (round 84; round 188 also
    // `is_plugged`, which catches the full-battery-on-power-bank case Android
    // reports as NOT_CHARGING), or the start/end flags already read by
    // [_readChargingFlag] (the only signal on older logs whose power records
    // lack the keys) — invalidates the whole series, so nothing is built and
    // no misleading W/Wh number can surface. The Graphs tab shows an
    // explanatory note instead.
    if (raw.any((s) => s.isCharging == true || s.isPlugged == true)) {
      _chargingDuringSession = true;
    }
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
    double voltAt(IndexedPowerSample s) =>
        _singleCellVoltageV(s.voltageMv) ?? avgV;

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
    // A phone whose battery sensor reports no current AND whose charge
    // counter never moves yields an all-zero series (round 188): a flat 0 W
    // line with a confident "0.00 Wh" caption would be pure fiction, so the
    // graph shows its "Not enough samples." placeholder instead.
    if (pts.every((p) => p.$2 == 0)) return;

    // A light 3-point moving average smooths the jitter from coarse current /
    // charge-counter steps, so the line is readable without hiding the trend.
    bool joined(int a, int b) =>
        maxStepMs == null || pts[b].$1 - pts[a].$1 < maxStepMs;
    for (var i = 0; i < pts.length; i++) {
      final lo = i == 0 || !joined(i - 1, i) ? i : i - 1;
      final hi = i == pts.length - 1 || !joined(i, i + 1) ? i : i + 1;
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
      final dtMs = _power[i].$1 - _power[i - 1].$1;
      if (maxStepMs != null && dtMs >= maxStepMs) continue;
      final dtH = dtMs / 3600000.0;
      if (dtH <= 0) continue;
      wh += (_power[i].$2 + _power[i - 1].$2) / 2.0 * dtH;
    }
    _energyTotalWh = wh;
  }

  /// Fills the Photos tab from the shared [SessionLogIndex] (round 163, E5):
  /// maps each saved photo's indexed record to the viewer's display types,
  /// then picks up to [_randomSampleCount] of them AT RANDOM (round 187 —
  /// or takes all), so the user can eyeball whether detections look right.
  /// The heavy log parse — previously a full `readAsLines()` plus a second
  /// full re-scan for high-res box time-matching, all on the UI isolate —
  /// lives in [SessionLogIndex.build] now.
  /// [all] loads every photo; [sample] sets a new sample size; neither keeps
  /// the current size (a reload after a cleanup).
  Future<void> _loadPhotos({bool all = false, int? sample}) async {
    final size = all ? null : (sample ?? _photoSampleSize);
    setState(() {
      _photosRequested = true;
      _photosLoading = true;
      _photoSampleSize = size;
    });
    var order = const <String>[];
    var photosByName = const <String, IndexedPhoto>{};
    var referenceNames = const <String>{};
    try {
      final index = await _logIndex;
      order = index.photoOrder;
      photosByName = index.photos;
      referenceNames = index.referenceNames;
    } catch (e) {
      // Use whatever parsed.
      logSwallowed('summary_photos_scan', e);
    }

    // Label text for a trigger box — same format the parse always rendered:
    // "#id class  0.87".
    String triggerLabel(IndexedPhotoBox b) {
      final confLabel = b.confidence != null
          ? '  ${b.confidence!.toStringAsFixed(2)}'
          : '';
      return '#${b.trackId ?? '?'} ${b.className ?? ''}$confLabel'.trim();
    }

    // Builds a fully-populated display sample from one photo's indexed record.
    _PhotoSample sampleFor(IndexedPhoto p, File file) {
      // Companion sits next to its high-res photo in roi_frames/; only offer
      // the flip when the file is really on disk (best-effort save, r108).
      final liveName = p.liveName;
      final liveFile = liveName == null
          ? null
          : File('${file.parent.path}/$liveName');
      final liveExists = liveFile != null && liveFile.existsSync();
      final still = p.stillMatch;
      return _PhotoSample(
        file: file,
        name: p.name,
        boxes: [
          for (final b in p.boxes)
            _DetBox(
              left: b.left,
              top: b.top,
              right: b.right,
              bottom: b.bottom,
              label: triggerLabel(b),
              triggered: b.triggered,
            ),
        ],
        trackIds: p.trackIds,
        trackConf: p.trackConf,
        captureMs: p.captureMs,
        width: p.resW,
        height: p.resH,
        liveFile: liveExists ? liveFile : null,
        liveName: liveExists ? liveName : null,
        livePx: p.livePx,
        contentLagMs: p.contentLagMs,
        liveLagMs: p.liveLagMs,
        contentAtMs: p.contentAtMs,
        contentAtApprox: p.contentAtApprox,
        // Round 114/115 time-matched boxes for the high-res view. Same label
        // format as the trigger boxes; a trailing ≈ marks the odd single-side
        // box inside an interpolated photo. Matched frames rarely carry this
        // photo's filename; those boxes render in the co-detected color —
        // honest, they were not the trigger.
        stillBoxes: still == null
            ? null
            : [
                for (final b in still.boxes)
                  _DetBox(
                    left: b.left,
                    top: b.top,
                    right: b.right,
                    bottom: b.bottom,
                    label:
                        '#${b.trackId ?? '?'} ${b.className ?? ''}'
                                '${b.confidence != null ? '  ${b.confidence!.toStringAsFixed(2)}' : ''}'
                                '${still.anyInterpolated && !b.interpolated ? ' ≈' : ''}'
                            .trim(),
                    triggered: b.triggered,
                  ),
              ],
        stillMatch: still,
        stillWithinTol: p.stillWithinTol,
        stillMatchNote: p.stillMatchNote,
        isReference: p.isReference,
        clip: p.clip,
        ptsUs: p.ptsUs,
      );
    }

    // Either every saved photo (in order) or an even sample across the session.
    final dir = widget.logFile.parent.path;
    // Normal captures live in roi_frames/, reference photos in gt_frames/;
    // the log stores just the file name.
    File fileFor(String name) => File(
      '$dir/${referenceNames.contains(name) ? 'gt_frames' : 'roi_frames'}/$name',
    );
    // Frames kept from videos (round 234) are listed as soon as the visits
    // are found and saved afterwards: count and sample only the saved ones.
    if (_videoTab) order = [for (final n in order) if (fileFor(n).existsSync()) n];
    final picked = <_PhotoSample>[];
    if (order.isNotEmpty) {
      // Either every photo, or a random sample of [size] photos. The picked
      // names keep their capture order either way, so swiping through the
      // viewer always moves forward in time.
      List<String> names = order;
      if (size != null && order.length > size) {
        final indices = List<int>.generate(order.length, (i) => i)
          ..shuffle(Random());
        names = (indices.take(size).toList()..sort())
            .map((i) => order[i])
            .toList();
      }
      for (final name in names) {
        final p = photosByName[name];
        final file = fileFor(name);
        if (p != null && file.existsSync()) picked.add(sampleFor(p, file));
      }
    }
    if (mounted) {
      setState(() {
        _totalSavedPhotos = order.length;
        _totalReferencePhotos = referenceNames.length;
        _photos = picked;
        _photosLoading = false;
      });
    }
  }

  /// Stream-grid ROI side of a start/roi_update record — the ÷32 number the
  /// user saw on screen. Round-109+ records carry it as `roi_side_stream_px`;
  /// older ones get it recomputed from the record's `roi` block (which may be
  /// a high-res-frame projection, e.g. "1333" for an on-screen 480 — session_6)
  /// against the start record's analysis frame.
  int? _roiStreamSideOf(Map<dynamic, dynamic> rec) {
    final direct = (rec['roi_side_stream_px'] as num?)?.toInt();
    if (direct != null && direct > 0) return direct;
    final roi = rec['roi'];
    if (roi is! Map) return null;
    final aw = (_startRec?['analysis_frame_width_px'] as num?)?.toInt() ?? 0;
    final ah = (_startRec?['analysis_frame_height_px'] as num?)?.toInt() ?? 0;
    return roiStreamSideFromLog(roi, aw, ah);
  }

  /// Collects the session's settled mid-session ROI changes (`roi_update`
  /// records) for the Settings tab's history list — from the shared
  /// [SessionLogIndex] since round 163 (E5); previously its own full
  /// `readAsLines()` scan.
  Future<void> _loadRoiHistory() async {
    var entries = const <RoiHistoryEntry>[];
    try {
      entries = (await _logIndex).roiHistory;
    } catch (e) {
      logSwallowed('roi_history_load', e);
    }
    if (mounted && entries.isNotEmpty) {
      setState(() => _roiHistory = entries);
    }
  }

  /// Empties what [_loadGraphs] fills, before it runs again.
  void _clearGraphData() {
    _spans.clear();
    _temps.clear();
    _cpuTemps.clear();
    _gpuTemps.clear();
    _headroom.clear();
    _fps.clear();
    _infMs.clear();
    _memUsedGb.clear();
    _appCpuCores.clear();
    _power.clear();
    _videoSamples = null;
    _energyTotalWh = _powerAvg = _powerMedian = _powerMin = _powerMax = null;
    _chargingDuringSession = _chargingAtStartOrEnd;
    // Not _uniqueTracks: read once from the end record, a live session's
    // visit count (round 241: the graphs switch reloads the graphs only).
  }
}
