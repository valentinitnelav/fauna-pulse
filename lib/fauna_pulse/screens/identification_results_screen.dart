// FaunaPulse (round 208, reworked rounds 209, 214, 215): results of an
// identification run for one session.
//
// Reads tracks_<pack>.json (full detail) and summary_<pack>.json (counts).
// Screen = key/value header, then a per-taxon TABLE (taxon, rank, visits,
// time, median ∑Conf.; sortable by any column, filterable by rank, grouped
// "as identified" or by a fixed rank). A row opens the visits behind it
// (numbered 1..N, the tracker's ids in their own column, sortable); a visit
// opens its detail sheet: the ladder as an aligned table with the chosen
// rank highlighted (∑Conf. from the combined embedding, Avg from the crops
// scored one by one, Agree counts), flags with explanations, the photo with
// the detector box and the square crop drawn (toggle, zoom), and the crops
// table (each crop's own ∑Conf. for the reported taxon, its predicted
// species; tap a row to show that crop).
//
// Vocabulary used on every table (owner, round 215): "∑Conf." = probability
// of a TAXON, i.e. the probabilities of all label-pack names under it added
// up; "Conf." = probability of ONE name (a species). Percentages are model
// confidence, not accuracy.
//
// Column widths are MEASURED from the header and the longest cell texts
// (TextPainter), so a sort arrow or a long number never gets ellipsised;
// the text column takes the rest, and a table that still does not fit
// (the crops table) scrolls sideways with a visible scrollbar.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../identification/crop_worker.dart' show planSquareCrop;
import '../identification/label_pack.dart' show kRankNames;
import '../identification/taxa_table.dart';
import '../logging/app_error_hooks.dart';
import '../widgets/setting_help.dart';

const _cellStyle = TextStyle(color: Colors.white, fontSize: 13);
const _dimCellStyle = TextStyle(color: Colors.white54, fontSize: 13);
const _headerStyle = TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold);
const _detectorBoxColor = Colors.amber;
const _cropBoxColor = Colors.cyanAccent;

/// Horizontal space between table columns.
const double _gutter = 8;

String _pct(num? v) => v == null ? '–' : '${(v * 100).round()} %';
String _secs(num? v) => v == null ? '–' : formatVisitTime(v.toDouble());

/// One column of a small table. Alignment standard for every results
/// table: identifiers and names left, quantities right ([numeric]). Exactly
/// one column is [flex] (takes the remaining width); the others are
/// measured from their content.
class _Col {
  final String key;
  final String label;
  final bool numeric;
  final bool flex;
  const _Col(this.key, this.label, {this.numeric = false, this.flex = false});
}

double _textWidth(String s, TextStyle style, TextScaler scaler) {
  final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, textScaler: scaler)..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// Width per non-flex column: the widest of the header label, the sort
/// arrow and the longest cell texts ([samples], the longest few suffice).
Map<String, double> _fitWidths(List<_Col> cols, Iterable<String> Function(_Col) samples, TextScaler scaler) {
  final out = <String, double>{};
  for (final c in cols) {
    if (c.flex) continue;
    var w = math.max(_textWidth(c.label, _headerStyle, scaler), _textWidth('▼', _headerStyle, scaler));
    final strs = samples(c).toSet().toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final s in strs.take(6)) {
      w = math.max(w, _textWidth(s, _cellStyle.copyWith(fontWeight: FontWeight.bold), scaler));
    }
    out[c.key] = w + 4;
  }
  return out;
}

double _fixedWidth(List<_Col> cols, Map<String, double> widths) {
  var w = _gutter * (cols.length - 1);
  for (final c in cols) {
    if (!c.flex) w += widths[c.key] ?? 40;
  }
  return w;
}

/// Lays [cells] out on [cols]: measured widths for the fixed columns, the
/// flex column expands (or takes [flexWidth] when the table scrolls
/// sideways).
Widget _cellsRow(List<_Col> cols, Map<String, double> widths, List<Widget> cells, double? flexWidth) {
  assert(cells.length == cols.length);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < cols.length; i++) ...[
        if (i > 0) const SizedBox(width: _gutter),
        if (cols[i].flex)
          flexWidth == null ? Expanded(child: cells[i]) : SizedBox(width: flexWidth, child: cells[i])
        else
          SizedBox(
            width: widths[cols[i].key] ?? 40,
            child: Align(alignment: cols[i].numeric ? Alignment.centerRight : Alignment.centerLeft, child: cells[i]),
          ),
      ],
    ],
  );
}

/// Bold header row; the active sort column shows ▲/▼; the rule under it is
/// thicker than the row dividers. [onSort] null = not sortable.
class _SortHeader extends StatelessWidget {
  final List<_Col> cols;
  final Map<String, double> widths;
  final String sortKey;
  final bool asc;
  final void Function(String key)? onSort;
  final double? flexWidth;
  const _SortHeader({required this.cols, required this.widths, this.sortKey = '', this.asc = true, this.onSort, this.flexWidth});

  @override
  Widget build(BuildContext context) {
    Widget cell(_Col c) {
      final active = c.key == sortKey;
      final text = Text(
        active ? '${c.label} ${asc ? '▲' : '▼'}' : c.label,
        textAlign: c.numeric ? TextAlign.right : TextAlign.left,
        maxLines: 2,
        style: active ? _headerStyle.copyWith(color: Colors.white) : _headerStyle,
      );
      final padded = Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: text);
      return onSort == null ? padded : InkWell(onTap: () => onSort!(c.key), child: padded);
    }

    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white54, width: 1.5))),
      child: _cellsRow(cols, widths, [for (final c in cols) cell(c)], flexWidth),
    );
  }
}

/// A data row with a thin line under it; [highlight] marks the chosen /
/// selected row; [below] spans the whole row (a file name).
class _TableRow extends StatelessWidget {
  final List<_Col> cols;
  final Map<String, double> widths;
  final List<Widget> cells;
  final bool highlight;
  final VoidCallback? onTap;
  final Widget? below;
  final double? flexWidth;
  const _TableRow({required this.cols, required this.widths, required this.cells, this.highlight = false, this.onTap, this.below, this.flexWidth});

  @override
  Widget build(BuildContext context) {
    final row = _cellsRow(cols, widths, cells, flexWidth);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: highlight ? Colors.white10 : null,
          border: Border(bottom: BorderSide(color: highlight ? Colors.white38 : Colors.white12, width: highlight ? 1 : 0.5)),
        ),
        child: below == null ? row : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [row, below!]),
      ),
    );
  }
}

/// Header + rows that fit the width when they can, and otherwise scroll
/// sideways with a visible scrollbar (the flex column then gets [flexMin]).
class _MiniTable extends StatefulWidget {
  final List<_Col> cols;
  final Map<String, double> widths;
  final double flexMin;
  final List<Widget> Function(double? flexWidth) build;
  const _MiniTable({required this.cols, required this.widths, required this.build, this.flexMin = 120});

  @override
  State<_MiniTable> createState() => _MiniTableState();
}

class _MiniTableState extends State<_MiniTable> {
  final _h = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, box) {
        final natural = _fixedWidth(widget.cols, widget.widths) + widget.flexMin;
        if (natural <= box.maxWidth) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.build(null));
        }
        return Scrollbar(
          controller: _h,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _h,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: natural,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.build(widget.flexMin)),
            ),
          ),
        );
      },
    );
  }
}

Widget _txt(String s, {bool right = false, TextStyle style = _cellStyle, bool bold = false, int maxLines = 1}) => Text(
  s,
  textAlign: right ? TextAlign.right : TextAlign.left,
  maxLines: maxLines,
  softWrap: maxLines > 1,
  overflow: TextOverflow.ellipsis,
  style: bold ? style.copyWith(fontWeight: FontWeight.bold) : style,
);

/// Sheet list padding that clears the system navigation bar (a modal sheet
/// is edge-to-edge like the rest of the app).
EdgeInsets _sheetPadding(BuildContext context) => EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.paddingOf(context).bottom);

int _cmpNum(num? a, num? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1; // nulls last
  if (b == null) return -1;
  return a.compareTo(b);
}

double? _ladderP(Map<String, dynamic> t, String? rank) {
  final r = rank ?? t['identified_rank'];
  if (r == null) return null;
  for (final s in (t['ladder'] as List).cast<Map<String, dynamic>>()) {
    if (s['rank'] == r) return (s['p'] as num).toDouble();
  }
  return null;
}

String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

class IdentificationResultsScreen extends StatefulWidget {
  final Directory sessionDir;
  final File tracksJson;
  final File summaryJson;
  final File tracksCsv;

  const IdentificationResultsScreen({
    super.key,
    required this.sessionDir,
    required this.tracksJson,
    required this.summaryJson,
    required this.tracksCsv,
  });

  @override
  State<IdentificationResultsScreen> createState() => _IdentificationResultsScreenState();
}

class _IdentificationResultsScreenState extends State<IdentificationResultsScreen> {
  static const int _rowsFolded = 25;
  static const _cols = [
    _Col('taxon', 'Taxon', flex: true),
    _Col('rank', 'Rank'),
    _Col('visits', 'Visits', numeric: true),
    _Col('time', 'Time', numeric: true),
    _Col('conf', '∑Conf.', numeric: true),
  ];

  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _tracks = const [];
  List<TaxonRow> _rows = const [];
  String _groupRank = kGroupAsIdentified;
  bool _allRows = false;
  bool _showSuspect = false;
  String _sortKey = 'visits';
  bool _sortAsc = false;
  String? _rankFilter; // null = all
  String? _error;

  List<Map<String, dynamic>> get _visible =>
      _showSuspect ? _tracks : _tracks.where((t) => t['suspect'] != true).toList();
  int get _suspectCount => _tracks.where((t) => t['suspect'] == true).length;
  double get _margin => ((_summary?['settings'] as Map?)?['margin'] as num?)?.toDouble() ?? 0.15;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final summary = jsonDecode(await widget.summaryJson.readAsString()) as Map<String, dynamic>;
      final full = jsonDecode(await widget.tracksJson.readAsString()) as Map<String, dynamic>;
      final tracks = (full['tracks'] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _tracks = tracks;
        _recompute();
      });
    } catch (e) {
      logSwallowed('identify_results_load', e);
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _recompute() {
    _rows = aggregateTracks(_visible, groupRank: _groupRank);
    _sortRows();
  }

  void _sortRows() {
    final rows = [..._rows];
    int cmp(TaxonRow a, TaxonRow b) => switch (_sortKey) {
      'taxon' => a.taxon.toLowerCase().compareTo(b.taxon.toLowerCase()),
      'rank' => _rankOrder(a).compareTo(_rankOrder(b)),
      'time' => a.totalS.compareTo(b.totalS),
      'conf' => _cmpNum(a.medianP, b.medianP),
      _ => a.visits.compareTo(b.visits),
    };
    rows.sort((a, b) {
      final c = cmp(a, b);
      final d = _sortAsc ? c : -c;
      return d != 0 ? d : a.taxon.compareTo(b.taxon);
    });
    _rows = rows;
  }

  int _rankOrder(TaxonRow r) => r.isBucket ? 99 : kRankNames.indexOf(r.rank);

  void _setSort(String key) {
    setState(() {
      if (_sortKey == key) {
        _sortAsc = !_sortAsc;
      } else {
        _sortKey = key;
        _sortAsc = key == 'taxon' || key == 'rank';
      }
      _sortRows();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final name = widget.sessionDir.path.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Identification'),
            Text(name, style: const TextStyle(fontSize: 13, color: Colors.white70), overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Share results (CSV file)',
            icon: const Icon(Icons.share_outlined),
            onPressed: widget.tracksCsv.existsSync()
                ? () => SharePlus.instance.share(ShareParams(files: [XFile(widget.tracksCsv.path)]))
                : null,
          ),
        ],
      ),
      body: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
            : s == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  ..._header(s),
                  const Divider(height: 28, color: Colors.white24),
                  ..._table(context),
                ],
              ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 88, child: Text(k, style: const TextStyle(color: Colors.white54))),
        Expanded(child: Text(v, style: const TextStyle(color: Colors.white))),
      ],
    ),
  );

  List<Widget> _header(Map<String, dynamic> s) {
    final iso = s['generated_iso'].toString();
    final when = iso.length >= 16 ? iso.substring(0, 16).replaceFirst('T', ' ') : iso;
    final merged = (s['visits_merged'] as num? ?? 0).toInt();
    return [
      _kv('Model', '${s['model_id']}'),
      _kv('Label pack', '${s['pack_id']} (${s['pack_rows']} names)'),
      _kv('Date run', when),
      _kv(
        'Visits',
        '${s['tracks_total']}'
        '${merged > 0 ? ' ($merged joined from consecutive track ids, ${s['tracks_before_merge']} track ids in all)' : ''}',
      ),
    ];
  }

  List<Widget> _table(BuildContext context) {
    final ranksPresent = <String>{for (final r in _rows) r.isBucket ? 'unresolved' : r.rank};
    final filtered = _rankFilter == null
        ? _rows
        : _rows.where((r) => (r.isBucket ? 'unresolved' : r.rank) == _rankFilter).toList();
    final shown = _allRows ? filtered : filtered.take(_rowsFolded).toList();
    final widths = _fitWidths(_cols, (c) => [
      for (final r in shown)
        switch (c.key) {
          'rank' => r.isBucket ? '–' : r.rank,
          'visits' => '${r.visits}',
          'time' => formatVisitTime(r.totalS),
          _ => _pct(r.medianP),
        },
    ], MediaQuery.textScalerOf(context));
    return [
      const HelpLabel(
        label: 'Visits per taxon / rank',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'One row per taxon. "As identified" gives one row per answer at the rank the model was '
            'sure about (a visit identified only to genus Bombus and one identified to Bombus '
            'terrestris are two rows). Pick a rank to count every visit under its order, family, '
            'genus or species instead; visits the model did not resolve that deep land in a '
            '"not resolved" row.\n'
            'Rank: the taxonomic rank of the row\'s taxon; the Rank filter keeps only rows of one rank.\n'
            'Visits: number of visits (track ids, or joined visits) in the row.\n'
            'Time: the row\'s visit durations added up (first to last detector frame of each visit).\n'
            '∑Conf.: median over the row\'s visits of each visit\'s ∑Conf. for that taxon. ∑Conf. of a '
            'taxon = the probabilities of all label-pack names under it added up (a genus = the sum of '
            'its species, a family = the sum of its genera, and so on). It comes from the visit\'s '
            'combined embedding: the model turns each crop into a vector, FaunaPulse averages the '
            'visit\'s vectors (weighted by crop quality), compares the average with every name in the '
            'pack and turns the similarities into probabilities that sum to 100 % over the pack. It is '
            'model confidence, not a measured accuracy: treat species-level names as suggestions.\n'
            'Tap a column header to sort, a row to list its visits, a visit for its full ladder.',
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        runSpacing: 0,
        children: [
          for (final (value, label) in [
            (kGroupAsIdentified, 'As identified'),
            for (final r in kRankNames.skip(3)) (r, r[0].toUpperCase() + r.substring(1)),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _groupRank == value,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => setState(() {
                _groupRank = value;
                _allRows = false;
                _rankFilter = null;
                _recompute();
              }),
            ),
        ],
      ),
      if (_suspectCount > 0)
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _showSuspect,
          onChanged: (v) => setState(() {
            _showSuspect = v;
            _recompute();
          }),
          title: Text('Include ${_plural(_suspectCount, 'suspect visit')}', style: const TextStyle(color: Colors.white)),
          subtitle: const Text(
            'Short-lived AND weakly supported (low detector confidence, weak identification or "no organism"); '
            'likely false detections. Thresholds under Advanced settings; the CSV keeps them with a "suspect" flag.',
            style: helperTextStyle,
          ),
        ),
      if (ranksPresent.length > 1)
        Row(
          children: [
            const Text('Rank filter: ', style: helperTextStyle),
            DropdownButton<String?>(
              value: _rankFilter,
              isDense: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('all')),
                for (final r in kRankNames)
                  if (ranksPresent.contains(r)) DropdownMenuItem<String?>(value: r, child: Text(r)),
                if (ranksPresent.contains('unresolved'))
                  const DropdownMenuItem<String?>(value: 'unresolved', child: Text('not resolved / none')),
              ],
              onChanged: (v) => setState(() => _rankFilter = v),
            ),
          ],
        ),
      const SizedBox(height: 4),
      _MiniTable(
        cols: _cols,
        widths: widths,
        flexMin: 110,
        build: (fw) => [
          _SortHeader(cols: _cols, widths: widths, sortKey: _sortKey, asc: _sortAsc, onSort: _setSort, flexWidth: fw),
          for (final r in shown) _taxonRow(r, widths, fw),
        ],
      ),
      if (filtered.length > shown.length)
        TextButton(
          onPressed: () => setState(() => _allRows = true),
          child: Text('Show all ${filtered.length} rows'),
        ),
      if (filtered.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No visits.', style: helperTextStyle)),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _visible.isEmpty ? null : () => _showVisits('All visits', _visible, rank: null, showTaxon: true),
          icon: const Icon(Icons.list),
          label: Text('All ${_visible.length} visits'),
        ),
      ),
    ];
  }

  Widget _taxonRow(TaxonRow r, Map<String, double> widths, double? fw) {
    final style = r.isBucket ? _dimCellStyle : _cellStyle;
    return _TableRow(
      cols: _cols,
      widths: widths,
      flexWidth: fw,
      // A bucket row ("unidentified", "not resolved …") holds visits of
      // different taxa, so its sheet keeps the taxon column.
      onTap: () => _showVisits(r.isBucket ? r.taxon : '${r.taxon} (${r.rank})', r.tracks, rank: r.isBucket ? null : r.rank, showTaxon: r.isBucket),
      cells: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _txt(r.taxon, style: style, bold: !r.isBucket, maxLines: 2),
            if (r.lineage.isNotEmpty) _txt(r.lineage.join(' › '), style: helperTextStyle, maxLines: 3),
          ],
        ),
        _txt(r.isBucket ? '–' : r.rank, style: _dimCellStyle),
        _txt('${r.visits}', right: true),
        _txt(formatVisitTime(r.totalS), right: true, style: _dimCellStyle),
        _txt(_pct(r.medianP), right: true, style: _dimCellStyle),
      ],
    );
  }

  void _showVisits(String title, List<Map<String, dynamic>> tracks, {required String? rank, required bool showTaxon}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, controller) => _VisitsSheet(
          title: title,
          tracks: tracks,
          rank: rank,
          showTaxon: showTaxon,
          controller: controller,
          onOpen: (t) => _showTrack(t),
        ),
      ),
    );
  }

  void _showTrack(Map<String, dynamic> t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        builder: (_, controller) => _TrackSheet(sessionDir: widget.sessionDir, track: t, margin: _margin, controller: controller),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Visits list: numbered rows, tracker ids in their own column, sortable.
// ---------------------------------------------------------------------------

class _VisitsSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> tracks;

  /// Rank whose ∑Conf. the sheet shows (the taxon row's rank); null = each
  /// visit's own identified rank (the "All visits" list, bucket rows).
  final String? rank;

  /// False when every visit is the same taxon (the title says it).
  final bool showTaxon;
  final ScrollController controller;
  final void Function(Map<String, dynamic>) onOpen;
  const _VisitsSheet({
    required this.title,
    required this.tracks,
    required this.rank,
    required this.showTaxon,
    required this.controller,
    required this.onOpen,
  });

  @override
  State<_VisitsSheet> createState() => _VisitsSheetState();
}

class _VisitsSheetState extends State<_VisitsSheet> {
  late final List<_Col> _cols = [
    const _Col('no', 'No.'),
    _Col('id', 'Track id', flex: !widget.showTaxon),
    if (widget.showTaxon) const _Col('taxon', 'Taxon', flex: true),
    const _Col('crops', 'Crops', numeric: true),
    const _Col('time', 'Time', numeric: true),
    const _Col('conf', '∑Conf.', numeric: true),
  ];
  String _sortKey = 'no';
  bool _asc = true;
  late final List<(int, Map<String, dynamic>)> _rows = [for (var i = 0; i < widget.tracks.length; i++) (i + 1, widget.tracks[i])];

  double? _p(Map<String, dynamic> t) => _ladderP(t, widget.rank);

  String _idText(Map<String, dynamic> t) {
    final ids = (t['track_ids'] as List?)?.cast<num>() ?? const [];
    if (t['track_id'] == null) return 'crop';
    return ids.length > 1 ? '#${ids.first.toInt()}+${ids.length - 1}' : '#${t['track_id']}';
  }

  void _sort(String key) {
    setState(() {
      if (_sortKey == key) {
        _asc = !_asc;
      } else {
        _sortKey = key;
        _asc = key == 'no' || key == 'id' || key == 'taxon';
      }
      int cmp((int, Map<String, dynamic>) a, (int, Map<String, dynamic>) b) => switch (_sortKey) {
        'id' => _cmpNum(a.$2['track_id'] as num?, b.$2['track_id'] as num?),
        'taxon' => '${a.$2['headline']}'.toLowerCase().compareTo('${b.$2['headline']}'.toLowerCase()),
        'crops' => (a.$2['crops'] as List).length.compareTo((b.$2['crops'] as List).length),
        'time' => _cmpNum(a.$2['duration_s'] as num?, b.$2['duration_s'] as num?),
        'conf' => _cmpNum(_p(a.$2), _p(b.$2)),
        _ => a.$1.compareTo(b.$1),
      };
      _rows.sort((a, b) {
        final c = cmp(a, b);
        return _asc ? c : -c;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final widths = _fitWidths(_cols, (c) => [
      for (final (no, t) in _rows)
        switch (c.key) {
          'no' => '$no',
          'id' => _idText(t),
          'crops' => '${(t['crops'] as List).length}',
          'time' => _secs(t['duration_s'] as num?),
          _ => _pct(_p(t)),
        },
    ], MediaQuery.textScalerOf(context));
    return ListView.builder(
      controller: widget.controller,
      padding: _sheetPadding(context),
      itemCount: _rows.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.title} · ${_plural(widget.tracks.length, 'visit')}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(
                'No. = row number here; Track id = the id the detector and tracker gave the visit (ids can '
                'jump). Time = first to last detector frame. ∑Conf. = the visit\'s probability for '
                '${widget.rank == null ? 'its reported taxon' : 'this taxon'} (names under it summed). '
                'Tap a row for the full ladder, photo and crops.',
                style: helperTextStyle,
              ),
              const SizedBox(height: 6),
              _SortHeader(cols: _cols, widths: widths, sortKey: _sortKey, asc: _asc, onSort: _sort),
            ],
          );
        }
        final (no, t) = _rows[i - 1];
        final dim = t['headline'] == 'no organism' || t['headline'] == 'unidentified';
        final suspect = t['suspect'] == true;
        final idCell = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _txt(_idText(t)),
            if (suspect && !widget.showTaxon) const Text('suspect', style: TextStyle(color: Colors.amber, fontSize: 11)),
          ],
        );
        return _TableRow(
          cols: _cols,
          widths: widths,
          onTap: () => widget.onOpen(t),
          cells: [
            _txt('$no', style: _dimCellStyle),
            idCell,
            if (widget.showTaxon)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _txt('${t['headline']}', style: dim ? _dimCellStyle : _cellStyle, maxLines: 2),
                  if (t['identified_rank'] != null || suspect)
                    Text(
                      [if (t['identified_rank'] != null) '${t['identified_rank']}', if (suspect) 'suspect'].join(' · '),
                      style: suspect ? const TextStyle(color: Colors.amber, fontSize: 11) : helperTextStyle,
                    ),
                ],
              ),
            _txt('${(t['crops'] as List).length}', right: true, style: _dimCellStyle),
            _txt(_secs(t['duration_s'] as num?), right: true, style: _dimCellStyle),
            _txt(_pct(_p(t)), right: true, style: _dimCellStyle),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// One visit: ladder, flags, photo with boxes, crops table.
// ---------------------------------------------------------------------------

class _TrackSheet extends StatefulWidget {
  final Directory sessionDir;
  final Map<String, dynamic> track;
  final double margin;
  final ScrollController controller;
  const _TrackSheet({required this.sessionDir, required this.track, required this.margin, required this.controller});

  @override
  State<_TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<_TrackSheet> {
  static const _ladderCols = [
    _Col('rank', 'Rank'),
    _Col('taxon', 'Taxon', flex: true),
    _Col('p', '∑Conf.', numeric: true),
    _Col('p_mean', 'Avg', numeric: true),
    _Col('support', 'Agree', numeric: true),
  ];
  // What matters for tracing the answer comes first; size and weight sit
  // to the right (the table scrolls sideways on a phone).
  static const _cropCols = [
    _Col('no', 'No.'),
    _Col('mass', '∑Conf.', numeric: true),
    _Col('agrees', 'Agree', numeric: true),
    _Col('top1', 'Species', flex: true),
    _Col('p', 'Conf.', numeric: true),
    _Col('side', 'Side px', numeric: true),
    _Col('weight', 'Weight', numeric: true),
  ];

  late final List<Map<String, dynamic>> _crops = (widget.track['crops'] as List).cast<Map<String, dynamic>>();
  late final List<(int, Map<String, dynamic>)> _cropRows = [for (var i = 0; i < _crops.length; i++) (i + 1, _crops[i])];
  String _sortKey = 'no';
  bool _asc = true;
  late int _shown = _bestIndex();
  bool _showBoxes = true;
  final _zoom = TransformationController();

  String? get _rank => widget.track['identified_rank'] as String?;
  int get _rankIdx => _rank == null ? -1 : kRankNames.indexOf(_rank!);

  /// This crop's own ∑Conf. for the reported taxon (null for older files).
  double? _mass(Map<String, dynamic> c) {
    final l = (c['p_ladder'] as List?)?.cast<num>();
    if (l == null || _rankIdx < 0 || _rankIdx >= l.length) return null;
    return l[_rankIdx].toDouble();
  }

  int _bestIndex() {
    final best = widget.track['best_view'] as Map<String, dynamic>?;
    if (best == null) return 0;
    final i = _crops.indexWhere((c) => c['src'] == best['src']);
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _sort(String key) {
    setState(() {
      if (_sortKey == key) {
        _asc = !_asc;
      } else {
        _sortKey = key;
        _asc = key == 'no' || key == 'top1';
      }
      int cmp((int, Map<String, dynamic>) a, (int, Map<String, dynamic>) b) => switch (_sortKey) {
        'mass' => _cmpNum(_mass(a.$2), _mass(b.$2)),
        'side' => _cmpNum(a.$2['crop_px'] as num?, b.$2['crop_px'] as num?),
        'weight' => _cmpNum(a.$2['weight'] as num?, b.$2['weight'] as num?),
        'p' => _cmpNum(a.$2['top1_p'] as num?, b.$2['top1_p'] as num?),
        'agrees' => (a.$2['agrees'] == true ? 1 : 0).compareTo(b.$2['agrees'] == true ? 1 : 0),
        'top1' => '${a.$2['top1']}'.compareTo('${b.$2['top1']}'),
        _ => a.$1.compareTo(b.$1),
      };
      _cropRows.sort((a, b) {
        final c = cmp(a, b);
        return _asc ? c : -c;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final ladder = (t['ladder'] as List).cast<Map<String, dynamic>>();
    final ids = (t['track_ids'] as List?)?.cast<num>() ?? const [];
    final flags = (t['flags'] as List).cast<String>();
    final title = t['track_id'] == null
        ? 'Crop'
        : 'Visit: track id #${t['track_id']}${ids.length > 1 ? ' (joined ${ids.skip(1).map((i) => '#${i.toInt()}').join(', ')})' : ''}';
    final n = _crops.length;
    final scaler = MediaQuery.textScalerOf(context);
    final ladderWidths = _fitWidths(_ladderCols, (c) => [
      for (final s in ladder)
        switch (c.key) {
          'rank' => '${s['rank']}',
          'p' => _pct(s['p'] as num?),
          'p_mean' => s['p_mean'] == null ? '?' : _pct(s['p_mean'] as num?),
          _ => '${((s['support'] as num? ?? 0) * n).round()}/$n',
        },
    ], scaler);
    return ListView(
      controller: widget.controller,
      padding: _sheetPadding(context),
      children: [
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        Text(
          '${t['headline']}'
          '${_rank != null ? ' ($_rank)' : ''}'
          ' · ${_secs(t['duration_s'] as num?)}'
          '${t['detections'] != null ? ' · ${t['detections']} detector frames' : ''}'
          ' · ${_plural(n, 'photo')} (crops)',
          style: const TextStyle(color: Colors.white70),
        ),
        const Text(
          'Time = first to last detector frame of the track id. Detector frames = every frame the live '
          'detector saw it in (several per second). Photos = the frames saved on the photo schedule '
          '(default one per second during the first 10 s of a visit) plus frames another insect '
          'triggered while this one was in view; each saved photo gives one crop.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 12),
        const HelpLabel(
          label: 'Ladder',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'Rank / Taxon: the taxon chosen at every rank on one consistent path from kingdom to '
              'species.\n'
              '∑Conf.: the visit\'s probability for that taxon from its COMBINED embedding: the crops\' '
              'vectors averaged with their weights, scored once against the label pack, and the '
              'probabilities of all names under the taxon summed. This is the visit\'s answer; it can only '
              'shrink going down the ladder.\n'
              'Avg: the same probability the other way round: each crop scored on its own, then the '
              'crops\' ∑Conf. values averaged with the same weights (the weighted mean of the ∑Conf. '
              'column in the crops table). Close to ∑Conf. when the crops agree; a large gap means the '
              'crops disagree and the averaged vector landed between them.\n'
              'Agree: how many crops, each judged on its own, put their predicted species under that '
              'taxon (3/5 = three of five). The Agree column of the crops table shows which.\n'
              'Highlighted row: the deepest rank whose ∑Conf. reached the threshold = the reported '
              'identification. Rows below it are suggestions.',
        ),
        const SizedBox(height: 4),
        _MiniTable(
          cols: _ladderCols,
          widths: ladderWidths,
          flexMin: 110,
          build: (fw) => [
            _SortHeader(cols: _ladderCols, widths: ladderWidths, flexWidth: fw),
            for (final s in ladder)
              _TableRow(
                cols: _ladderCols,
                widths: ladderWidths,
                flexWidth: fw,
                highlight: s['rank'] == _rank,
                cells: [
                  _txt('${s['rank']}', style: _dimCellStyle, bold: s['rank'] == _rank),
                  _txt('${s['taxon']}', bold: s['rank'] == _rank, maxLines: 2),
                  _txt(_pct(s['p'] as num?), right: true, bold: s['rank'] == _rank),
                  _txt(s['p_mean'] == null ? '?' : _pct(s['p_mean'] as num?), right: true, style: _dimCellStyle, bold: s['rank'] == _rank),
                  _txt('${((s['support'] as num? ?? 0) * n).round()}/$n', right: true, style: _dimCellStyle, bold: s['rank'] == _rank),
                ],
              ),
          ],
        ),
        if ((t['none_p'] as num? ?? 0) > 0.05)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('"None of these" (flower, leaf, shadow …): ${_pct(t['none_p'] as num?)}', style: helperTextStyle),
          ),
        if (flags.isNotEmpty) ...[
          const SizedBox(height: 10),
          HelpLabel(
            label: 'Flags: ${flags.join(', ')}',
            labelStyle: const TextStyle(color: Colors.white),
            helperText:
                'merged: joined from consecutive track ids.\n'
                'short: below the duration or detections threshold.\n'
                'low_det: mean detector confidence below the threshold.\n'
                'weak_id: order-level ∑Conf. below the threshold.\n'
                'suspect: short AND weakly supported; likely a false detection (kept, never deleted).\n'
                'none: the "none of these" entries won; unidentified: not even the class reached the '
                'threshold.\n'
                'path_conflict: at some rank the single most probable taxon is NOT inside the taxon chosen '
                'one rank above (say the most probable family overall belongs to a different order than '
                'the most probable order). The ladder always follows the path from the top down, so from '
                'that rank on it shows the best taxon inside the chosen parent, which has a lower ∑Conf. '
                'than the one it had to skip. A sign that the crops point in two directions.\n'
                'rule_conflict: the Avg column (crops scored one by one, then averaged) picks a different '
                'taxon than ∑Conf. (crops averaged first) at the CSV rank.\n'
                'single_crop: only one crop, so there is no agreement to measure.',
          ),
        ],
        const SizedBox(height: 14),
        ..._photoSection(),
        const SizedBox(height: 14),
        ..._cropsSection(scaler),
      ],
    );
  }

  List<Widget> _photoSection() {
    final c = _crops.isEmpty ? null : _crops[_shown];
    final best = widget.track['best_view'] as Map<String, dynamic>?;
    final file = c == null ? null : File('${widget.sessionDir.path}/roi_frames/${c['src']}');
    final isBest = best != null && c != null && c['src'] == best['src'];
    return [
      HelpLabel(
        label: 'Photo',
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Opens on the BEST VIEW: among the good-quality crops, the one whose own ∑Conf. for the '
            'reported taxon${_rank == null ? '' : ' ($_rank)'} is highest, i.e. the single photo that most '
            'clearly shows what the visit was identified as (for an unidentified visit: the highest '
            'single-species probability). Tap a row of the crops table to show that crop instead.\n'
            'Yellow box: the detector\'s box for this organism. Cyan box: the square (box + margin) that '
            'was cut out and shown to the identification model. The eye button hides the boxes, pinch or '
            'double-tap zooms, the reset button returns to full view.',
      ),
      const SizedBox(height: 4),
      if (c != null)
        Row(
          children: [
            Expanded(
              child: Text(
                'Showing crop No. ${_shown + 1}${isBest ? ' (best view)' : ''}: ${c['src']}',
                style: helperTextStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: _showBoxes ? 'Hide boxes' : 'Show boxes',
              visualDensity: VisualDensity.compact,
              icon: Icon(_showBoxes ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _showBoxes = !_showBoxes),
            ),
            IconButton(
              tooltip: 'Reset zoom',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.zoom_out_map),
              onPressed: () => _zoom.value = Matrix4.identity(),
            ),
          ],
        ),
      if (file != null && file.existsSync())
        AspectRatio(
          aspectRatio: 1,
          child: ClipRect(
            child: GestureDetector(
              onDoubleTap: () => _zoom.value = _zoom.value.isIdentity() ? (Matrix4.identity()..scaleByDouble(2.5, 2.5, 1, 1)) : Matrix4.identity(),
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: 1,
                maxScale: 8,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(file, fit: BoxFit.contain, cacheWidth: 1200),
                    if (_showBoxes && c != null)
                      CustomPaint(painter: _BoxesPainter(box: (c['box'] as List).cast<num>(), margin: widget.margin)),
                  ],
                ),
              ),
            ),
          ),
        )
      else
        const Text('Photo file not found in roi_frames/.', style: helperTextStyle),
    ];
  }

  List<Widget> _cropsSection(TextScaler scaler) {
    final widths = _fitWidths(_cropCols, (c) => [
      for (final (no, cr) in _cropRows)
        switch (c.key) {
          'no' => '$no',
          'mass' => _mass(cr) == null ? '?' : _pct(_mass(cr)),
          'agrees' => '✓',
          'p' => _pct(cr['top1_p'] as num?),
          'side' => '${cr['crop_px']}',
          _ => (cr['weight'] as num).toStringAsFixed(2),
        },
    ], scaler);
    final missing = _crops.any((c) => c['agrees'] == null || _mass(c) == null);
    final taxonText = _rank == null ? 'the reported taxon' : '${widget.track['headline']} ($_rank)';
    return [
      HelpLabel(
        label: 'Crops',
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Every photo of this visit that was shown to the model, in capture order (No.).\n'
            '∑Conf.: this crop\'s OWN probability for $taxonText, from the crop\'s vector alone (names under '
            'the taxon summed). The ladder\'s Avg is the weighted mean of this column; the ladder\'s ∑Conf. '
            'comes from the averaged vector instead, so it is not a sum or mean of these numbers.\n'
            'Agree: ✓ when the crop\'s predicted species falls under $taxonText, – when it does not.\n'
            'Species / Conf.: the single species this crop alone predicts (the model\'s best guess) and its '
            'probability (one name, no summing). The species row of the ladder comes from the combined '
            'vector and can be a different species.\n'
            'Side px: side of the square crop in photo pixels (box + margin); small crops are blurry after '
            'enlargement to the model\'s 224 px.\n'
            'Weight: this crop\'s share in the average (0 to 1): larger, sharper crops with a confident '
            'detection and little padding at the ROI edge weigh more.\n'
            'Tap a row to show that crop in the photo above; tap a header to sort; drag sideways when the '
            'table is wider than the screen.',
      ),
      const SizedBox(height: 4),
      if (missing)
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            '"?" = this result file was written by an older app version; "Re-score with this pack" on '
            'the Identify screen fills the ∑Conf., Avg and Agree values in seconds.',
            style: TextStyle(color: Colors.amber, fontSize: 12),
          ),
        ),
      _MiniTable(
        cols: _cropCols,
        widths: widths,
        flexMin: 150,
        build: (fw) => [
          _SortHeader(cols: _cropCols, widths: widths, sortKey: _sortKey, asc: _asc, onSort: _sort, flexWidth: fw),
          for (final (no, c) in _cropRows)
            _TableRow(
              cols: _cropCols,
              widths: widths,
              flexWidth: fw,
              highlight: _crops.indexOf(c) == _shown,
              onTap: () => setState(() {
                _shown = _crops.indexOf(c);
                _zoom.value = Matrix4.identity();
              }),
              cells: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _txt('$no', style: _dimCellStyle),
                    if (_crops.indexOf(c) == _shown) const Padding(padding: EdgeInsets.only(left: 3), child: Icon(Icons.photo, size: 12, color: Colors.white70)),
                  ],
                ),
                _txt(_mass(c) == null ? '?' : _pct(_mass(c)), right: true),
                _txt(c['agrees'] == null ? '?' : (c['agrees'] == true ? '✓' : '–'), right: true, style: c['agrees'] == true ? _cellStyle : _dimCellStyle),
                _txt('${c['top1']}', maxLines: 2),
                _txt(_pct(c['top1_p'] as num?), right: true, style: _dimCellStyle),
                _txt('${c['crop_px']}', right: true, style: _dimCellStyle),
                _txt((c['weight'] as num).toStringAsFixed(2), right: true, style: _dimCellStyle),
              ],
              below: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('${c['src']}', style: const TextStyle(color: Colors.white38, fontSize: 11), overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    ];
  }
}

/// Draws the detector box and the square crop (box + margin) over a square
/// ROI photo; coordinates are fractions of the photo side.
class _BoxesPainter extends CustomPainter {
  final List<num> box;
  final double margin;
  const _BoxesPainter({required this.box, required this.margin});

  @override
  void paint(Canvas canvas, Size size) {
    final l = box[0].toDouble(), t = box[1].toDouble(), r = box[2].toDouble(), b = box[3].toDouble();
    final det = Rect.fromLTRB(l * size.width, t * size.height, r * size.width, b * size.height);
    // Same geometry as the crop worker, on a 1000-px virtual square.
    final plan = planSquareCrop(imgW: 1000, imgH: 1000, left: l, top: t, right: r, bottom: b, margin: margin);
    final sq = Rect.fromLTWH(plan.sx / 1000 * size.width, plan.sy / 1000 * size.height, plan.side / 1000 * size.width, plan.side / 1000 * size.height);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(sq, paint..color = _cropBoxColor);
    canvas.drawRect(det, paint..color = _detectorBoxColor);
  }

  @override
  bool shouldRepaint(_BoxesPainter old) => old.box != box || old.margin != margin;
}
