// FaunaPulse (round 225): Dart side of offline video analysis.
//
// Reads clip facts ([VideoFrameSource.info]) and walks one clip at a time
// through the native decoder + a loaded detector: open, then next() until
// done, then close. One clip is open at a time and every call is awaited by
// the caller, so the native single-thread executor never sees overlapping
// work. Only boxes cross the channel, never pictures. See VideoFrameSource.kt.

import 'package:flutter/services.dart';

import '../config/channel_config.dart';

/// Facts about one video file, read without decoding it.
class VideoInfo {
  final int? durationMs;

  /// Clockwise degrees the picture must turn to stand upright (0/90/180/270).
  final int rotation;

  /// Upright size in pixels (as the user sees the video).
  final int width;
  final int height;
  final String? mime;
  final int frameCount;

  /// Time stamp of the first frame; clip time is measured from it (files
  /// don't always start at 0).
  final int? firstPtsUs;

  /// Mean frames per second from the real time stamps; [nominalFps] is what
  /// the file header claims (often absent or rounded).
  final double? meanFps;
  final int? nominalFps;

  /// Time stored in the file (UTC epoch ms); null when the file carries
  /// none. Android phones store when recording STOPPED (round 226 check on
  /// a Xiaomi clip), so the start is this minus [durationMs]. Messengers
  /// such as WhatsApp drop it; editors reset it to the export time.
  final int? creationEpochMs;

  /// Why the file can't be analysed (e.g. 10-bit/HDR), in plain language.
  final String? unsupportedReason;

  const VideoInfo({
    this.durationMs,
    this.rotation = 0,
    this.width = 0,
    this.height = 0,
    this.mime,
    this.frameCount = 0,
    this.firstPtsUs,
    this.meanFps,
    this.nominalFps,
    this.creationEpochMs,
    this.unsupportedReason,
  });

  factory VideoInfo.fromMap(Map r) => VideoInfo(
    durationMs: (r['durationMs'] as num?)?.toInt(),
    rotation: (r['rotation'] as num?)?.toInt() ?? 0,
    width: (r['width'] as num?)?.toInt() ?? 0,
    height: (r['height'] as num?)?.toInt() ?? 0,
    mime: r['mime'] as String?,
    frameCount: (r['frameCount'] as num?)?.toInt() ?? 0,
    firstPtsUs: (r['firstPtsUs'] as num?)?.toInt(),
    meanFps: (r['meanFps'] as num?)?.toDouble(),
    nominalFps: (r['nominalFps'] as num?)?.toInt(),
    creationEpochMs: (r['creationEpochMs'] as num?)?.toInt(),
    unsupportedReason: r['unsupportedReason'] as String?,
  );
}

/// One analysed frame: its time stamp, its 0-based position in display
/// order, and boxes as `[left, top, right, bottom, confidence, classIndex]`
/// normalized 0..1 to the whole upright frame.
class VideoFrameBoxes {
  final int ptsUs;
  final int frame;
  final List<List<num>> boxes;
  const VideoFrameBoxes(this.ptsUs, this.frame, this.boxes);
}

/// What one [VideoFrameSource.next] call returned.
class VideoChunk {
  final List<VideoFrameBoxes> frames;

  /// True once the clip's last frame was decoded.
  final bool done;

  /// Frames decoded in this call (analysed or skipped by the frame-rate cap).
  final int decoded;
  final int frameWidth;
  final int frameHeight;

  /// Analysed area in upright frame pixels `[x, y, width, height]`.
  final List<int>? roiPx;

  /// Class names of the model; only in the first chunk after open.
  final List<String>? names;
  final double decodeMs;
  final double convertMs;
  final double inferMs;

  const VideoChunk({
    required this.frames,
    required this.done,
    this.decoded = 0,
    this.frameWidth = 0,
    this.frameHeight = 0,
    this.roiPx,
    this.names,
    this.decodeMs = 0,
    this.convertMs = 0,
    this.inferMs = 0,
  });

  factory VideoChunk.fromMap(Map r) => VideoChunk(
    frames: [
      for (final f in (r['frames'] as List? ?? const []))
        VideoFrameBoxes(
          (f['pts'] as num).toInt(),
          (f['frame'] as num).toInt(),
          [for (final b in (f['boxes'] as List)) (b as List).cast<num>()],
        ),
    ],
    done: r['done'] as bool? ?? true,
    decoded: (r['decoded'] as num?)?.toInt() ?? 0,
    frameWidth: (r['frameWidth'] as num?)?.toInt() ?? 0,
    frameHeight: (r['frameHeight'] as num?)?.toInt() ?? 0,
    roiPx: (r['roi'] as List?)?.map((v) => (v as num).toInt()).toList(),
    names: (r['names'] as List?)?.cast<String>(),
    decodeMs: (r['decodeMs'] as num?)?.toDouble() ?? 0,
    convertMs: (r['convertMs'] as num?)?.toDouble() ?? 0,
    inferMs: (r['inferMs'] as num?)?.toDouble() ?? 0,
  );
}

class VideoFrameSource {
  static final MethodChannel _channel = ChannelConfig.createSingleImageChannel();

  /// Reads [path]'s facts (duration, size, rotation, frame count, date).
  static Future<VideoInfo> info(String path) async {
    final r = await _channel.invokeMethod<Map>('videoInfo', {'path': path});
    if (r == null) throw StateError('videoInfo returned nothing');
    return VideoInfo.fromMap(r);
  }

  /// The first frame as an upright JPEG, at most [maxSide] px on its long
  /// side (for drawing the analysis square on).
  static Future<Uint8List> thumbnail(String path, {int maxSide = 720}) async {
    final r = await _channel.invokeMethod<Uint8List>('videoThumbnail', {'path': path, 'maxSide': maxSide});
    if (r == null) throw StateError('videoThumbnail returned nothing');
    return r;
  }

  /// Opens [path] for analysis with the detector loaded as [instanceId]
  /// (`YOLO.instanceId`), closing any clip opened before.
  ///
  /// [roi] = (cx, cy, side) fractions of the upright frame, as in live
  /// sessions, or null for the whole frame. Analysis starts at [startPtsUs]
  /// and takes one frame per [minIntervalUs] (0 = every frame). [maxSidePx]
  /// caps the analysed picture; larger areas are averaged down.
  static Future<void> open(
    String path, {
    required String instanceId,
    required double confidence,
    required double iou,
    List<double>? roi,
    int startPtsUs = 0,
    int minIntervalUs = 0,
    int maxSidePx = 1280,
  }) => _channel.invokeMethod<void>('videoOpen', {
    'path': path,
    'instanceId': instanceId,
    'confidence': confidence,
    'iou': iou,
    'roi': roi,
    'startPtsUs': startPtsUs,
    'minIntervalUs': minIntervalUs,
    'maxSidePx': maxSidePx,
  });

  /// Analyses up to [maxFrames] frames, returning early after [budgetMs]
  /// (so progress and cancel stay responsive on slow phones).
  static Future<VideoChunk> next({int maxFrames = 8, int budgetMs = 1000}) async {
    final r = await _channel.invokeMethod<Map>('videoNext', {
      'maxFrames': maxFrames,
      'budgetMs': budgetMs,
    });
    if (r == null) throw StateError('videoNext returned nothing');
    return VideoChunk.fromMap(r);
  }

  /// Releases the decoder. Safe to call when nothing is open.
  static Future<void> close() => _channel.invokeMethod<void>('videoClose');
}
