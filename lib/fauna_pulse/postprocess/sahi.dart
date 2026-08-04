// FaunaPulse — SAHI-style tiled inference for post-hoc analysis (round 139).
//
// "SAHI" (Slicing Aided Hyper Inference) is a standard trick for finding
// SMALL objects: instead of shrinking the whole photo down to the model's
// input size (letterboxing — a 1024 px photo fed to a 640 px model loses
// ~40% of its linear resolution), the photo is cut into overlapping tiles of
// roughly the model's own input size, the detector runs once per tile at
// near-native pixel scale, and the per-tile detections are mapped back into
// whole-photo coordinates and de-duplicated. An optional extra pass over the
// whole (letterboxed) photo catches insects LARGER than one tile.
//
// It plugs into the batch driver as a [PredictFn] wrapper ([sahiPredictFn]),
// so post_detector.dart, the keep/cleanup logic and the review UI all work
// unchanged — they just see more (merged) boxes per photo. The goal here is
// flagging photos that contain a pollinator (triage recall), not tighter
// boxes.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../logging/app_error_hooks.dart';
import 'post_detector.dart';
import 'sahi_profile.dart';

/// User-facing tiling parameters. All exposed in the analysis screen's
/// advanced section; stored in shared_preferences (`analysis_sahi_*`).
class SahiOptions {
  final bool enabled;

  /// Tile side in pixels; 0 = auto → the selected model's own input size
  /// (tiles at native model scale — the standard choice).
  final int tileSidePx;

  /// Fraction of a tile shared with its neighbour (0..0.5). Overlap ensures
  /// an insect sitting on a tile border appears whole in the adjacent tile.
  final double overlapFrac;

  /// Also run the plain whole-photo pass — catches insects larger than a
  /// tile, at the cost of one extra inference.
  final bool fullImagePass;

  /// Overlap level at which two same-class boxes from different passes count
  /// as the same insect and merge into one. Since round 141 the overlap is
  /// measured as IoS — intersection over the SMALLER box's area — not IoU:
  /// a partial insect detected at a tile border sits inside the full-insect
  /// box with high IoS but low IoU, so IoU-NMS kept both (the "many small
  /// boxes" artifact) while IoS merges them. Same criterion as obss/sahi.
  final double mergeIou;

  /// Drop TILE detections whose box is NARROWER than this fraction of the
  /// photo side in either dimension (0 = off). Trims the two tiling
  /// artifacts: background specks (tiny both ways) and border slivers —
  /// partial insects cut by a tile edge are thin in one direction but can
  /// be long in the other, so the narrower side is the right test (round
  /// 143; the short-lived r141 rule required BOTH sides small and let
  /// slivers through). Applied to tile-derived boxes only, never to the
  /// whole-photo pass — so the filter can only trim tiling's additions,
  /// never fall below the plain run.
  final double minBoxFrac;

  const SahiOptions({
    this.enabled = false,
    this.tileSidePx = 0,
    this.overlapFrac = 0.25,
    this.fullImagePass = true,
    this.mergeIou = 0.5,
    this.minBoxFrac = 0,
  });

  int effectiveTileSide(int modelInputPx) =>
      tileSidePx > 0 ? tileSidePx : modelInputPx;

  /// Echoed into the run's `post_start` record so results stay interpretable.
  /// `merge_metric` marks round-141+ runs (IoS); records without it are
  /// r139–140 runs that merged by plain IoU.
  Map<String, dynamic> toJson(int modelInputPx) => {
    'tile_px': effectiveTileSide(modelInputPx),
    'overlap': overlapFrac,
    'full_pass': fullImagePass,
    'merge_iou': mergeIou,
    'merge_metric': 'ios',
    'min_box_frac': minBoxFrac,
  };
}

/// One tile's pixel rectangle inside the source photo.
class TileRect {
  final int left, top, width, height;
  const TileRect(this.left, this.top, this.width, this.height);
}

/// Tile offsets along one axis: evenly spaced, first at 0, last flush with
/// the far edge, stride ≤ `tile·(1−overlap)`. A single offset means the axis
/// fits in one tile.
List<int> _axisOffsets(int size, int tile, double overlapFrac) {
  if (tile >= size) return const [0];
  final stride = tile * (1 - overlapFrac);
  final n = max(1, ((size - tile) / stride).ceil() + 1);
  if (n == 1) return const [0];
  final step = (size - tile) / (n - 1);
  return [for (var i = 0; i < n; i++) (i * step).round()];
}

/// The tile grid for a `w`×`h` photo. ONE tile (the whole photo) means
/// tiling is a no-op for this photo — the caller should run only the plain
/// pass.
List<TileRect> planTiles(int w, int h, int tileSide, double overlapFrac) {
  final tw = min(tileSide, w), th = min(tileSide, h);
  return [
    for (final top in _axisOffsets(h, th, overlapFrac))
      for (final left in _axisOffsets(w, tw, overlapFrac))
        TileRect(left, top, tw, th),
  ];
}

double _intersection(PostBox a, PostBox b) {
  final il = max(a.left, b.left), it = max(a.top, b.top);
  final ir = min(a.right, b.right), ib = min(a.bottom, b.bottom);
  return max(0.0, ir - il) * max(0.0, ib - it);
}

double _area(PostBox a) => (a.right - a.left) * (a.bottom - a.top);

/// Intersection-over-union of two normalized boxes.
double boxIou(PostBox a, PostBox b) {
  final inter = _intersection(a, b);
  if (inter <= 0) return 0;
  return inter / (_area(a) + _area(b) - inter);
}

/// Intersection over the SMALLER box's area ("IoS"). A small box fully
/// inside a big one scores ~1.0 here but only area-ratio IoU, which is why
/// IoS is the right duplicate test for tiled inference (obss/sahi's default
/// too): the partial insect a tile sees at its border must merge into the
/// full-insect box from the neighbouring tile or the whole-photo pass.
double boxIos(PostBox a, PostBox b) {
  final inter = _intersection(a, b);
  if (inter <= 0) return 0;
  return inter / min(_area(a), _area(b));
}

/// Greedy same-class NMS: the highest-confidence box wins; any same-class
/// box overlapping a winner by ≥ [overlapThresh] is a duplicate (the same
/// insect seen from two overlapping passes) and is dropped. Overlap is IoS
/// since round 141 (was IoU in r139–140) — see [boxIos] for why.
List<PostBox> mergePostBoxes(List<PostBox> boxes, double overlapThresh) {
  final sorted = [...boxes]
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <PostBox>[];
  for (final b in sorted) {
    final duplicate = kept.any(
      (k) => k.className == b.className && boxIos(k, b) >= overlapThresh,
    );
    if (!duplicate) kept.add(b);
  }
  return kept;
}

/// compute() worker: decode the JPEG, cut the tile grid, re-encode each tile.
/// Runs in a background isolate — pure-Dart decode of a 1024 px JPEG takes
/// ~0.1 s and would jank the progress UI on the main isolate.
/// Returns null when the bytes don't decode; empty tile lists when the photo
/// fits in one tile (tiling is a no-op). The two trailing ints are this
/// worker's decode / crop+encode wall time in MICROseconds (round 168, perf
/// review E6 step 1) — timed in here because the isolate boundary hides them
/// from the caller, which sees only the compute() total.
(int, int, List<(int, int, int, int)>, List<Uint8List>, int, int)? tileWorker(
  (Uint8List, int, double) job,
) {
  final (bytes, tileSide, overlapFrac) = job;
  final sw = Stopwatch()..start();
  final decoded = img.decodeImage(bytes);
  final decodeUs = sw.elapsedMicroseconds;
  if (decoded == null) return null;
  final tiles = planTiles(decoded.width, decoded.height, tileSide, overlapFrac);
  if (tiles.length <= 1) {
    return (decoded.width, decoded.height, const [], const [], decodeUs, 0);
  }
  sw
    ..reset()
    ..start();
  final rects = <(int, int, int, int)>[];
  final jpegs = <Uint8List>[];
  for (final t in tiles) {
    final crop = img.copyCrop(
      decoded,
      x: t.left,
      y: t.top,
      width: t.width,
      height: t.height,
    );
    rects.add((t.left, t.top, t.width, t.height));
    jpegs.add(Uint8List.fromList(img.encodeJpg(crop, quality: 90)));
  }
  return (decoded.width, decoded.height, rects, jpegs, decodeUs,
      sw.elapsedMicroseconds);
}

/// One-call NATIVE tiled predictor (round 177, perf review E6): given the
/// source JPEG, the Dart-planned tile rectangles (`[left, top, width,
/// height]` px each) and whether to also run the whole photo, returns the
/// plugin's `YOLO.predictTiled` map: `imageWidth`/`imageHeight` (decoded
/// dims, echoed for verification), `tiles` (one 'detections'-shaped list per
/// rectangle, normalized to the TILE) and optionally `fullPass`.
typedef TiledPredictFn =
    Future<Map<String, dynamic>> Function(
      Uint8List bytes,
      List<List<int>> tiles,
      bool fullPass,
    );

/// Width/height read from the JPEG HEADER only — no pixel decode
/// (microseconds instead of the ~100 ms a full 1024 px decode costs). The
/// native tiled path needs the dimensions BEFORE the photo crosses the
/// channel, to plan the tile grid in Dart. Null for non-JPEG/corrupt bytes
/// (the caller then takes the pure-Dart path, whose full decode decides).
(int, int)? jpegDimensions(Uint8List bytes) {
  try {
    final info = img.JpegDecoder().startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (info.width, info.height);
  } catch (_) {
    return null;
  }
}

/// Tile-normalized box → whole-photo-normalized coordinates (shared by the
/// pure-Dart and the native tiled paths, so the mapping can never drift).
PostBox _tileBoxToPhoto(
  PostBox b,
  int tl,
  int tt,
  int tw,
  int th,
  int imgW,
  int imgH,
) => PostBox(
  className: b.className,
  confidence: b.confidence,
  left: (tl + b.left * tw) / imgW,
  top: (tt + b.top * th) / imgH,
  right: (tl + b.right * tw) / imgW,
  bottom: (tt + b.bottom * th) / imgH,
);

/// The r141/r143 speck/sliver filter: drops a TILE-derived box whose narrower
/// side is under the configured fraction of the photo side. Never applied to
/// whole-photo-pass boxes.
bool _underMinBox(PostBox mapped, SahiOptions options) =>
    options.minBoxFrac > 0 &&
    min(mapped.right - mapped.left, mapped.bottom - mapped.top) <
        options.minBoxFrac;

/// The `YOLO.predict`-shaped result map the batch driver parses.
Map<String, dynamic> _detectionsResult(List<PostBox> merged) => {
  'detections': [
    for (final b in merged)
      {
        'className': b.className,
        'confidence': b.confidence,
        'normalizedBox': {
          'left': b.left,
          'top': b.top,
          'right': b.right,
          'bottom': b.bottom,
        },
      },
  ],
};

/// One photo through the native tiled path (round 177). Returns the standard
/// result map, or null when this photo should take the plain path instead
/// (unreadable JPEG header, or a grid of one tile — tiling is a no-op).
/// Throws when the native reply is unusable; the caller then falls back to
/// the pure-Dart pipeline, which is the always-correct baseline.
Future<Map<String, dynamic>?> _nativeTiledPhoto(
  Uint8List bytes,
  TiledPredictFn tiledPredict,
  SahiOptions options,
  int tileSide,
  SahiPhaseProfile? profile,
) async {
  final probe = Stopwatch()..start();
  final dims = jpegDimensions(bytes);
  if (dims == null) return null;
  final (imgW, imgH) = dims;
  final tiles = planTiles(imgW, imgH, tileSide, options.overlapFrac);
  if (tiles.length <= 1) return null;
  final probeUs = probe.elapsedMicroseconds;

  final rects = [
    for (final t in tiles) [t.left, t.top, t.width, t.height],
  ];
  final call = Stopwatch()..start();
  final reply = await tiledPredict(bytes, rects, options.fullImagePass);
  call.stop();
  final gotW = (reply['imageWidth'] as num?)?.toInt() ?? 0;
  final gotH = (reply['imageHeight'] as num?)?.toInt() ?? 0;
  if (gotW != imgW || gotH != imgH) {
    // The native decode disagrees with the header probe: the planned grid
    // does not match what was cropped — boxes would mis-map, so fall back.
    throw StateError(
      'tiled dims mismatch: planned ${imgW}x$imgH, decoded ${gotW}x$gotH',
    );
  }
  final tileLists = reply['tiles'];
  if (tileLists is! List || tileLists.length != rects.length) {
    throw StateError(
      'tiled reply carries '
      '${tileLists is List ? tileLists.length : 'no'} tile lists '
      'for ${rects.length} rects',
    );
  }

  // Success is certain from here — the profile is written in ONE place so a
  // throw above can never leave this photo half-counted before the Dart
  // fallback counts it in full.
  if (profile != null) {
    profile.photos++;
    profile.tiledPhotos++;
    profile.nativeTiledPhotos++;
    profile.tiles += rects.length;
    if (options.fullImagePass) profile.fullPasses++;
    profile.sourceDecodeUs += probeUs;
    // One lump: the native decode, all tile crops and every inference.
    profile.tilePredictUs += call.elapsedMicroseconds;
  }

  final all = <PostBox>[];
  for (var i = 0; i < rects.length; i++) {
    final r = rects[i];
    for (final b in boxesFromPredictResult({'detections': tileLists[i]})) {
      final mapped = _tileBoxToPhoto(b, r[0], r[1], r[2], r[3], imgW, imgH);
      if (_underMinBox(mapped, options)) continue;
      all.add(mapped);
    }
  }
  if (options.fullImagePass) {
    all.addAll(
      boxesFromPredictResult({'detections': reply['fullPass'] ?? const []}),
    );
  }
  final mergeSw = Stopwatch()..start();
  final merged = mergePostBoxes(all, options.mergeIou);
  if (profile != null) profile.mergeUs += mergeSw.elapsedMicroseconds;
  return _detectionsResult(merged);
}

/// Wraps a plain single-image [base] predictor into a tiled one, returning
/// the same result-map shape `YOLO.predict` produces (a 'detections' list
/// with `className`/`confidence`/`normalizedBox`), so the batch driver's
/// parsing works unchanged.
///
/// When [tiledPredict] is given (round 177, perf review E6) each photo goes
/// through the native one-call tiled path — the measured 83-86% pure-Dart
/// tiling overhead disappears. The first native failure disables that path
/// for the rest of the run (reliability first, like the r163 camera-parking
/// fallback) and the pure-Dart pipeline below takes over seamlessly.
///
/// When [profile] is given (round 168, perf review E6 step 1) every phase's
/// wall time is accumulated into it — behaviour is identical either way, the
/// stopwatches just answer where a SAHI run's time actually goes.
PredictFn sahiPredictFn({
  required PredictFn base,
  required SahiOptions options,
  required int modelInputPx,
  TiledPredictFn? tiledPredict,
  SahiPhaseProfile? profile,
}) {
  final tileSide = options.effectiveTileSide(modelInputPx);
  var nativeBroken = false;
  return (Uint8List bytes) async {
    if (tiledPredict != null && !nativeBroken) {
      try {
        final native = await _nativeTiledPhoto(
          bytes,
          tiledPredict,
          options,
          tileSide,
          profile,
        );
        if (native != null) return native;
        // null = plain single pass is the right treatment for this photo;
        // the code below handles it (its tile grid will be empty too).
      } catch (e) {
        nativeBroken = true;
        if (profile != null) profile.nativeFallbacks++;
        logSwallowed('sahi_native_tiled', e);
      }
    }
    final sw = Stopwatch()..start();
    final tiled = await compute(tileWorker, (
      bytes,
      tileSide,
      options.overlapFrac,
    ));
    if (profile != null) {
      // The worker reports its in-isolate decode/prep time; what remains of
      // the compute() total is isolate startup + the byte copies both ways.
      profile.photos++;
      final decodeUs = tiled?.$5 ?? 0;
      final prepUs = tiled?.$6 ?? 0;
      profile.sourceDecodeUs += decodeUs;
      profile.tilePrepUs += prepUs;
      profile.tileTransferUs += max(
        0,
        sw.elapsedMicroseconds - decodeUs - prepUs,
      );
    }
    final all = <PostBox>[];
    var ranTiles = false;
    if (tiled != null && tiled.$3.isNotEmpty) {
      ranTiles = true;
      if (profile != null) profile.tiledPhotos++;
      final (imgW, imgH, rects, jpegs, _, _) = tiled;
      for (var i = 0; i < rects.length; i++) {
        final (tl, tt, tw, th) = rects[i];
        sw
          ..reset()
          ..start();
        final tileResult = await base(jpegs[i]);
        if (profile != null) {
          profile.tiles++;
          profile.tilePredictUs += sw.elapsedMicroseconds;
        }
        for (final b in boxesFromPredictResult(tileResult)) {
          final mapped = _tileBoxToPhoto(b, tl, tt, tw, th, imgW, imgH);
          // Optional speck/sliver filter — tile boxes only (see SahiOptions).
          if (_underMinBox(mapped, options)) continue;
          all.add(mapped);
        }
      }
    }
    // The whole-photo pass: always when tiling was a no-op (or the decode
    // failed — the native side may still decode what the Dart codec can't),
    // otherwise only when enabled.
    if (!ranTiles || options.fullImagePass) {
      sw
        ..reset()
        ..start();
      final fullResult = await base(bytes);
      if (profile != null) {
        profile.fullPasses++;
        profile.fullPredictUs += sw.elapsedMicroseconds;
      }
      all.addAll(boxesFromPredictResult(fullResult));
    }
    sw
      ..reset()
      ..start();
    final merged = mergePostBoxes(all, options.mergeIou);
    if (profile != null) profile.mergeUs += sw.elapsedMicroseconds;
    return _detectionsResult(merged);
  };
}
