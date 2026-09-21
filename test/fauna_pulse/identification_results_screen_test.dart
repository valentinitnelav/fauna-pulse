// Round 209: the identification results screen on a narrow phone with a
// bottom system bar — the table renders without overflow (a RenderFlex
// overflow is a test error), long pack/taxon names are ellipsised, and the
// last row clears the navigation bar (see summary_bottom_inset_test.dart
// for the pattern and its async traps).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_results_screen.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

const _ranks = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'];

Map<String, dynamic> _track(int id, List<String> path, String rank, double p) => {
  'track_id': id,
  'headline': path[_ranks.indexOf(rank)],
  'identified_rank': rank,
  'none_p': 0.01,
  'start_ms': 1000,
  'end_ms': 4000,
  'duration_s': 3.0,
  'det_conf_mean': 0.9,
  'ladder': [
    for (var k = 0; k < 7; k++) {'rank': _ranks[k], 'taxon': path[k], 'p': p, 'support': 1.0},
  ],
  'flags': const [],
  'best_view': {'src': 'a.jpg', 'species': path.last, 'p': p},
  'crops': [
    {'src': 'a.jpg', 'box': [0.1, 0.1, 0.5, 0.5], 'weight': 1.0, 'crop_px': 200, 'sharpness': 10.0, 'top1': path.last, 'top1_p': p},
  ],
};

void main() {
  testWidgets('results table: no overflow on a 360-px phone, last row above the bar', (tester) async {
    simulateBottomSystemBar(tester);
    final tmp = Directory.systemTemp.createTempSync('identify_results');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final idDir = Directory('${tmp.path}/identification')..createSync();
    final longName = List.filled(6, 'Averyveryverylongfamilyname').join('');
    final tracks = [
      for (var i = 1; i <= 40; i++)
        _track(i, ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris'], 'genus', 0.9),
      _track(41, ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', longName, 'X', 'X y'], 'family', 0.8),
    ];
    final tracksJson = File('${idDir.path}/tracks_p.json')
      ..writeAsStringSync(jsonEncode({'session_id': 's', 'tracks': tracks}));
    final summaryJson = File('${idDir.path}/summary_p.json')
      ..writeAsStringSync(
        jsonEncode({
          'generated_iso': '2026-09-21T10:00:00.000',
          'model_id': 'bioclip-2_image_fp16_with_a_very_long_model_file_name',
          'pack_id': 'bioclip2_flower_visitors_32fam_v1',
          'pack_rows': 38600,
          'tracks_total': 41,
          'by_identified_rank': {'genus': 40, 'family': 1},
          'none': 0,
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
    // Key/value header (round 214), one aggregated row for the 40 Bombus
    // visits (taxon and rank in separate cells), one for the long family.
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Label pack'), findsOneWidget);
    expect(find.text('Date run'), findsOneWidget);
    expect(find.text('2026-09-21 10:00'), findsOneWidget);
    expect(find.text('Bombus'), findsOneWidget);
    expect(find.text('genus'), findsWidgets);
    expect(find.text('40'), findsOneWidget);
    expect(find.text(longName), findsOneWidget);

    // Sort by taxon (tap the header): the long Diptera family sorts first.
    await tester.tap(find.text('Taxon'));
    await tester.pump();
    expect(tester.getTopLeft(find.text(longName)).dy, lessThan(tester.getTopLeft(find.text('Bombus')).dy));

    // Group by order: both rows collapse into their orders.
    await tester.tap(find.text('Order'));
    await tester.pump();
    expect(find.text('Hymenoptera'), findsOneWidget);
    expect(find.text('Diptera'), findsOneWidget);

    // Rank filter dropdown appears only when several ranks are present (not
    // here: both rows are orders), so the visits sheet is checked instead.
    await tester.tap(find.text('Hymenoptera'));
    await tester.pumpAndSettle();
    expect(find.text('Track id'), findsOneWidget);
    expect(find.text('No. ▲'), findsOneWidget); // default sort column
    expect(find.text('#1'), findsOneWidget); // first visible row (lazy list)
    // Close the sheet.
    await tester.tapAt(const Offset(180, 20));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    expectAboveBottomInset(tester, find.textContaining('All 41 visits'), label: 'last results row');

    await tester.pumpWidget(const SizedBox());
  });
}
