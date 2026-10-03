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
//
// Round 279 (owner, after a test user asked for pictures rather than text):
// SetupPicture, a drawing of how to set up the phone for an answer (the side
// view, and what the phone screen shows with the yellow square), found by the
// same `icon`: assets/images/setup_<icon>.png. The drawings were made for
// FaunaPulse as simple SVG sketches (the sources stay outside the repository,
// with other versions); an answer without a drawing shows its round icon.
// Round 280 (owner): the animals on the phone screen of the drawings are found,
// with a thin box in the camera's live box colour, and the bee is the
// FaunaPulse bee of the app icon; assets/images/roi_<icon>.png is that phone
// screen alone, for the home screen's step 2.
// Round 286 (owner: the answer in use should show at a glance): its circle
// gets a thicker ring and a tick, and its words are bold.

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

  /// A ring and a tick in the picture's colour (the answer in use).
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
    final circle = Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: selected ? 0.28 : 0.16),
        border: selected ? Border.all(color: color, width: 2.5) : null,
      ),
      child: picture,
    );
    if (!selected) return circle;
    final badge = s * 0.38;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(
            right: -badge * 0.15,
            top: -badge * 0.15,
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                // A rim in the page colour sets the tick apart from the ring.
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              ),
              child: Icon(Icons.check, size: badge * 0.62, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

/// The phone screen of the drawing of [icon] alone (home screen, step 2).
String roiPicture(String icon) => 'assets/images/roi_$icon.png';

/// What [roiPicture] shows, for screen readers.
String roiDescription(String icon) => switch (icon) {
  'flat_surface' => 'The phone screen: a ladybird and a bee on a platform, each in a detection box, inside the '
      'yellow square.',
  'mammals_birds' => 'The phone screen: a bird on a feeder, in a detection box, inside the yellow square.',
  _ => 'The phone screen: a bee on a flower, in a detection box, inside the yellow square.',
};

/// What the drawing of [icon] shows, for screen readers.
String? _setupDescription(String icon) => switch (icon) {
  'pollinators' => 'A phone on a tripod, 15 to 20 cm above a flower. On its screen, a bee on the flower is '
      'found (a box around it) inside the yellow square.',
  'flat_surface' => 'A phone on a tripod, looking straight down at a flat platform with insects on it. On its '
      'screen, each insect is found (a box around it) inside the yellow square.',
  'mammals_birds' => 'A phone fixed to a tree, facing a bird feeder. On its screen, the bird is found (a box '
      'around it) inside a large yellow square.',
  _ => null,
};

/// The drawing of how to set up the phone for the answer [icon]; its round
/// icon when there is no drawing.
class SetupPicture extends StatelessWidget {
  final String icon;

  const SetupPicture({super.key, required this.icon});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: AspectRatio(
        aspectRatio: 420 / 220,
        child: Image.asset(
          'assets/images/setup_$icon.png',
          fit: BoxFit.contain,
          semanticLabel: _setupDescription(icon),
          errorBuilder: (context, error, stack) => Center(child: WatchIcon(icon: icon, size: 72)),
        ),
      ),
    ),
  );
}

/// A [WatchIcon] with its words under it, to tap.
class WatchTile extends StatelessWidget {
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const WatchTile({super.key, required this.icon, required this.label, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: InkWell(
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
              style: TextStyle(fontSize: 11.5, height: 1.2, fontWeight: selected ? FontWeight.bold : null),
            ),
          ],
        ),
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
