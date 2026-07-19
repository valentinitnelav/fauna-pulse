// Tests for RoiUpdateDebouncer (round 109): a drag's many change ticks must
// settle into ONE roi_update write of the final geometry, an adjustment that
// ends back where it started must write nothing, and a stop-flush must never
// lose the last pending value.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/logging/roi_update_debouncer.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';

void main() {
  Roi roi(double side) => Roi(centerX: 0.5, centerY: 0.5, sideFraction: side);

  test(
    'a burst of ticks writes once, with the LAST value, after the delay',
    () {
      fakeAsync((async) {
        final d = RoiUpdateDebouncer();
        final written = <Roi>[];
        d.seed(roi(0.45));
        for (var i = 10; i <= 30; i++) {
          d.notify(roi(i / 100), written.add);
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(written, isEmpty); // still mid-drag: every tick reset the timer
        async.elapse(const Duration(seconds: 2));
        expect(written, hasLength(1));
        expect(written.single.sideFraction, closeTo(0.30, 1e-9));
      });
    },
  );

  test('a drag that settles back on the last logged value writes nothing', () {
    fakeAsync((async) {
      final d = RoiUpdateDebouncer();
      final written = <Roi>[];
      d.seed(roi(0.45));
      d.notify(roi(0.30), written.add);
      d.notify(roi(0.45), written.add); // back to the seeded start value
      async.elapse(const Duration(seconds: 3));
      expect(written, isEmpty);
    });
  });

  test('flush writes a still-pending value immediately (stop path)', () {
    fakeAsync((async) {
      final d = RoiUpdateDebouncer();
      final written = <Roi>[];
      d.seed(roi(0.45));
      d.notify(roi(0.25), written.add);
      async.elapse(const Duration(milliseconds: 500)); // timer hasn't fired
      d.flush(written.add);
      expect(written, hasLength(1));
      expect(written.single.sideFraction, closeTo(0.25, 1e-9));
      // Nothing left: a second flush (or the dead timer) must not re-write.
      d.flush(written.add);
      async.elapse(const Duration(seconds: 5));
      expect(written, hasLength(1));
    });
  });

  test('a second adjustment to a NEW value logs again', () {
    fakeAsync((async) {
      final d = RoiUpdateDebouncer();
      final written = <Roi>[];
      d.seed(roi(0.45));
      d.notify(roi(0.25), written.add);
      async.elapse(const Duration(seconds: 2));
      d.notify(roi(0.35), written.add);
      async.elapse(const Duration(seconds: 2));
      expect(written.map((r) => r.sideFraction), [
        closeTo(0.25, 1e-9),
        closeTo(0.35, 1e-9),
      ]);
    });
  });

  test('cancel drops the pending value without writing (dispose path)', () {
    fakeAsync((async) {
      final d = RoiUpdateDebouncer();
      final written = <Roi>[];
      d.seed(roi(0.45));
      d.notify(roi(0.25), written.add);
      d.cancel();
      async.elapse(const Duration(seconds: 5));
      d.flush(written.add); // nothing pending anymore either
      expect(written, isEmpty);
    });
  });

  // Round 132: the generic base class with the default `==` equality, as the
  // camera screen uses it for focus changes (a Dart record type — structural
  // equality makes seed/no-op detection work without a custom comparator).
  test('SettledUpdateDebouncer settles record values with == equality', () {
    fakeAsync((async) {
      final d = SettledUpdateDebouncer<({bool manual, double value})>();
      final written = <({bool manual, double value})>[];
      d.seed((manual: false, value: 0));
      // Slider drag: many ticks, one settled write of the last value.
      for (var i = 1; i <= 5; i++) {
        d.notify((manual: true, value: i / 10), written.add);
        async.elapse(const Duration(milliseconds: 100));
      }
      async.elapse(const Duration(seconds: 2));
      expect(written, [(manual: true, value: 0.5)]);
      // Reset back to the seeded auto state: writes the change…
      d.notify((manual: false, value: 0), written.add);
      async.elapse(const Duration(seconds: 2));
      expect(written, hasLength(2));
      // …but notifying the SAME state again is a no-op.
      d.notify((manual: false, value: 0), written.add);
      async.elapse(const Duration(seconds: 2));
      expect(written, hasLength(2));
    });
  });
}
