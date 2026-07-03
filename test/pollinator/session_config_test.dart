// Tests for SessionConfig's seconds→frames conversions and JSON round-trip.
//
// The user sets occlusion tolerance and minimum visit length in SECONDS; the
// tracker counts FRAMES. These conversions must match (round, fall back to 15
// FPS, clamp to >= 1 frame) so the tracker behaves the same regardless of the
// live frame rate.

import 'package:flutter_test/flutter_test.dart';
import 'package:pollinator_monitor/pollinator/models/session_config.dart';
import 'package:pollinator_monitor/pollinator/tracking/byte_track.dart';

void main() {
  group('bee-tuned defaults', () {
    test('occlusion tolerance defaults to 3 s', () {
      expect(const SessionConfig().occlusionSeconds, 3.0);
    });
    test('match overlap defaults to 0.1', () {
      expect(const ByteTrackParams().matchThresh, 0.1);
    });
  });

  test('auto-throttle defaults and round-trip', () {
    const c = SessionConfig();
    expect(c.autoThrottle, true);
    expect(c.minInferenceFps, 3);
    expect(c.throttleDutyTarget, 0.5);
    final restored = SessionConfig.fromJson(
      c.copyWith(
        autoThrottle: false,
        minInferenceFps: 5,
        throttleDutyTarget: 0.4,
      ).toJson(),
    );
    expect(restored.autoThrottle, false);
    expect(restored.minInferenceFps, 5);
    expect(restored.throttleDutyTarget, 0.4);
  });

  test('older logs without auto-throttle fields fall back to defaults', () {
    final restored = SessionConfig.fromJson(const {'inferenceFps': 0});
    expect(restored.autoThrottle, true);
    expect(restored.minInferenceFps, 3);
    expect(restored.throttleDutyTarget, 0.5);
  });

  test('motion gate defaults (off) and round-trip', () {
    const c = SessionConfig();
    expect(c.motionGateEnabled, false); // opt-in until validated
    expect(c.motionGatePixelDelta, 25);
    expect(c.motionGateAreaFraction, 0.005);
    expect(c.motionGateWakeSeconds, 3.0);
    expect(c.motionGateGridSize, 48);
    final restored = SessionConfig.fromJson(
      c.copyWith(
        motionGateEnabled: true,
        motionGatePixelDelta: 40,
        motionGateAreaFraction: 0.01,
        motionGateWakeSeconds: 5.0,
        motionGateGridSize: 96,
      ).toJson(),
    );
    expect(restored.motionGateEnabled, true);
    expect(restored.motionGatePixelDelta, 40);
    expect(restored.motionGateAreaFraction, 0.01);
    expect(restored.motionGateWakeSeconds, 5.0);
    expect(restored.motionGateGridSize, 96);
  });

  test('older configs without motion-gate fields fall back to defaults', () {
    final restored = SessionConfig.fromJson(const {'inferenceFps': 0});
    expect(restored.motionGateEnabled, false);
    expect(restored.motionGatePixelDelta, 25);
    expect(restored.motionGateAreaFraction, 0.005);
    expect(restored.motionGateWakeSeconds, 3.0);
    expect(restored.motionGateGridSize, 48);
  });

  test('default inference cap is a deliberate 10/s (0 stays uncapped)', () {
    expect(const SessionConfig().inferenceFps, 10);
    // An explicitly saved 0 (uncapped) must survive the round-trip — only a
    // MISSING key falls back to the new default.
    expect(
      SessionConfig.fromJson(const {'inferenceFps': 0}).inferenceFps,
      0,
    );
    expect(SessionConfig.fromJson(const {}).inferenceFps, 10);
  });

  test('velocity smoothing round-trips through the config JSON', () {
    final original = const SessionConfig().copyWith(
      trackerParams: const ByteTrackParams(velocitySmoothing: 0.8),
    );
    final restored = SessionConfig.fromJson(original.toJson());
    expect(restored.trackerParams.velocitySmoothing, 0.8);
  });

  group('minHitsFramesFor', () {
    test('multiplies seconds by FPS and rounds', () {
      const c = SessionConfig(minHitsSeconds: 0.2);
      expect(c.minHitsFramesFor(15), 3); // 0.2 * 15 = 3
      expect(c.minHitsFramesFor(30), 6); // 0.2 * 30 = 6
    });

    test('falls back to 15 FPS before a real measurement', () {
      const c = SessionConfig(minHitsSeconds: 0.2);
      expect(c.minHitsFramesFor(0), 3);
      expect(c.minHitsFramesFor(double.nan), 3);
    });

    test('clamps to at least 1 frame so a track can always confirm', () {
      const c = SessionConfig(minHitsSeconds: 0.0);
      expect(c.minHitsFramesFor(30), 1);
    });

    test('matches occlusionFramesFor rounding behaviour', () {
      // Same arithmetic as the verified occlusion conversion.
      const occ = SessionConfig(occlusionSeconds: 0.5);
      const hits = SessionConfig(minHitsSeconds: 0.5);
      expect(hits.minHitsFramesFor(20), occ.occlusionFramesFor(20)); // both 10
    });
  });

  test('minHitsSeconds round-trips through toJson/fromJson', () {
    const original = SessionConfig(minHitsSeconds: 0.4);
    final restored = SessionConfig.fromJson(original.toJson());
    expect(restored.minHitsSeconds, 0.4);
  });

  test('older logs without minHitsSeconds fall back to the default', () {
    // A config map recorded before this field existed.
    final restored = SessionConfig.fromJson(const {'occlusionSeconds': 1.0});
    expect(restored.minHitsSeconds, 0.2);
  });

  group('capture mode & saved-size target', () {
    test('defaults: auto, target 1024', () {
      const c = SessionConfig();
      expect(c.captureMode, RoiCaptureMode.auto);
      expect(c.targetRoiSavedPx, 1024);
    });

    test('round-trips through toJson/fromJson', () {
      final restored = SessionConfig.fromJson(
        const SessionConfig()
            .copyWith(
              captureMode: RoiCaptureMode.still,
              targetRoiSavedPx: 512,
            )
            .toJson(),
      );
      expect(restored.captureMode, RoiCaptureMode.still);
      expect(restored.targetRoiSavedPx, 512);
    });

    test('round-62 min/max configs migrate: the min becomes the target', () {
      final restored = SessionConfig.fromJson(const {
        'captureMode': 'auto',
        'minRoiSavedPx': 640,
        'maxRoiSavedPx': 1280,
      });
      expect(restored.targetRoiSavedPx, 640);
    });

    test('legacy fullResPhotos=true loads as still mode', () {
      final restored = SessionConfig.fromJson(const {'fullResPhotos': true});
      expect(restored.captureMode, RoiCaptureMode.still);
    });

    test('legacy fullResPhotos=false keeps its fast-only behaviour', () {
      // An old setup must not silently switch to auto (which can take stills).
      final restored = SessionConfig.fromJson(const {'fullResPhotos': false});
      expect(restored.captureMode, RoiCaptureMode.fast);
    });

    test('configs without either key get the new auto default', () {
      expect(
        SessionConfig.fromJson(const {}).captureMode,
        RoiCaptureMode.auto,
      );
    });
  });

  test('gate idle check rate: default 5, survives the JSON round-trip', () {
    expect(const SessionConfig().motionGateIdleFps, 5);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(motionGateIdleFps: 12).toJson(),
    );
    expect(restored.motionGateIdleFps, 12);
  });
}
