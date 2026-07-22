// Tests for SAHI-style tiled inference (round 139): tile-grid planning, the
// duplicate-merge NMS, tile→photo coordinate mapping and the end-to-end
// predict wrapper on a tiny synthetic image (no native channel involved).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:fauna_pulse/fauna_pulse/postprocess/post_detector.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/sahi.dart';

void main() {
  group('planTiles', () {
    test('1024 px photo with 640 px tiles at 25% overlap → 2×2, flush edges',
        () {
      final tiles = planTiles(1024, 1024, 640, 0.25);
      expect(tiles, hasLength(4));
      final lefts = tiles.map((t) => t.left).toSet().toList()..sort();
      expect(lefts, [0, 384]); // last tile flush: 384 + 640 = 1024
      expect(tiles.every((t) => t.width == 640 && t.height == 640), isTrue);
    });

    test('1024 px photo with 320 px tiles → 4×4 (the owner\'s example)', () {
      final tiles = planTiles(1024, 1024, 320, 0.25);
      final cols = tiles.map((t) => t.left).toSet().length;
      final rows = tiles.map((t) => t.top).toSet().length;
      expect((cols, rows), (4, 4));
      final lefts = tiles.map((t) => t.left).toSet().toList()..sort();
      expect(lefts.last + 320, 1024); // flush with the far edge
    });

    test('photo smaller than the tile → single no-op tile', () {
      final tiles = planTiles(500, 500, 640, 0.25);
      expect(tiles, hasLength(1));
      expect((tiles.single.width, tiles.single.height), (500, 500));
    });

    test('non-square photos tile per axis', () {
      final tiles = planTiles(1280, 640, 640, 0.25);
      final cols = tiles.map((t) => t.left).toSet().length;
      final rows = tiles.map((t) => t.top).toSet().length;
      expect((cols, rows), (3, 1));
    });
  });

  group('mergePostBoxes', () {
    PostBox box(String cls, double conf, double l, double t) => PostBox(
      className: cls,
      confidence: conf,
      left: l,
      top: t,
      right: l + 0.2,
      bottom: t + 0.2,
    );

    test('same-class near-duplicates merge, highest confidence wins', () {
      final merged = mergePostBoxes(
        [box('bee', 0.7, 0.10, 0.10), box('bee', 0.9, 0.11, 0.10)],
        0.5,
      );
      expect(merged, hasLength(1));
      expect(merged.single.confidence, 0.9);
    });

    test('different classes never merge', () {
      final merged = mergePostBoxes(
        [box('bee', 0.9, 0.10, 0.10), box('fly', 0.8, 0.10, 0.10)],
        0.5,
      );
      expect(merged, hasLength(2));
    });

    test('distant same-class boxes both survive', () {
      final merged = mergePostBoxes(
        [box('bee', 0.9, 0.1, 0.1), box('bee', 0.8, 0.7, 0.7)],
        0.5,
      );
      expect(merged, hasLength(2));
    });
  });

  group('sahiPredictFn', () {
    // A tiny real JPEG so the tile worker's decode/crop/encode runs for real.
    late Uint8List photo64;

    setUpAll(() {
      final im = img.Image(width: 64, height: 64);
      img.fill(im, color: img.ColorRgb8(40, 120, 40));
      photo64 = Uint8List.fromList(img.encodeJpg(im, quality: 90));
    });

    Map<String, dynamic> detectionAt(double l, double t, double r, double b) => {
      'detections': [
        {
          'className': 'bee',
          'confidence': 0.9,
          'normalizedBox': {'left': l, 'top': t, 'right': r, 'bottom': b},
        },
      ],
    };

    test('runs one pass per tile + the full pass, merges the result',
        () async {
      var calls = 0;
      final predict = sahiPredictFn(
        base: (bytes) async {
          calls++;
          return const {'detections': []};
        },
        options: const SahiOptions(enabled: true, overlapFrac: 0.25),
        modelInputPx: 32, // 64 px photo, 32 px tiles → 3×3 grid + full pass
      );
      final result = await predict(photo64);
      expect(calls, 10);
      expect(result['detections'], isEmpty);
    });

    test('tile detections map into whole-photo coordinates', () async {
      // Only the LAST tile (bottom-right, flush at 32..64) "detects", with a
      // box covering that whole tile → expect ~[0.5, 0.5, 1.0, 1.0] in photo
      // coordinates.
      var call = 0;
      final predict = sahiPredictFn(
        base: (bytes) async {
          call++;
          return call == 9 ? detectionAt(0, 0, 1, 1) : const {'detections': []};
        },
        options: const SahiOptions(
          enabled: true,
          overlapFrac: 0.25,
          fullImagePass: false,
        ),
        modelInputPx: 32,
      );
      final boxes = boxesFromPredictResult(await predict(photo64));
      expect(boxes, hasLength(1));
      expect(boxes.single.left, closeTo(0.5, 0.01));
      expect(boxes.single.top, closeTo(0.5, 0.01));
      expect(boxes.single.right, closeTo(1.0, 0.01));
      expect(boxes.single.bottom, closeTo(1.0, 0.01));
    });

    test('photo smaller than a tile falls back to a single full pass even '
        'with the full pass switched off', () async {
      var calls = 0;
      final predict = sahiPredictFn(
        base: (bytes) async {
          calls++;
          return detectionAt(0.1, 0.1, 0.3, 0.3);
        },
        options: const SahiOptions(
          enabled: true,
          fullImagePass: false,
        ),
        modelInputPx: 128, // tile bigger than the 64 px photo
      );
      final boxes = boxesFromPredictResult(await predict(photo64));
      expect(calls, 1);
      expect(boxes, hasLength(1));
    });

    test('duplicates from overlapping tiles merge to one insect', () async {
      // ONE insect at photo pixels 24..40 (photo-normalized 0.375..0.625).
      // Every 48 px tile of the 64 px photo contains it fully, so every pass
      // reports it — in that pass's OWN coordinates. After mapping back they
      // coincide exactly and must merge to a single box.
      // Tile order is deterministic (rows outer, columns inner, full last):
      const offsets = [(0, 0), (16, 0), (0, 16), (16, 16)];
      var call = 0;
      final predict = sahiPredictFn(
        base: (bytes) async {
          final i = call++;
          if (i < offsets.length) {
            final (l, t) = offsets[i];
            return detectionAt(
              (24 - l) / 48,
              (24 - t) / 48,
              (40 - l) / 48,
              (40 - t) / 48,
            );
          }
          return detectionAt(0.375, 0.375, 0.625, 0.625); // full pass
        },
        options: const SahiOptions(enabled: true, fullImagePass: true),
        modelInputPx: 48, // 64 px photo → 2×2 tiles + full pass
      );
      final boxes = boxesFromPredictResult(await predict(photo64));
      expect(call, 5);
      expect(boxes, hasLength(1));
      expect(boxes.single.left, closeTo(0.375, 0.01));
      expect(boxes.single.bottom, closeTo(0.625, 0.01));
    });
  });
}
