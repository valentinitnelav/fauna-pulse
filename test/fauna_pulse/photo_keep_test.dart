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

    test('pair rule: a hit on EITHER member keeps both (round 137)', () {
      // Companion detected, high-res main missed (or vice versa) — the pair
      // stands together. An unrelated distant pair is dropped whole.
      final outcomes = [
        o('roi_a.jpg', 0, false),
        o('roi_a_live.jpg', 0, true),
        o('roi_b.jpg', 60000, false),
        o('roi_b_live.jpg', 60000, false),
      ];
      expect(keepNames(outcomes, 2000), {'roi_a.jpg', 'roi_a_live.jpg'});
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

  test('photoOutcomesFromJsonl parses boxes for the viewer overlay', () {
    final content = jsonEncode({
      'type': 'post_detection',
      'jpeg': 'a.jpg',
      'captured_at_ms': 5,
      'boxes': [
        {'class_name': 'bee', 'conf': 0.83, 'box': [0.1, 0.2, 0.3, 0.4]},
      ],
    });
    final box = photoOutcomesFromJsonl(content).single.boxes.single;
    expect(box.className, 'bee');
    expect(box.confidence, 0.83);
    expect([box.left, box.top, box.right, box.bottom], [0.1, 0.2, 0.3, 0.4]);
  });

  test('pairBase strips the _live suffix', () {
    expect(pairBase('roi_a_live.jpg'), 'roi_a.jpg');
    expect(pairBase('roi_a.jpg'), 'roi_a.jpg');
  });

  group('keepDecisions (round 138: keep reasons for the review UI)', () {
    test('bridged photos name the NEAREST decisive detection, signed delta',
        () {
      final decisions = keepDecisions([
        o('hit_early.jpg', 0, true),
        o('miss.jpg', 1500, false), // 1.5 s after early hit, 2.5 s before late
        o('hit_late.jpg', 4000, true),
      ], 3000);
      final d = decisions['miss.jpg']!;
      expect(d.reason, KeepReason.bridged);
      expect(d.decisiveName, 'hit_early.jpg');
      expect(d.deltaMs, -1500); // decisive detection is EARLIER
    });

    test('prefers the closer detection when both sides are in the window', () {
      final decisions = keepDecisions([
        o('hit_early.jpg', 0, true),
        o('miss.jpg', 2600, false),
        o('hit_late.jpg', 4000, true), // 1.4 s away vs 2.6 s
      ], 3000);
      final d = decisions['miss.jpg']!;
      expect(d.decisiveName, 'hit_late.jpg');
      expect(d.deltaMs, 1400); // decisive detection is LATER
    });

    test('pair members kept via sibling carry the sibling name', () {
      final decisions = keepDecisions([
        o('roi_a.jpg', 0, false),
        o('roi_a_live.jpg', 0, true),
      ], 0);
      expect(decisions['roi_a_live.jpg']!.reason, KeepReason.detected);
      final d = decisions['roi_a.jpg']!;
      expect(d.reason, KeepReason.pair);
      expect(d.decisiveName, 'roi_a_live.jpg');
    });

    test('deleted photos are simply absent from the map', () {
      final decisions = keepDecisions([
        o('hit.jpg', 0, true),
        o('far.jpg', 60000, false),
      ], 2000);
      expect(decisions.containsKey('far.jpg'), isFalse);
      expect(keepNames([o('hit.jpg', 0, true), o('far.jpg', 60000, false)], 2000),
          {'hit.jpg'});
    });
  });

  test('formatKeepWindow / formatKeepDelta', () {
    expect(formatKeepWindow(2), '2 s');
    expect(formatKeepWindow(2.5), '2.5 s');
    expect(formatKeepWindow(90), '90 s');
    expect(formatKeepWindow(300), '5 min');
    expect(formatKeepWindow(3600), '1 h');
    expect(formatKeepDelta(3000), '3 s later');
    expect(formatKeepDelta(-90000), '90 s earlier');
    expect(formatKeepDelta(-120000), '2 min earlier');
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

  // Round 172: the analysis screen showed the raw FILE count as "photos"
  // (126 for a 63-photo high-res session whose summary says 63). These
  // helpers are the single source of the photo-unit counting it now uses.
  group('photoUnitCount / analyzedPhotoUnitCount', () {
    const names = [
      'roi_a_2026-07-17_100000_000.jpg',
      'roi_a_2026-07-17_100000_000_live.jpg', // pair with the one above
      'roi_a_2026-07-17_100001_000.jpg', // plain photo, no companion
      'roi_a_2026-07-17_100002_000_live.jpg', // orphan (high-res write failed)
    ];

    test('a high-res/live pair counts as ONE photo, an orphan as its own', () {
      expect(photoUnitCount(names), 3);
    });

    test('sessions without companions count 1:1', () {
      expect(
        photoUnitCount(['a.jpg', 'b.jpg', 'c.jpg']),
        3,
      );
    });

    test('a photo is analyzed only when EVERY pair member is done', () {
      // Only the high-res member of the pair is done: the pair stays pending.
      expect(
        analyzedPhotoUnitCount(names, {'roi_a_2026-07-17_100000_000.jpg'}),
        0,
      );
      // Both members done + the orphan done = 2 of 3 photos analyzed.
      expect(
        analyzedPhotoUnitCount(names, {
          'roi_a_2026-07-17_100000_000.jpg',
          'roi_a_2026-07-17_100000_000_live.jpg',
          'roi_a_2026-07-17_100002_000_live.jpg',
        }),
        2,
      );
    });
  });

  // Round 179 (owner idea): the tiny-box threshold as a REVIEW-time
  // sensitivity filter over already-recorded boxes — the cleanup numbers
  // re-derive live instead of needing a re-analysis per value.
  group('applyMinBoxFrac / lastSahiMinBoxFrac', () {
    PhotoOutcome outcome(String name, List<PostBox> boxes, {bool failed = false}) =>
        PhotoOutcome(name, 1000, failed ? null : boxes.isNotEmpty, boxes);

    PostBox box(double w, double h) => PostBox(
      className: 'bee',
      confidence: 0.9,
      left: 0.4,
      top: 0.4,
      right: 0.4 + w,
      bottom: 0.4 + h,
    );

    test('0 = off returns the outcomes untouched', () {
      final list = [outcome('a.jpg', [box(0.01, 0.01)])];
      expect(identical(applyMinBoxFrac(list, 0), list), isTrue);
    });

    test('drops dots and slivers by the NARROWER side, recomputes hasBoxes',
        () {
      final filtered = applyMinBoxFrac([
        outcome('dot.jpg', [box(0.01, 0.01)]), // dot: gone
        outcome('sliver.jpg', [box(0.20, 0.01)]), // long but thin: gone
        outcome('insect.jpg', [box(0.08, 0.06), box(0.01, 0.01)]),
      ], 0.05);
      expect(filtered[0].hasBoxes, isFalse);
      expect(filtered[0].boxes, isEmpty);
      expect(filtered[1].hasBoxes, isFalse);
      expect(filtered[2].hasBoxes, isTrue);
      expect(filtered[2].boxes, hasLength(1)); // the dot beside it is gone
      // Boundary: exactly the threshold survives (mirrors the analysis-time
      // filter's `< minBoxFrac` drop rule). Anchored at 0 so the width is
      // the same double as the threshold literal (0.4+0.05-0.4 is not).
      expect(
        applyMinBoxFrac([
          outcome('edge.jpg', const [
            PostBox(
              className: 'bee',
              confidence: 0.9,
              left: 0,
              top: 0,
              right: 0.05,
              bottom: 0.05,
            ),
          ]),
        ], 0.05).single.hasBoxes,
        isTrue,
      );
    });

    test('failed photos (hasBoxes null) pass through untouched', () {
      final filtered = applyMinBoxFrac([
        outcome('failed.jpg', const [], failed: true),
      ], 0.05);
      expect(filtered.single.hasBoxes, isNull);
    });

    test('lastSahiMinBoxFrac reads the LAST run, plain runs reset to null',
        () {
      String start({double? minBox}) => jsonEncode({
        'type': 'post_start',
        'model': 'm',
        if (minBox != null)
          'sahi': {'tile_px': 320, 'min_box_frac': minBox},
      });
      expect(lastSahiMinBoxFrac(''), isNull);
      expect(lastSahiMinBoxFrac(start(minBox: 0.02)), 0.02);
      expect(
        lastSahiMinBoxFrac('${start(minBox: 0.05)}\n${start(minBox: 0.02)}'),
        0.02,
      );
      // A newer PLAIN run (no sahi block) means the current records are not
      // pre-filtered at all.
      expect(lastSahiMinBoxFrac('${start(minBox: 0.05)}\n${start()}'), isNull);
    });
  });
}
