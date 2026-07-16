// Tests for the round-114 photo↔detections time-matching rules
// (logging/photo_box_matcher.dart): content-moment derivation, adaptive
// tolerance, ROI-move rejection, and the bounded nearest-frame accumulator.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/photo_box_matcher.dart';

void main() {
  group('contentMomentOf', () {
    test('prefers the measured content_at_ms (r114+ logs)', () {
      final m = contentMomentOf(const {
        'content_at_ms': 1000500,
        'captured_at_ms': 1000000,
        'content_lag_ms': 400.0,
        'live_lag_ms': 30,
      });
      expect(m, isNotNull);
      expect(m!.ms, 1000500);
      expect(m.approx, isFalse);
    });

    test('reconstructs r108–113 logs from the lags, flagged approximate', () {
      // content_lag_ms is measured from takePicture(), which runs AFTER the
      // trigger by the dispatch gap the companion grab causes — live_lag_ms
      // brackets that gap, so it is added in.
      final m = contentMomentOf(const {
        'captured_at_ms': 1000000,
        'content_lag_ms': 400.0,
        'live_lag_ms': 30,
      });
      expect(m, isNotNull);
      expect(m!.ms, 1000430);
      expect(m.approx, isTrue);
    });

    test('reconstruction works without live_lag_ms (pre-r112 logs)', () {
      final m = contentMomentOf(const {
        'captured_at_ms': 1000000,
        'content_lag_ms': 400.0,
      });
      expect(m!.ms, 1000400);
      expect(m.approx, isTrue);
    });

    test('fast-path captures (no content lag) have no content moment', () {
      expect(contentMomentOf(const {'captured_at_ms': 1000000}), isNull);
      expect(contentMomentOf(const {}), isNull);
    });
  });

  group('toleranceMs', () {
    test('floors at 250 ms for fast detectors', () {
      // 10 FPS → 100 ms median → 150 ms would be too twitchy; floor applies.
      expect(toleranceMs(List.filled(50, 100)), 250);
      expect(toleranceMs(const []), 250);
    });

    test('scales with the median interval on throttled sessions', () {
      // 3 FPS throttle floor → 333 ms median → 1.5× = 500 ms.
      expect(toleranceMs(List.filled(50, 333)), 500);
    });

    test('uses the median, not the mean (gate gaps must not inflate it)', () {
      // Mostly 100 ms cadence with a few multi-second gate-sleep gaps.
      final intervals = [...List.filled(99, 100), 30000, 45000];
      expect(toleranceMs(intervals), 250); // median still 100 → floor
    });
  });

  group('roiMovedInWindow', () {
    test('rejects an update inside (trigger, content + stamp lag]', () {
      // roi_update stamps are debounced ~2 s late, hence the widened window.
      expect(roiMovedInWindow([1000200], 1000000, 1000400), isTrue);
      expect(
        roiMovedInWindow([1000400 + kRoiUpdateStampLagMs], 1000000, 1000400),
        isTrue,
      );
    });

    test('ignores updates before the trigger or after the widened window', () {
      expect(roiMovedInWindow([999000], 1000000, 1000400), isFalse);
      expect(
        roiMovedInWindow(
          [1000400 + kRoiUpdateStampLagMs + 1],
          1000000,
          1000400,
        ),
        isFalse,
      );
      expect(roiMovedInWindow(const [], 1000000, 1000400), isFalse);
    });
  });

  group('FrameBracketAccumulator', () {
    List<Map<String, dynamic>> tracksAt(int n) => [
      {
        'track_id': n,
        'box_in_roi': {'left': 0.1, 'top': 0.1, 'right': 0.2, 'bottom': 0.2},
      },
    ];

    test('keeps the nearest frame on EACH side independently', () {
      final acc = FrameBracketAccumulator({'a.jpg': 1000400});
      acc.feed(1000000, tracksAt(1)); // 400 ms early
      acc.feed(1000350, tracksAt(2)); // 50 ms early — better before
      acc.feed(1000900, tracksAt(3)); // 500 ms late — the after side
      acc.feed(1000700, tracksAt(4)); // 300 ms late — better after
      final b = acc.bracketOf('a.jpg');
      expect(b.before!.deltaMs, -50);
      expect(b.before!.tracks.single['track_id'], 2);
      expect(b.after!.deltaMs, 300);
      expect(b.after!.tracks.single['track_id'], 4);
    });

    test('an exact hit (delta 0) lands on the BEFORE side', () {
      // Keeps the interpolation denominator (after − before) > 0.
      final acc = FrameBracketAccumulator({'a.jpg': 1000400});
      acc.feed(1000400, tracksAt(1));
      final b = acc.bracketOf('a.jpg');
      expect(b.before!.deltaMs, 0);
      expect(b.after, isNull);
    });

    test('frames beyond the window are dropped', () {
      final acc = FrameBracketAccumulator({'a.jpg': 1000000}, windowMs: 1500);
      acc.feed(998499, tracksAt(1)); // 1501 ms early — out
      acc.feed(1001501, tracksAt(2)); // 1501 ms late — out
      final b = acc.bracketOf('a.jpg');
      expect(b.before, isNull);
      expect(b.after, isNull);
    });

    test('one frame serves EVERY photo within the window — a capture pause '
        'spanning two photos must not starve the second (r115 fix)', () {
      // Photos at 1000 and 2000; frames only at 900 and 2500 (a single
      // detector hole covers both content moments). The r114 accumulator
      // offered a frame only to its two binary-search neighbours, so the
      // photo at 1000 never saw the 2500 frame.
      final acc = FrameBracketAccumulator({
        'a.jpg': 1000,
        'b.jpg': 2000,
      }, windowMs: 1500);
      acc.feed(900, tracksAt(1));
      acc.feed(2500, tracksAt(2));
      final a = acc.bracketOf('a.jpg');
      final b = acc.bracketOf('b.jpg');
      expect(a.before!.deltaMs, -100);
      expect(a.after!.deltaMs, 1500); // received despite b sitting between
      expect(b.before!.deltaMs, -1100);
      expect(b.after!.deltaMs, 500);
    });

    test('empty frames and photo-less sessions are no-ops', () {
      final acc = FrameBracketAccumulator({});
      acc.feed(1000000, tracksAt(1)); // no photos — must not throw
      final acc2 = FrameBracketAccumulator({'a.jpg': 1000000});
      acc2.feed(1000000, const []); // trackless frame carries no boxes
      expect(acc2.bracketOf('a.jpg').before, isNull);
    });
  });

  group('buildPhotoBoxes', () {
    Map<String, dynamic> entry(
      int id,
      double l,
      double t,
      double r,
      double b, {
      double conf = 0.5,
      String? jpeg,
    }) => {
      'track_id': id,
      'class_name': 'bee',
      'confidence': conf,
      'box_in_roi': {'left': l, 'top': t, 'right': r, 'bottom': b},
      'jpeg': ?jpeg,
    };

    test('same track on both sides interpolates each edge (midpoint)', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: -200, tracks: [
          entry(4, 0.2, 0.2, 0.4, 0.4),
        ]),
        after: MatchedFrame(deltaMs: 200, tracks: [
          entry(4, 0.4, 0.4, 0.6, 0.6),
        ]),
        photoFile: 'p.jpg',
      );
      final box = res!.boxes.single;
      expect(box.interpolated, isTrue);
      expect(box.left, closeTo(0.3, 1e-9));
      expect(box.top, closeTo(0.3, 1e-9));
      expect(box.right, closeTo(0.5, 1e-9));
      expect(box.bottom, closeTo(0.5, 1e-9));
      expect(box.beforeDeltaMs, -200);
      expect(box.afterDeltaMs, 200);
      expect(res.anyInterpolated, isTrue);
      expect(res.allInterpolated, isTrue);
      expect(res.nearestAbsDeltaMs, 200);
    });

    test('asymmetric bracket weights by time (−100/+300 → w = 0.25)', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: -100, tracks: [
          entry(4, 0.0, 0.0, 0.2, 0.2),
        ]),
        after: MatchedFrame(deltaMs: 300, tracks: [
          entry(4, 0.4, 0.4, 0.6, 0.6),
        ]),
        photoFile: 'p.jpg',
      );
      final box = res!.boxes.single;
      expect(box.left, closeTo(0.1, 1e-9)); // 0 + 0.25 × 0.4
      // Confidence comes from the NEARER frame (before, 100 ms away).
      expect(box.confidence, 0.5);
    });

    test('a before frame at delta 0 yields exactly its own box', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: 0, tracks: [
          entry(4, 0.2, 0.2, 0.4, 0.4),
        ]),
        after: MatchedFrame(deltaMs: 400, tracks: [
          entry(4, 0.8, 0.8, 0.9, 0.9),
        ]),
        photoFile: 'p.jpg',
      );
      expect(res!.boxes.single.left, closeTo(0.2, 1e-9));
    });

    test('a track on one side only is emitted verbatim, uninterpolated — '
        'even from the farther frame', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: -100, tracks: [
          entry(4, 0.2, 0.2, 0.4, 0.4),
        ]),
        after: MatchedFrame(deltaMs: 300, tracks: [
          entry(4, 0.4, 0.4, 0.6, 0.6),
          entry(9, 0.7, 0.7, 0.9, 0.9), // only in the farther (after) frame
        ]),
        photoFile: 'p.jpg',
      );
      expect(res!.boxes, hasLength(2));
      final nine = res.boxes.singleWhere((b) => b.trackId == 9);
      expect(nine.interpolated, isFalse);
      expect(nine.left, closeTo(0.7, 1e-9));
      expect(nine.beforeDeltaMs, isNull);
      expect(nine.afterDeltaMs, 300);
      expect(res.anyInterpolated, isTrue);
      expect(res.allInterpolated, isFalse); // the mixed-photo case
    });

    test('bracket span beyond the gap cap degrades to the nearer frame', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: -1400, tracks: [
          entry(4, 0.2, 0.2, 0.4, 0.4),
        ]),
        after: MatchedFrame(deltaMs: 1400, tracks: [
          entry(4, 0.6, 0.6, 0.8, 0.8),
        ]),
        photoFile: 'p.jpg',
        maxTotalGapMs: 2000,
      );
      final box = res!.boxes.single;
      expect(box.interpolated, isFalse);
      // Symmetric span: |−1400| ≤ 1400 keeps the before frame.
      expect(box.left, closeTo(0.2, 1e-9));
      expect(res.anyInterpolated, isFalse);
    });

    test('single-side brackets work and both-null returns null', () {
      final only = buildPhotoBoxes(
        before: null,
        after: MatchedFrame(deltaMs: 410, tracks: [
          entry(4, 0.4, 0.4, 0.6, 0.6),
        ]),
        photoFile: 'p.jpg',
      );
      expect(only!.boxes.single.afterDeltaMs, 410);
      expect(only.nearestAbsDeltaMs, 410);
      expect(buildPhotoBoxes(before: null, after: null, photoFile: 'p.jpg'),
          isNull);
    });

    test('triggered propagates from EITHER contributing entry', () {
      final res = buildPhotoBoxes(
        before: MatchedFrame(deltaMs: -100, tracks: [
          entry(4, 0.2, 0.2, 0.4, 0.4, jpeg: 'p.jpg'),
        ]),
        after: MatchedFrame(deltaMs: 100, tracks: [
          entry(4, 0.4, 0.4, 0.6, 0.6),
        ]),
        photoFile: 'p.jpg',
      );
      expect(res!.boxes.single.triggered, isTrue);
    });
  });
}
