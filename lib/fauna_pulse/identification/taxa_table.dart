// FaunaPulse (round 209): aggregates the per-visit identifications of one
// session into a compact per-taxon table, so a session with hundreds or
// thousands of tracked visits still reads as a short list ("Bombus: 41
// visits, 12 min, 87 %"). Pure Dart over the tracks_<pack>.json records so
// it is testable without widgets.

import 'label_pack.dart' show kRankNames;

/// Group visits by the rank they were identified to ("as identified", the
/// default: a visit stopped at genus is one row, a species is another) or
/// by one fixed rank (all visits under their family, for example).
const kGroupAsIdentified = 'identified';

/// One row of the per-taxon table.
class TaxonRow {
  /// The taxon name, or one of the buckets: "unidentified", "no organism",
  /// "not resolved to `<rank>`".
  final String taxon;

  /// Rank of [taxon]; empty for a bucket row.
  final String rank;

  /// Ancestors above [taxon] (order downwards, or kingdom downwards when the
  /// taxon is an order or shallower), for the subtitle. Empty for buckets.
  final List<String> lineage;

  /// The visit records (`tracks_<pack>.json` entries) in this row.
  final List<Map<String, dynamic>> tracks;

  /// Sum of the visits' durations in seconds (visits without a duration
  /// contribute nothing).
  final double totalS;

  /// Median model confidence at the grouping rank; null for bucket rows.
  final double? medianP;

  const TaxonRow({
    required this.taxon,
    required this.rank,
    required this.lineage,
    required this.tracks,
    required this.totalS,
    required this.medianP,
  });

  int get visits => tracks.length;
  bool get isBucket => rank.isEmpty;
}

/// Builds the table for [tracks] grouped by [groupRank] ([kGroupAsIdentified]
/// or one of [kRankNames]). Rows are sorted by visits (desc), buckets last.
List<TaxonRow> aggregateTracks(List<Map<String, dynamic>> tracks, {String groupRank = kGroupAsIdentified}) {
  final rankIdx = groupRank == kGroupAsIdentified ? -1 : kRankNames.indexOf(groupRank);
  final groups = <String, _Group>{};

  for (final t in tracks) {
    final headline = '${t['headline']}';
    final identifiedRank = t['identified_rank'] as String?;
    final ladder = (t['ladder'] as List? ?? const []).cast<Map<String, dynamic>>();
    String key, taxon, rank;
    var lineage = const <String>[];
    double? p;
    if (identifiedRank == null || headline == 'no organism' || headline == 'unidentified') {
      key = taxon = headline;
      rank = '';
    } else {
      final useIdx = rankIdx < 0 ? kRankNames.indexOf(identifiedRank) : rankIdx;
      final reached = kRankNames.indexOf(identifiedRank) >= useIdx;
      final step = useIdx >= 0 && useIdx < ladder.length ? ladder[useIdx] : null;
      if (!reached || step == null) {
        key = taxon = 'not resolved to $groupRank';
        rank = '';
      } else {
        rank = kRankNames[useIdx];
        taxon = '${step['taxon']}';
        key = '$rank|$taxon';
        p = (step['p'] as num?)?.toDouble();
        // Order downwards is what a pollination ecologist reads; kingdom to
        // class only matter when the answer stopped that high.
        final orderIdx = kRankNames.indexOf('order');
        final from = useIdx > orderIdx ? orderIdx : 0;
        lineage = [for (var k = from; k < useIdx; k++) '${ladder[k]['taxon']}'];
      }
    }
    final g = groups.putIfAbsent(key, () => _Group(taxon, rank, lineage));
    g.tracks.add(t);
    g.totalS += (t['duration_s'] as num?)?.toDouble() ?? 0;
    if (p != null) g.ps.add(p);
  }

  final rows = [
    for (final g in groups.values)
      TaxonRow(
        taxon: g.taxon,
        rank: g.rank,
        lineage: g.lineage,
        tracks: g.tracks,
        totalS: g.totalS,
        medianP: _median(g.ps),
      ),
  ];
  rows.sort((a, b) {
    if (a.isBucket != b.isBucket) return a.isBucket ? 1 : -1;
    final byVisits = b.visits.compareTo(a.visits);
    return byVisits != 0 ? byVisits : a.taxon.compareTo(b.taxon);
  });
  return rows;
}

class _Group {
  final String taxon;
  final String rank;
  final List<String> lineage;
  final tracks = <Map<String, dynamic>>[];
  final ps = <double>[];
  double totalS = 0;
  _Group(this.taxon, this.rank, this.lineage);
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// "45 s", "12 min", "1.3 h" for a table cell.
String formatVisitTime(double seconds) {
  if (seconds < 60) return '${seconds.round()} s';
  if (seconds < 3600) return '${(seconds / 60).round()} min';
  return '${(seconds / 3600).toStringAsFixed(1)} h';
}
