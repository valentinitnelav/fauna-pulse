// Round 209: the per-taxon aggregation behind the identification results
// table (one row per taxon with visits, time and median confidence).

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/taxa_table.dart';

Map<String, dynamic> track(
  int id, {
  required List<String> path,
  String? identifiedRank,
  double p = 0.9,
  double? durationS,
  String? headline,
}) {
  const ranks = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'];
  return {
    'track_id': id,
    'headline': headline ?? (identifiedRank == null ? 'unidentified' : path[ranks.indexOf(identifiedRank)]),
    'identified_rank': identifiedRank,
    'duration_s': durationS,
    'ladder': [
      for (var k = 0; k < path.length; k++) {'rank': ranks[k], 'taxon': path[k], 'p': p, 'support': 1.0},
    ],
    'flags': const [],
    'crops': const [],
  };
}

const _bombus = ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris'];
const _syrphid = ['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Episyrphus', 'Episyrphus balteatus'];

void main() {
  final tracks = [
    track(1, path: _bombus, identifiedRank: 'genus', p: 0.8, durationS: 10),
    track(2, path: _bombus, identifiedRank: 'genus', p: 0.9, durationS: 20),
    track(3, path: _bombus, identifiedRank: 'species', p: 0.95, durationS: 5),
    track(4, path: _syrphid, identifiedRank: 'family', p: 0.85, durationS: 40),
    track(5, path: _syrphid, identifiedRank: null, durationS: 1),
    track(6, path: _syrphid, identifiedRank: null, headline: 'no organism'),
  ];

  test('as identified: one row per answer, buckets last, sorted by visits', () {
    final rows = aggregateTracks(tracks);
    expect(rows.map((r) => r.taxon).toList(), [
      'Bombus',
      'Bombus terrestris',
      'Syrphidae',
      'no organism',
      'unidentified',
    ]);
    final bombus = rows.first;
    expect(bombus.rank, 'genus');
    expect(bombus.visits, 2);
    expect(bombus.totalS, 30);
    expect(bombus.medianP, closeTo(0.85, 1e-9));
    expect(bombus.lineage, ['Hymenoptera', 'Apidae']);
    expect(rows[1].lineage, ['Hymenoptera', 'Apidae', 'Bombus']);
    expect(rows[3].isBucket, isTrue);
    expect(rows[3].medianP, isNull);
  });

  test('by family: species and genus answers count under their family', () {
    final rows = aggregateTracks(tracks, groupRank: 'family');
    expect(rows.first.taxon, 'Apidae');
    expect(rows.first.rank, 'family');
    expect(rows.first.visits, 3);
    expect(rows.first.lineage, ['Hymenoptera']);
    expect(rows[1].taxon, 'Syrphidae');
    expect(rows[1].visits, 1);
  });

  test('by species: shallower answers land in a "not resolved" row', () {
    final rows = aggregateTracks(tracks, groupRank: 'species');
    expect(rows.first.taxon, 'Bombus terrestris');
    expect(rows.first.visits, 1);
    final unresolved = rows.firstWhere((r) => r.taxon == 'not resolved to species');
    expect(unresolved.visits, 3);
    expect(unresolved.isBucket, isTrue);
  });

  test('formatVisitTime picks a readable unit', () {
    expect(formatVisitTime(42), '42 s');
    expect(formatVisitTime(90), '2 min');
    expect(formatVisitTime(5400), '1.5 h');
  });
}
