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

  group('NearestFrameAccumulator', () {
    List<Map<String, dynamic>> tracksAt(int n) => [
      {'track_id': n},
    ];

    test('keeps the nearest frame per photo, replacing worse candidates', () {
      final acc = NearestFrameAccumulator({'a.jpg': 1000400});
      acc.feed(1000000, tracksAt(1)); // 400 ms early
      acc.feed(1000350, tracksAt(2)); // 50 ms early — better
      acc.feed(1000900, tracksAt(3)); // 500 ms late — worse, ignored
      final m = acc.best['a.jpg'];
      expect(m, isNotNull);
      expect(m!.deltaMs, -50);
      expect(m.tracks.single['track_id'], 2);
    });

    test('routes each frame to its nearest photos only (binary search)', () {
      final acc = NearestFrameAccumulator({
        'a.jpg': 1000000,
        'b.jpg': 1002000,
        'c.jpg': 1004000,
      });
      acc.feed(1001900, tracksAt(7)); // nearest to b (−100)
      expect(acc.best['b.jpg']!.deltaMs, -100);
      // a may hold it as a distant candidate; c (2100 ms away, beyond both
      // neighbours) must not.
      expect(acc.best['c.jpg'], isNull);
    });

    test('empty frames and photo-less sessions are no-ops', () {
      final acc = NearestFrameAccumulator({});
      acc.feed(1000000, tracksAt(1)); // no photos — must not throw
      expect(acc.best, isEmpty);
      final acc2 = NearestFrameAccumulator({'a.jpg': 1000000});
      acc2.feed(1000000, const []); // trackless frame carries no boxes
      expect(acc2.best, isEmpty);
    });
  });
}
