// FaunaPulse (round 289, owner): every window (dialog) closes the same way.
// At the bottom right, "Cancel" when the window asks to confirm something,
// which then does not happen, or "Close" when it only informs or offers
// something extra (a few name what they keep instead, where "Cancel" could be
// read the wrong way: "Keep running", "Stay"). At the top right of the
// title, an X that does what that button does, so a long window can be
// closed without scrolling to its end. Where the buttons do not fit side by
// side, each window stacks them with the main action on top and Cancel or
// Close at the bottom (actionsOverflowDirection: VerticalDirection.up; the
// dialog theme has no such setting).
import 'package:flutter/material.dart';

class DialogTitle extends StatelessWidget {
  final Widget title;

  /// What the X does: the same as the window's Cancel or Close button (null
  /// while that button cannot be pressed either).
  final VoidCallback? onClose;

  const DialogTitle(this.title, {super.key, required this.onClose});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: title),
      const SizedBox(width: 4),
      // A little up and into the corner, level with the title's first line.
      Transform.translate(
        offset: const Offset(8, -4),
        child: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          onPressed: onClose,
        ),
      ),
    ],
  );
}
