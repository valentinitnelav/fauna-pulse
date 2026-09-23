// Round 209: the Photos tab shows each visit's identification (from the
// newest summary_<pack>.json) as an "Identified" info row under the photo,
// keyed by track id — the answer is per visit, not per photo. Same fixture
// recipe as summary_posthoc_boxes_test.dart (sync IO, runAsync/pump loop).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fauna_pulse/fauna_pulse/screens/session_summary_screen.dart';

void main() {
  testWidgets('AI session photo shows the per-visit identification row', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const jpegName = 'roi_ai01_2026-08-04_120000_000.jpg';
    final tmp = Directory.systemTemp.createTempSync('summary_identified');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final im = img.Image(width: 32, height: 32);
    img.fill(im, color: img.ColorRgb8(40, 120, 40));
    Directory('${tmp.path}/roi_frames').createSync();
    File('${tmp.path}/roi_frames/$jpegName').writeAsBytesSync(img.encodeJpg(im, quality: 90));
    File('${tmp.path}/session.jsonl').writeAsStringSync([
      '{"type":"start_of_session","time_ms":1000,"session_id":"t","config":{"captureTrigger":"detector"}}',
      '{"type":"detections","time_ms":2000,"frame_ms":2000,"tracks":['
          '{"track_id":7,"class_name":"bee","confidence":0.91,'
          '"box_in_roi":{"left":0.1,"top":0.1,"right":0.3,"bottom":0.3},"jpeg":"$jpegName"}]}',
      '{"type":"end_of_session","time_ms":60000,"ended_normally":true,"unique_track_count":1}',
    ].join('\n'));
    // The compact per-visit list an identification run leaves behind.
    Directory('${tmp.path}/identification').createSync();
    File('${tmp.path}/identification/summary_pack1.json').writeAsStringSync(
      jsonEncode({
        'generated_iso': '2026-09-21T10:00:00.000',
        'pack_id': 'pack1',
        'tracks_total': 1,
        'tracks': [
          {'track_id': 7, 'headline': 'Bombus', 'identified_rank': 'genus', 'p': 0.87, 'n_crops': 1},
        ],
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: SessionSummaryScreen(logFile: File('${tmp.path}/session.jsonl'), initialTabIndex: 0)),
    );
    for (var i = 0; i < 250; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.text('Identified').evaluate().isNotEmpty) break;
    }
    expect(find.text('Identified'), findsOneWidget);
    expect(find.text('#7 Bombus (genus, 87 %)'), findsOneWidget);
    expect(find.textContaining('Identifications (pack pack1, 2026-09-21 10:00)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
