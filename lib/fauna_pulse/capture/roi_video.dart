// FaunaPulse (round 238): time-lapse bursts saved as video clips of the ROI
// (Settings → Setup → "Save bursts as": Video).
//
// Each burst becomes one MP4 clip in the session's `videos/` folder, recorded
// natively (RoiVideoWriter.kt) from the live camera frames: the ROI square,
// upright, at the "Saved photo side" and the chosen frame rate. The clips are
// analysed later on "Run AI on videos", like imported videos, so each closed
// clip gets the same `video_clip` record an import writes (file, start time,
// length, size), plus how it was recorded.
//
// Records in session.jsonl:
//   timelapse_video_start  a clip was opened (so a clip cut short by an app
//                          kill is still accounted for): file, burst, fps,
//                          side_px, bitrate, encoder
//   video_clip             a clip was closed: the import fields plus
//                          frames_skipped, burst, end_reason and timings
//   video_skipped          a burst, or part of one, without a clip: burst,
//                          reason (storage_low / start_failed / no_frames /
//                          stop_failed), message
//
// Round 240, live AI + ROI video: the same clips while the live AI runs, as
// 5-minute segments ([kLiveVideoSegmentMs]); the records say `segment`
// instead of `burst`, and the opening one is `live_video_start`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../logging/device_storage.dart' show formatBytes;
import '../logging/session_logger.dart';
import '../models/session_config.dart';
import 'roi_capture.dart' show roiPhotoFileName;

/// Bits per pixel per frame: about 4 Mbit/s for a 1024-px square at 15
/// frames per second (about 1.8 GB per recorded hour). Enough for a still
/// scene with small moving insects; a lower value blurs fine detail first.
const double kRoiVideoBitsPerPixel = 0.25;

/// Encoder bit rate (bits per second) of a [sidePx] square clip at [fps].
int roiVideoBitrate(int sidePx, int fps) =>
    (kRoiVideoBitsPerPixel * sidePx * sidePx * fps).round();

/// Clips come out larger than the set bit rate: 20 % on the Xiaomi's
/// encoder (round 238, 480 px, a moving scene), so storage estimates add it.
const double kRoiVideoSizeMargin = 1.2;

/// Bytes per recorded hour of such a clip, with [kRoiVideoSizeMargin].
double roiVideoBytesPerHour(int sidePx, int fps) =>
    roiVideoBitrate(sidePx, fps) / 8 * 3600 * kRoiVideoSizeMargin;

/// Share of the session time that is recorded: burst ÷ (burst + break), 1
/// for a continuous time-lapse (no break).
double timeLapseRecordedShare(double burstSeconds, double gapSeconds) {
  if (gapSeconds <= 0) return 1;
  if (burstSeconds <= 0) return 0;
  return burstSeconds / (burstSeconds + gapSeconds);
}

/// Minutes a session with [c] records for: the session length, or for a
/// scheduled run every window on every day.
int plannedSessionMinutes(SessionConfig c) {
  if (!c.scheduleEnabled) return c.sessionMinutes;
  final perDay = c.scheduleWindows.fold<int>(
    0,
    (s, w) => s + math.max(0, w.endMinute - w.startMinute),
  );
  return perDay * c.scheduleDays;
}

/// The storage estimate under "Save bursts as" (plain language). The side is
/// the "Saved photo side": clips are never larger, smaller when the ROI
/// covers fewer camera pixels.
String roiVideoStorageEstimate(SessionConfig c) => _storageEstimate(
  c,
  c.timeLapseVideoFps,
  timeLapseRecordedShare(c.durationSeconds, c.timeLapseGapSeconds),
);

/// The same for live AI + ROI video (round 240): the whole session is filmed.
String liveAiVideoStorageEstimate(SessionConfig c) => _storageEstimate(c, c.liveAiVideoFps, 1);

String _storageEstimate(SessionConfig c, int fps, double share) {
  final side = c.targetRoiSavedPx;
  final perHour = roiVideoBytesPerHour(side, fps);
  final minutes = plannedSessionMinutes(c);
  final recordedMin = minutes * share;
  final total = perHour * recordedMin / 60;
  String mins(double m) => m >= 90
      ? '${(m / 60).toStringAsFixed(1)} h'
      : m >= 1
      ? '${m.round()} min'
      : '${(m * 60).round()} s';
  final what = c.scheduleEnabled ? 'This schedule' : 'A ${mins(minutes.toDouble())} session';
  return 'Up to about ${formatBytes(perHour.round())} per hour of video '
      '(${side}px, $fps frames per second; less for a smaller ROI or a still '
      'scene). $what records about ${mins(recordedMin)} of video: '
      'about ${formatBytes(total.round())}.';
}

/// Length of one live-AI clip (round 240): a new clip starts every 5 minutes,
/// so an app killed mid-session loses at most the open one (an MP4 is only
/// readable once closed).
const int kLiveVideoSegmentMs = 5 * 60 * 1000;

/// File name of a clip: the photo name with `.mp4`, so clips and photos of
/// one session sort together and carry the session's token.
String roiVideoFileName(int epochMs, String token) =>
    roiPhotoFileName(epochMs, token).replaceFirst(RegExp(r'\.jpg$'), '.mp4');

/// Opens and closes the clips of one recording, one at a time. Calls are
/// queued, so the end of one clip and the start of the next never overlap on
/// the native side. The screen calls [sync] on every time-lapse tick with the
/// burst that should be recording now (null between bursts, or while the
/// camera is off), and [stop] before the session ends.
class TimeLapseVideoClips {
  TimeLapseVideoClips({
    required this.videosDir,
    required this.fileToken,
    required this.fps,
    required this.sidePx,
    required this.startNative,
    required this.stopNative,
    required this.logger,
    this.storageLow,
    this.onProblem,
    this.live = false,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Live AI segments (round 240) instead of time-lapse bursts.
  final bool live;
  String get _indexKey => live ? 'segment' : 'burst';

  final Directory videosDir;
  final String fileToken;
  final int fps;

  /// Side for the next clip (the ROI can change between bursts).
  final int Function() sidePx;

  /// Opens a clip at the path: `{sidePx, bitrate, encoder}`, `{error}`, or
  /// null (no camera).
  final Future<Map<String, dynamic>?> Function(String path, int sidePx, int fps) startNative;

  /// Closes the clip: its facts (see RoiVideoWriter.facts), or null.
  final Future<Map<String, dynamic>?> Function(String reason) stopNative;

  final SessionLogger? Function() logger;
  final bool Function()? storageLow;

  /// Told once per burst and reason when a burst gets no clip (the screen
  /// shows it, since a field user would otherwise not notice).
  final void Function(String reason, String? message)? onProblem;
  final int Function() _now;

  int? _burst;
  String? _file;
  int _startedMs = 0;
  int _side = 0;
  int? _noClipBurst;
  String? _noClipReason;
  Future<void> _queue = Future.value();

  /// Clips closed with at least one frame, and their bytes.
  int clips = 0;
  int bytes = 0;

  /// Whether a clip is open.
  bool get recording => _burst != null;

  /// Why the current burst has no clip (storage_low, start_failed), or null.
  String? get problem => _burst == null ? _noClipReason : null;

  /// Makes the open clip match [burst]: nothing when it already records that
  /// burst; otherwise the open clip ends ([endReason]) and, for a non-null
  /// burst, a new one starts. A burst whose clip could not start is not
  /// retried until the next burst, except for low storage, which is checked
  /// again on every call (and logged once).
  Future<void> sync(int? burst, {String endReason = 'burst_end'}) => _enqueue(() async {
    if (burst != null && burst == _burst) return;
    if (_burst != null) await _stop(endReason);
    if (burst != null) await _start(burst);
  });

  /// Ends the open clip, if any.
  Future<void> stop(String reason) => _enqueue(() async {
    if (_burst != null) await _stop(reason);
  });

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _queue.then((_) => op()).catchError((Object e) {
      logger()?.logAppError({'source': 'timelapse_video', 'message': '$e'});
    });
    _queue = next;
    return next;
  }

  void _noClip(int burst, String reason, [String? message, String? file]) {
    if (_noClipBurst == burst && _noClipReason == reason) return;
    _noClipBurst = burst;
    _noClipReason = reason;
    onProblem?.call(reason, message);
    logger()?.logVideoSkipped({
      _indexKey: burst,
      'reason': reason,
      'file': ?file,
      'message': ?message,
    });
  }

  Future<void> _start(int burst) async {
    if (storageLow?.call() ?? false) {
      _noClip(burst, 'storage_low', 'Less than 1 GB free: no new video until space is freed.');
      return;
    }
    if (_noClipBurst == burst && _noClipReason == 'start_failed') return;
    final ms = _now();
    final name = roiVideoFileName(ms, fileToken);
    videosDir.createSync(recursive: true);
    final side = sidePx();
    final r = await startNative('${videosDir.path}/$name', side, fps);
    if (r == null || r['error'] != null) {
      _noClip(burst, 'start_failed', '${r?['error'] ?? 'the camera did not answer'}');
      return;
    }
    _burst = burst;
    _file = 'videos/$name';
    _startedMs = ms;
    _noClipReason = null;
    _side = (r['sidePx'] as num?)?.toInt() ?? side;
    final startRecord = {
      'file': _file,
      _indexKey: burst,
      'fps': fps,
      'side_px': _side,
      if (_side != side) 'requested_side_px': side,
      'bitrate': r['bitrate'],
      'encoder': r['encoder'],
    };
    live ? logger()?.logLiveVideoStart(startRecord) : logger()?.logTimeLapseVideoStart(startRecord);
  }

  Future<void> _stop(String reason) async {
    final file = _file!;
    final burst = _burst!;
    _burst = null;
    _file = null;
    final r = await stopNative(reason).timeout(const Duration(seconds: 5), onTimeout: () => null);
    if (r == null) {
      _noClip(burst, 'stop_failed', 'The clip did not close in time; the file may be unreadable.', file);
      return;
    }
    final frames = (r['frames'] as num?)?.toInt() ?? 0;
    if (frames == 0) {
      _noClip(burst, 'no_frames', '${r['error'] ?? 'no camera frame arrived'}', file);
      return;
    }
    final durationMs = (r['durationMs'] as num?)?.round() ?? 0;
    final size = (r['bytes'] as num?)?.toInt() ?? 0;
    final firstEpoch = (r['firstEpochMs'] as num?)?.round();
    clips++;
    bytes += size;
    double r2(num? v) => ((v ?? 0) * 100).round() / 100;
    logger()?.logVideoClip({
      'file': file,
      // The camera's time of the first frame; the clock at opening only when
      // the camera gave none.
      'start_epoch_ms': firstEpoch ?? _startedMs,
      'start_time_source': firstEpoch != null ? 'camera' : 'clock',
      'duration_ms': durationMs,
      'size_bytes': size,
      'width': _side,
      'height': _side,
      'rotation': 0,
      'codec': 'video/avc',
      'frame_count': frames,
      'fps_mean': durationMs > 0 ? r2(frames * 1000 / durationMs) : null,
      'fps_nominal': fps,
      'frames_skipped': (r['skipped'] as num?)?.toInt() ?? 0,
      _indexKey: burst,
      'end_reason': r['reason'] ?? reason,
      'first_pts_us': r['firstPtsUs'],
      'bitrate': r['bitrate'],
      'encoder': r['encoder'],
      'crop_ms_mean': r['cropMsMean'] == null ? null : r2(r['cropMsMean'] as num),
      'draw_ms_mean': r['drawMsMean'] == null ? null : r2(r['drawMsMean'] as num),
      if (r['flushed'] == false) 'flushed': false,
      'error': ?r['error'],
    });
  }
}

/// Totals of a session's clips from its log (round 239): the `video_clip`
/// records, and the bursts with a `video_skipped` record and no clip.
class VideoClipTotals {
  final int count;
  final int bytes;
  final int durationMs;
  final int skippedBursts;
  const VideoClipTotals(this.count, this.bytes, this.durationMs, [this.skippedBursts = 0]);

  static const none = VideoClipTotals(0, 0, 0);

  /// "3 clips · 25.7 s filmed · 3.3 MB".
  String get label {
    final s = durationMs / 1000;
    final filmed = s < 60
        ? '${s.toStringAsFixed(1)} s'
        : s < 3600
        ? '${s ~/ 60} min ${(s % 60).floor()} s'
        : '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
    return '$count clip${count == 1 ? '' : 's'} · $filmed filmed · ${formatBytes(bytes)}';
  }

  static Future<VideoClipTotals> read(Directory sessionDir) async {
    final log = File('${sessionDir.path}/session.jsonl');
    if (!log.existsSync()) return none;
    var count = 0, bytes = 0, ms = 0;
    final clipBursts = <int>{};
    final skipped = <int>{};
    final lines = log.openRead().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.contains('"video_clip"') && !line.contains('"video_skipped"')) continue;
      try {
        final rec = jsonDecode(line) as Map<String, dynamic>;
        final burst = ((rec['burst'] ?? rec['segment']) as num?)?.toInt();
        if (rec['type'] == 'video_clip') {
          count++;
          bytes += (rec['size_bytes'] as num?)?.toInt() ?? 0;
          ms += (rec['duration_ms'] as num?)?.toInt() ?? 0;
          if (burst != null) clipBursts.add(burst);
        } else if (rec['type'] == 'video_skipped' && burst != null) {
          skipped.add(burst);
        }
      } catch (_) {}
    }
    return VideoClipTotals(count, bytes, ms, skipped.difference(clipBursts).length);
  }
}
