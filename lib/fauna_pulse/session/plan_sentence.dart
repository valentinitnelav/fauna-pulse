// FaunaPulse (round 298): what a recording will do, in one or two plain sentences.
//
// Idea from the sister app FaunaLapse (card 3, "Schedule"), whose summary reads like "Photos: one
// every 2 s for 60 s, then 5 min off. For 1 h from Start." Shown in the "Before you record"
// sheet so the user can check the plan before pressing Start. Pure, so it is unit tested.

import '../models/session_config.dart';

/// A duration in seconds as "10 s", "0.5 s", "30 min", "1.5 min", "2 h".
String planDuration(double seconds) {
  String num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  if (seconds < 60) return '${num(seconds)} s';
  if (seconds < 3600) return '${num(seconds / 60)} min';
  return '${num(seconds / 3600)} h';
}

/// What will be recorded (first sentence) and when (second sentence).
String planSentence(SessionConfig c) {
  final step = planDuration(c.stepSeconds);
  final burst = planDuration(c.durationSeconds);
  final String what;
  switch (c.captureTrigger) {
    case CaptureTrigger.detector:
      what =
          'Live detection: a photo of each animal every $step for $burst after it appears'
          '${c.liveAiVideo ? ', and video of the square at ${c.liveAiVideoFps} frames per second' : ''}.';
    case CaptureTrigger.motion:
      what = 'Motion photos: one every $step while something moves in the square.';
    case CaptureTrigger.timelapse:
      final gap = c.timeLapseGapSeconds;
      final rest = gap <= 0 ? ', without breaks' : ', then ${planDuration(gap)} off';
      what = c.timeLapseVideo
          ? 'Video at ${c.timeLapseVideoFps} frames per second: clips of $burst$rest.'
          : 'Photos: one every $step for $burst$rest.';
  }
  final days = c.scheduleDays == 1 ? '1 day' : '${c.scheduleDays} days';
  final when = c.scheduleEnabled
      ? 'Daily ${c.scheduleWindows.map((w) => w.label).join(', ')} for $days; each window is its own session.'
      : 'For ${planDuration(c.sessionMinutes * 60.0)} from Start.';
  return '$what $when';
}
