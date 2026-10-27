// FaunaPulse — one-time session setup reminder (moved out of the
// camera screen in round 73, review item B6d; behaviour unchanged).

import 'package:flutter/material.dart';
import 'dialog_title.dart';
import 'dont_show_again_box.dart';

/// One-time setup reminder shown when the camera screen opens. It explains how
/// to frame the shot (fix a flower, place the yellow square) and — importantly —
/// tells the user to CHECK the focus: since round 164 focus is always manual,
/// already locked at a ~13 cm close-up preset when the screen opens, and the
/// focus button (amber dot until adjusted) fine-tunes it. It does not block
/// recording; the user dismisses it with Close (or X) and can tick "Don't show
/// again" to never see it again.
///
/// Pops `true` if the user asked to hide it permanently, otherwise `false`.
class SessionInfoDialog extends StatefulWidget {
  const SessionInfoDialog({super.key});

  @override
  State<SessionInfoDialog> createState() => _SessionInfoDialogState();
}

class _SessionInfoDialogState extends State<SessionInfoDialog> {
  bool _dontShowAgain = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: DialogTitle(const Text('Setting up a session'), onClose: () => Navigator.of(context).pop(_dontShowAgain)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bullet(
              Icons.park,
              'If you watch a flower, tie it to a stick so the wind does not '
              'move it.',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.crop_square,
              'Put the yellow square (the area FaunaPulse watches) where '
              'animals come: flowers, a flat surface or a feeding site.',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.center_focus_strong,
              'Check the focus: it starts fixed at about 13 cm. Tap the focus '
              'button (amber dot) and move the Far–Near slider until the '
              'subject is sharp. The focus then stays there for the whole '
              'session (autofocus would often pick the background).',
            ),
          ],
        ),
      ),
      actions: [
        // Checkbox + button share the actions row; keep them readable on small
        // screens by letting the row wrap.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: DontShowAgainBox(
                value: _dontShowAgain,
                onChanged: (v) => setState(() => _dontShowAgain = v),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_dontShowAgain),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bullet(IconData icon, String text) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
}
