// Pollinator Monitor — dims everything outside the ROI on the preview.
//
// The model only looks inside the ROI, so we darken the rest of the frame to
// make that unmistakable (and to keep the user's eye on the target flower). It
// is purely a visual overlay drawn on top of the camera preview — it does not
// change the camera feed or save any battery on the sensor itself.

import 'package:flutter/material.dart';

import '../models/roi.dart';
import 'preview_transform.dart';

class RoiMask extends StatelessWidget {
  final Roi roi;
  final double frameAspect;

  /// How dark the outside-ROI area is (0 = clear, 1 = solid black).
  final double opacity;

  const RoiMask({
    super.key,
    required this.roi,
    required this.frameAspect,
    this.opacity = 0.55,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RoiMaskPainter(roi, frameAspect, opacity),
      ),
    );
  }
}

class _RoiMaskPainter extends CustomPainter {
  final Roi roi;
  final double frameAspect;
  final double opacity;

  _RoiMaskPainter(this.roi, this.frameAspect, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final transform = PreviewTransform(widget: size, frameAspect: frameAspect);
    final roiRect = transform.rectToScreen(roi.normalizedRect(frameAspect));

    // Fill the whole screen, then punch out the ROI rectangle using the
    // even-odd rule so only the area OUTSIDE the ROI is darkened.
    final outside = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(roiRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: opacity),
    );

    // A thin outline on the ROI edge for definition.
    canvas.drawRect(
      roiRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white24,
    );
  }

  @override
  bool shouldRepaint(covariant _RoiMaskPainter old) =>
      old.roi != roi ||
      old.frameAspect != frameAspect ||
      old.opacity != opacity;
}
