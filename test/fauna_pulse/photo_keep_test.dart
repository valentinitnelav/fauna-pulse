// Tests for the photo-keep / cleanup logic (round 136): which analyzed photos
// survive storage triage, the deletion run itself, and the session-head parse
// that tells AI-live sessions apart from motion/time-lapse ones.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_keep.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/post_detector.dart';

void main() {
  PhotoOutcome o(String name, int? atMs, bool? boxes) =>
      PhotoOutcome(name, atMs, boxes);

  group('keepNames', () {
    test('keeps detections, bridges a nearby miss, drops distant photos', () {
      final outcomes = [
        o('a.jpg', 0, true),
        o('b.jpg', 1000, false), // 1 s after a hit — bridged
        o('c.jpg', 2000, true),
        o('d.jpg', 3500, false), // 1.5 s after last hit — kept (within 2 s)
        o('e.jpg', 10000, false), // far from any hit — dropped
      ];
      expect(
        keepNames(outcomes, 2000),
        {'a.jpg', 'b.jpg', 'c.jpg', 'd.jpg'},
      );
    });

    test('gap 0 keeps only detections themselves', () {
      final outcomes = [
        o('a.jpg', 0, true),
        o('b.jpg', 1000, false),
      ];
      expect(keepNames(outcomes, 0), {'a.jpg'});
    });

    test('neighbours BEFORE a detection are kept too (insect arriving)', () {
      final outcomes = [
        o('a.jpg', 0, false),
        o('b.jpg', 1000, true),
      ];
      expect(keepNames(outcomes, 1500), {'a.jpg', 'b.jpg'});
    });

    test('a failed analysis is always kept — no result is not no insect', () {
      final outcomes = [o('a.jpg', 0, null)];
      expect(keepNames(outcomes, 2000), {'a.jpg'});
    });

    test('a photo without a parseable timestamp is kept only on detection',
        () {
      final outcomes = [
        o('hit.jpg', 0, true),
        o('nostamp.jpg', null, false),
      ];
      expect(keepNames(outcomes, 5000), {'hit.jpg'});
    });
  });

  test('photoOutcomesFromJsonl: last record per photo wins, error → null', () {
    final content = [
      jsonEncode({
        'type': 'post_detection',
        'jpeg': 'a.jpg',
        'captured_at_ms': 5,
        'boxes': [
          {'class_name': 'bee', 'conf': 0.9, 'box': [0, 0, 1, 1]},
        ],
      }),
      jsonEncode({
        'type': 'post_detection',
        'jpeg': 'a.jpg',
        'captured_at_ms': 5,
        'boxes': [],
      }),
      jsonEncode({
        'type': 'post_detection',
        'jpeg': 'b.jpg',
        'captured_at_ms': 7,
        'error': 'boom',
        'boxes': [],
      }),
    ].join('\n');
    final outcomes = photoOutcomesFromJsonl(content);
    expect(outcomes, hasLength(2));
    expect(outcomes.firstWhere((x) => x.name == 'a.jpg').hasBoxes, isFalse);
    expect(outcomes.firstWhere((x) => x.name == 'b.jpg').hasBoxes, isNull);
  });

  group('planCleanup + runCleanup', () {
    late Directory sessionDir;

    setUp(() {
      sessionDir = Directory.systemTemp.createTempSync('photo_keep_test');
      Directory('${sessionDir.path}/roi_frames').createSync(recursive: true);
    });

    tearDown(() => sessionDir.deleteSync(recursive: true));

    void photo(String name) =>
        File('${sessionDir.path}/roi_frames/$name').writeAsBytesSync([1, 2, 3]);

    test('deletes unkept photos + their _live companions, writes the audit '
        'record', () async {
      photo('keep.jpg');
      photo('drop.jpg');
      photo('drop_live.jpg');
      final outcomes = [
        o('keep.jpg', 0, true),
        o('drop.jpg', 60000, false),
      ];
      final keep = keepNames(outcomes, 2000);
      final plan = planCleanup(sessionDir, outcomes, keep);
      expect(plan.deleteNames, containsAll(['drop.jpg', 'drop_live.jpg']));
      expect(plan.deleteBytes, 6);

      final deleted = await runCleanup(sessionDir, plan, gapSeconds: 2.0);
      expect(deleted, 2);
      expect(File('${sessionDir.path}/roi_frames/keep.jpg').existsSync(), true);
      expect(
        File('${sessionDir.path}/roi_frames/drop.jpg').existsSync(),
        false,
      );

      final audit = File(
        '${sessionDir.path}/${PostDetector.outputFileName}',
      ).readAsLinesSync().map(jsonDecode).toList();
      final rec = audit.last as Map<String, dynamic>;
      expect(rec['type'], 'post_cleanup');
      expect(rec['deleted'], 2);
      expect(rec['gap_seconds'], 2.0);
    });

    test('an already-missing file is skipped without error', () async {
      final outcomes = [o('gone.jpg', 0, false)];
      final plan = planCleanup(sessionDir, outcomes, const {});
      expect(plan.deleteNames, isEmpty);
      expect(await runCleanup(sessionDir, plan, gapSeconds: 1.0), 0);
    });
  });

  group('liveSessionInfoFromLogHead', () {
    String startLine(Map<String, dynamic> config) => jsonEncode({
      'type': 'start_of_session',
      'time_ms': 1,
      'config': config,
    });

    test('reads an explicit captureTrigger + model', () {
      final info = liveSessionInfoFromLogHead(
        startLine({'captureTrigger': 'timelapse', 'modelPath': 'yolo26n'}),
      );
      expect(info!.captureTrigger, 'timelapse');
      expect(info.modelPath, 'yolo26n');
      expect(info.usedDetectorLive, isFalse);
    });

    test('legacy motionOnlyCapture bool maps to motion', () {
      final info = liveSessionInfoFromLogHead(
        startLine({'motionOnlyCapture': true}),
      );
      expect(info!.captureTrigger, 'motion');
    });

    test('no trigger fields at all means detector (the old default)', () {
      final info = liveSessionInfoFromLogHead(
        startLine({'modelPath': 'yolo26n'}),
      );
      expect(info!.usedDetectorLive, isTrue);
    });

    test('no start record yields null', () {
      expect(liveSessionInfoFromLogHead('{"type":"fps"}'), isNull);
    });
  });
}
