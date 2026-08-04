// Reproduction/regression test for the owner's round-175 report: after a
// SAHI analysis of a TIME-LAPSE session, "Review photos before deleting"
// (the summary's Photos tab) showed NO green post-hoc boxes even though
// post_detections.jsonl carries boxes for nearly every photo.
//
// Follows summary_bottom_inset_test.dart's async recipe (sync fixture IO,
// runAsync/pump interleave — see that file's header for why).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';

void main() {
  testWidgets(
    'time-lapse session: post-hoc boxes from post_detections.jsonl are '
    'painted on the Photos tab',
    (tester) async {
      SharedPreferences.setMockInitialValues({});

      const jpegName = 'roi_t3st_2026-08-04_193515_231.jpg';
      final tmp = Directory.systemTemp.createTempSync('summary_posthoc');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      // A real (tiny) JPEG so the viewer's Image.file has something to show.
      final im = img.Image(width: 32, height: 32);
      img.fill(im, color: img.ColorRgb8(40, 120, 40));
      Directory('${tmp.path}/roi_frames').createSync();
      File(
        '${tmp.path}/roi_frames/$jpegName',
      ).writeAsBytesSync(img.encodeJpg(im, quality: 90));
      // The session log: a time-lapse session with one photo.
      File('${tmp.path}/session.jsonl').writeAsStringSync([
        '{"type":"start_of_session","time_ms":1000,"session_id":"t",'
            '"config":{"captureTrigger":"timelapse"}}',
        '{"type":"timelapse_capture","time_ms":2000,"jpeg":"$jpegName",'
            '"captured_at_ms":1990,"burst":0}',
        '{"type":"end_of_session","time_ms":60000,"ended_normally":true,'
            '"unique_track_count":0}',
      ].join('\n'));
      // The analysis results: one detection box on that photo (the shape a
      // SAHI run writes — same record the owner's session carries).
      File('${tmp.path}/post_detections.jsonl').writeAsStringSync([
        '{"type":"post_start","time_ms":5000,"model":"m.tflite",'
            '"model_name":"m","confidence":0.25,"iou":0.7,"use_gpu":true,'
            '"photos_total":1,"photos_pending":1}',
        '{"type":"post_detection","time_ms":6000,"jpeg":"$jpegName",'
            '"captured_at_ms":1990,"infer_ms":50,"boxes":[{"class_name":"bee",'
            '"conf":0.9,"box":[0.1,0.2,0.3,0.4]}]}',
        '{"type":"post_end","time_ms":7000,"processed":1,"failed":0,'
            '"skipped_done":0,"ended_normally":true}',
      ].join('\n'));

      await tester.pumpWidget(
        MaterialApp(
          home: SessionSummaryScreen(
            logFile: File('${tmp.path}/session.jsonl'),
            initialTabIndex: 2, // Photos tab — the review-before-delete path
          ),
        ),
      );
      // Wait for the tab chrome (the "All" button), then request the photos
      // exactly like the owner does, and wait for the viewer.
      for (var i = 0; i < 250; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.text('All').evaluate().isNotEmpty) break;
      }
      await tester.tap(find.text('All'));
      for (var i = 0; i < 250; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (find.textContaining('saved photo').evaluate().isNotEmpty) break;
      }
      expect(
        find.textContaining('Showing 1 of 1 saved photo'),
        findsOneWidget,
        reason: 'photo viewer never appeared — fixture/load problem',
      );
      // A few more cycles so the async _loadPostHoc setState lands too.
      for (var i = 0; i < 25; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }

      // Find the box-overlay painter and assert the green post-hoc box is in
      // its list. The painter/box classes are private; their FIELDS have
      // public names, so dynamic access works here.
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .where((p) => p.runtimeType.toString() == '_BoxPainter')
          .toList();
      expect(
        painters,
        isNotEmpty,
        reason: 'no box painter found — boxes overlay not built at all',
      );
      final boxes = (painters.first as dynamic).boxes as List;
      final postHoc = boxes.where((b) => (b as dynamic).postHoc == true);
      expect(
        postHoc,
        isNotEmpty,
        reason:
            'post_detections.jsonl carries a box for the shown photo, but '
            'no post-hoc box reached the painter (owner bug, round 175)',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
