// FaunaPulse — maps camera-frame coordinates onto the on-screen preview.
//
// Why this exists: the native camera preview (CameraX) uses "FIT_CENTER" — it
// scales the camera frame *uniformly* (same factor in X and Y) so the WHOLE frame
// fits inside the preview area, adding thin empty "letterbox" bars on the two
// sides that don't fill. "Contain" (as opposed to "stretch") keeps the image from
// looking squashed, and — unlike "cover"/crop — keeps every pixel of the sensor
// frame visible, so the region of interest can be grown to the full sensor
// resolution and still stay inside what the user sees.
//
// Our own drawings (the ROI square and the track-id boxes) come in "normalized"
// units: 0..1 across the camera frame's width and height. If we naively
// multiplied those by the on-screen width and height, we would be *stretching*
// the frame to the screen's shape — so a square in the frame would look
// rectangular on a tall phone screen. This class instead reproduces the exact
// cover transform the camera uses, so a square in the frame draws as a true
// square on screen and our boxes line up with what the camera shows.
//
// Terms used once:
//   * frameAspect = frame width / frame height (e.g. 0.75 for a 3:4 portrait
//     frame). The shape of the image the detector sees.
//   * "displayed size" = how big the (uniformly scaled) frame is on screen,
//     including the part that overflows off the edges.

import 'dart:ui';

class PreviewTransform {
  /// On-screen size of the preview area (usually the whole screen).
  final Size widget;

  /// Camera frame aspect ratio (width / height).
  final double frameAspect;

  /// Width/height of the uniformly scaled frame as drawn on screen (the cover
  /// fit), and the (possibly negative) offset that centres it. A negative
  /// offset means that edge of the frame is cropped off-screen — exactly what
  /// FILL_CENTER does.
  late final double displayedWidth;
  late final double displayedHeight;
  late final double _offsetX;
  late final double _offsetY;

  PreviewTransform({required this.widget, required this.frameAspect}) {
    final widgetAspect = widget.width / widget.height;
    if (widgetAspect <= frameAspect) {
      // The screen is narrower (relative to its height) than the frame, so to
      // fit the whole frame we match the width and leave empty bars top/bottom.
      displayedWidth = widget.width;
      displayedHeight = widget.width / frameAspect;
    } else {
      // The screen is wider than the frame, so we match the height and leave
      // empty bars on the left and right.
      displayedHeight = widget.height;
      displayedWidth = widget.height * frameAspect;
    }
    // With "contain" both offsets are >= 0 (the bars), so the whole frame sits
    // inside the preview rather than being cropped off the edges.
    _offsetX = (widget.width - displayedWidth) / 2;
    _offsetY = (widget.height - displayedHeight) / 2;
  }

  /// A normalized point (0..1 of the frame) to an on-screen offset in pixels.
  Offset pointToScreen(double nx, double ny) =>
      Offset(_offsetX + nx * displayedWidth, _offsetY + ny * displayedHeight);

  /// The part of the frame that is actually visible on screen, in normalized
  /// (0..1 of the frame) coordinates. Under the "contain" fit the whole frame is
  /// visible, so this is the full 0..1 rectangle; it is kept as a method (rather
  /// than assumed) so the ROI clamping stays correct if the fit ever changes.
  Rect visibleNormalizedRect() {
    double nx(double sx) => (sx - _offsetX) / displayedWidth;
    double ny(double sy) => (sy - _offsetY) / displayedHeight;
    return Rect.fromLTRB(
      nx(0).clamp(0.0, 1.0),
      ny(0).clamp(0.0, 1.0),
      nx(widget.width).clamp(0.0, 1.0),
      ny(widget.height).clamp(0.0, 1.0),
    );
  }

  /// A normalized rectangle (0..1 of the frame) to its on-screen pixel rect.
  /// Because the scale is uniform, a square frame rect maps to a square screen
  /// rect (its centre may sit partly off-screen if the frame is cropped).
  Rect rectToScreen(Rect normalized) => Rect.fromLTRB(
    _offsetX + normalized.left * displayedWidth,
    _offsetY + normalized.top * displayedHeight,
    _offsetX + normalized.right * displayedWidth,
    _offsetY + normalized.bottom * displayedHeight,
  );
}
