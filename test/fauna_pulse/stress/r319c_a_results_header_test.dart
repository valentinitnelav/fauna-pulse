// Round 319 part 3, Identification results screen (phone checks P1X, P2R):
// - A8: the header named the name list by its inner id
//   ('bioclip2_pollinator_orders_europe_v1') while Identify organisms lists its
//   file ('bioclip-2_pollinator-orders-europe_v1.fpack'). The stored results
//   keep the file name in their settings ('pack'); results without it still
//   show the inner id.
// - A4: one track ID gave the button 'All 1 track IDs'.

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/identification_results_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ranks = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'];
const _path = ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris'];

Map<String, dynamic> _track(int id) => {
  'track_id': id,
  'headline': 'Bombus',
  'identified_rank': 'genus',
  'none_p': 0.01,
  'start_ms': 1000,
  'end_ms': 4000,
  'duration_s': 3.0,
  'det_conf_mean': 0.9,
  'ladder': [
    for (var k = 0; k < 7; k++) {'rank': _ranks[k], 'taxon': _path[k], 'p': 0.9, 'p_mean': 0.9, 'p_max': 0.9, 'support': 1.0},
  ],
  'flags': const [],
  'best_view': {'src': 'a.jpg', 'species': _path.last, 'p': 0.9},
  'crops': [
    {'src': 'a.jpg', 'box': [0.1, 0.1, 0.5, 0.5], 'crop_px': 200, 'sharpness': 10.0, 'det_conf': 0.87, 'top1': _path.last, 'top1_tree': _path.take(5).toList(), 'top1_p': 0.9, 'agrees': true, 'counted': true, 'p_ladder': List.filled(7, 0.9)},
  ],
};

Future<void> _show(WidgetTester tester, {Map<String, dynamic>? settings, int tracks = 1}) async {
  final tmp = Directory.systemTemp.createTempSync('r319c_a_results');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final idDir = Directory('${tmp.path}/identification')..createSync();
  final tracksJson = File('${idDir.path}/tracks_p.json')
    ..writeAsStringSync(jsonEncode({'session_id': 's', 'tracks': [for (var i = 1; i <= tracks; i++) _track(i)]}));
  final summaryJson = File('${idDir.path}/summary_p.json')
    ..writeAsStringSync(
      jsonEncode({
        'generated_iso': '2026-10-21T12:53:00.000',
        'model_id': 'bioclip-2_224_fp16',
        'pack_id': 'bioclip2_pollinator_orders_europe_v1',
        'pack_rows': 35270,
        'pack_sink_rows': 6,
        'settings': ?settings,
        'tracks_total': tracks,
        'by_identified_rank': {'genus': tracks},
        'no_organism': 0,
        'unidentified': 0,
        'taxa_order': {},
        'taxa_family': {},
        'tracks': [],
      }),
    );
  await tester.pumpWidget(
    MaterialApp(
      home: IdentificationResultsScreen(
        sessionDir: tmp,
        tracksJson: tracksJson,
        summaryJson: summaryJson,
        tracksCsv: File('${idDir.path}/tracks_p.csv'),
      ),
    ),
  );
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (find.text('Bombus').evaluate().isNotEmpty) break;
  }
  expect(find.text('Name list'), findsOneWidget);
}

void main() {
  testWidgets('A8: the name list is named by its file, as on Identify organisms', (tester) async {
    await _show(tester, settings: {'model': 'bioclip-2_224_fp16.tflite', 'pack': 'bioclip-2_pollinator-orders-europe_v1.fpack'});
    expect(find.text('bioclip-2_pollinator-orders-europe_v1.fpack (35,264 names)'), findsOneWidget);
    expect(find.textContaining('bioclip2_pollinator_orders_europe_v1'), findsNothing);
  });

  testWidgets('A8: results without the file name in their settings show the inner id', (tester) async {
    await _show(tester, settings: {'model': 'bioclip-2_224_fp16.tflite'});
    expect(find.text('bioclip2_pollinator_orders_europe_v1 (35,264 names)'), findsOneWidget);
  });

  testWidgets('A4: one track ID: "All 1 track ID"', (tester) async {
    await _show(tester);
    expect(find.text('All 1 track ID', skipOffstage: false), findsOneWidget);
  });

  testWidgets('A4: two track IDs: "All 2 track IDs"', (tester) async {
    await _show(tester, tracks: 2);
    expect(find.text('All 2 track IDs', skipOffstage: false), findsOneWidget);
  });
}
