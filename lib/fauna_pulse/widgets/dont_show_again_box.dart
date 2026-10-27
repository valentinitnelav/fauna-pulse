// FaunaPulse (round 330, owner): the "Don't show again" tick box of windows the app opens on
// its own, which would otherwise come back every time (rule "Notes that repeat" in
// docs/AGENT_CHANGELOG_OVERVIEW.md). "Show tips and notes" in the Home menu brings every hidden
// note back.

import 'package:flutter/material.dart';

class DontShowAgainBox extends StatelessWidget {
  const DontShowAgainBox({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    // The words are part of the tap target, not only the small box.
    onTap: () => onChanged(!value),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
        const Flexible(child: Text("Don't show again")),
      ],
    ),
  );
}
