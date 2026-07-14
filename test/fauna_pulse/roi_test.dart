// Tests for the ROI geometry helpers.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';

void main() {
  const aspect = 4 / 3; // a 4:3 frame, e.g. 1280x960

  test('normalizedRect keeps the square square in pixels', () {
    const roi = Roi(centerX: 0.5, centerY: 0.5, sideFraction: 0.6);
    final r = roi.normalizedRect(aspect);
    // halfW = 0.3; halfH = 0.3 * (4/3) = 0.4.
    expect(r.left, closeTo(0.2, 1e-9));
    expect(r.right, closeTo(0.8, 1e-9));
    expect(r.top, closeTo(0.1, 1e-9));
    expect(r.bottom, closeTo(0.9, 1e-9));

    // Width in px == height in px (a true square) for a 1280x960 frame.
    final px = roi.pixelRect(1280, 960);
    expect(px.width, closeTo(px.height, 1e-6));
    expect(roi.pixelSide(1280), closeTo(768, 1e-6));
  });

  test('containsBoxCenter filters by box centre', () {
    const roi = Roi(centerX: 0.5, centerY: 0.5, sideFraction: 0.6);
    // Centre (0.5,0.5) is inside.
    expect(
      roi.containsBoxCenter(const Rect.fromLTWH(0.45, 0.45, 0.1, 0.1), aspect),
      isTrue,
    );
    // A box near the top-left corner, centre outside the ROI.
    expect(
      roi.containsBoxCenter(const Rect.fromLTWH(0.0, 0.0, 0.05, 0.05), aspect),
      isFalse,
    );
  });

  test('copyClamped keeps the square fully inside the frame', () {
    const roi = Roi(centerX: 0.5, centerY: 0.5, sideFraction: 0.6);
    final moved = roi.copyClamped(centerX: 5.0, centerY: -5.0, frameAspect: aspect);
    final r = moved.normalizedRect(aspect);
    expect(r.left, greaterThanOrEqualTo(-1e-9));
    expect(r.top, greaterThanOrEqualTo(-1e-9));
    expect(r.right, lessThanOrEqualTo(1 + 1e-9));
    expect(r.bottom, lessThanOrEqualTo(1 + 1e-9));
  });

  test('snapSideToGrid lands the side on the saved-crop ÷32 grid', () {
    // A maxed box on a 720x960 portrait stream: the width (720) is the short
    // side, so the readout/crop cap is 704 (largest multiple of 32 that fits
    // 720). The box must shrink from the full 720 width to that 704 to match.
    const sourceWidth = 720;
    const maxSidePx = 704; // (720 ~/ 32) * 32
    const portraitAspect = 720 / 960; // imageWidth / imageHeight = 0.75
    const roi = Roi(centerX: 0.5, centerY: 0.5, sideFraction: 1.0);
    final snapped = roi.snapSideToGrid(
      sourceWidth: sourceWidth,
      maxSidePx: maxSidePx,
      frameAspect: portraitAspect,
    );
    // The snapped side, back in pixels, is exactly the saved 704.
    expect(snapped.sideFraction * sourceWidth, closeTo(704, 1e-6));

    // Idempotent: snapping an already-on-grid box does not move it.
    final again = snapped.snapSideToGrid(
      sourceWidth: sourceWidth,
      maxSidePx: maxSidePx,
      frameAspect: portraitAspect,
    );
    expect(again.sideFraction, closeTo(snapped.sideFraction, 1e-9));

    // Unknown source size (0) leaves the box untouched.
    final untouched = roi.snapSideToGrid(
      sourceWidth: 0,
      maxSidePx: maxSidePx,
      frameAspect: portraitAspect,
    );
    expect(untouched.sideFraction, roi.sideFraction);
  });

  test('toLogJson reports equal pixel width/height and normalized centre', () {
    const roi = Roi(centerX: 0.4, centerY: 0.6, sideFraction: 0.5);
    final j = roi.toLogJson(1280, 960);
    expect(j['width_px'], j['height_px']);
    expect(j['center_x_norm'], 0.4);
    expect(j['center_y_norm'], 0.6);
  });
}
