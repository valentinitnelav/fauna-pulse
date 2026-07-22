// Tests for the post-hoc batch detection driver (round 135): file selection,
// filename time parsing, resume bookkeeping and the run loop itself (with a
// fake predictor — no native channel involved).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/post_detector.dart';

void main() {
  group('capturedAtMsFromPhotoName', () {
    test('parses the trigger stamp as local time', () {
      final ms = capturedAtMsFromPhotoName('roi_k7x2_2026-07-14_153045_123.jpg');
      expect(ms, DateTime(2026, 7, 14, 15, 30, 45, 123).millisecondsSinceEpoch);
    });

    test('works for any prefix (gt frames share the stamp format)', () {
      final ms = capturedAtMsFromPhotoName('gt_ab12_2025-01-02_010203_004.jpg');
      expect(ms, DateTime(2025, 1, 2, 1, 2, 3, 4).millisecondsSinceEpoch);
    });

    test('returns null when no stamp is present', () {
      expect(capturedAtMsFromPhotoName('photo.jpg'), isNull);
    });
  });

  group('selectPhotoNames', () {
    test('skips a _live companion when its main photo exists', () {
      final picked = selectPhotoNames([
        'roi_a_2026-07-14_120000_000.jpg',
        'roi_a_2026-07-14_120000_000_live.jpg',
      ]);
      expect(picked, ['roi_a_2026-07-14_120000_000.jpg']);
    });

    test('keeps an orphan _live companion (failed high-res write)', () {
      final picked = selectPhotoNames(['roi_a_2026-07-14_120000_000_live.jpg']);
      expect(picked, ['roi_a_2026-07-14_120000_000_live.jpg']);
    });

    test('sorts by name (capture order) and drops non-jpg files', () {
      final picked = selectPhotoNames([
        'roi_a_2026-07-14_120001_000.jpg',
        'roi_a_2026-07-14_120000_000.jpg',
        'notes.txt',
      ]);
      expect(picked, [
        'roi_a_2026-07-14_120000_000.jpg',
        'roi_a_2026-07-14_120001_000.jpg',
      ]);
    });
  });

  test('processedNamesFromJsonl reads done photos, tolerates truncation', () {
    final content = [
      jsonEncode({'type': 'post_start', 'model': 'm'}),
      jsonEncode({'type': 'post_detection', 'jpeg': 'a.jpg', 'boxes': []}),
      jsonEncode({'type': 'post_detection', 'jpeg': 'b.jpg', 'boxes': []}),
      '{"type":"post_detection","jpeg":"trunc', // crash-truncated line
    ].join('\n');
    expect(processedNamesFromJsonl(content), {'a.jpg', 'b.jpg'});
  });

  test('boxesFromPredictResult reads normalized boxes', () {
    final boxes = boxesFromPredictResult({
      'detections': [
        {
          'className': 'bee',
          'confidence': 0.9,
          'normalizedBox': {
            'left': 0.1,
            'top': 0.2,
            'right': 0.3,
            'bottom': 0.4,
          },
        },
      ],
    });
    expect(boxes, hasLength(1));
    expect(boxes.first.className, 'bee');
    expect(boxes.first.confidence, 0.9);
    expect(boxes.first.toJson()['box'], [0.1, 0.2, 0.3, 0.4]);
  });

  group('PostDetector.run', () {
    late Directory sessionDir;

    const config = PostRunConfig(
      modelPath: 'model.tflite',
      modelName: 'model',
      confidence: 0.25,
      iou: 0.7,
      useGpu: true,
    );

    Map<String, dynamic> fakeResult() => {
      'detections': [
        {
          'className': 'bee',
          'confidence': 0.8,
          'normalizedBox': {
            'left': 0.1,
            'top': 0.1,
            'right': 0.2,
            'bottom': 0.2,
          },
        },
      ],
    };

    setUp(() {
      sessionDir = Directory.systemTemp.createTempSync('post_detector_test');
      final frames = Directory('${sessionDir.path}/roi_frames')
        ..createSync(recursive: true);
      for (final name in [
        'roi_t_2026-07-14_120000_000.jpg',
        'roi_t_2026-07-14_120001_000.jpg',
        'roi_t_2026-07-14_120002_000.jpg',
      ]) {
        File('${frames.path}/$name').writeAsBytesSync([1, 2, 3]);
      }
    });

    tearDown(() => sessionDir.deleteSync(recursive: true));

    List<Map<String, dynamic>> records() =>
        File('${sessionDir.path}/${PostDetector.outputFileName}')
            .readAsLinesSync()
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();

    test('processes every photo and writes start/detection/end records',
        () async {
      final seen = <Uint8List>[];
      final detector = PostDetector(
        predict: (bytes) async {
          seen.add(bytes);
          return fakeResult();
        },
      );
      final result = await detector.run(sessionDir, config: config);

      expect(result.processed, 3);
      expect(result.failed, 0);
      expect(result.cancelled, isFalse);
      expect(seen, hasLength(3));

      final recs = records();
      expect(recs.first['type'], 'post_start');
      expect(recs.first['photos_pending'], 3);
      final dets = recs.where((r) => r['type'] == 'post_detection').toList();
      expect(dets, hasLength(3));
      expect(dets.first['captured_at_ms'], isNotNull);
      expect((dets.first['boxes'] as List).single['class_name'], 'bee');
      expect(recs.last['type'], 'post_end');
      expect(recs.last['ended_normally'], isTrue);
    });

    test('a second run skips already-processed photos', () async {
      final detector = PostDetector(predict: (_) async => fakeResult());
      await detector.run(sessionDir, config: config);

      var calls = 0;
      final second = PostDetector(
        predict: (_) async {
          calls++;
          return fakeResult();
        },
      );
      final result = await second.run(sessionDir, config: config);
      expect(calls, 0);
      expect(result.processed, 0);
      expect(result.skippedDone, 3);
    });

    test('cancel stops between photos and marks the end record', () async {
      var calls = 0;
      final detector = PostDetector(
        predict: (_) async {
          calls++;
          return fakeResult();
        },
      );
      final result = await detector.run(
        sessionDir,
        config: config,
        isCancelled: () => calls >= 1,
      );
      expect(result.cancelled, isTrue);
      expect(result.processed, 1);
      expect(records().last['reason'], 'cancelled');

      // The interrupted run resumes: only the remaining photos are pending.
      final resumed = await PostDetector(
        predict: (_) async => fakeResult(),
      ).run(sessionDir, config: config);
      expect(resumed.processed, 2);
      expect(resumed.skippedDone, 1);
    });

    test('a failing photo is recorded and the run continues', () async {
      var calls = 0;
      final detector = PostDetector(
        predict: (_) async {
          calls++;
          if (calls == 2) throw Exception('boom');
          return fakeResult();
        },
      );
      final result = await detector.run(sessionDir, config: config);
      expect(result.processed, 2);
      expect(result.failed, 1);
      final failedRec = records().firstWhere((r) => r['error'] != null);
      expect(failedRec['type'], 'post_detection');
      expect(failedRec['boxes'], isEmpty);
    });
  });
}
