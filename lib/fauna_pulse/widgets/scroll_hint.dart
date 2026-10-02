// FaunaPulse (round 278, owner): a quiet scroll bar that shows a page goes on
// below (the home screen did not make that clear). Always visible while the
// page is longer than the screen: a faint line along the right edge (the
// path) and a grey bar on it that moves with the page, at most a third of the
// height long (owner: "not too long"; Flutter's own Scrollbar makes the bar
// as long as the visible part, which on a page a bit longer than the screen
// is most of it). Only a hint: touches go to the page.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Where the bar sits on a path [trackHeight] long: its top and length, or
/// null when the whole page is visible.
({double top, double length})? scrollHintBar({
  required double trackHeight,
  required double viewport,
  required double maxScroll,
  required double pixels,
}) {
  if (maxScroll <= 0 || trackHeight <= 0) return null;
  final length = math.min(math.max(trackHeight * viewport / (viewport + maxScroll), 48.0), trackHeight / 3);
  final f = (pixels / maxScroll).clamp(0.0, 1.0);
  return (top: f * (trackHeight - length), length: length);
}

/// Puts the hint over the right edge of [child], which scrolls with
/// [controller].
class ScrollHint extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  const ScrollHint({super.key, required this.controller, required this.child});

  @override
  State<ScrollHint> createState() => _ScrollHintState();
}

class _ScrollHintState extends State<ScrollHint> {
  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    // A page that grows or shrinks without scrolling (sessions counted,
    // the screen turned) redraws the hint too.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        setState(() {});
        return false;
      },
      child: Stack(
        children: [
          widget.child,
          Positioned(
            right: 3,
            top: 8,
            bottom: 8,
            width: 6,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _HintPainter(
                  widget.controller,
                  track: onSurface.withValues(alpha: 0.12),
                  bar: onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintPainter extends CustomPainter {
  final ScrollController controller;
  final Color track;
  final Color bar;

  _HintPainter(this.controller, {required this.track, required this.bar}) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.hasClients) return;
    final p = controller.position;
    if (!p.hasContentDimensions) return;
    final b = scrollHintBar(
      trackHeight: size.height,
      viewport: p.viewportDimension,
      maxScroll: p.maxScrollExtent - p.minScrollExtent,
      pixels: p.pixels - p.minScrollExtent,
    );
    if (b == null) return;
    final x = size.width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x - 1, 0, 2, size.height), const Radius.circular(1)),
      Paint()..color = track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x - 2, b.top, 4, b.length), const Radius.circular(2)),
      Paint()..color = bar,
    );
  }

  @override
  bool shouldRepaint(_HintPainter old) => true;
}
