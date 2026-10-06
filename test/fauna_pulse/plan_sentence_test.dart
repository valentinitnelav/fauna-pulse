// Round 298: the plain plan sentence of the "Before you record" sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/session/plan_sentence.dart';

void main() {
  test('durations read naturally', () {
    expect(planDuration(10), '10 s');
    expect(planDuration(0.5), '0.5 s');
    expect(planDuration(1800), '30 min');
    expect(planDuration(90), '1.5 min');
    expect(planDuration(7200), '2 h');
  });

  test('time-lapse photos and video, manual and scheduled', () {
    const base = SessionConfig(sessionMinutes: 60);
    final photos = base.copyWith(
      captureTrigger: CaptureTrigger.timelapse,
      stepSeconds: 1,
      durationSeconds: 10,
      timeLapseGapSeconds: 1800,
    );
    expect(planSentence(photos), 'Photos: one every 1 s for 10 s, then 30 min off. For 1 h from Start.');
    expect(
      planSentence(photos.copyWith(timeLapseSaveAs: TimeLapseSaveAs.video, timeLapseGapSeconds: 0)),
      'Video at 5 frames per second: clips of 10 s, without breaks. For 1 h from Start.',
    );
    final scheduled = photos.copyWith(
      scheduleEnabled: true,
      scheduleWindows: [ScheduleWindow(6 * 60, 10 * 60)],
      scheduleDays: 3,
    );
    expect(planSentence(scheduled), endsWith('Daily 06:00–10:00 for 3 days; each window is its own session.'));
  });

  test('live detection and motion photos', () {
    expect(
      planSentence(const SessionConfig(sessionMinutes: 30)),
      'Live detection: a photo of each animal every 1 s for 10 s after it appears. For 30 min from Start.',
    );
    expect(
      planSentence(const SessionConfig(sessionMinutes: 30).copyWith(captureTrigger: CaptureTrigger.motion)),
      startsWith('Motion photos: one every 1 s while something moves in the square.'),
    );
  });
}
