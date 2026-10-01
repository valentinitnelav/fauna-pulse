// FaunaPulse (round 273): the speed choices of every video player in the app,
// the session's Video tab and the square editor of "Find animals in videos".
//
// 5× and 10× were added for a quick look over a whole video, e.g. to see
// whether the camera or the flower moves before placing the analysed square.
// The player may skip pictures at these speeds (the phone cannot show them
// all); they are for an overview, not for following one insect.
import 'package:flutter/material.dart';

/// "Speed: 0.5× 1× 2× 4× 5× 10×" as choice chips.
class VideoSpeedChips extends StatelessWidget {
  static const speeds = [0.5, 1.0, 2.0, 4.0, 5.0, 10.0];

  final double speed;
  final ValueChanged<double> onChanged;

  const VideoSpeedChips({super.key, required this.speed, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Speed:', style: TextStyle(color: Colors.white70, fontSize: 12)),
        for (final s in speeds)
          ChoiceChip(
            label: Text('${s == s.roundToDouble() ? s.round() : s}×'),
            selected: speed == s,
            onSelected: (_) => onChanged(s),
          ),
      ],
    );
  }
}
