// FaunaPulse (round 278): the round pictures of "What do you want to watch?"
// on the home screen (owner choice: the app's own icons in softly coloured
// circles, which look the same on every phone, rather than emoji):
//   • pollinators on flowers: a bee with a flower, amber;
//   • insects on a flat surface: a bug standing on a line, light green;
//   • mammals and birds: a paw with a flying bird (two curved wings, drawn
//     here: the only bird among Flutter's icons is its mascot, which reads as
//     a face at this size), brown;
//   • other models: a plus, grey.
// Which picture an answer gets is its `icon` in assets/model_downloads.json.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The `icon` of the "Other models" tile (not in the list file).
const kOtherModelsIcon = 'other';

Color watchColor(String icon) => switch (icon) {
  'pollinators' => Colors.amber,
  'flat_surface' => Colors.lightGreen,
  'mammals_birds' => Colors.brown.shade300,
  _ => Colors.white60,
};

/// A tinted circle with the picture of [icon].
class WatchIcon extends StatelessWidget {
  final String icon;
  final double size;

  /// A ring in the picture's colour (the last answer chosen).
  final bool selected;

  const WatchIcon({super.key, required this.icon, this.size = 52, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final color = watchColor(icon);
    final s = size;
    final Widget picture = switch (icon) {
      'pollinators' => Icon(Icons.emoji_nature, size: s * 0.56, color: color),
      'flat_surface' => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.pest_control, size: s * 0.44, color: color),
          Container(
            width: s * 0.56,
            height: 2.5,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
        ],
      ),
      'mammals_birds' => SizedBox(
        width: s * 0.7,
        height: s * 0.62,
        child: Stack(
          children: [
            Positioned(left: 0, bottom: 0, child: Icon(Icons.pets, size: s * 0.44, color: color)),
            Positioned(
              right: 0,
              top: s * 0.04,
              child: CustomPaint(size: Size(s * 0.32, s * 0.16), painter: _BirdPainter(color)),
            ),
          ],
        ),
      ),
      _ => Icon(Icons.add, size: s * 0.5, color: color),
    };
    return Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.16),
        border: selected ? Border.all(color: color, width: 2) : null,
      ),
      child: picture,
    );
  }
}

/// A [WatchIcon] with its words under it, to tap.
class WatchTile extends StatelessWidget {
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const WatchTile({super.key, required this.icon, required this.label, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          WatchIcon(icon: icon, selected: selected),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, height: 1.2),
          ),
        ],
      ),
    ),
  );
}

/// A flying bird seen from afar: two curved wings meeting in the middle.
class _BirdPainter extends CustomPainter {
  final Color color;

  const _BirdPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final wings = Path()
      ..moveTo(0, h * 0.45)
      ..quadraticBezierTo(w * 0.25, -h * 0.15, w * 0.5, h * 0.75)
      ..quadraticBezierTo(w * 0.75, -h * 0.15, w, h * 0.45);
    canvas.drawPath(
      wings,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.6, w * 0.11)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_BirdPainter old) => old.color != color;
}
