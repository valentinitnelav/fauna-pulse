// Tests for the crop geometry and pixel worker (round 208, plan 11.2).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:fauna_pulse/fauna_pulse/identification/crop_worker.dart';

void main() {
  group('planCrop square', () {
    test('square on the longer side with margin, centred, inside the photo', () {
      final p = planCrop(imgW: 1000, imgH: 1000, left: 0.4, top: 0.4, right: 0.6, bottom: 0.5, margin: 0.15, square: true);
      expect(p.cropPx, 200);
      expect(p.w, 260); // 200 × 1.3
      expect(p.h, 260);
      expect(p.sx, 370); // centre 500 − 130
      expect(p.sy, 320); // centre 450 − 130
      expect(p.padFrac, 0);
      expect(p.needsPadding, isFalse);
      expect(p.iw, 260);
    });

    test('a box at the edge is padded, not shifted', () {
      final p = planCrop(imgW: 1000, imgH: 1000, left: 0.0, top: 0.0, right: 0.2, bottom: 0.2, margin: 0.15, square: true);
      expect(p.w, 260);
      expect(p.sx, -30);
      expect(p.ix, 0);
      expect(p.iw, 230);
      expect(p.padFrac, closeTo(1 - (230 * 230) / (260 * 260), 1e-9));
      expect(p.needsPadding, isTrue);
    });

    test('zero margin reproduces the plain longer-side square', () {
      final p = planCrop(imgW: 640, imgH: 480, left: 0.5, top: 0.5, right: 0.6, bottom: 0.7, margin: 0, square: true);
      expect(p.cropPx, 96);
      expect(p.w, 96);
      expect(p.h, 96);
    });
  });

  group('planCrop box-shaped (round 262)', () {
    test('zero margin is exactly the detector box', () {
      final p = planCrop(imgW: 1000, imgH: 1000, left: 0.4, top: 0.4, right: 0.6, bottom: 0.5, margin: 0, square: false);
      expect(p.cropPx, 200);
      expect((p.sx, p.sy, p.w, p.h), (400, 400, 200, 100));
      expect(p.padFrac, 0);
    });

    test('the margin is a share of the longer side, added on every side', () {
      final p = planCrop(imgW: 1000, imgH: 1000, left: 0.4, top: 0.4, right: 0.6, bottom: 0.5, margin: 0.1, square: false);
      expect((p.w, p.h), (240, 140)); // 200 + 2 × 20, 100 + 2 × 20
      expect((p.sx, p.sy), (380, 380));
    });

    test('a box at the edge is padded, not shifted', () {
      final p = planCrop(imgW: 1000, imgH: 1000, left: 0.0, top: 0.0, right: 0.2, bottom: 0.1, margin: 0.1, square: false);
      expect((p.sx, p.sy, p.w, p.h), (-20, -20, 240, 140));
      expect((p.ix, p.iy, p.iw, p.ih), (0, 0, 220, 120));
      expect(p.padFrac, closeTo(1 - (220 * 120) / (240 * 140), 1e-9));
    });
  });

  test('laplacianVariance is higher for an edge than for a flat patch', () {
    const w = 16, h = 16;
    final flat = Uint8List(w * h * 3);
    for (var i = 0; i < flat.length; i++) {
      flat[i] = 100;
    }
    final edge = Uint8List(w * h * 3);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = x < w ~/ 2 ? 20 : 220;
        final j = (y * w + x) * 3;
        edge[j] = v;
        edge[j + 1] = v;
        edge[j + 2] = v;
      }
    }
    expect(laplacianVariance(flat, w, h), 0);
    expect(laplacianVariance(edge, w, h), greaterThan(100));
  });

  test('cropBatchSync produces model-size RGB, skips tiny boxes, pads at edges', () {
    // 200×100 photo: left half red, right half blue.
    final photo = img.Image(width: 200, height: 100, numChannels: 3);
    for (final p in photo) {
      if (p.x < 100) {
        p.r = 255;
        p.g = 0;
        p.b = 0;
      } else {
        p.r = 0;
        p.g = 0;
        p.b = 255;
      }
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(photo, quality: 95));
    final results = cropBatchSync(
      CropBatchArgs(
        jpegBytes: jpeg,
        requests: const [
          CropRequest('red', 0.1, 0.2, 0.3, 0.6), // 40×40 inside the red half
          CropRequest('tiny', 0.5, 0.5, 0.52, 0.52), // 4 px
          CropRequest('corner', 0.9, 0.0, 1.0, 0.2), // touches the right/top edge
        ],
        margin: 0.1,
        minCropPx: 16,
        outSize: 32,
      ),
    );
    expect(results.length, 3);
    final red = results[0];
    expect(red.skipped, isNull);
    expect(red.rgb!.length, 32 * 32 * 3);
    expect(red.cropPx, 40);
    // Centre pixel of the resized crop is red.
    final c = (16 * 32 + 16) * 3;
    expect(red.rgb![c], greaterThan(200));
    expect(red.rgb![c + 2], lessThan(60));
    expect(results[1].skipped, 'too_small');
    final corner = results[2];
    expect(corner.skipped, isNull);
    expect(corner.padFrac, greaterThan(0));
    // Top-right of the padded crop is the CLIP mean colour.
    final tr = (0 * 32 + 31) * 3;
    expect((corner.rgb![tr] - kPadR).abs(), lessThan(12));
  });

  test('cropBatchSync box-shaped: a thin box at the top edge needs no padding (round 262)', () {
    // 200×100 photo: left half red, right half blue; box 100×20 px at the top,
    // across the colour boundary.
    final photo = img.Image(width: 200, height: 100, numChannels: 3);
    for (final p in photo) {
      p.r = p.x < 100 ? 255 : 0;
      p.g = 0;
      p.b = p.x < 100 ? 0 : 255;
    }
    final jpeg = Uint8List.fromList(img.encodeJpg(photo, quality: 95));
    List<CropResult> cut(bool square) => cropBatchSync(
      CropBatchArgs(
        jpegBytes: jpeg,
        requests: const [CropRequest('thin', 0.25, 0.0, 0.75, 0.2)],
        margin: 0,
        square: square,
        minCropPx: 16,
        outSize: 32,
      ),
    );
    final box = cut(false).single;
    expect(box.rgb!.length, 32 * 32 * 3);
    expect(box.cropPx, 100);
    expect(box.padFrac, 0);
    // Stretched to the square: the top-left pixel is red, the top-right blue.
    expect(box.rgb![0], greaterThan(200));
    expect(box.rgb![31 * 3 + 2], greaterThan(200));
    // The square version of the same box reaches above the photo.
    final square = cut(true).single;
    expect(square.padFrac, closeTo(0.4, 1e-9)); // 100×100 centred on y 10: 40 rows padded
    expect((square.rgb![0] - kPadR).abs(), lessThan(12));
  });
}
