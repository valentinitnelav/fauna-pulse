// Tests for SessionConfig's seconds→frames conversions and JSON round-trip.
//
// The user sets occlusion tolerance and minimum visit length in SECONDS; the
// tracker counts FRAMES. These conversions must match (round, fall back to 15
// FPS, clamp to >= 1 frame) so the tracker behaves the same regardless of the
// live frame rate.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/models/schedule_window.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';

void main() {
  group('bee-tuned defaults', () {
    test('occlusion tolerance defaults to 3 s', () {
      expect(const SessionConfig().occlusionSeconds, 3.0);
    });
    test(
      'legacy config missing occlusionSeconds falls back to 3 s, not 1 s',
      () {
        // A config saved before this key existed must load the current bee-tuned
        // buffer. The fromJson fallback used to be 1.0, silently fragmenting
        // tracks for old configs even though the constructor default was 3.0.
        final restored = SessionConfig.fromJson(const {'inferenceFps': 0});
        expect(restored.occlusionSeconds, 3.0);
      },
    );
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
      c
          .copyWith(
            autoThrottle: false,
            minInferenceFps: 5,
            throttleDutyTarget: 0.4,
          )
          .toJson(),
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
      c
          .copyWith(
            motionGateEnabled: true,
            motionGatePixelDelta: 40,
            motionGateAreaFraction: 0.01,
            motionGateWakeSeconds: 5.0,
            motionGateGridSize: 96,
          )
          .toJson(),
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
    expect(SessionConfig.fromJson(const {'inferenceFps': 0}).inferenceFps, 0);
    expect(SessionConfig.fromJson(const {}).inferenceFps, 10);
  });

  test('velocity smoothing round-trips through the config JSON', () {
    final original = const SessionConfig().copyWith(
      trackerParams: const ByteTrackParams(velocitySmoothing: 0.8),
    );
    final restored = SessionConfig.fromJson(original.toJson());
    expect(restored.trackerParams.velocitySmoothing, 0.8);
  });

  test('tracker algorithm choice + C-BIoU params round-trip (round 105)', () {
    // Defaults: field-tested ByteTrack, evaluation logging off.
    const c = SessionConfig();
    expect(c.trackerAlgorithm, TrackerAlgorithm.bytetrack);
    expect(c.cbiouParams.bufferScale1, 0.3);
    expect(c.cbiouParams.bufferScale2, 0.5);
    expect(c.cbiouParams.highThresh, 0.5);
    expect(c.logRawDetections, false);

    final restored = SessionConfig.fromJson(
      c
          .copyWith(
            trackerAlgorithm: TrackerAlgorithm.cbiou,
            cbiouParams: const CBiouParams(
              bufferScale1: 0.4,
              bufferScale2: 0.8,
              highThresh: 0.6,
            ),
            logRawDetections: true,
          )
          .toJson(),
    );
    expect(restored.trackerAlgorithm, TrackerAlgorithm.cbiou);
    expect(restored.cbiouParams.bufferScale1, 0.4);
    expect(restored.cbiouParams.bufferScale2, 0.8);
    expect(restored.cbiouParams.highThresh, 0.6);
    expect(restored.logRawDetections, true);
  });

  test('still sync companion round-trips and defaults ON (round 108)', () {
    // Default on: the companion guards dataset completeness; and a config
    // saved before the key existed must also load as on.
    expect(const SessionConfig().stillSyncCompanion, true);
    expect(SessionConfig.fromJson(const {}).stillSyncCompanion, true);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(stillSyncCompanion: false).toJson(),
    );
    expect(restored.stillSyncCompanion, false);
  });

  test('ground-truth frame dump settings round-trip (round 107)', () {
    const c = SessionConfig();
    expect(c.gtFramesEnabled, false);
    expect(c.gtFrameSeconds, 5.0);
    final restored = SessionConfig.fromJson(
      c.copyWith(gtFramesEnabled: true, gtFrameSeconds: 30.0).toJson(),
    );
    expect(restored.gtFramesEnabled, true);
    expect(restored.gtFrameSeconds, 30.0);
    // Configs saved before the fields existed load the defaults.
    expect(SessionConfig.fromJson(const {}).gtFramesEnabled, false);
    expect(SessionConfig.fromJson(const {}).gtFrameSeconds, 5.0);
  });

  test('configs saved before round 105 load as ByteTrack', () {
    // No trackerAlgorithm key at all, and an unknown name: both must fall
    // back to the algorithm those sessions actually used.
    expect(
      SessionConfig.fromJson(const {}).trackerAlgorithm,
      TrackerAlgorithm.bytetrack,
    );
    expect(
      SessionConfig.fromJson(const {
        'trackerAlgorithm': 'not-a-tracker',
      }).trackerAlgorithm,
      TrackerAlgorithm.bytetrack,
    );
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
            .copyWith(captureMode: RoiCaptureMode.still, targetRoiSavedPx: 512)
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
      expect(SessionConfig.fromJson(const {}).captureMode, RoiCaptureMode.auto);
    });
  });

  test('camera fps cap: default 15, 0 survives, missing key falls back', () {
    // Round 82: caps the camera HARDWARE rate (sensor/ISP), unlike
    // inferenceFps which only skips delivered frames in software.
    expect(const SessionConfig().cameraFpsCap, 15);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(cameraFpsCap: 24).toJson(),
    );
    expect(restored.cameraFpsCap, 24);
    // An explicitly saved 0 (device default) must survive the round-trip —
    // only a MISSING key falls back to the 15 default (mirrors inferenceFps).
    expect(SessionConfig.fromJson(const {'cameraFpsCap': 0}).cameraFpsCap, 0);
    expect(SessionConfig.fromJson(const {}).cameraFpsCap, 15);
  });

  test('crop 1:1 lock: default off, survives the JSON round-trip', () {
    expect(const SessionConfig().cropSquareLock, false);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(cropSquareLock: true).toJson(),
    );
    expect(restored.cropSquareLock, true);
    // Configs saved before the key existed fall back to off.
    expect(SessionConfig.fromJson(const {}).cropSquareLock, false);
  });

  test('gate idle check rate: default 5, survives the JSON round-trip', () {
    expect(const SessionConfig().motionGateIdleFps, 5);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(motionGateIdleFps: 12).toJson(),
    );
    expect(restored.motionGateIdleFps, 12);
  });

  group('capture trigger (r97 enum, replaces the r95 motionOnlyCapture bool)', () {
    test('defaults to the AI detector', () {
      const c = SessionConfig();
      expect(c.captureTrigger, CaptureTrigger.detector);
      expect(c.detectorEnabled, true);
      expect(c.motionOnlyCapture, false);
      expect(c.timeLapseCapture, false);
    });

    test('round-trips through toJson/fromJson', () {
      for (final t in CaptureTrigger.values) {
        final restored = SessionConfig.fromJson(
          const SessionConfig().copyWith(captureTrigger: t).toJson(),
        );
        expect(restored.captureTrigger, t);
      }
    });

    test('legacy r95 motionOnlyCapture:true loads as the motion trigger', () {
      final restored = SessionConfig.fromJson(const {
        'motionOnlyCapture': true,
      });
      expect(restored.captureTrigger, CaptureTrigger.motion);
      expect(restored.motionOnlyCapture, true);
    });

    test('configs without either key default to detector', () {
      expect(
        SessionConfig.fromJson(const {}).captureTrigger,
        CaptureTrigger.detector,
      );
    });

    test('toJson still writes the legacy motionOnlyCapture bool', () {
      // One-generation compatibility, mirroring captureMode/fullResPhotos.
      final j = const SessionConfig()
          .copyWith(captureTrigger: CaptureTrigger.motion)
          .toJson();
      expect(j['motionOnlyCapture'], true);
      expect(j['captureTrigger'], 'motion');
    });
  });

  test('time-lapse burst interval: default 30 min, survives the round-trip', () {
    expect(const SessionConfig().timeLapseIntervalSeconds, 1800.0);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(timeLapseIntervalSeconds: 600.0).toJson(),
    );
    expect(restored.timeLapseIntervalSeconds, 600.0);
    // Configs saved before the key existed fall back to the default.
    expect(SessionConfig.fromJson(const {}).timeLapseIntervalSeconds, 1800.0);
  });

  group('scheduled recording', () {
    test('defaults: off, one 06:00–10:00 window, 1 day', () {
      const c = SessionConfig();
      expect(c.scheduleEnabled, false);
      expect(c.scheduleWindows, const [ScheduleWindow(360, 600)]);
      expect(c.scheduleDays, 1);
      expect(c.isScheduleValid, true);
    });

    test('round-trips through toJson/fromJson', () {
      final restored = SessionConfig.fromJson(
        const SessionConfig()
            .copyWith(
              scheduleEnabled: true,
              scheduleWindows: const [
                ScheduleWindow(360, 600), // 06:00–10:00
                ScheduleWindow(900, 1200), // 15:00–20:00
              ],
              scheduleDays: 2,
            )
            .toJson(),
      );
      expect(restored.scheduleEnabled, true);
      expect(restored.scheduleWindows, const [
        ScheduleWindow(360, 600),
        ScheduleWindow(900, 1200),
      ]);
      expect(restored.scheduleDays, 2);
    });

    test('legacy configs without the keys fall back to defaults', () {
      final restored = SessionConfig.fromJson(const {'inferenceFps': 0});
      expect(restored.scheduleEnabled, false);
      expect(restored.scheduleWindows, const [ScheduleWindow(360, 600)]);
      expect(restored.scheduleDays, 1);
    });

    test('malformed window entries are dropped, garbage list falls back', () {
      final restored = SessionConfig.fromJson(const {
        'scheduleWindows': [
          {'start': 900, 'end': 1200},
          {'start': 'six', 'end': 600}, // malformed → dropped
          42, // malformed → dropped
          {'start': 700, 'end': 650}, // start >= end → dropped
        ],
      });
      expect(restored.scheduleWindows, const [ScheduleWindow(900, 1200)]);
      // A non-list value falls back to the default window.
      expect(
        SessionConfig.fromJson(const {'scheduleWindows': 'no'}).scheduleWindows,
        const [ScheduleWindow(360, 600)],
      );
    });

    test('windows load sorted by start and capped at 3', () {
      final restored = SessionConfig.fromJson(const {
        'scheduleWindows': [
          {'start': 900, 'end': 960},
          {'start': 60, 'end': 120},
          {'start': 360, 'end': 600},
          {'start': 1300, 'end': 1400},
        ],
      });
      expect(restored.scheduleWindows, const [
        ScheduleWindow(60, 120),
        ScheduleWindow(360, 600),
        ScheduleWindow(900, 960),
      ]);
    });

    test('isScheduleValid rejects overlapping windows', () {
      final c = const SessionConfig().copyWith(
        scheduleWindows: const [
          ScheduleWindow(360, 600),
          ScheduleWindow(540, 720), // overlaps the first
        ],
      );
      expect(c.isScheduleValid, false);
      // Touching ends (one starts exactly when the other ends) are fine.
      final touching = const SessionConfig().copyWith(
        scheduleWindows: const [
          ScheduleWindow(360, 600),
          ScheduleWindow(600, 720),
        ],
      );
      expect(touching.isScheduleValid, true);
    });

    test('scheduleDays clamps to at least 1 on load', () {
      expect(SessionConfig.fromJson(const {'scheduleDays': 0}).scheduleDays, 1);
      expect(
        SessionConfig.fromJson(const {'scheduleDays': -3}).scheduleDays,
        1,
      );
    });
  });
}
