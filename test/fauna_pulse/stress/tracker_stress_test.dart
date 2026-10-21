// Stress tests for the frame-association trackers (ByteTracker in its three
// variants, CBiouTracker in two): very many boxes in one frame, broken box
// values (NaN, infinity, zero or negative size, outside the image), broken
// time stamps (backwards, repeating, a 10-hour gap) and empty frames in
// between. Every tracker must survive all of it: no exception, finite ids and
// boxes, bounded run time.
//
// Tests that show a real bug are kept and marked `skip: 'BUG: ...'` so the
// normal suite stays green. Run them with --run-skipped to see them fail.
// All random numbers come from a seeded Random, so every run is the same.

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker_replay.dart';

Detection det(Rect box, [double conf = 0.9]) =>
    Detection(box: box, confidence: conf, classIndex: 0, className: 'bee');

/// Every tracker variant the app (or its replay harness) can build.
final Map<String, InsectTracker Function()> kTrackers = {
  'ByteTracker distance': () => ByteTracker(params: const ByteTrackParams(minHitsToConfirm: 2)),
  'ByteTracker timeAware': () =>
      ByteTracker(params: const ByteTrackParams(minHitsToConfirm: 2), timeAwareMotion: true),
  'ByteTracker bufferedIou': () => ByteTracker(
    params: const ByteTrackParams(minHitsToConfirm: 2),
    fallbackMode: FallbackMode.bufferedIou,
  ),
  'CBiouTracker': () => CBiouTracker(params: const CBiouParams(minHitsToConfirm: 2)),
  'CBiouTracker timeAware': () =>
      CBiouTracker(params: const CBiouParams(minHitsToConfirm: 2), timeAwareMotion: true),
};

/// A grid of [n] small boxes that do not touch each other, each moved by a
/// tiny seeded amount per call (so the second frame is not identical).
List<Detection> grid(int n, Random rng, {double conf = 0.9}) {
  final cols = sqrt(n).ceil();
  const cell = 0.9 / 32;
  return [
    for (var i = 0; i < n; i++)
      det(
        Rect.fromLTWH(
          0.05 + (i % cols) * cell + rng.nextDouble() * 0.002,
          0.05 + (i ~/ cols) * cell + rng.nextDouble() * 0.002,
          cell * 0.5,
          cell * 0.5,
        ),
        conf,
      ),
  ];
}

bool finiteRect(Rect r) => r.left.isFinite && r.top.isFinite && r.right.isFinite && r.bottom.isFinite;

/// Milliseconds one call of [f] takes.
double timeMs(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  sw.stop();
  return sw.elapsedMicroseconds / 1000.0;
}

/// The checks every returned track list must pass.
void expectSaneTracks(List<Track> tracks, {required String where}) {
  final seen = <int>{};
  for (final t in tracks) {
    expect(t.id, greaterThan(0), reason: '$where: id');
    expect(seen.add(t.id), isTrue, reason: '$where: duplicate id ${t.id} in one frame');
    expect(finiteRect(t.box), isTrue, reason: '$where: box ${t.box} of id ${t.id} is not finite');
    expect(t.vx.isFinite && t.vy.isFinite, isTrue, reason: '$where: velocity of id ${t.id}');
  }
}

void main() {
  group('1000 boxes in one frame', () {
    for (final entry in kTrackers.entries) {
      test('${entry.key}: frame 1, 2 and 3 with 1000 boxes each', () {
        final rng = Random(1);
        final tracker = entry.value();
        final times = <double>[];
        List<Track> tracks = const [];
        for (var f = 0; f < 3; f++) {
          final dets = grid(1000, rng);
          times.add(timeMs(() => tracks = tracker.update(dets, 1000 + f * 100)));
        }
        // ignore: avoid_print
        print('${entry.key}: 1000 boxes per frame -> ${times.map((t) => t.toStringAsFixed(0)).join(' / ')} ms, '
            'confirmed ${tracks.length}, active ${tracker.activeTrackCount}');
        expectSaneTracks(tracks, where: entry.key);
        expect(tracker.activeTrackCount, lessThanOrEqualTo(1000));
        // The grid boxes never touch, so each stays its own track.
        expect(tracker.totalConfirmed, greaterThan(900), reason: 'most of the 1000 grid boxes get a track ID');
        // Generous bound, so a slow laptop does not fail it. The real limit
        // for a finding is 1 s per frame (see the test below).
        expect(times.reduce(max), lessThan(20000));
      });
    }

    test('run time per frame stays under 1 s with 1000 boxes (all tracker variants)', () {
      final slow = <String>[];
      for (final entry in kTrackers.entries) {
        final rng = Random(2);
        final tracker = entry.value();
        var worst = 0.0;
        for (var f = 0; f < 3; f++) {
          final dets = grid(1000, rng);
          worst = max(worst, timeMs(() => tracker.update(dets, 1000 + f * 100)));
        }
        if (worst > 1000) slow.add('${entry.key}: ${worst.toStringAsFixed(0)} ms');
      }
      expect(slow, isEmpty, reason: 'frames slower than 1 s: $slow');
    }, skip: false);

    test('dense overlap: 400 boxes piled in a small area, 3 frames', () {
      // A false-alarm storm (a wet leaf lit by the sun): almost every box
      // overlaps almost every other. This is the worst case for the pair list.
      for (final entry in kTrackers.entries) {
        final rng = Random(3);
        final tracker = entry.value();
        final times = <double>[];
        List<Track> tracks = const [];
        for (var f = 0; f < 3; f++) {
          final dets = [
            for (var i = 0; i < 400; i++)
              det(
                Rect.fromLTWH(0.3 + rng.nextDouble() * 0.1, 0.3 + rng.nextDouble() * 0.1, 0.1, 0.1),
                0.5 + rng.nextDouble() * 0.5,
              ),
          ];
          times.add(timeMs(() => tracks = tracker.update(dets, 1000 + f * 100)));
        }
        // ignore: avoid_print
        print('${entry.key}: 400 piled boxes -> ${times.map((t) => t.toStringAsFixed(0)).join(' / ')} ms');
        expectSaneTracks(tracks, where: entry.key);
        expect(times.reduce(max), lessThan(10000), reason: '${entry.key} dense frame');
      }
    });

    test('dense overlap: 1000 piled boxes, run time per frame under 1 s', () {
      // The same false-alarm storm with 1000 boxes: every track overlaps
      // almost every box, so the pair list holds up to a million entries.
      final slow = <String>[];
      for (final entry in kTrackers.entries) {
        final rng = Random(31);
        final tracker = entry.value();
        final times = <double>[];
        for (var f = 0; f < 3; f++) {
          final dets = [
            for (var i = 0; i < 1000; i++)
              det(
                Rect.fromLTWH(0.3 + rng.nextDouble() * 0.1, 0.3 + rng.nextDouble() * 0.1, 0.1, 0.1),
                0.5 + rng.nextDouble() * 0.5,
              ),
          ];
          times.add(timeMs(() => tracker.update(dets, 1000 + f * 100)));
        }
        // ignore: avoid_print
        print('${entry.key}: 1000 piled boxes -> ${times.map((t) => t.toStringAsFixed(0)).join(' / ')} ms');
        if (times.reduce(max) > 1000) slow.add('${entry.key}: ${times.reduce(max).toStringAsFixed(0)} ms');
      }
      expect(slow, isEmpty, reason: 'frames slower than 1 s: $slow');
    }, skip: 'BUG: with 1000 heavily overlapping boxes one update() takes 1.0 to 2.4 s on the laptop '
        '(ByteTracker about 1.1 s, CBiouTracker about 2.1 s; 400 boxes: about 0.17 s). Cause: _associate builds all '
        'tracks x detections pairs (up to 1 million _Pair objects) and sorts them, per pass. The detector keeps at most numItemsThreshold (default 30) boxes, so this is hard to reach in the field. A phone is several '
        'times slower than the laptop. Fix idea: skip pairs with score 0 early, or cap the detections per frame.');

    test('cost grows with the square of the box count (prints the numbers)', () {
      // Frame 2 with n confirmed tracks and n detections, n = 125 .. 1000.
      for (final entry in kTrackers.entries) {
        final ms = <int, double>{};
        for (final n in [125, 250, 500, 1000]) {
          final rng = Random(4);
          final tracker = entry.value();
          tracker.update(grid(n, rng), 1000);
          tracker.update(grid(n, rng), 1100); // confirms all
          final dets = grid(n, rng);
          ms[n] = timeMs(() => tracker.update(dets, 1200));
        }
        // ignore: avoid_print
        print('${entry.key}: frame with tracks, ms by box count '
            '${ms.entries.map((e) => '${e.key}:${e.value.toStringAsFixed(0)}').join(' ')}');
        expect(ms[1000]!, greaterThan(0));
      }
    });

    test('a frame with 1000 low-confidence boxes and no tracks is cheap', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        final dets = grid(1000, Random(5), conf: 0.1);
        final ms = timeMs(() => tracker.update(dets, 1000));
        expect(ms, lessThan(1000), reason: entry.key);
        expect(tracker.activeTrackCount, 0, reason: 'low-confidence boxes never start a track');
      }
    });
  });

  group('broken box values', () {
    final nan = double.nan, inf = double.infinity;
    final evil = <String, Rect>{
      'NaN left': Rect.fromLTRB(nan, 0.4, 0.5, 0.5),
      'all NaN': Rect.fromLTRB(nan, nan, nan, nan),
      '+infinity right': Rect.fromLTRB(0.4, 0.4, inf, 0.5),
      '-infinity left': Rect.fromLTRB(-inf, 0.4, 0.5, 0.5),
      'whole plane': Rect.fromLTRB(-inf, -inf, inf, inf),
      'huge 1e300': const Rect.fromLTRB(-1e300, -1e300, 1e300, 1e300),
      'zero size': const Rect.fromLTWH(0.5, 0.5, 0, 0),
      'zero width': const Rect.fromLTWH(0.5, 0.5, 0, 0.1),
      'negative size': const Rect.fromLTRB(0.6, 0.6, 0.4, 0.4),
      'negative width only': const Rect.fromLTRB(0.6, 0.4, 0.4, 0.6),
      'denormal size': const Rect.fromLTWH(0.5, 0.5, 5e-324, 5e-324),
      'far outside (negative)': const Rect.fromLTWH(-5, -5, 1, 1),
      'far outside (large)': const Rect.fromLTWH(7, 7, 1, 1),
      'bigger than the image': const Rect.fromLTRB(-2, -2, 3, 3),
    };

    for (final tName in kTrackers.keys) {
      for (final e in evil.entries) {
        test('$tName: a ${e.key} box next to a real insect for 30 frames', () {
          final tracker = kTrackers[tName]!();
          late List<Track> tracks;
          for (var f = 0; f < 30; f++) {
            final good = Rect.fromLTWH(0.2 + f * 0.003, 0.2, 0.08, 0.08);
            tracks = tracker.update([det(good), det(e.value)], 1000 + f * 100);
            expectSaneTracks(tracks, where: '$tName / ${e.key} / frame $f');
          }
          // The real insect keeps one ID. Boxes outside the image are
          // allowed to be a (second) track: the frame processor clips them.
          final goodTracks = tracks.where((t) => (t.box.center - const Offset(0.24, 0.24)).distance < 0.2);
          expect(goodTracks, hasLength(1));
          expect(goodTracks.single.id, 1, reason: 'the real insect started first and keeps ID 1');
          expect(tracker.activeTrackCount, lessThan(10), reason: 'broken boxes must not pile up tracks');
          if (!e.key.startsWith('far outside') && e.key != 'bigger than the image') {
            expect(tracker.totalConfirmed, 1, reason: 'a broken box must not become a counted track ID');
          }
        });
      }
    }

    test('broken boxes only, 500 frames: ids stay finite, tracks do not pile up', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        final all = evil.values.toList();
        for (var f = 0; f < 500; f++) {
          final tracks = tracker.update([for (final r in all) det(r)], 1000 + f * 100);
          expectSaneTracks(tracks, where: '${entry.key} frame $f');
        }
        expect(tracker.activeTrackCount, lessThan(100), reason: entry.key);
      }
    });

    test('broken confidence values (NaN, infinity, negative, above 1) do not break the tracker', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        late List<Track> tracks;
        for (var f = 0; f < 30; f++) {
          final b = Rect.fromLTWH(0.2 + f * 0.003, 0.2, 0.08, 0.08);
          final conf = [0.9, nan, inf, -inf, -1.0, 7.0][f % 6];
          tracks = tracker.update([det(b, conf)], 1000 + f * 100);
          expectSaneTracks(tracks, where: '${entry.key} frame $f');
        }
      }
    });

    test('a NaN confidence is not copied onto a confirmed track (the log writer cannot encode NaN)', () {
      // jsonEncode(double.nan) throws, and the track's confidence goes into
      // the session log. A low pool detection with NaN confidence matches a
      // confirmed track in the second pass and overwrites its confidence.
      final tracker = ByteTracker(params: const ByteTrackParams(minHitsToConfirm: 2));
      tracker.update([det(const Rect.fromLTWH(0.4, 0.4, 0.1, 0.1))], 1000);
      tracker.update([det(const Rect.fromLTWH(0.4, 0.4, 0.1, 0.1))], 1100);
      final tracks = tracker.update([det(const Rect.fromLTWH(0.4, 0.4, 0.1, 0.1), double.nan)], 1200);
      expect(tracks, hasLength(1));
      expect(tracks.single.confidence.isNaN, isFalse);
    });
  });

  group('iou and biou on broken rectangles', () {
    test('iou and biou stay inside 0..1 for random, inverted and degenerate rectangles', () {
      final rng = Random(7);
      Rect any() {
        double v() => rng.nextInt(6) == 0 ? [0.0, -0.0, 1.0, -1.0, 1e-300, 1e300][rng.nextInt(6)] : rng.nextDouble() * 2 - 0.5;
        return Rect.fromLTRB(v(), v(), v(), v());
      }

      for (var i = 0; i < 20000; i++) {
        final a = any(), b = any();
        final v = iou(a, b);
        expect(v.isNaN, isFalse, reason: 'iou($a, $b) is NaN');
        expect(v, inInclusiveRange(0.0, 1.0 + 1e-9), reason: 'iou($a, $b) = $v');
        final w = biou(a, b, 0.3);
        expect(w.isNaN, isFalse, reason: 'biou($a, $b) is NaN');
        expect(w, inInclusiveRange(0.0, 1.0 + 1e-9), reason: 'biou($a, $b) = $w');
      }
    });

    test('iou with a NaN or infinite rectangle is 0, not NaN', () {
      const a = Rect.fromLTWH(0.2, 0.2, 0.2, 0.2);
      final cases = [
        Rect.fromLTRB(double.nan, 0, 1, 1),
        Rect.fromLTRB(-double.infinity, -double.infinity, double.infinity, double.infinity),
      ];
      for (final c in cases) {
        expect(iou(a, c).isNaN, isFalse, reason: 'iou(a, $c)');
        expect(iou(c, c).isNaN, isFalse, reason: 'iou(c, c) for $c');
      }
    });
  });

  group('broken time stamps', () {
    /// One insect that drifts slowly; [stamps] gives the time of each frame.
    void runInsect(InsectTracker tracker, List<int> stamps, {String? where}) {
      for (var f = 0; f < stamps.length; f++) {
        final b = Rect.fromLTWH(0.2 + (f % 50) * 0.002, 0.2, 0.08, 0.08);
        final tracks = tracker.update([det(b)], stamps[f]);
        expectSaneTracks(tracks, where: '${where ?? ''} frame $f ts ${stamps[f]}');
      }
    }

    final series = <String, List<int>>{
      'going backwards': [for (var i = 0; i < 30; i++) 10000 - i * 100],
      'repeating the same value': List.filled(30, 5000),
      'zig-zag (+200, -100)': [for (var i = 0; i < 30; i++) 10000 + (i.isEven ? i * 100 : i * 100 - 300)],
      'all zero': List.filled(30, 0),
      'negative': [for (var i = 0; i < 30; i++) -100000 + i * 100],
      'starting at zero': [for (var i = 0; i < 30; i++) i * 100],
      'near the largest integer': [for (var i = 0; i < 30; i++) 9007199254740991 - 3000 + i * 100],
      'jump to the far future and back': [1000, 1100, 1200, 1 << 61, 1 << 61 + 100, 1300, 1400],
      'a 10-hour gap in the middle': [for (var i = 0; i < 10; i++) 1000 + i * 100] +
          [for (var i = 0; i < 10; i++) 1000 + 36000000 + i * 100],
    };

    for (final tName in kTrackers.keys) {
      for (final s in series.entries) {
        test('$tName: time stamps ${s.key}', () {
          final tracker = kTrackers[tName]!();
          runInsect(tracker, s.value, where: '$tName / ${s.key}');
          expect(tracker.activeTrackCount, lessThan(5));
          // A slowly drifting insect is one insect whatever the clock says.
          expect(tracker.totalConfirmed, 1, reason: 'one insect, one ID, whatever the clock does');
        });
      }
    }

    test('a track ID that is matched across a 10-hour gap is cut into two track IDs', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        const box = Rect.fromLTWH(0.4, 0.4, 0.1, 0.1);
        tracker.update([det(box)], 1000);
        tracker.update([det(box)], 1100);
        tracker.update([det(box)], 1100 + 36000000);
        final tracks = tracker.update([det(box)], 1200 + 36000000);
        // The log would otherwise show one visit that lasts 10 hours and is
        // inflated by the gap. The app only expires tracks on a motion-gate
        // wake (FrameProcessor.setGateIdle), not when the app comes back
        // from the background (camera_session_screen.dart,
        // didChangeAppLifecycleState).
        expect(tracks.single.durationMs, lessThan(60000), reason: '${entry.key}: duration of the one visit');
      }
    }, skip: 'BUG: a confirmed track that is matched again after a 10-hour gap in time stamps keeps its ID and '
        'its first-seen time, so one visit gets a 10-hour length. Only the motion-gate wake calls '
        'expireLostTracks(); returning from the background does not. Needs a time-gap rule in update().');

    test('a lost track is not revived by an insect that arrives 10 hours later', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value()..maxFrameGapMs = 3000; // the camera screen sets it from occlusionSeconds
        const box = Rect.fromLTWH(0.4, 0.4, 0.1, 0.1);
        tracker.update([det(box)], 1000);
        final id = tracker.update([det(box)], 1100).single.id;
        tracker.update(const [], 1200); // the insect leaves: track is "lost"
        // The camera stops (app in the background) and comes back 10 h later.
        tracker.update([det(box)], 1200 + 36000000);
        final tracks = tracker.update([det(box)], 1300 + 36000000);
        expect(tracks.map((t) => t.id), isNot(contains(id)), reason: '${entry.key}: old ID reused for a new insect');
        expect(tracker.drainEvents().where((e) => e.kind == TrackEventKind.removed).map((e) => e.reason),
            contains('frame_gap_expired'), reason: entry.key);
      }
    });

    test('a frame gap shorter than maxFrameGapMs keeps the lost track (insect back after 2 s)', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value()..maxFrameGapMs = 3000;
        const box = Rect.fromLTWH(0.4, 0.4, 0.1, 0.1);
        tracker.update([det(box)], 1000);
        final id = tracker.update([det(box)], 1100).single.id;
        tracker.update(const [], 1200); // lost
        final tracks = tracker.update([det(box)], 3200); // 2 s gap, under the limit
        expect(tracks.map((t) => t.id), contains(id), reason: '${entry.key}: short gap must not split the ID');
      }
    });

    test('alternating empty frames: ID kept while the buffer allows, track list never grows', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        var maxActive = 0;
        for (var f = 0; f < 400; f++) {
          final b = Rect.fromLTWH(0.2 + (f % 40) * 0.002, 0.2, 0.08, 0.08);
          // Two frames in a row first: a track that is not confirmed yet is
          // dropped at its first missed frame (by design), so it must be
          // confirmed before the detector starts to miss every second frame.
          final tracks = tracker.update(f < 2 || f.isEven ? [det(b)] : const [], 1000 + f * 100);
          expectSaneTracks(tracks, where: '${entry.key} frame $f');
          maxActive = max(maxActive, tracker.activeTrackCount);
          tracker.drainEvents();
        }
        expect(maxActive, lessThan(4), reason: entry.key);
        expect(tracker.totalConfirmed, 1, reason: '${entry.key}: a detection every second frame is one insect');
      }
    });

    test('only empty frames for 5000 frames: nothing happens, no event pile-up', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        for (var f = 0; f < 5000; f++) {
          expect(tracker.update(const [], 1000 + f * 100), isEmpty);
        }
        expect(tracker.activeTrackCount, 0);
        expect(tracker.drainEvents(), isEmpty);
      }
    });

    test('events pile up if nobody drains them (memory proxy over 20000 frames)', () {
      // FrameProcessor drains once per frame; the replay helper too. This
      // documents that update() itself keeps every event until drained.
      final tracker = ByteTracker(params: const ByteTrackParams(minHitsToConfirm: 2, trackBuffer: 1));
      for (var f = 0; f < 20000; f++) {
        tracker.update(f % 3 == 0 ? const [] : [det(Rect.fromLTWH(0.2 + (f % 7) * 0.1, 0.2, 0.05, 0.05))], 1000 + f * 100);
      }
      final events = tracker.drainEvents();
      // ignore: avoid_print
      print('undrained events after 20000 frames: ${events.length}');
      expect(events.length, lessThan(200000));
      expect(tracker.drainEvents(), isEmpty);
    });
  });

  group('long runs', () {
    test('20000 frames of 5 insects coming and going: working set and IDs stay bounded', () {
      for (final entry in kTrackers.entries) {
        final rng = Random(11);
        final tracker = entry.value();
        var peak = 0;
        final sw = Stopwatch()..start();
        for (var f = 0; f < 20000; f++) {
          final dets = <Detection>[];
          for (var k = 0; k < 5; k++) {
            if (rng.nextInt(4) == 0) continue; // 25 % of detections missed
            dets.add(det(Rect.fromLTWH(0.1 + k * 0.17 + rng.nextDouble() * 0.01, 0.3 + rng.nextDouble() * 0.01, 0.08, 0.08), 0.4 + rng.nextDouble() * 0.6));
          }
          final tracks = tracker.update(dets, 1000 + f * 120);
          tracker.drainEvents();
          if (f % 1000 == 0) expectSaneTracks(tracks, where: '${entry.key} frame $f');
          peak = max(peak, tracker.activeTrackCount);
        }
        sw.stop();
        // ignore: avoid_print
        print('${entry.key}: 20000 frames in ${sw.elapsedMilliseconds} ms, peak active $peak, '
            'counted ${tracker.totalConfirmed}');
        expect(peak, lessThan(60), reason: entry.key);
        expect(sw.elapsedMilliseconds, lessThan(30000), reason: entry.key);
      }
    });

    test('reset() after a heavy run gives a tracker that behaves like a new one', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        final rng = Random(12);
        for (var f = 0; f < 5; f++) {
          tracker.update(grid(300, rng), 1000 + f * 100);
        }
        tracker.reset();
        expect(tracker.activeTrackCount, 0);
        expect(tracker.totalConfirmed, 0);
        expect(tracker.drainEvents(), isEmpty);
        const box = Rect.fromLTWH(0.4, 0.4, 0.1, 0.1);
        tracker.update([det(box)], 500);
        final tracks = tracker.update([det(box)], 600);
        expect(tracks.single.id, 1, reason: '${entry.key}: IDs start again at 1');
      }
    });

    test('setFrameBudgets with extreme values (0, 1, 1 million) does not break update()', () {
      for (final entry in kTrackers.entries) {
        final tracker = entry.value();
        for (final (buffer, hits) in [(0, 0), (1, 1), (1000000, 1000000), (-5, -5)]) {
          tracker.setFrameBudgets(trackBuffer: buffer, minHitsToConfirm: hits);
          for (var f = 0; f < 10; f++) {
            final b = Rect.fromLTWH(0.2 + f * 0.003, 0.2, 0.08, 0.08);
            expectSaneTracks(tracker.update(f % 4 == 3 ? const [] : [det(b)], 1000 + f * 100), where: '${entry.key} $buffer/$hits');
          }
          tracker.drainEvents();
        }
      }
    });
  });

  group('tracker_replay helpers with broken input', () {
    test('parseRawDetectionLines skips a line whose boxes hold a non-number', () {
      // The doc comment says unparseable lines are skipped (a crash can cut a
      // line). A cut line is skipped, but a line that parses as JSON and has
      // null or text inside a box is not.
      final lines = [
        '{"type":"raw_detections","frame_ms":1000,"boxes":[[0.1,0.1,0.2,0.2,0.9,0]]}',
        '{"type":"raw_detections","frame_ms":1100,"boxes":[[0.1,0.1,null,0.2,0.9,0]]}',
        '{"type":"raw_detections","frame_ms":"x","boxes":[]}',
        '{"type":"raw_detections","frame_ms":1200,"boxes":[[0.1,0.1,0.2,0.2,0.9,0]]}',
      ];
      late List<ReplayFrame> frames;
      expect(() => frames = parseRawDetectionLines(lines), returnsNormally);
      expect(frames.length, greaterThanOrEqualTo(2));
      // The null box is dropped (its frame stays), the text frame_ms line is skipped.
      expect(frames.map((f) => f.timestampMs), [1000, 1100, 1200]);
      expect(frames[1].detections, isEmpty);
    });

    test('parseRawDetectionLines: cut lines, wrong types and huge numbers are skipped without an exception', () {
      final lines = [
        '',
        '   ',
        '{"type":"raw_detections","frame_ms":1000,"boxes":[[0.1,0.1,0.2',
        '[1,2,3]',
        '"text"',
        '{"type":"raw_detections","frame_ms":1000,"boxes":"none"}',
        '{"type":"raw_detections","frame_ms":1000,"boxes":[[1,2,3]]}',
        '{"type":"other","frame_ms":1000}',
        '{"type":"raw_detections","frame_ms":2000,"boxes":[[0.1,0.1,0.2,0.2,0.9,0],[1e308,0,1e308,0,1,0]]}',
        '{"type":"raw_detections","frame_ms":1500,"boxes":[]}',
      ];
      final frames = parseRawDetectionLines(lines);
      // Sorted by time, the two valid frame records and the empty one remain.
      expect(frames.map((f) => f.timestampMs), [1000, 1500, 2000]);
    });

    test('replayTracker over 3000 frames with random gaps, NaN boxes and repeated stamps', () {
      final rng = Random(21);
      final frames = <ReplayFrame>[];
      var ts = 1000;
      for (var f = 0; f < 3000; f++) {
        ts += [0, 50, 100, 150, 3500, 40000][rng.nextInt(6)];
        frames.add(ReplayFrame(timestampMs: ts, detections: [
          if (rng.nextBool()) det(Rect.fromLTWH(0.2 + rng.nextDouble() * 0.01, 0.2, 0.08, 0.08)),
          if (rng.nextInt(5) == 0) det(Rect.fromLTRB(double.nan, 0, 1, 1)),
        ]));
      }
      for (final entry in kTrackers.entries) {
        final report = replayTracker(tracker: entry.value(), frames: frames);
        expect(report.frames, 3000);
        expect(report.visitDurationsS.every((d) => d.isFinite && d >= 0), isTrue, reason: entry.key);
        expect(report.meanTrackMs.isFinite, isTrue);
      }
    });

    test('replayTracker with no frames and with one frame', () {
      for (final entry in kTrackers.entries) {
        final empty = replayTracker(tracker: entry.value(), frames: const []);
        expect(empty.visits, 0);
        expect(empty.summary(), isNotEmpty);
        final one = replayTracker(
          tracker: entry.value(),
          frames: [ReplayFrame(timestampMs: 5, detections: [det(const Rect.fromLTWH(0.1, 0.1, 0.1, 0.1))])],
        );
        expect(one.visits, 0);
      }
    });
  });
}
