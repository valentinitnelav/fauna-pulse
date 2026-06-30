// Pollinator Monitor — Region Of Interest (ROI) model.
//
// "ROI" (region of interest) = the square box the user drags over the flower.
// We only keep insect detections whose centre falls inside this box, so that
// background movement outside the flower is ignored.
//
// Why this is a little subtle: the camera frame is NOT square (e.g. 1280x960,
// a 4:3 rectangle), but the box must be square *in real pixels* because the
// detector's input is square. So we store the box in a resolution-independent
// way and reconstruct the exact pixels only when we know the frame size.
//
// We store:
//   * centerX, centerY  — the box centre as a fraction (0..1) of the frame
//                         width/height. Resolution-independent.
//   * sideFraction      — the square's side length as a fraction (0..1) of the
//                         frame WIDTH. The side in real pixels is therefore
//                         sideFraction * imageWidth, and that same pixel length
//                         is used for the height (keeping it square).
//
// Because the height fraction must be derived from the width-based side, every
// conversion below needs the frame's aspect ratio (width / height).

import 'dart:math' as math;
import 'dart:ui';

/// Rounds a pixel length to the nearest multiple of 32 (never below 32). Most
/// detectors (YOLO, RF-DETR, etc.) require input width/height divisible by 32,
/// so the saved ROI crops — and the resolution shown to the user — are snapped
/// to that grid to stay directly usable downstream.
int snapToMultipleOf32(double pixels) {
  final steps = (pixels / 32).round();
  return (steps < 1 ? 1 : steps) * 32;
}

/// An immutable square region of interest, defined in frame-relative units.
class Roi {
  /// Box centre X as a fraction of frame width (0..1).
  final double centerX;

  /// Box centre Y as a fraction of frame height (0..1).
  final double centerY;

  /// Square side length as a fraction of frame width (0..1).
  final double sideFraction;

  const Roi({
    required this.centerX,
    required this.centerY,
    required this.sideFraction,
  });

  /// A sensible default: a centred square covering 45% of the frame width.
  /// Kept under half-width so that, once the camera frame is shown with the
  /// preview's "cover" crop (which makes the frame wider than the screen), the
  /// box and its bottom-right resize handle stay comfortably on screen.
  static const Roi defaultRoi = Roi(
    centerX: 0.5,
    centerY: 0.5,
    sideFraction: 0.45,
  );

  /// Half of the square's vertical extent, expressed in normalized (0..1)
  /// frame-height units. [frameAspect] is imageWidth / imageHeight.
  ///
  /// Derivation: pixel side = sideFraction * imageWidth, so half the side in
  /// pixels is sideFraction * imageWidth / 2; dividing by imageHeight to
  /// normalize gives (sideFraction / 2) * (imageWidth / imageHeight).
  double _halfHeightNorm(double frameAspect) =>
      (sideFraction / 2) * frameAspect;

  double get _halfWidthNorm => sideFraction / 2;

  /// The ROI as a normalized rectangle (all edges in 0..1 of the frame), given
  /// the frame aspect ratio. Useful for hit-testing against normalized
  /// detection boxes and for cropping a captured image of any resolution.
  Rect normalizedRect(double frameAspect) {
    final hh = _halfHeightNorm(frameAspect);
    return Rect.fromLTRB(
      centerX - _halfWidthNorm,
      centerY - hh,
      centerX + _halfWidthNorm,
      centerY + hh,
    );
  }

  /// The ROI as an exact pixel rectangle within a frame of the given size.
  Rect pixelRect(int imageWidth, int imageHeight) {
    final frameAspect = imageWidth / imageHeight;
    final r = normalizedRect(frameAspect);
    return Rect.fromLTRB(
      r.left * imageWidth,
      r.top * imageHeight,
      r.right * imageWidth,
      r.bottom * imageHeight,
    );
  }

  /// Square side length in real pixels for a frame of [imageWidth] pixels wide.
  double pixelSide(int imageWidth) => sideFraction * imageWidth;

  /// Whether a normalized point (px, py in 0..1 of the frame) lies inside the
  /// ROI. [frameAspect] is imageWidth / imageHeight.
  bool containsNormalizedPoint(double px, double py, double frameAspect) {
    return normalizedRect(frameAspect).contains(Offset(px, py));
  }

  /// Whether the centre of a normalized detection box lies inside the ROI.
  bool containsBoxCenter(Rect normalizedBox, double frameAspect) {
    return containsNormalizedPoint(
      normalizedBox.center.dx,
      normalizedBox.center.dy,
      frameAspect,
    );
  }

  /// Returns a copy with the given fields changed, clamped so the square always
  /// stays fully inside the frame. [frameAspect] is needed because the vertical
  /// extent depends on it.
  Roi copyClamped({
    double? centerX,
    double? centerY,
    double? sideFraction,
    required double frameAspect,
  }) {
    var side = (sideFraction ?? this.sideFraction).clamp(0.05, 1.0).toDouble();
    // The square cannot be taller than the frame: its pixel side cannot exceed
    // imageHeight. In width-fraction units that ceiling is 1 / frameAspect.
    final maxSideByHeight = 1.0 / frameAspect;
    side = math.min(side, maxSideByHeight).toDouble();

    final halfW = side / 2;
    final halfH = (side / 2) * frameAspect;
    final cx = (centerX ?? this.centerX).clamp(halfW, 1.0 - halfW).toDouble();
    final cy = (centerY ?? this.centerY).clamp(halfH, 1.0 - halfH).toDouble();
    return Roi(centerX: cx, centerY: cy, sideFraction: side);
  }

  /// Returns a copy clamped so the whole square stays inside [visible] (a
  /// normalized rectangle of the frame that is actually on screen). The side is
  /// shrunk first if it cannot fit, then the centre is pulled inside. This stops
  /// the user dragging or growing the ROI off the visible preview.
  Roi clampToVisible(Rect visible, double frameAspect) {
    var side = sideFraction;
    // Height of the square in normalized frame-height units is side*frameAspect.
    final maxSideByWidth = visible.width;
    final maxSideByHeight = visible.height / frameAspect;
    side = math.min(side, math.min(maxSideByWidth, maxSideByHeight));
    side = side.clamp(0.05, 1.0).toDouble();

    final halfW = side / 2;
    final halfH = (side / 2) * frameAspect;
    final cx = centerX
        .clamp(visible.left + halfW, visible.right - halfW)
        .toDouble();
    final cy = centerY
        .clamp(visible.top + halfH, visible.bottom - halfH)
        .toDouble();
    return Roi(centerX: cx, centerY: cy, sideFraction: side);
  }

  /// Returns a copy whose side is snapped to the exact pixel square that will be
  /// SAVED to disk — the nearest multiple of 32 that fits, never exceeding
  /// [maxSidePx] (the crop source's short-side cap, already a multiple of 32).
  ///
  /// Why: the saved crop and the on-screen resolution readout always snap the
  /// side to a multiple of 32 (model-friendly), but the draggable box itself was
  /// continuous, so a maxed box could visually span e.g. 720 px while only 704 px
  /// were saved. Snapping the geometry too makes the box the user sees equal the
  /// saved crop pixel-for-pixel ("what you see is what you save").
  ///
  /// [sourceWidth] is the width (in pixels) the crop is taken from — the live
  /// analysis frame, or the full-resolution still in full-res mode. Snapping only
  /// ever shrinks the side, so the centre stays valid; it is re-clamped here for
  /// safety. Returns [this] unchanged if [sourceWidth] is not yet known (<= 0) or
  /// the snap would not change the side.
  Roi snapSideToGrid({
    required int sourceWidth,
    required int maxSidePx,
    required double frameAspect,
  }) {
    if (sourceWidth <= 0 || maxSidePx <= 0) return this;
    // Pixel side the readout/crop would use, then back to a width fraction.
    final snappedPx = snapToMultipleOf32(
      sideFraction * sourceWidth,
    ).clamp(32, maxSidePx);
    final snappedFraction = snappedPx / sourceWidth;
    // copyClamped re-clamps the centre so the (possibly smaller) square stays
    // fully inside the frame.
    return copyClamped(
      sideFraction: snappedFraction,
      frameAspect: frameAspect,
    );
  }

  /// Log representation per CLAUDE.md: pixel width/height plus the normalized
  /// centre relative to the full sensor frame.
  Map<String, dynamic> toLogJson(int imageWidth, int imageHeight) {
    final side = pixelSide(imageWidth);
    return {
      'center_x_norm': centerX,
      'center_y_norm': centerY,
      'width_px': side.round(),
      'height_px': side.round(),
      'frame_width_px': imageWidth,
      'frame_height_px': imageHeight,
    };
  }

  Map<String, dynamic> toJson() => {
    'centerX': centerX,
    'centerY': centerY,
    'sideFraction': sideFraction,
  };

  factory Roi.fromJson(Map<String, dynamic> json) => Roi(
    centerX: (json['centerX'] as num).toDouble(),
    centerY: (json['centerY'] as num).toDouble(),
    sideFraction: (json['sideFraction'] as num).toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      other is Roi &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      other.sideFraction == sideFraction;

  @override
  int get hashCode => Object.hash(centerX, centerY, sideFraction);
}
