// Tests for the crop-and-export helpers (round 91): the drag→rectangle
// geometry (including the 1:1 lock and edge clamping) and the pure JPEG
// sub-rectangle crop the summary photo viewer exports through.

import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pollinator_monitor/pollinator/capture/crop_export.dart';

void main() {
  group('sceneRectForDrag', () {
    test('free aspect follows the drag, whichever way it goes', () {
      final r = sceneRectForDrag(
        const Offset(10, 20),
        const Offset(110, 60),
        320,
        square: false,
      );
      expect(r, const Rect.fromLTRB(10, 20, 110, 60));
      // Dragging up-left gives the same rectangle as down-right.
      final rev = sceneRectForDrag(
        const Offset(110, 60),
        const Offset(10, 20),
        320,
        square: false,
      );
      expect(rev, r);
    });

    test('points outside the photo are clamped to its edges', () {
      final r = sceneRectForDrag(
        const Offset(-30, 10),
        const Offset(400, 500),
        320,
        square: false,
      );
      expect(r, const Rect.fromLTRB(0, 10, 320, 320));
    });

    test('1:1 lock: side is the larger drag extent, anchored at the start', () {
      final r = sceneRectForDrag(
        const Offset(50, 50),
        const Offset(150, 90), // dx 100, dy 40 → side 100
        320,
        square: true,
      );
      expect(r, const Rect.fromLTRB(50, 50, 150, 150));
      expect(r.width, r.height);
    });

    test('1:1 lock follows the drag direction (up-left too)', () {
      final r = sceneRectForDrag(
        const Offset(200, 200),
        const Offset(120, 190), // dx -80, dy -10 → side 80 up-left
        320,
        square: true,
      );
      expect(r, const Rect.fromLTRB(120, 120, 200, 200));
    });

    test('1:1 lock near an edge SHRINKS the square instead of leaving it', () {
      // Start 60 px from the right edge, drag 200 px right and 200 down:
      // only 60 px of room → a 60 px square, still 1:1.
      final r = sceneRectForDrag(
        const Offset(260, 50),
        const Offset(460, 250),
        320,
        square: true,
      );
      expect(r.width, r.height);
      expect(r, const Rect.fromLTRB(260, 50, 320, 110));
    });
  });

  group('moveSceneRect', () {
    const box = Rect.fromLTRB(100, 100, 200, 200);

    test('shifts the rectangle by the drag delta', () {
      final r = moveSceneRect(box, const Offset(30, -20), 320);
      expect(r, const Rect.fromLTRB(130, 80, 230, 180));
    });

    test('clamps at the photo edges instead of leaving it', () {
      // 500 px right / 500 up on a 320 photo: stops flush at the edges.
      final r = moveSceneRect(box, const Offset(500, -500), 320);
      expect(r, const Rect.fromLTRB(220, 0, 320, 100));
    });

    test('never changes the size — an enforced 1:1 stays 1:1', () {
      for (final d in const [Offset(500, 0), Offset(-500, 123), Offset(7, 9)]) {
        final r = moveSceneRect(box, d, 320);
        expect(r.width, box.width);
        expect(r.height, box.height);
      }
    });

    test('a non-square rectangle keeps its aspect too', () {
      const wide = Rect.fromLTRB(10, 10, 210, 60); // 200 × 50
      final r = moveSceneRect(wide, const Offset(1000, 1000), 320);
      expect(r.width, 200);
      expect(r.height, 50);
      expect(r.right, 320);
      expect(r.bottom, 320);
    });
  });

  test('normalizedRect divides by the viewer side', () {
    final n = normalizedRect(const Rect.fromLTRB(80, 160, 240, 320), 320);
    expect(n, const Rect.fromLTRB(0.25, 0.5, 0.75, 1.0));
  });

  group('cropExportName', () {
    test('keeps the source stem and appends _crop_HHMMSS.jpg', () {
      final name = cropExportName(
        'roi_abc_170001.jpg',
        now: DateTime(2026, 7, 12, 9, 5, 3),
      );
      expect(name, 'roi_abc_170001_crop_090503.jpg');
    });
    test('copes with a name without extension', () {
      final name = cropExportName('photo', now: DateTime(2026, 1, 1, 1, 2, 3));
      expect(name, 'photo_crop_010203.jpg');
    });
  });

  group('cropJpegRectSync', () {
    // A 100×80 test JPEG: left half red, right half blue, so the crop's
    // content (not just its size) can be checked.
    Uint8List makeJpeg() {
      final im = img.Image(width: 100, height: 80);
      img.fill(im, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(
        im,
        x1: 50,
        y1: 0,
        x2: 99,
        y2: 79,
        color: img.ColorRgb8(0, 0, 255),
      );
      return Uint8List.fromList(img.encodeJpg(im, quality: 95));
    }

    test('cuts the requested sub-rectangle at the right pixel size', () {
      final out = cropJpegRectSync(
        makeJpeg(),
        const Rect.fromLTRB(0.5, 0.25, 1.0, 0.75),
      );
      expect(out, isNotNull);
      expect(out!.width, 50);
      expect(out.height, 40);
      final decoded = img.decodeImage(out.jpeg)!;
      expect(decoded.width, 50);
      expect(decoded.height, 40);
      // The right half of the source is blue.
      final p = decoded.getPixel(25, 20);
      expect(p.b, greaterThan(200));
      expect(p.r, lessThan(60));
    });

    test('clamps a rectangle that reaches past the photo', () {
      final out = cropJpegRectSync(
        makeJpeg(),
        const Rect.fromLTRB(-0.5, -0.5, 1.5, 1.5),
      );
      expect(out, isNotNull);
      expect(out!.width, 100);
      expect(out.height, 80);
    });

    test('rejects a crop smaller than $kMinCropSidePx px on a side', () {
      final out = cropJpegRectSync(
        makeJpeg(),
        const Rect.fromLTRB(0.0, 0.0, 0.05, 0.5), // 5 px wide
      );
      expect(out, isNull);
    });

    test('rejects bytes that are not an image', () {
      final out = cropJpegRectSync(
        Uint8List.fromList([1, 2, 3, 4]),
        const Rect.fromLTRB(0, 0, 1, 1),
      );
      expect(out, isNull);
    });
  });
}
