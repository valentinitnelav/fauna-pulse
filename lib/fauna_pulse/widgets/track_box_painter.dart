// Pollinator Monitor — draws our own bounding boxes labelled with the track id.
//
// The plugin can draw native overlays, but those show class names only. We hide
// the native overlay (controller.setShowOverlays(false)) and paint here instead
// so each box is labelled with its stable track id (e.g. "#7 bee") — letting the
// user see when detection AND tracking are working.

import 'package:flutter/material.dart';

import '../models/track.dart';
import 'preview_transform.dart';

class TrackBoxPainter extends CustomPainter {
  /// Confirmed tracks to draw (normalized boxes, 0..1 of the frame).
  final List<Track> tracks;

  /// Camera frame aspect ratio (width / height), so boxes map through the same
  /// "cover" fit the preview uses and line up with the live image.
  final double frameAspect;

  const TrackBoxPainter(this.tracks, {required this.frameAspect});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = const Color(0xFF00E5FF);

    final transform = PreviewTransform(widget: size, frameAspect: frameAspect);

    for (final t in tracks) {
      // Map the normalized box through the same cover fit as the preview so the
      // box sits exactly over the insect in the live image.
      final rect = transform.rectToScreen(t.box);
      canvas.drawRect(rect, boxPaint);

      // Show the stable track id, the class, and the detector's confidence for
      // this box (0..1, two decimals). The confidence is already on the Track
      // (it comes straight from the model output), so this adds no extra work.
      final label =
          '#${t.id} ${t.className}  Conf.: ${t.confidence.toStringAsFixed(2)}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelBg = Rect.fromLTWH(
        rect.left,
        (rect.top - tp.height - 4).clamp(0.0, size.height),
        tp.width + 8,
        tp.height + 4,
      );
      canvas.drawRect(labelBg, Paint()..color = const Color(0xCC0091A7));
      tp.paint(canvas, Offset(labelBg.left + 4, labelBg.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant TrackBoxPainter old) =>
      old.tracks != tracks || old.frameAspect != frameAspect;
}
