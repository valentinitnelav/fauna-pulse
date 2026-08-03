// Tests for the always-manual focus preset math (round 164):
// focusPresetNormalized maps the 7.5-dioptre (~13 cm) target onto the
// slider's 0..1 scale, given the lens's own closest-focus ability, exactly
// inverting the native linear mapping (normalized × maxDioptres).

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/session/camera_diagnostics_controller.dart';

void main() {
  test('the preset targets 7.5 dioptres (~13 cm)', () {
    expect(kFocusPresetDioptres, 7.5);
  });

  test('a lens focusing closer than the target lands mid-slider', () {
    // A typical main lens: closest focus 10 dioptres (10 cm).
    expect(focusPresetNormalized(10), 0.75);
    // A macro-ish lens: closest 15 dioptres → the target sits at half.
    expect(focusPresetNormalized(15), 0.5);
  });

  test('a lens that cannot reach 13 cm clamps to its own closest (1.0)', () {
    // Closest focus 5 dioptres = 20 cm: the target is beyond its ability.
    expect(focusPresetNormalized(5), 1.0);
    // Exactly the target: full slider, no clamp needed.
    expect(focusPresetNormalized(7.5), 1.0);
  });

  test('fixed-focus lenses (range 0 or bogus) yield 0', () {
    expect(focusPresetNormalized(0), 0);
    expect(focusPresetNormalized(-1), 0);
  });

  test('round-trip: normalized × range recovers the target when reachable', () {
    for (final range in [7.5, 8.0, 10.0, 12.5, 20.0]) {
      expect(focusPresetNormalized(range) * range, closeTo(7.5, 1e-9));
    }
  });

  test('a custom target dioptre value is honoured', () {
    // 5 dioptres = 20 cm on a 10-dioptre lens → half the slider.
    expect(focusPresetNormalized(10, targetDioptres: 5), 0.5);
  });
}
