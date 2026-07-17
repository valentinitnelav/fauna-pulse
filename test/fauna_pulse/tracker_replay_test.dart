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
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker_replay.dart';

Detection det(Rect box, [double conf = 0.9]) =>
    Detection(box: box, confidence: conf, classIndex: 0, className: 'bee');

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
      expect(
        frames.first.detections[0].box,
        const Rect.fromLTRB(0.40, 0.40, 0.50, 0.50),
      );
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

  group('frame-stream degraders (round 107)', () {
    final frames = parseRawDetectionLines(visitLines(0, 10000, 100, 0.40));

    test('keepEveryNth keeps 1-in-n with original timestamps', () {
      final thinned = keepEveryNth(frames, 3);
      expect(thinned.length, (frames.length / 3).ceil());
      expect(thinned[1].timestampMs, frames[3].timestampMs);
    });

    test('injectGaps removes the frames inside each periodic window', () {
      final gapped = injectGaps(frames, gapSeconds: 1.0, everySeconds: 5.0);
      // 0–1 s and 5–6 s of every 5 s block are gone.
      expect(gapped.any((f) => f.timestampMs < 1000), isFalse);
      expect(
        gapped.any((f) => f.timestampMs >= 5000 && f.timestampMs < 6000),
        isFalse,
      );
      expect(
        gapped.any((f) => f.timestampMs >= 1000 && f.timestampMs < 5000),
        isTrue,
      );
    });

    test('staircaseFps thins each segment to its cap', () {
      // Segments of 2 s cycling 10 → 2 fps over a 10 fps stream.
      final stepped = staircaseFps(frames, [10, 2], segmentSeconds: 2);
      final seg0 = stepped.where((f) => f.timestampMs < 2000).length;
      final seg1 = stepped
          .where((f) => f.timestampMs >= 2000 && f.timestampMs < 4000)
          .length;
      expect(seg0, greaterThan(15)); // ~10 fps kept
      expect(seg1, lessThanOrEqualTo(5)); // capped to ~2 fps
    });
  });

  group('time-aware motion variant (round 107)', () {
    // Constant rightward motion (0.3 frame-widths/s), regular 100 ms frames,
    // then one 1 s delivery gap. The per-frame velocity reading predicts a
    // tenth of the true displacement across the gap and loses the insect;
    // reading velocity per SECOND lands the prediction on it.
    List<Detection> at(double t) => [
      det(Rect.fromLTWH(0.10 + 0.3 * t, 0.40, 0.10, 0.10)),
    ];

    int confirmedAfterGap(InsectTracker t) {
      t.update(at(0.0), 0);
      t.update(at(0.1), 100);
      t.update(at(0.2), 200); // confirmed, velocity warmed up
      t.update(at(1.2), 1200); // the gap frame
      t.update(at(1.3), 1300); // enough to re-confirm a split id
      return t.totalConfirmed;
    }

    test('ByteTracker: per-frame velocity splits the id across the gap', () {
      expect(
        confirmedAfterGap(
          ByteTracker(
            params: const ByteTrackParams(
              minHitsToConfirm: 2,
              velocitySmoothing: 0.8,
            ),
          ),
        ),
        2,
      );
    });
    test('ByteTracker: time-aware velocity holds the id across the gap', () {
      expect(
        confirmedAfterGap(
          ByteTracker(
            params: const ByteTrackParams(
              minHitsToConfirm: 2,
              velocitySmoothing: 0.8,
            ),
            timeAwareMotion: true,
          ),
        ),
        1,
      );
    });
    test('CBiouTracker: same contrast with strict buffers', () {
      CBiouTracker make({required bool timeAware}) => CBiouTracker(
        params: const CBiouParams(
          minHitsToConfirm: 2,
          bufferScale1: 0.05,
          bufferScale2: 0.05,
        ),
        timeAwareMotion: timeAware,
      );
      expect(confirmedAfterGap(make(timeAware: false)), 2);
      expect(confirmedAfterGap(make(timeAware: true)), 1);
    });
  });

  group('buffered-IoU fallback variant (round 107)', () {
    // A small (0.06) stationary box jumps 0.13 — past the distance gate
    // (1.5 × diagonal ≈ 0.127) but within the buffered reach (0.05 absolute
    // floor per side). IoU passes are locked out with a 0.9 threshold so
    // ONLY the fallback can hold the id (mirrors the r105 distance test).
    int confirmedAfterJump(FallbackMode mode) {
      final t = ByteTracker(
        params: const ByteTrackParams(
          minHitsToConfirm: 2,
          matchThresh: 0.9,
          lowMatchThresh: 0.9,
        ),
        fallbackMode: mode,
      );
      const before = Rect.fromLTWH(0.40, 0.40, 0.06, 0.06);
      const after = Rect.fromLTWH(0.53, 0.40, 0.06, 0.06);
      t.update([det(before)], 0);
      t.update([det(before)], 100); // confirmed, velocity ~0
      t.update([det(after)], 200); // the jump
      t.update([det(after)], 300); // re-confirms a split id if one spawned
      return t.totalConfirmed;
    }

    test('distance fallback loses the jump (outside its gate)', () {
      expect(confirmedAfterJump(FallbackMode.distance), 2);
    });
    test('buffered-IoU fallback holds it (absolute reach floor)', () {
      expect(confirmedAfterJump(FallbackMode.bufferedIou), 1);
    });
  });

  // --- Optional: replay a REAL session --------------------------------------
  // Skipped unless --dart-define=REPLAY_SESSION=/path/to/session.jsonl is
  // given. Prints the round-107 variant matrix (each tracker/flag combination
  // on the full stream and on one throttle-like degraded stream); judge the
  // counts against a hand count of visits from the session's photos.
  const sessionPath = String.fromEnvironment('REPLAY_SESSION');
  test(
    'replay a recorded session through both trackers',
    () {
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
              minHitsS =
                  (cfg['minHitsSeconds'] as num?)?.toDouble() ?? minHitsS;
            }
            break;
          }
        } catch (_) {}
      }
      // ignore: avoid_print
      print(
        'Replaying ${frames.length} frames from $sessionPath '
        '(occlusion $occlusionS s, min visit $minHitsS s):',
      );
      // The round-107 variant matrix. Factories, not instances: each run
      // needs a fresh tracker, and the degraded pass must not share state
      // with the full-stream pass.
      final variants = <String, InsectTracker Function()>{
        'byte': () => ByteTracker(),
        'byte dtAware': () => ByteTracker(timeAwareMotion: true),
        'byte bIoU-fb': () =>
            ByteTracker(fallbackMode: FallbackMode.bufferedIou),
        'byte dt+bIoU': () => ByteTracker(
          timeAwareMotion: true,
          fallbackMode: FallbackMode.bufferedIou,
        ),
        'cbiou': () => CBiouTracker(),
        'cbiou dtAware': () => CBiouTracker(timeAwareMotion: true),
      };
      // One throttle-like stress stream: the same detections delivered at a
      // 15 → 3 → 10 fps staircase (10 s segments).
      final degraded = staircaseFps(frames, [15, 3, 10]);
      for (final (label, stream) in [
        ('full stream', frames),
        ('staircase 15/3/10 fps (${degraded.length} frames)', degraded),
      ]) {
        // ignore: avoid_print
        print('--- $label ---');
        for (final e in variants.entries) {
          final report = replayTracker(
            tracker: e.value(),
            frames: stream,
            occlusionSeconds: occlusionS,
            minHitsSeconds: minHitsS,
          );
          // ignore: avoid_print
          print('  ${e.key.padRight(13)} -> ${report.summary()}');
        }
      }
    },
    skip: sessionPath.isEmpty ? 'no REPLAY_SESSION defined' : false,
  );
}
