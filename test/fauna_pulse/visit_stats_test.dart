// Unit tests for the summary Graphs tab's per-session visit statistics
// (round 187): visit-length histogram binning (incl. the overflow bar) and
// the visits-by-hour counts.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/visit_stats.dart';

void main() {
  group('visitDurationHistogram', () {
    test('empty input yields an empty histogram', () {
      final h = visitDurationHistogram(const [], 1);
      expect(h.values, isEmpty);
      expect(h.overflow, isFalse);
    });

    test('bins by width; boundary values land in the upper bin', () {
      // 0.4 s, 1.9 s → bin 0 and 1 at 1 s bins; an exact 2.0 s boundary
      // belongs to bin 2 (bins are [i*bin, (i+1)*bin)).
      final h = visitDurationHistogram(const [400, 1900, 2000], 1);
      expect(h.values, [1, 1, 1]);
      expect(h.binSeconds, 1);
      expect(h.overflow, isFalse);
      expect(h.binStartSeconds(2), 2);
    });

    test('wider bins merge visits', () {
      final h = visitDurationHistogram(const [400, 1900, 2000, 9000], 5);
      // 0–5 s: three visits; 5–10 s: one.
      expect(h.values, [3, 1]);
    });

    test('long tails collapse into the overflow bar', () {
      // At 1 s bins a 2-hour visit would need 7200 bars; everything at/over
      // bar 60 lands in the last one instead.
      final h = visitDurationHistogram(const [500, 7200000], 1, maxBars: 60);
      expect(h.values.length, 60);
      expect(h.values.first, 1);
      expect(h.values.last, 1);
      expect(h.overflow, isTrue);
    });

    test('negative/zero durations count in bin 0, never crash', () {
      final h = visitDurationHistogram(const [-5, 0], 1);
      expect(h.values, [2]);
    });
  });

  group('visitsByHour', () {
    test('counts visit starts per local hour', () {
      int at(int hour, int minute) =>
          DateTime(2026, 8, 5, hour, minute).millisecondsSinceEpoch;
      final byHour = visitsByHour([at(9, 15), at(9, 59), at(17, 0)]);
      expect(byHour.length, 24);
      expect(byHour[9], 2);
      expect(byHour[17], 1);
      expect(byHour.reduce((a, b) => a + b), 3);
    });
  });

  group('compactSecondsLabel', () {
    test('seconds, minutes, hours', () {
      expect(compactSecondsLabel(0), '0s');
      expect(compactSecondsLabel(45), '45s');
      expect(compactSecondsLabel(60), '1m');
      expect(compactSecondsLabel(90), '1.5m');
      expect(compactSecondsLabel(300), '5m');
      expect(compactSecondsLabel(3600), '1h');
      expect(compactSecondsLabel(5400), '1.5h');
    });
  });
}
