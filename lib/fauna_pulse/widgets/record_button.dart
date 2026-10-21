// FaunaPulse: the camera screen's record button (moved out of
// camera_session_screen.dart in round 319 so it can be tested without a camera).
// Round 319 (stress finding n43): while a stop runs (video clips closing, files
// written, up to a few seconds on a hot phone), it shows "Stopping…" with a small
// progress ring and takes no taps, so the user sees that the tap was taken.

import 'package:flutter/material.dart';

class RecordButton extends StatelessWidget {
  const RecordButton({
    super.key,
    required this.ready,
    required this.square,
    required this.scheduleBadge,
    required this.stopping,
    required this.onTap,
  });

  /// False (greyed out) until calibration completes.
  final bool ready;

  /// A stop square (recording or a scheduled run active) instead of a circle.
  final bool square;

  /// The clock badge: idle with scheduling on (a tap launches the whole run).
  final bool scheduleBadge;

  /// A stop is in progress: no taps, a progress ring and "Stopping…".
  final bool stopping;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: stopping ? null : onTap,
      child: Opacity(
        opacity: ready && !stopping ? 1.0 : 0.4,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: square ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: square ? BorderRadius.circular(8) : null,
              ),
              child: stopping
                  ? const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                      ),
                    )
                  : (!square && scheduleBadge)
                  ? const Icon(Icons.schedule, color: Colors.white, size: 30)
                  : null,
            ),
          ),
        ),
      ),
    );
    if (!stopping) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 2),
        const Text(
          'Stopping…',
          style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
