// Stress round (2026-10-20), step P1: what happens when the SAVED settings are
// not what the app wrote last time (another type, a number far outside the
// range of its Settings box, a huge number, a half-written file).
//
// Settings are read at every start of the app, so a bad saved value is the
// kind of thing that can silently reset ALL settings or crash the start. The
// settings screens only allow numbers inside a range, but the saved text is
// read back with much less care (hard casts such as `as bool?`, and only a few
// values clamped on load).
//
// Cases that show a real bug are kept but skipped with 'BUG: ...' so the normal
// suite stays green. Run them with `flutter test --run-skipped <this file>`.
// Everything is seeded and small (no big memory use).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart' show IdentifyPrefs;
import 'package:fauna_pulse/fauna_pulse/models/model_choice_keys.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart' show VideoAnalysisPrefs;
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart' show TrackerAlgorithm;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One range a Settings box allows (docs/SETTINGS_REFERENCE.md,
/// lib/fauna_pulse/screens/settings_sheet.dart). [lo] and [hi] are inclusive.
class Range {
  final String key;
  final double lo;
  final double hi;
  final String box;
  const Range(this.key, this.lo, this.hi, this.box);
}

/// The ranges of the boxes that write into SessionConfig (one per stored key).
const ranges = <Range>[
  Range('stepSeconds', 0.1, 10, 'Photo step'),
  Range('durationSeconds', 1, 86400, 'Photo duration'),
  Range('timeLapseGapSeconds', 0, 86400, 'Time between bursts'),
  Range('timeLapseWakeLeadSeconds', 1, 60, 'Camera wake lead'),
  Range('timeLapseTorchLeadSeconds', 1, 60, 'Torch lead'),
  Range('scheduleDays', 1, 14, 'Days to run'),
  Range('confidenceThreshold', 0.05, 0.95, 'Confidence threshold'),
  Range('iouThreshold', 0.1, 0.95, 'IoU threshold'),
  Range('cpuThreads', 0, 8, 'CPU threads'),
  Range('occlusionSeconds', 0.2, 10, 'Occlusion tolerance'),
  Range('minHitsSeconds', 0, 2, 'Minimum track length'),
  Range('liveAiVideoFps', 1, 30, 'Video frame rate (live)'),
  Range('timeLapseVideoFps', 1, 30, 'Video frame rate (time-lapse)'),
  Range('targetRoiSavedPx', 128, 2048, 'Saved photo side'),
  Range('screenOffAfterMin', 0, 10, 'Screen off by itself after'),
  Range('lowBatteryStopPercent', 0, 50, 'Stop at battery level'),
  Range('storageReserveMb', 50, 5000, 'Keep free storage'),
  Range('inferenceFps', 5, 30, 'Max detector rate'),
  Range('minInferenceFps', 1, 30, 'Min detector rate'),
  Range('throttleDutyTarget', 0.3, 0.8, 'Target processor load'),
  Range('motionGateWakeSeconds', 0.5, 60, 'Wake duration after motion'),
  Range('motionGatePixelDelta', 5, 100, 'Pixel sensitivity'),
  Range('motionGateAreaFraction', 0.0005, 0.2, 'Trigger area'),
  Range('motionGateGridSize', 16, 160, 'Motion grid resolution'),
  Range('motionGateIdleFps', 1, 30, 'Idle check rate'),
  Range('fpsSampleSeconds', 1, 60, 'Frame-rate sample'),
  Range('thermalSampleSeconds', 1, 120, 'Temperature sample'),
  Range('powerSampleSeconds', 1, 120, 'Power sample'),
  Range('gtFrameSeconds', 1, 3600, 'Reference photo interval'),
  // The Session length box has no upper limit (docs/SETTINGS_REFERENCE.md); one year is used as the largest sensible value.
  Range('sessionMinutes', 1, 60 * 24 * 365, 'Session length'),
];

/// Settings stored as whole numbers in the file.
const wholeNumberKeys = {
  'scheduleDays',
  'cpuThreads',
  'liveAiVideoFps',
  'timeLapseVideoFps',
  'targetRoiSavedPx',
  'screenOffAfterMin',
  'lowBatteryStopPercent',
  'storageReserveMb',
  'inferenceFps',
  'minInferenceFps',
  'motionGatePixelDelta',
  'motionGateGridSize',
  'motionGateIdleFps',
  'fpsSampleSeconds',
  'thermalSampleSeconds',
  'powerSampleSeconds',
  'sessionMinutes',
};

/// A config as the app writes it, with a few distinctive non-default values,
/// so "everything reset to defaults" is easy to see.
Map<String, dynamic> savedConfig() {
  final c = const SessionConfig().copyWith(
    confidenceThreshold: 0.33,
    stepSeconds: 2.5,
    sessionMinutes: 45,
    folderName: 'my_meadow',
    showFps: false,
    useGpu: false,
    storageReserveMb: 777,
  );
  return jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>;
}

Future<SessionConfig> loadWith(Map<String, dynamic> json) async {
  SharedPreferences.setMockInitialValues({kSessionConfigPref: jsonEncode(json)});
  return SessionConfig.load();
}

bool isDefaults(SessionConfig c) =>
    c.confidenceThreshold == 0.25 && c.folderName == 'session' && c.sessionMinutes == 60 && c.stepSeconds == 1.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('faunapulse_stress_p1');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('SessionConfig.load: unreadable saved text', () {
    test('text that is not JSON gives the defaults and does not throw', () async {
      SharedPreferences.setMockInitialValues({kSessionConfigPref: '{"stepSeconds": 2.'});
      expect(isDefaults(await SessionConfig.load()), isTrue);
    });

    test('JSON that is not an object (list, number, null) gives the defaults', () async {
      for (final raw in ['[]', '5', 'null', '"text"', '']) {
        SharedPreferences.setMockInitialValues({kSessionConfigPref: raw});
        expect(isDefaults(await SessionConfig.load()), isTrue, reason: 'saved text "$raw"');
      }
    });

    test('a saved config cut off in the middle (half-written file) gives the defaults', () async {
      final text = jsonEncode(savedConfig());
      for (final cut in [1, text.length ~/ 3, text.length ~/ 2, text.length - 1]) {
        SharedPreferences.setMockInitialValues({kSessionConfigPref: text.substring(0, cut)});
        final c = await SessionConfig.load();
        expect(isDefaults(c), isTrue, reason: 'cut at $cut of ${text.length}');
      }
    });

    test('the settings key holds a number instead of text: start still works (defaults)', () async {
      // Another app version or a bug may have written another type under the key.
      SharedPreferences.setMockInitialValues({kSessionConfigPref: 5});
      SessionConfig? c;
      Object? error;
      try {
        c = await SessionConfig.load();
      } catch (e) {
        error = e;
      }
      expect(error, isNull, reason: 'load() threw $error; SharedPreferences.getString is outside the try block');
      expect(c == null || isDefaults(c), isTrue);
    });

    test('an empty object keeps working: all defaults, nothing thrown', () async {
      final c = await loadWith({});
      expect(isDefaults(c), isTrue);
    });

    test('unknown extra keys, and keys of a newer version, are ignored', () async {
      final j = savedConfig()..['somethingNew'] = {'a': 1};
      final c = await loadWith(j);
      expect(c.confidenceThreshold, 0.33);
    });
  });

  // -------------------------------------------------------------------------
  group('SessionConfig.load: one key of the wrong type', () {
    /// Wrong values for a key: every JSON type except the right one.
    const wrongs = <String, Object?>{'string': 'abc', 'list': [1], 'map': {'a': 1}, 'bool': true, 'number': 7};

    test('a wrong-typed text key resets ONLY itself, never all other settings', () async {
      final base = savedConfig();
      final resets = <String>[];
      for (final key in base.keys) {
        final good = base[key];
        for (final wrongName in wrongs.keys) {
          final wrong = wrongs[wrongName];
          // Same type as the good value is not "wrong".
          final sameType = (good is String && wrong is String) ||
              (good is num && wrong is num) ||
              (good is bool && wrong is bool) ||
              (good is List && wrong is List) ||
              (good is Map && wrong is Map);
          if (sameType) continue;
          final j = Map<String, dynamic>.of(base)..[key] = wrong;
          final c = await loadWith(j);
          // The other settings must survive (confidenceThreshold 0.33 is the marker).
          if (key != 'confidenceThreshold' && c.confidenceThreshold != 0.33) {
            resets.add('$key=$wrongName');
          }
        }
      }
      expect(resets, isEmpty, reason: 'these single wrong-typed keys reset every other setting:\n${resets.join('\n')}');
    });

    test('example: "showFps" saved as text resets the confidence threshold too', () async {
      final c = await loadWith(savedConfig()..['showFps'] = 'yes');
      expect(c.confidenceThreshold, 0.33);
      expect(c.folderName, 'my_meadow');
    });

    test('a wrong-typed value inside trackerParams resets ALL settings', () async {
      final j = savedConfig()..['trackerParams'] = {'highThresh': 'high'};
      final c = await loadWith(j);
      expect(c.confidenceThreshold, 0.33);
    });

    test('a wrong-typed value inside cbiouParams resets ALL settings', () async {
      final j = savedConfig()..['cbiouParams'] = {'bufferScale1': [1]};
      final c = await loadWith(j);
      expect(c.confidenceThreshold, 0.33);
    });

    test('null for a key is the same as missing (default), and others stay', () async {
      final base = savedConfig();
      for (final key in base.keys) {
        final j = Map<String, dynamic>.of(base)..[key] = null;
        final c = await loadWith(j);
        if (key != 'confidenceThreshold') {
          expect(c.confidenceThreshold, 0.33, reason: 'null in "$key" must not reset the rest');
        }
      }
    });

    test('whole numbers where a decimal number is expected, and the reverse, load fine', () async {
      final j = savedConfig()
        ..['confidenceThreshold'] = 1
        ..['stepSeconds'] = 2
        ..['sessionMinutes'] = 30.0
        ..['cpuThreads'] = 2.0;
      final c = await loadWith(j);
      // The whole number 1 loads as a decimal; it is above the box maximum, so
      // it is clamped to 0.95.
      expect(c.confidenceThreshold, 0.95);
      expect(c.stepSeconds, 2.0);
      expect(c.sessionMinutes, 30);
      expect(c.cpuThreads, 2);
    });

    test('a fractional number for a whole-number key keeps the other settings', () async {
      final j = savedConfig()
        ..['sessionMinutes'] = 30.7
        ..['motionGateGridSize'] = 48.9;
      final c = await loadWith(j);
      expect(c.confidenceThreshold, 0.33);
      expect(c.sessionMinutes, 30);
    });

    test('malformed schedule windows are dropped, the rest is kept', () async {
      final j = savedConfig()
        ..['scheduleWindows'] = [
          'x',
          null,
          {'start': 'a', 'end': 5},
          {'start': 600, 'end': 600},
          {'start': -5, 'end': 100},
          {'start': 0, 'end': 99999},
          {'start': 480, 'end': 600},
        ];
      final c = await loadWith(j);
      expect(c.confidenceThreshold, 0.33);
      expect([for (final w in c.scheduleWindows) w.label], ['08:00–10:00']);
    });

    test('more than 3 windows: capped at 3 and sorted', () async {
      final j = savedConfig()
        ..['scheduleWindows'] = [
          for (final s in [1000, 100, 700, 400, 1300]) {'start': s, 'end': s + 30},
        ];
      final c = await loadWith(j);
      expect(c.scheduleWindows.length, 3);
      expect([for (final w in c.scheduleWindows) w.startMinute], [100, 400, 700]);
    });
  });

  // -------------------------------------------------------------------------
  group('SessionConfig.load: huge, tiny and negative numbers', () {
    /// Dirty numbers a damaged or older file could hold.
    List<num> dirty(Range r) => [
      -1e9,
      -1,
      0,
      r.lo - (r.hi - r.lo) * 0.5 - 1,
      r.hi + 1,
      r.hi * 1000 + 1,
      1e15,
    ];

    /// A value is OK if it is inside the box range (or a documented special
    /// value: camera cap 0 = no cap).
    bool inside(Range r, double v) => v.isFinite && v >= r.lo - 1e-9 && v <= r.hi + 1e-9;

    double? read(SessionConfig c, String key) => (c.toJson()[key] as num?)?.toDouble();

    // Values a settings box can never hold, but the file can: see each skip.
    // fromJson clamps every other key to its box range. scheduleDays keeps
    // 1..365 on purpose, so a longer run saved by an older version still loads.
    const knownUnclamped = <String, String>{
      'scheduleDays': 'clamped 1..365 but the screen allows only 1..14, so 365 loads and runs 365 days',
    };

    for (final r in ranges) {
      test('"${r.key}" (box "${r.box}", ${r.lo}..${r.hi}): dirty saved values end up inside the box range', () async {
        final bad = <String>[];
        for (final v in dirty(r)) {
          if (r.key == 'sessionMinutes' && v > r.hi) continue; // no upper limit for the session length
          final value = wholeNumberKeys.contains(r.key) ? v.round() : v;
          final c = await loadWith(savedConfig()..[r.key] = value);
          final got = read(c, r.key);
          if (got == null || !inside(r, got)) bad.add('saved $value -> loaded $got');
        }
        expect(bad, isEmpty, reason: 'outside ${r.lo}..${r.hi}: ${bad.join('; ')}');
      }, skip: knownUnclamped.containsKey(r.key) ? 'BUG: ${knownUnclamped[r.key]}' : null);
    }

    test('stream size saved as 0 or negative gives a usable size', () async {
      for (final v in [0, -1, -640]) {
        final c = await loadWith(savedConfig()..['streamWidth'] = v..['streamHeight'] = v);
        expect(c.streamWidth, greaterThan(0), reason: 'streamWidth saved as $v');
        expect(c.streamHeight, greaterThan(0), reason: 'streamHeight saved as $v');
      }
    });

    test('camera frame cap 1..4 becomes 5, 0 stays "no cap", 999 becomes 30', () async {
      for (final (saved, want) in [(1, 5), (4, 5), (0, 0), (-3, 0), (999, 30), (17, 17)]) {
        final c = await loadWith(savedConfig()..['cameraFpsCap'] = saved);
        expect(c.cameraFpsCap, want, reason: 'saved $saved');
      }
    });

    test('Infinity in the saved text (1e999) does not break load, save or the tracker', () async {
      // jsonDecode turns 1e999 into Infinity. Nothing in the app writes it,
      // but a hand-edited or damaged file can.
      final text = jsonEncode(savedConfig()).replaceFirst('"occlusionSeconds":3.0', '"occlusionSeconds":1e999');
      expect(text.contains('1e999'), isTrue);
      SharedPreferences.setMockInitialValues({kSessionConfigPref: text});
      final c = await SessionConfig.load();
      expect(c.confidenceThreshold, 0.33, reason: 'the other settings must survive');
      await c.save(); // jsonEncode(Infinity) throws
      c.buildTracker(15); // occlusionFramesFor: Infinity.round() throws
    });

    test('Infinity in a whole-number key resets ALL settings (toInt throws)', () async {
      final text = jsonEncode(savedConfig()).replaceFirst('"cpuThreads":0', '"cpuThreads":1e999');
      expect(text.contains('1e999'), isTrue);
      SharedPreferences.setMockInitialValues({kSessionConfigPref: text});
      final c = await SessionConfig.load();
      expect(c.confidenceThreshold, 0.33);
    });

    test('very long strings (100 000 characters) in text keys load and save', () async {
      final big = 'x' * 100000;
      final c = await loadWith(savedConfig()..['folderName'] = big..['modelPath'] = big);
      expect(c.folderName.length, 100000);
      await c.save();
      final back = await SessionConfig.load();
      expect(back.folderName.length, 100000);
    });

    test('a folder name with path characters is not changed by load (checked where it is used)', () async {
      final c = await loadWith(savedConfig()..['folderName'] = '../../etc/x\u0000y');
      // load keeps it as text; where the folder is created it must be cleaned.
      expect(c.folderName, '../../etc/x\u0000y');
    });

    test('1000 random damaged configs (seeded): load never throws and always returns a config', () async {
      final rnd = Random(20261020);
      final keys = savedConfig().keys.toList();
      Object? junk() => switch (rnd.nextInt(8)) {
        0 => null,
        1 => rnd.nextInt(1 << 31) - (1 << 30),
        2 => rnd.nextDouble() * 1e6 - 5e5,
        3 => rnd.nextBool(),
        4 => 'text${rnd.nextInt(99)}',
        5 => [rnd.nextInt(9)],
        6 => {'a': rnd.nextInt(9)},
        _ => 0,
      };
      for (var i = 0; i < 1000; i++) {
        final j = savedConfig();
        for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
          j[keys[rnd.nextInt(keys.length)]] = junk();
        }
        final c = await loadWith(j);
        // Always a config; toJson must stay encodable.
        jsonEncode(c.toJson());
      }
    });
  });

  // -------------------------------------------------------------------------
  group('SessionConfig save and load', () {
    test('values at the minimum and maximum of every box survive save then load unchanged', () async {
      for (final atMax in [false, true]) {
        var j = savedConfig();
        for (final r in ranges) {
          final v = atMax ? r.hi : r.lo;
          j[r.key] = wholeNumberKeys.contains(r.key) ? v.round() : v;
        }
        // the camera cap and the two detector rates are tied together on load
        j['cameraFpsCap'] = atMax ? 30 : 5;
        j['scheduleWindows'] = [
          {'start': 0, 'end': 1440},
        ];
        final c = SessionConfig.fromJson(j);
        await c.save();
        final back = await SessionConfig.load();
        expect(back.toJson(), c.toJson(), reason: atMax ? 'all at maximum' : 'all at minimum');
        for (final r in ranges) {
          final got = (back.toJson()[r.key] as num).toDouble();
          expect(got, closeTo(atMax ? r.hi : r.lo, 1e-9), reason: '${r.key} at ${atMax ? 'max' : 'min'}');
        }
      }
    });

    test('save then load twice gives the same JSON text (stable, no drift)', () async {
      final c = SessionConfig.fromJson(savedConfig());
      await c.save();
      final a = (await SessionConfig.load()).toJson();
      await (await SessionConfig.load()).save();
      final b = (await SessionConfig.load()).toJson();
      expect(jsonEncode(b), jsonEncode(a));
    });

    test('saving a config with a decimal like 0.1 + 0.2 does not make the box show a long number', () async {
      final c = const SessionConfig().copyWith(stepSeconds: 0.1 + 0.2);
      await c.save();
      final back = await SessionConfig.load();
      expect(back.stepSeconds, c.stepSeconds);
    });
  });

  // -------------------------------------------------------------------------
  group('VideoAnalysisPrefs: values saved with another type', () {
    final doubleKeys = [
      'video_analysis_confidence',
      'video_analysis_iou',
      'video_analysis_fps',
      'video_analysis_thermal_limit_c',
      'video_analysis_occlusion_s',
      'video_analysis_min_visit_s',
      'video_analysis_sample_s',
      'video_analysis_keep_step_s',
      'video_analysis_keep_duration_s',
    ];

    test('all keys missing: defaults', () async {
      SharedPreferences.setMockInitialValues({});
      final p = await VideoAnalysisPrefs.load();
      expect(p.confidence, 0.25);
      expect(p.keepFrames, isTrue);
    });

    test('save then load round trip keeps the values', () async {
      final p = VideoAnalysisPrefs(confidence: 0.4, analysisFps: 12, occlusionSeconds: 6.5, keepFrames: false);
      await p.save();
      final back = await VideoAnalysisPrefs.load();
      expect(back.confidence, 0.4);
      expect(back.analysisFps, 12);
      expect(back.occlusionSeconds, 6.5);
      expect(back.keepFrames, isFalse);
    });

    test('each decimal setting saved as TEXT: load must not throw and must keep the other settings', () async {
      final failures = <String>[];
      for (final key in doubleKeys) {
        SharedPreferences.setMockInitialValues({'video_analysis_confidence': 0.4, 'video_analysis_fps': 9.0, key: 'oops'});
        try {
          final p = await VideoAnalysisPrefs.load();
          if (key != 'video_analysis_confidence' && p.confidence != 0.4) failures.add('$key: other setting lost');
        } catch (e) {
          failures.add('$key: ${e.runtimeType}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('each decimal setting saved as a WHOLE NUMBER (older version wrote setInt): load must not throw', () async {
      final failures = <String>[];
      for (final key in doubleKeys) {
        SharedPreferences.setMockInitialValues({key: 5});
        try {
          await VideoAnalysisPrefs.load();
        } catch (e) {
          failures.add('$key: ${e.runtimeType}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test('the on/off setting saved as text: load must not throw', () async {
      SharedPreferences.setMockInitialValues({'video_analysis_keep_frames': 'yes'});
      await VideoAnalysisPrefs.load();
    });

    test('tracker settings saved as broken text are ignored (defaults)', () async {
      SharedPreferences.setMockInitialValues({
        'video_analysis_bytetrack': '{broken',
        'video_analysis_cbiou': '[1,2]',
        'video_analysis_tracker': 'nonsense',
      });
      final p = await VideoAnalysisPrefs.load();
      expect(p.trackerAlgorithm, TrackerAlgorithm.bytetrack);
      expect(p.trackerParams.highThresh, const ByteTrackParams().highThresh);
    });

    test('tracker settings with a wrong-typed value inside: load must not throw', () async {
      SharedPreferences.setMockInitialValues({
        'video_analysis_bytetrack': jsonEncode({'highThresh': 'high'}),
      });
      await VideoAnalysisPrefs.load();
    });

    test('absurd numbers are loaded as they are: derived values stay usable', () async {
      SharedPreferences.setMockInitialValues({
        'video_analysis_fps': 0.0,
        'video_analysis_sample_s': -5.0,
        'video_analysis_keep_step_s': 0.0,
        'video_analysis_occlusion_s': -1.0,
      });
      final p = await VideoAnalysisPrefs.load();
      // "Find animals in videos" divides the video by 1 / analysisFps and
      // keeps a frame every keepStepSeconds: neither may be 0 or negative.
      expect(p.analysisFps, greaterThan(0));
      expect(p.sampleSeconds, greaterThan(0));
      expect(p.keepStepSeconds, greaterThan(0));
      expect(p.occlusionSeconds, greaterThan(0));
    });

    test('trackerConfig builds a tracker for the extremes without throwing', () {
      for (final occ in [0.2, 10.0]) {
        for (final minVisit in [0.0, 1.0, 2.0]) {
          final p = VideoAnalysisPrefs(occlusionSeconds: occ, minVisitSeconds: minVisit);
          final cfg = p.trackerConfig(const SessionConfig());
          for (final fps in [0.5, 5.0, 30.0]) {
            cfg.buildTracker(fps);
          }
          expect(p.newTrackConfidence, isNotNull);
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  group('IdentifyPrefs: values saved with another type', () {
    final doubleKeys = [
      'identify_margin',
      'identify_tau',
      'identify_none_threshold',
      'identify_thermal_limit_c',
      'identify_merge_gap_s',
      'identify_merge_size_tol',
      'identify_merge_min_cos',
      'identify_flag_min_duration_s',
      'identify_flag_min_det_conf',
      'identify_flag_min_order_p',
      'identify_drop_factor',
    ];
    final intKeys = [
      'identify_cpu_threads',
      'identify_min_crop_px',
      'identify_max_crops_per_track',
      'identify_flag_min_detections',
    ];

    test('every value round-trips through save and load', () async {
      final p = IdentifyPrefs(
        modelName: 'm.tflite',
        packName: 'p.json',
        useGpu: false,
        cpuThreads: 4,
        margin: 0.3,
        minCropPx: 64,
        maxCropsPerTrack: 7,
        tau: 0.8,
        mergeVisits: true,
        dropFactor: 5,
      );
      await p.save();
      final back = await IdentifyPrefs.load();
      expect(back.toJson(), p.toJson());
    });

    test('a decimal setting saved as TEXT: load must not throw, other settings stay', () async {
      final failures = <String>[];
      for (final key in doubleKeys) {
        SharedPreferences.setMockInitialValues({'identify_tau': 0.9, key: 'oops'});
        try {
          final p = await IdentifyPrefs.load();
          if (key != 'identify_tau' && p.tau != 0.9) failures.add('$key: other setting lost');
        } catch (e) {
          failures.add('$key: ${e.runtimeType}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, skip: 'BUG: IdentifyPrefs.load() uses getDouble with no guard; another type throws a TypeError and the identification screen cannot open (identification_assets.dart:188-215)');

    test('a decimal setting saved as a WHOLE NUMBER: load must not throw', () async {
      final failures = <String>[];
      for (final key in doubleKeys) {
        SharedPreferences.setMockInitialValues({key: 1});
        try {
          await IdentifyPrefs.load();
        } catch (e) {
          failures.add('$key: ${e.runtimeType}');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, skip: 'BUG: same cause: getDouble on a stored int throws a TypeError (identification_assets.dart:188-215)');

    test('a whole-number setting saved as a DECIMAL or TEXT: load must not throw', () async {
      final failures = <String>[];
      for (final key in intKeys) {
        for (final wrong in <Object>[2.5, 'x']) {
          SharedPreferences.setMockInitialValues({key: wrong});
          try {
            await IdentifyPrefs.load();
          } catch (e) {
            failures.add('$key=$wrong: ${e.runtimeType}');
          }
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, skip: 'BUG: getInt without a guard (identification_assets.dart:196-210)');

    test('the model name saved as a number: load must not throw', () async {
      SharedPreferences.setMockInitialValues({kIdentifyModelPref: 5, kIdentifyPackPref: true});
      await IdentifyPrefs.load();
    }, skip: 'BUG: getString without a guard (identification_assets.dart:188-189)');

    test('absurd numbers are loaded as they are: every value ends up inside the range of its box', () async {
      // Boxes (identify_settings_fields.dart): crops per track ID 0 (= all) to 100, smallest box 16 to 512,
      // ignore-factor 1 to 100, confidence needed 0.5 to 0.99, crop margin 0 to 0.5, CPU threads 0 to 8.
      SharedPreferences.setMockInitialValues({
        'identify_max_crops_per_track': -4,
        'identify_min_crop_px': -4,
        'identify_drop_factor': 0.0,
        'identify_margin': -3.0,
        'identify_tau': 0.0,
        'identify_none_threshold': 7.0,
        'identify_merge_gap_s': -9.0,
        'identify_cpu_threads': 9999,
      });
      final p = await IdentifyPrefs.load();
      final bad = <String>[
        if (p.maxCropsPerTrack < 0 || p.maxCropsPerTrack > 100) 'crops per track ${p.maxCropsPerTrack}',
        if (p.minCropPx < 16 || p.minCropPx > 512) 'smallest box ${p.minCropPx}',
        if (p.dropFactor < 1 || p.dropFactor > 100) 'ignore factor ${p.dropFactor}',
        if (p.margin < 0 || p.margin > 0.5) 'crop margin ${p.margin}',
        if (p.tau < 0.5 || p.tau > 0.99) 'confidence needed ${p.tau}',
        if (p.noneThreshold < 0.1 || p.noneThreshold > 0.9) 'no-organism threshold ${p.noneThreshold}',
        if (p.mergeGapS < 0.5 || p.mergeGapS > 120) 'merge gap ${p.mergeGapS}',
        if (p.cpuThreads < 0 || p.cpuThreads > 8) 'cpu threads ${p.cpuThreads}',
      ];
      expect(bad, isEmpty, reason: 'outside the box range: $bad');
    }, skip: 'BUG: IdentifyPrefs.load() does not clamp anything (tau 0 makes every rank "identified", ignore factor 0, negative margin, 9999 threads are used as saved) (identification_assets.dart:188-215)');

    test('the per-model speed key never contains path characters', () {
      for (final name in ['a/b\\c:d*e?"<>|', '../../x', 'ü ö ä 日本', '', 'x' * 500]) {
        final k = IdentifyPrefs.msPerCropKey(name);
        expect(RegExp(r'^identify_ms_per_crop_[A-Za-z0-9._-]*$').hasMatch(k), isTrue, reason: k);
      }
    });
  });
}
