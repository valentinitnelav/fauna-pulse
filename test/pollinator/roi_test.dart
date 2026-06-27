// Tests for the ROI geometry helpers.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/models/roi.dart';

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

  test('toLogJson reports equal pixel width/height and normalized centre', () {
    const roi = Roi(centerX: 0.4, centerY: 0.6, sideFraction: 0.5);
    final j = roi.toLogJson(1280, 960);
    expect(j['width_px'], j['height_px']);
    expect(j['center_x_norm'], 0.4);
    expect(j['center_y_norm'], 0.6);
  });
}
