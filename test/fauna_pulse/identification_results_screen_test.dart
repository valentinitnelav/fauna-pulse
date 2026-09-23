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
    for (var k = 0; k < 7; k++) {'rank': _ranks[k], 'taxon': path[k], 'p': p, 'p_mean': p, 'p_max': p, 'support': 1.0},
  ],
  'flags': const [],
  'best_view': {'src': 'a.jpg', 'species': path.last, 'p': p},
  'crops': [
    {'src': 'a.jpg', 'box': [0.1, 0.1, 0.5, 0.5], 'crop_px': 200, 'sharpness': 10.0, 'top1': path.last, 'top1_tree': path.take(5).toList(), 'top1_p': p, 'agrees': true, 'counted': true, 'p_ladder': List.filled(7, p)},
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
    // Round 221: track id #1 carries flags, each shown where it applies; a
    // Diptera species beat the ladder's species below the reported genus.
    ((tracks.first['ladder'] as List)[6] as Map<String, Object>).addAll({
      'p': 0.2,
      'rival': 'Eristalis tenax',
      'rival_p': 0.3,
      'rival_lineage': ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Eristalis'],
    });
    tracks.first['flags'] = ['short', 'path_conflict', 'single_crop'];
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
    // The sheet's explanation block can push the first (lazily built) row
    // below the fold under the test font: scroll the sheet's own list.
    // Round 217: Agree column in S3 (checked before scrolling: the lazy
    // list disposes its header row once it leaves the viewport).
    expect(find.text('Agree'), findsOneWidget);
    await tester.dragUntilVisible(find.text('#1'), find.byType(ListView).last, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('#1'), findsOneWidget);
    // Round 222: Agree split into share and count columns.
    expect(find.text('100 %'), findsWidgets);
    expect(find.text('1/1'), findsWidgets); // one crop per track
    // Open the track id's sheet (S4): best-single-photo line, no Avg/Weight.
    await tester.tap(find.text('#1'));
    await tester.pumpAndSettle();
    final sheet = find.byType(ListView).last;
    expect(find.textContaining('Short visit: '), findsOneWidget);
    // Round 222: the reported genus row keeps white, the species below the
    // threshold is grey.
    expect(tester.widget<Text>(find.text('Bombus')).style?.color, Colors.white);
    expect(tester.widget<Text>(find.text('Bombus terrestris').first).style?.color, Colors.white54);
    await tester.dragUntilVisible(find.textContaining('(path_conflict)'), sheet, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'species: Eristalis tenax (order Diptera, not Hymenoptera) scores 30 %, more than Bombus terrestris '
        '(20 %), the best species inside Bombus (path_conflict)',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets); // on the species row and the notes
    await tester.dragUntilVisible(find.textContaining('Best single photo'), sheet, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.textContaining('Best single photo'), findsOneWidget);
    expect(find.text('Avg'), findsNothing);
    expect(find.text('Weight'), findsNothing);
    expect(find.textContaining('left out'), findsNothing); // every fixture crop counted
    // Round 222: the photo's file name on its own line; the crops table ends
    // with the top species' family, order and class, one column each.
    expect(find.text('Showing crop No. 1 (best view):'), findsOneWidget);
    await tester.dragUntilVisible(find.text('Class'), sheet, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('Taxonomic tree'), findsNothing);
    expect(find.text('Insecta'), findsWidgets);
    expect(find.textContaining('"?" = a value'), findsNothing); // fixture has every value
    expect(find.textContaining('(single_crop)'), findsOneWidget); // above the crops table
    await tester.dragUntilVisible(find.textContaining('Flags in tracks CSV'), sheet, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(find.text('Flags in tracks CSV: short, path_conflict, single_crop'), findsOneWidget);
    // Close both sheets (dragging expanded them to full height, so there is
    // no barrier left to tap).
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('Track id'), findsNothing);

    // .first: the taxon table may add its own horizontal Scrollable (it
    // does under the test font, whose glyphs are all 13 px wide).
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    expectAboveBottomInset(tester, find.textContaining('All 41 track ids'), label: 'last results row');

    // Round 222: "All track ids": rank in its own column; the table scrolls
    // sideways under a title that stays in place.
    await tester.tap(find.textContaining('All 41 track ids'));
    await tester.pumpAndSettle();
    expect(find.text('Rank'), findsNWidgets(2)); // S2's and this sheet's
    expect(find.text('Crops agree'), findsOneWidget);
    final title = find.text('All track ids · 41 track ids');
    final titleX = tester.getTopLeft(title).dx, headerX = tester.getTopLeft(find.text('Crops agree')).dx;
    final sideways = tester
        .stateList<ScrollableState>(find.ancestor(of: find.text('Crops agree'), matching: find.byType(Scrollable)))
        .firstWhere((s) => s.position.axis == Axis.horizontal);
    expect(sideways.position.maxScrollExtent, greaterThan(0));
    sideways.position.jumpTo(sideways.position.maxScrollExtent);
    await tester.pump();
    expect(tester.getTopLeft(title).dx, titleX);
    expect(tester.getTopLeft(find.text('Crops agree')).dx, lessThan(headerX));

    await tester.pumpWidget(const SizedBox());
  });
}
