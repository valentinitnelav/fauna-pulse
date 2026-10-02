// FaunaPulse (round 278, owner): a hint on the camera screen when the phone is
// too slow for live detection, that is when it checks fewer than 5 pictures
// per second (the owner's number). Fast insects can then fly through between
// two checks, so time-lapse photos or video, with "Find animals" afterwards,
// give better results.
//
// It measures the work per picture (preparing + detecting + sorting the boxes,
// as the detector reports it), not the frame rate shown on the screen: the
// frame-rate cap and the motion gate lower that rate on purpose, which must
// not raise the hint. The first 15 s are left out (start-up, the graphics
// chip warming up); then the median of the last 30 pictures decides, or of
// the pictures of the last 10 s (at least 5) on a phone so slow that 30 take
// long (the phone check: 1.5 s per picture, 45 s for 30). A constant, not a
// setting: it only decides when a message appears and changes nothing in the
// capture.

import 'package:flutter/material.dart';

/// Set by "Don't show again".
const kHideSlowPhoneHintPrefKey = 'faunapulse_hide_slow_phone_hint';

class SlowPhoneHint {
  /// Left out at the start (ms).
  static const warmUpMs = 15000;

  /// Pictures the median is taken over.
  static const window = 30;

  /// ... or the pictures of this long (ms), when at least [minPictures].
  static const windowMs = 10000;
  static const minPictures = 5;

  /// 1000 ms / 5 pictures per second.
  static const slowMs = 200.0;

  int? _firstMs;
  final _recent = <({int at, double ms})>[];
  bool _fired = false;

  /// The median work per picture over the last [window] pictures (ms).
  double? medianMs;

  /// Feeds one detector result ([workMs] = preparing + detecting + sorting
  /// the boxes, at [nowMs]). True once: when the phone is too slow.
  bool add(int nowMs, double workMs) {
    if (_fired || workMs <= 0) return false;
    _firstMs ??= nowMs;
    if (nowMs - _firstMs! < warmUpMs) return false;
    _recent.add((at: nowMs, ms: workMs));
    if (_recent.length > window) _recent.removeAt(0);
    final enough =
        _recent.length == window || (_recent.length >= minPictures && nowMs - _recent.first.at >= windowMs);
    if (!enough) return false;
    final sorted = [for (final r in _recent) r.ms]..sort();
    medianMs = sorted[sorted.length ~/ 2];
    if (medianMs! <= slowMs) return false;
    _fired = true;
    return true;
  }
}

/// The hint itself, at the top of the camera screen.
class SlowPhoneBanner extends StatelessWidget {
  /// Pictures per second the phone manages (from the median).
  final double perSecond;
  final VoidCallback onOk;
  final VoidCallback onNeverAgain;

  const SlowPhoneBanner({super.key, required this.perSecond, required this.onOk, required this.onNeverAgain});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(10),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
    decoration: BoxDecoration(
      color: Colors.brown.shade900.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.speed, color: Colors.amber, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'This phone checks fewer than 5 pictures per second (about ${perSecond.toStringAsFixed(1)}), '
                'so fast animals can be missed. For better results: stop, tap ⚙, choose "Time-lapse" '
                'and "Save bursts as: Video", and find the animals afterwards (home screen, step 4).',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            children: [
              TextButton(
                onPressed: onNeverAgain,
                child: const Text("Don't show again", style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: onOk,
                child: const Text('OK', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
