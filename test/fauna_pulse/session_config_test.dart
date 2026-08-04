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

  test('high-res sync companion round-trips and defaults ON (round 108)', () {
    // Default on: the companion guards dataset completeness; and a config
    // saved before the key existed must also load as on.
    expect(const SessionConfig().highResSyncCompanion, true);
    expect(SessionConfig.fromJson(const {}).highResSyncCompanion, true);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(highResSyncCompanion: false).toJson(),
    );
    expect(restored.highResSyncCompanion, false);
  });

  test('reference photo settings round-trip and default ON (r107 gt keys)', () {
    // Promotion round: on by default, every 30 s (was off / 5 s in r107).
    const c = SessionConfig();
    expect(c.gtFramesEnabled, true);
    expect(c.gtFrameSeconds, 30.0);
    final restored = SessionConfig.fromJson(
      c.copyWith(gtFramesEnabled: false, gtFrameSeconds: 5.0).toJson(),
    );
    expect(restored.gtFramesEnabled, false);
    expect(restored.gtFrameSeconds, 5.0);
    // Configs saved before the fields existed load the new defaults.
    expect(SessionConfig.fromJson(const {}).gtFramesEnabled, true);
    expect(SessionConfig.fromJson(const {}).gtFrameSeconds, 30.0);
    // Migration guard: toJson always writes the keys, so an explicitly saved
    // OFF (or old 5 s interval) must survive the default flip.
    expect(
      SessionConfig.fromJson(const {'gtFramesEnabled': false}).gtFramesEnabled,
      false,
    );
    expect(
      SessionConfig.fromJson(const {'gtFrameSeconds': 5.0}).gtFrameSeconds,
      5.0,
    );
  });

  test('stream-resolution explicit flag round-trips (round 109)', () {
    // Fresh installs are non-explicit: the app may auto-pick the stream.
    expect(const SessionConfig().streamResolutionExplicit, false);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(streamResolutionExplicit: true).toJson(),
    );
    expect(restored.streamResolutionExplicit, true);
    expect(
      SessionConfig.fromJson(
        const SessionConfig().toJson(),
      ).streamResolutionExplicit,
      false,
    );
  });

  test('pre-109 configs: a non-default stored stream size counts as an '
      'explicit past choice', () {
    // No streamResolutionExplicit key. The old factory default (640×480)
    // means the user never touched the dropdown → auto may apply...
    expect(SessionConfig.fromJson(const {}).streamResolutionExplicit, false);
    expect(
      SessionConfig.fromJson(const {
        'streamWidth': 640,
        'streamHeight': 480,
      }).streamResolutionExplicit,
      false,
    );
    // ...but any other stored size was picked in Settings once and must
    // never be stomped by the auto default.
    expect(
      SessionConfig.fromJson(const {
        'streamWidth': 1440,
        'streamHeight': 1080,
      }).streamResolutionExplicit,
      true,
    );
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
    test('defaults: fast crops (round 117), target 1024', () {
      // Fast is the default: a high-res photo pauses the analysis stream up
      // to ~1.5 s and often blurs, so it is opt-in, not the baseline.
      const c = SessionConfig();
      expect(c.captureMode, RoiCaptureMode.fast);
      expect(c.targetRoiSavedPx, 1024);
      expect(SessionConfig.fromJson(const {}).captureMode, RoiCaptureMode.fast);
    });

    test('round-trips through toJson/fromJson', () {
      final restored = SessionConfig.fromJson(
        const SessionConfig()
            .copyWith(
              captureMode: RoiCaptureMode.highRes,
              targetRoiSavedPx: 512,
            )
            .toJson(),
      );
      expect(restored.captureMode, RoiCaptureMode.highRes);
      expect(restored.targetRoiSavedPx, 512);
    });

    test('r112 wire freeze: highRes saves as the historical "still" string', () {
      // Every recorded session and external parser keys on "still"; the Dart
      // rename (still → highRes) must never change the file format.
      final json = const SessionConfig()
          .copyWith(captureMode: RoiCaptureMode.highRes)
          .toJson();
      expect(json['captureMode'], 'still');
      // Defensive: a config that somehow carries the Dart enum name loads too.
      expect(
        SessionConfig.fromJson(const {'captureMode': 'highRes'}).captureMode,
        RoiCaptureMode.highRes,
      );
      expect(
        SessionConfig.fromJson(const {'captureMode': 'still'}).captureMode,
        RoiCaptureMode.highRes,
      );
    });

    test('round-62 min/max configs migrate: the min becomes the target', () {
      final restored = SessionConfig.fromJson(const {
        'captureMode': 'auto',
        'minRoiSavedPx': 640,
        'maxRoiSavedPx': 1280,
      });
      expect(restored.targetRoiSavedPx, 640);
    });

    test('legacy fullResPhotos=true loads as high-res mode', () {
      final restored = SessionConfig.fromJson(const {'fullResPhotos': true});
      expect(restored.captureMode, RoiCaptureMode.highRes);
    });

    test('legacy fullResPhotos=false keeps its fast-only behaviour', () {
      // An old setup must not silently switch to auto (which can take high-res photos).
      final restored = SessionConfig.fromJson(const {'fullResPhotos': false});
      expect(restored.captureMode, RoiCaptureMode.fast);
    });

    test('configs without either key get the fast default (r117)', () {
      expect(SessionConfig.fromJson(const {}).captureMode, RoiCaptureMode.fast);
    });

    test('pre-r119 placeholder model ids load as the nano that really ran', () {
      for (final id in ['yolo26s', 'yolo26m', 'yolo26l', 'yolo26x']) {
        expect(SessionConfig.fromJson({'modelPath': id}).modelPath, 'yolo26n');
      }
    });

    test('real model paths are NOT touched by the r119 migration', () {
      const kept = [
        'yolo26n',
        'assets/models/custom/arthropod_yolov11_int8.tflite',
        '/storage/emulated/0/Android/data/x/files/models/my_yolo26s.tflite',
      ];
      for (final path in kept) {
        expect(SessionConfig.fromJson({'modelPath': path}).modelPath, path);
      }
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

  group(
    'capture trigger (r97 enum, replaces the r95 motionOnlyCapture bool)',
    () {
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
    },
  );

  test(
    'time between bursts (r174): default 30 min, survives the round-trip',
    () {
      expect(const SessionConfig().timeLapseGapSeconds, 1800.0);
      final restored = SessionConfig.fromJson(
        const SessionConfig().copyWith(timeLapseGapSeconds: 600.0).toJson(),
      );
      expect(restored.timeLapseGapSeconds, 600.0);
      // 0 = continuous is a legal stored value.
      expect(
        SessionConfig.fromJson(
          const SessionConfig().copyWith(timeLapseGapSeconds: 0).toJson(),
        ).timeLapseGapSeconds,
        0.0,
      );
      // Configs saved before either key existed fall back to the default.
      expect(SessionConfig.fromJson(const {}).timeLapseGapSeconds, 1800.0);
    },
  );

  test('legacy timeLapseIntervalSeconds (start-to-start, pre-r174) migrates to '
      'an equivalent break: gap = interval - duration, clamped to 0', () {
    // 30 min start-to-start with 10 s bursts -> 1790 s break (identical
    // effective timing).
    expect(
      SessionConfig.fromJson(const {
        'timeLapseIntervalSeconds': 1800.0,
        'durationSeconds': 10.0,
      }).timeLapseGapSeconds,
      1790.0,
    );
    // Old interval <= duration meant continuous -> gap 0 (the owner's
    // r173/174 field configs).
    expect(
      SessionConfig.fromJson(const {
        'timeLapseIntervalSeconds': 10.0,
        'durationSeconds': 10.0,
      }).timeLapseGapSeconds,
      0.0,
    );
    // The new key wins when both are present.
    expect(
      SessionConfig.fromJson(const {
        'timeLapseGapSeconds': 60.0,
        'timeLapseIntervalSeconds': 1800.0,
        'durationSeconds': 10.0,
      }).timeLapseGapSeconds,
      60.0,
    );
  });

  test(
    'time-lapse camera sleep (r163, E3): default off, survives the round-trip',
    () {
      expect(const SessionConfig().timeLapseCameraSleep, false);
      final restored = SessionConfig.fromJson(
        const SessionConfig().copyWith(timeLapseCameraSleep: true).toJson(),
      );
      expect(restored.timeLapseCameraSleep, true);
      // Configs saved before the key existed fall back to off.
      expect(SessionConfig.fromJson(const {}).timeLapseCameraSleep, false);
    },
  );

  test(
    'time-lapse wake lead (r164): default 10 s, survives the round-trip',
    () {
      // 10 s, not less: the owner's field test at 5 s produced a dark,
      // blurry first burst photo (AE ramp + lens-actuator travel after the
      // camera powers back on need the extra margin).
      expect(const SessionConfig().timeLapseWakeLeadSeconds, 10.0);
      final restored = SessionConfig.fromJson(
        const SessionConfig().copyWith(timeLapseWakeLeadSeconds: 12.0).toJson(),
      );
      expect(restored.timeLapseWakeLeadSeconds, 12.0);
      // Configs saved before the key existed fall back to the default.
      expect(SessionConfig.fromJson(const {}).timeLapseWakeLeadSeconds, 10.0);
    },
  );

  test('time-lapse torch (r180): default off, survives the round-trip', () {
    expect(const SessionConfig().timeLapseTorch, false);
    final restored = SessionConfig.fromJson(
      const SessionConfig().copyWith(timeLapseTorch: true).toJson(),
    );
    expect(restored.timeLapseTorch, true);
    // Configs saved before the key existed fall back to off.
    expect(SessionConfig.fromJson(const {}).timeLapseTorch, false);
  });

  test(
    'time-lapse torch lead (r180): default 5 s, survives the round-trip',
    () {
      // 5 s: auto-exposure re-converges within ~1–2 s of the torch coming
      // on (it runs in the camera hardware's own loop), so 5 s leaves
      // margin for slow low-light AE without burning the LED needlessly.
      expect(const SessionConfig().timeLapseTorchLeadSeconds, 5.0);
      final restored = SessionConfig.fromJson(
        const SessionConfig().copyWith(timeLapseTorchLeadSeconds: 8.0).toJson(),
      );
      expect(restored.timeLapseTorchLeadSeconds, 8.0);
      // Configs saved before the key existed fall back to the default.
      expect(SessionConfig.fromJson(const {}).timeLapseTorchLeadSeconds, 5.0);
    },
  );

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

  group('notApplicableConfigKeys', () {
    // Guards the r147 start-record list against key-name drift: every key it
    // names must be a real toJson() key, or analysis filters would silently
    // miss renamed settings.
    test('every listed key exists in toJson() for every trigger', () {
      final jsonKeys = const SessionConfig().toJson().keys.toSet();
      for (final trigger in CaptureTrigger.values) {
        for (final key in notApplicableConfigKeys(trigger)) {
          expect(
            jsonKeys.contains(key),
            true,
            reason: '$key (for $trigger) is not a SessionConfig.toJson() key',
          );
        }
      }
    });

    test('mode expectations', () {
      // Detector: only the time-lapse burst settings are inert.
      expect(notApplicableConfigKeys(CaptureTrigger.detector), [
        'timeLapseGapSeconds',
        'timeLapseCameraSleep',
        'timeLapseWakeLeadSeconds',
        'timeLapseTorch',
        'timeLapseTorchLeadSeconds',
      ]);
      // Motion: AI keys inert, but the gate keys APPLY (they are the capture
      // sensitivity) — and wake duration governs how long photos continue.
      final motion = notApplicableConfigKeys(CaptureTrigger.motion);
      expect(motion, contains('modelPath'));
      expect(motion, contains('showBoxes'));
      expect(motion, contains('timeLapseGapSeconds'));
      expect(motion, contains('timeLapseCameraSleep'));
      expect(motion, contains('timeLapseWakeLeadSeconds'));
      expect(motion, contains('timeLapseTorch'));
      expect(motion, contains('timeLapseTorchLeadSeconds'));
      expect(motion, isNot(contains('motionGateWakeSeconds')));
      expect(motion, isNot(contains('motionGatePixelDelta')));
      // Reference photos apply in detector AND motion mode (that is the
      // point: unbiased samples even when the AI/motion trigger misses).
      expect(motion, isNot(contains('gtFramesEnabled')));
      expect(motion, isNot(contains('gtFrameSeconds')));
      // Time-lapse: AI keys AND all gate keys inert; the burst interval and
      // photo step/duration apply. Reference photos are inert too — the
      // whole session is already clock-driven photos.
      final tl = notApplicableConfigKeys(CaptureTrigger.timelapse);
      expect(tl, contains('modelPath'));
      expect(tl, contains('motionGateEnabled'));
      expect(tl, contains('motionGateWakeSeconds'));
      expect(tl, contains('gtFramesEnabled'));
      expect(tl, contains('gtFrameSeconds'));
      expect(tl, isNot(contains('timeLapseGapSeconds')));
      expect(tl, isNot(contains('timeLapseCameraSleep')));
      expect(tl, isNot(contains('timeLapseWakeLeadSeconds')));
      expect(tl, isNot(contains('timeLapseTorch')));
      expect(tl, isNot(contains('timeLapseTorchLeadSeconds')));
      expect(tl, isNot(contains('stepSeconds')));
    });
  });
}
