// Tests for the per-photo source decision (chooseCapturePath) and the saved
// crop size math (savedSidePx / capSavedSidePx) — pure functions, no camera.
//
// These must mirror the actual crop paths exactly: the same ÷32 snapping and
// short-side capping is applied by the native fast crop, the native still
// crop and the Dart fallback, so what the decision predicts is what lands on
// disk.

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';

void main() {
  group('savedSidePx', () {
    test('snaps the fraction-of-width side to the nearest multiple of 32', () {
      // 0.5 × 640 = 320 → already a multiple of 32.
      expect(savedSidePx(0.5, 640, 480), 320);
      // 0.3 × 640 = 192 exactly; 0.31 × 640 = 198.4 → nearest is 192.
      expect(savedSidePx(0.31, 640, 480), 192);
    });

    test('caps at the largest ÷32 that fits the short side', () {
      // Full-width box on 640×480: short side 480 is itself ÷32.
      expect(savedSidePx(1.0, 640, 480), 480);
      // 1280×720: 720 is not ÷32 → capped to 704 (matches the WYSIWYG rule).
      expect(savedSidePx(1.0, 1280, 720), 704);
    });

    test('returns 0 while the source size is unknown', () {
      expect(savedSidePx(0.5, 0, 0), 0);
    });

    test('never goes below 32', () {
      expect(savedSidePx(0.01, 640, 480), 32);
    });
  });

  group('capSavedSidePx', () {
    test('0 or negative cap means no cap', () {
      expect(capSavedSidePx(2976, 0), 2976);
      expect(capSavedSidePx(2976, -1), 2976);
    });

    test('shrinks to the largest ÷32 that fits the cap, never enlarges', () {
      expect(capSavedSidePx(2976, 1280), 1280);
      expect(capSavedSidePx(2976, 1000), 992); // 1000 → 31 × 32
      expect(capSavedSidePx(608, 1280), 608); // already under: untouched
    });
  });

  group('roiStreamSideFromLog', () {
    test('re-projects a still-frame roi block onto the analysis frame', () {
      // session_6: on-screen 480 ROI logged as 1333 against the 3000×4000
      // still; analysis frame was 1080×1440 → recovers the on-screen 480.
      const roi = {'width_px': 1333, 'frame_width_px': 3000};
      expect(roiStreamSideFromLog(roi, 1080, 1440), 480);
    });

    test('is the identity for a block already in the stream grid', () {
      const roi = {'width_px': 448, 'frame_width_px': 640};
      expect(roiStreamSideFromLog(roi, 640, 480), 448);
    });

    test('returns null when the block or the analysis dims are unusable', () {
      expect(roiStreamSideFromLog(const {}, 1080, 1440), isNull);
      expect(
        roiStreamSideFromLog(
          const {'width_px': 0, 'frame_width_px': 3000},
          1080,
          1440,
        ),
        isNull,
      );
      expect(
        roiStreamSideFromLog(
          const {'width_px': 1333, 'frame_width_px': 3000},
          0,
          0,
        ),
        isNull,
      );
    });
  });

  group('autoStreamResolution', () {
    // The Xiaomi test phone's probed analysis sizes (subset).
    const xiaomi = [
      '640x480',
      '1280x960',
      '1440x1080',
      '1920x1440',
      '4000x3000',
    ];

    test('picks the SMALLEST size whose short side reaches 1024', () {
      expect(autoStreamResolution(xiaomi), (1440, 1080));
    });

    test('skips candidates above the analysis ceiling', () {
      // Ceiling 1280×960: nothing with short side ≥ 1024 fits under it, so
      // the round-122 fallback picks the largest size under the ceiling.
      expect(autoStreamResolution(xiaomi, ceilingArea: 1280 * 960), (
        1280,
        960,
      ));
      // Ceiling 1920×1440 admits 1440×1080 (and 1920×1440) but not 4000×3000.
      expect(autoStreamResolution(xiaomi, ceilingArea: 1920 * 1440), (
        1440,
        1080,
      ));
    });

    test('ceiling 0 means unfiltered', () {
      expect(autoStreamResolution(['4000x3000']), (4000, 3000));
    });

    test('follows the saved-photo target (round 122)', () {
      // A lower target admits smaller streams; a higher one climbs.
      expect(autoStreamResolution(xiaomi, minShortSide: 960), (1280, 960));
      expect(autoStreamResolution(xiaomi, minShortSide: 1440), (1920, 1440));
    });

    test('falls back to the largest size when the target is unreachable', () {
      // Round 122: a phone weaker than the target gets its best stream
      // instead of keeping a small preset.
      expect(autoStreamResolution(['640x480', '1280x960']), (1280, 960));
      expect(autoStreamResolution(const []), isNull);
    });

    test('ignores malformed entries', () {
      expect(autoStreamResolution(['garbage', '1440x', 'x1080', '1440x1080']), (
        1440,
        1080,
      ));
    });
  });

  group('chooseCapturePath', () {
    // A 4000×3000 still and the default 640×480 analysis stream.
    CapturePath choose({
      RoiCaptureMode mode = RoiCaptureMode.auto,
      int targetPx = 640,
      double side = 0.5,
      int highResW = 4000,
      int highResH = 3000,
    }) => chooseCapturePath(
      mode: mode,
      targetPx: targetPx,
      roiSideFraction: side,
      streamW: 640,
      streamH: 480,
      highResW: highResW,
      highResH: highResH,
    );

    test('fast mode always uses the live-frame crop', () {
      expect(choose(mode: RoiCaptureMode.fast, side: 0.05), CapturePath.fast);
    });

    test(
      'high-res mode always uses the high-res path when its size is known',
      () {
        expect(
          choose(mode: RoiCaptureMode.highRes, side: 1.0),
          CapturePath.highRes,
        );
      },
    );

    test('high-res mode degrades to fast when the size probe failed', () {
      // Saving a small photo beats saving none.
      expect(
        choose(mode: RoiCaptureMode.highRes, highResW: 0, highResH: 0),
        CapturePath.fast,
      );
    });

    test(
      'auto takes a high-res photo when the fast crop misses the target',
      () {
        // 0.5 × 640 = 320 px < 640 target → pay for the high-res photo.
        expect(choose(side: 0.5), CapturePath.highRes);
      },
    );

    test('auto stays fast when the live-frame crop already suffices', () {
      // 0.5 × 640 = 320 px ≥ a 320 target → no high-res photo needed.
      expect(choose(side: 0.5, targetPx: 320), CapturePath.fast);
    });

    test('auto degrades to fast when the high-res probe failed', () {
      expect(choose(side: 0.1, highResW: 0, highResH: 0), CapturePath.fast);
    });

    test('r112 wire freeze: highRes logs as the historical "still"', () {
      // The `path` value in capture records is frozen — every recorded
      // session and external parser keys on "still"/"fast".
      expect(CapturePath.highRes.wireName, 'still');
      expect(CapturePath.fast.wireName, 'fast');
    });
  });

  group('uprightHighResDims', () {
    // Session_97 bug: the probe decoder had ALREADY applied the EXIF rotation
    // (returned 3000×4000 upright) and the old code swapped it again to
    // 4000×3000, so every size prediction ran against the wrong width
    // (predicted 1024, files were 992). The helper must handle both decoder
    // behaviours.
    test('EXIF-blind decoder (raw landscape) gets swapped for 90/270', () {
      expect(uprightHighResDims(90, 4000, 3000), (3000, 4000));
      expect(uprightHighResDims(270, 4000, 3000), (3000, 4000));
    });

    test('EXIF-aware decoder (already portrait) is NOT swapped again', () {
      expect(uprightHighResDims(90, 3000, 4000), (3000, 4000));
      expect(uprightHighResDims(270, 3000, 4000), (3000, 4000));
    });

    test('rotation 0/180 keeps dims as reported', () {
      expect(uprightHighResDims(0, 4000, 3000), (4000, 3000));
      expect(uprightHighResDims(180, 4000, 3000), (4000, 3000));
    });
  });

  group('rawRectForUprightRect', () {
    // Portrait phone, landscape sensor: raw 4000×3000, upright 3000×4000.
    // The same formulas live in MainActivity.kt (rawRectForUprightRect) —
    // these tests are the reference for both.
    const rawW = 4000, rawH = 3000;

    ({int left, int top, int right, int bottom}) map(
      int rot,
      int l,
      int t,
      int r,
      int b,
    ) => rawRectForUprightRect(
      rotationDegrees: rot,
      rawW: rawW,
      rawH: rawH,
      left: l,
      top: t,
      right: r,
      bottom: b,
    );

    test('rotation 0 is the identity', () {
      expect(map(0, 10, 20, 110, 120), (
        left: 10,
        top: 20,
        right: 110,
        bottom: 120,
      ));
    });

    test('a centred square stays centred for every rotation', () {
      // The square must be centred in each rotation's own upright frame:
      // rot 90/270 → upright 3000×4000 (portrait), rot 180 → 4000×3000.
      for (final rot in [90, 180, 270]) {
        final portrait = rot != 180;
        final rr = portrait
            ? map(rot, 1000, 1500, 2000, 2500)
            : map(rot, 1500, 1000, 2500, 2000);
        expect((rr.left + rr.right) ~/ 2, rawW ~/ 2, reason: 'rot $rot');
        expect((rr.top + rr.bottom) ~/ 2, rawH ~/ 2, reason: 'rot $rot');
        expect(rr.right - rr.left, 1000, reason: 'rot $rot square width');
        expect(rr.bottom - rr.top, 1000, reason: 'rot $rot square height');
      }
    });

    test('rotation 90: upright top-left comes from the raw bottom-left', () {
      // Rotating the raw image 90° clockwise carries its bottom-left corner
      // to the upright top-left.
      expect(map(90, 0, 0, 100, 100), (
        left: 0,
        top: rawH - 100,
        right: 100,
        bottom: rawH,
      ));
    });

    test('rotation 270: upright top-left comes from the raw top-right', () {
      expect(map(270, 0, 0, 100, 100), (
        left: rawW - 100,
        top: 0,
        right: rawW,
        bottom: 100,
      ));
    });

    test('rotation 180: upright top-left comes from the raw bottom-right', () {
      expect(map(180, 0, 0, 100, 100), (
        left: rawW - 100,
        top: rawH - 100,
        right: rawW,
        bottom: rawH,
      ));
    });

    test('mapped rects always stay inside the raw image', () {
      // A maximal upright square, per rotation's own upright frame:
      // rot 90/270 → upright 3000×4000 (portrait), rot 0/180 → 4000×3000.
      for (final rot in [90, 270]) {
        final rr = map(rot, 0, 500, 3000, 3500);
        expect(rr.left >= 0 && rr.top >= 0, isTrue, reason: 'rot $rot');
        expect(
          rr.right <= rawW && rr.bottom <= rawH,
          isTrue,
          reason: 'rot $rot',
        );
      }
      for (final rot in [0, 180]) {
        final rr = map(rot, 500, 0, 3500, 3000);
        expect(rr.left >= 0 && rr.top >= 0, isTrue, reason: 'rot $rot');
        expect(
          rr.right <= rawW && rr.bottom <= rawH,
          isTrue,
          reason: 'rot $rot',
        );
      }
    });
  });
}
