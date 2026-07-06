// Pollinator Monitor — "Calibrating…" banner (moved out of the camera screen
// in round 73, review item B6d; behaviour unchanged).

import 'package:flutter/material.dart';

/// A prominent centred banner shown while the ROI resolution is being measured
/// from the first full-resolution still, so the user knows the app is busy.
class CalibratingBanner extends StatelessWidget {
  const CalibratingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 14),
          Text(
            'Calibrating…',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Measuring ROI resolution',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
