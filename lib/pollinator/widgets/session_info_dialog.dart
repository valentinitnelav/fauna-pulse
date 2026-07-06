// Pollinator Monitor — one-time session setup reminder (moved out of the
// camera screen in round 73, review item B6d; behaviour unchanged).

import 'package:flutter/material.dart';

/// One-time setup reminder shown when the camera screen opens. It explains how
/// to frame the shot (fix the flower, centre the ROI) and — importantly — points
/// the user at the focus button beside the record button so they lock focus
/// *before* recording. It does not block recording; the user dismisses it with
/// "Got it" and can tick "Don't show again" to never see it again.
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
      title: const Text('Setting up a session'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _bullet(
              Icons.park,
              'Fix the target flower in place — e.g. tie it to a pole — so it '
              'does not sway in the wind.',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.crop_square,
              'Centre the yellow ROI box on the target flower(s) or '
              'inflorescence(s).',
            ),
            const SizedBox(height: 12),
            _bullet(
              Icons.center_focus_strong,
              'Before recording, tap the focus button (just right of the record '
              'button) and lock focus on the flower. Focus then stays fixed for '
              'the whole session. This is recommended: autofocus can drift onto '
              'the background if the flower moves.',
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
              child: InkWell(
                onTap: () => setState(() => _dontShowAgain = !_dontShowAgain),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _dontShowAgain,
                      onChanged: (v) =>
                          setState(() => _dontShowAgain = v ?? false),
                    ),
                    const Flexible(child: Text("Don't show again")),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_dontShowAgain),
              child: const Text('Got it'),
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
