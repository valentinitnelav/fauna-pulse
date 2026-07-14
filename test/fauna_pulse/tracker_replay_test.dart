// Tests for the offline tracker replay harness (round 105) — and, when the
// REPLAY_SESSION define points at a real session.jsonl recorded with "Log raw
// detections" on, the actual comparison runner:
//
//   flutter test test/fauna_pulse/tracker_replay_test.dart \
//       --dart-define=REPLAY_SESSION=/absolute/path/to/session.jsonl

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker_replay.dart';

/// Builds a session.jsonl line exactly as SessionRecorder.recordFrame writes
/// it (envelope from SessionLogger._append), so the parser is tested against
/// the real on-disk format.
String rawLine(int frameMs, List<List<num>> boxes) => jsonEncode({
  'type': 'raw_detections',
  'time_ms': frameMs + 3, // the queue stamps slightly later than the frame
  'time_iso': '2026-07-14T12:00:00.000+02:00',
  'frame_ms': frameMs,
  'boxes': boxes,
});

/// A stationary insect visible from [fromMs] to [toMs] at [stepMs] intervals.
List<String> visitLines(int fromMs, int toMs, int stepMs, double x) => [
  for (var ts = fromMs; ts <= toMs; ts += stepMs)
    rawLine(ts, [
      [x, 0.40, x + 0.10, 0.50, 0.9, 0],
    ]),
];

void main() {
  group('parseRawDetectionLines', () {
    test('reads boxes, skips other record types and corrupt lines', () {
      final frames = parseRawDetectionLines([
        '{"type":"start_of_session","time_ms":1}',
        rawLine(1000, [
          [0.40, 0.40, 0.50, 0.50, 0.9, 0],
          [0.10, 0.10, 0.20, 0.20, 0.4, 2],
        ]),
        rawLine(1100, []), // empty frame — must be kept (tracks age by frame)
        '{"type":"raw_detections","frame_ms":1200,"boxes":[[0.1,0.1', // cut
        '',
      ]);
      expect(frames, hasLength(2));
      expect(frames.first.timestampMs, 1000);
      expect(frames.first.detections, hasLength(2));
      expect(frames.first.detections[0].box,
          const Rect.fromLTRB(0.40, 0.40, 0.50, 0.50));
      expect(frames.first.detections[1].confidence, closeTo(0.4, 1e-9));
      expect(frames.first.detections[1].classIndex, 2);
      expect(frames.last.detections, isEmpty);
    });

    test('sorts frames by timestamp', () {
      final frames = parseRawDetectionLines([
        rawLine(2000, []),
        rawLine(1000, []),
      ]);
      expect(frames.map((f) => f.timestampMs), [1000, 2000]);
    });
  });

  group('replayTracker', () {
    test('counts two separate visits with sane durations', () {
      // Visit 1: 0–2 s. Long empty gap (> occlusion). Visit 2: 30–31 s.
      final lines = [
        ...visitLines(0, 2000, 100, 0.40),
        ...visitLines(30000, 31000, 100, 0.42),
      ];
      final frames = parseRawDetectionLines(lines);
      final report = replayTracker(
        tracker: ByteTracker(),
        frames: frames,
        occlusionSeconds: 3.0,
        minHitsSeconds: 0.2,
      );
      expect(report.algorithm, 'bytetrack');
      expect(report.visits, 2);
      expect(report.visitDurationsS, hasLength(2));
      expect(report.visitDurationsS[0], closeTo(2.0, 0.11));
      expect(report.visitDurationsS[1], closeTo(1.0, 0.11));
      expect(report.maxConcurrent, 1);
      expect(report.summary(), contains('2 visit(s)'));
    });

    test('both trackers run the same frames through one interface', () {
      final frames = parseRawDetectionLines(visitLines(0, 2000, 100, 0.40));
      for (final InsectTracker tracker in [ByteTracker(), CBiouTracker()]) {
        final report = replayTracker(tracker: tracker, frames: frames);
        expect(report.visits, 1, reason: tracker.algorithmName);
        expect(report.frames, frames.length);
      }
    });

    test('a gap longer than the occlusion tolerance expires lost tracks '
        '(no id inheritance across a motion-gate sleep)', () {
      // Same spot before and after a 30 s gap: live, the gate wake would
      // expire the lost track; the replay must reproduce that, so the
      // second appearance is a SECOND visit even though the spot matches.
      final lines = [
        ...visitLines(0, 1000, 100, 0.40),
        ...visitLines(30000, 31000, 100, 0.40),
      ];
      final report = replayTracker(
        tracker: ByteTracker(),
        frames: parseRawDetectionLines(lines),
        occlusionSeconds: 3.0,
      );
      expect(report.visits, 2);
    });
  });

  // --- Optional: replay a REAL session --------------------------------------
  // Skipped unless --dart-define=REPLAY_SESSION=/path/to/session.jsonl is
  // given. Prints one summary line per tracker; judge them against a hand
  // count of visits from the session's saved ROI photos.
  const sessionPath = String.fromEnvironment('REPLAY_SESSION');
  test('replay a recorded session through both trackers', () {
    final lines = File(sessionPath).readAsLinesSync();
    final frames = parseRawDetectionLines(lines);
    expect(
      frames,
      isNotEmpty,
      reason:
          'No raw_detections records in $sessionPath — was the session '
          'recorded with Settings → AI → Visit tracking → Advanced → '
          '"Log raw detections" enabled?',
    );
    // Read the seconds the session actually used from its start record, so
    // the replay matches the field run.
    var occlusionS = 3.0;
    var minHitsS = 0.2;
    for (final line in lines) {
      try {
        final rec = jsonDecode(line);
        if (rec is Map && rec['type'] == 'start_of_session') {
          final cfg = rec['config'];
          if (cfg is Map) {
            occlusionS =
                (cfg['occlusionSeconds'] as num?)?.toDouble() ?? occlusionS;
            minHitsS = (cfg['minHitsSeconds'] as num?)?.toDouble() ?? minHitsS;
          }
          break;
        }
      } catch (_) {}
    }
    // ignore: avoid_print
    print('Replaying ${frames.length} frames from $sessionPath '
        '(occlusion $occlusionS s, min visit $minHitsS s):');
    for (final InsectTracker tracker in [ByteTracker(), CBiouTracker()]) {
      final report = replayTracker(
        tracker: tracker,
        frames: frames,
        occlusionSeconds: occlusionS,
        minHitsSeconds: minHitsS,
      );
      // ignore: avoid_print
      print('  ${report.summary()}');
    }
  }, skip: sessionPath.isEmpty ? 'no REPLAY_SESSION defined' : false);
}
