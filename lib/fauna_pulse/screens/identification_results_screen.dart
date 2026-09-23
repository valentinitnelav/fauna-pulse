// FaunaPulse (round 208, reworked rounds 209, 214, 215, 216): results of an
// identification run for one session.
//
// Reads tracks_<pack>.json (full detail) and summary_<pack>.json (counts).
// Screen S2 = key/value header, then a per-taxon TABLE (taxon, rank, track
// ids, time, median confidence; sortable, filterable by rank, grouped "as
// identified" or by a fixed rank). A row opens sheet S3 with its track ids
// (numbered 1..N, the tracker's ids in their own column, sortable, with the
// median confidence stated above the table); a track id opens sheet S4:
// the ladder (Conf. = the crops' descriptions averaged with certainty weights and scored once,
// Agree as "50 % (5/10)"; tap a row to select its taxon), a "Best single
// photo" line, flags with explanations, the photo with the detector box
// and the square crop drawn (toggle, zoom), and the crops table (each
// crop's own confidence for the selected ladder taxon, its top species and
// that species' confidence, which is also the crop's weight, and the top
// species' taxonomic tree (round 220); tap a row to show that crop).
//
// Vocabulary (owner, rounds 215-219): "track id" = one tracked organism
// (a pollination ecologist's "visit"); "Conf." = the model's confidence
// that a track id belongs to a TAXON (round 219: the crops' descriptions
// averaged with certainty weights, far-less-sure crops left out, scored
// once, species under the taxon added up); "Species conf." = one species, one crop, nothing
// added up; "Med. Conf." = median of Conf. across the track ids of a taxon
// row. Every info text lists its table's columns in bold, one per line.
// Percentages are model confidence, not accuracy.
//
// Column widths are MEASURED from the header and the longest cell texts
// (TextPainter), so a sort arrow or a long number never gets ellipsised; a
// table with a flex column gives it the rest, a table without one stays
// left-packed, and a table that still does not fit scrolls sideways with a
// visible scrollbar.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../identification/crop_worker.dart' show planSquareCrop;
import '../identification/label_pack.dart' show kRankNames, kSinkKingdom;
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
String _plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// One column of a small table. Alignment standard for every results
/// table: identifiers and names left, quantities right ([numeric]). At most
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
/// sideways). Without a flex column the row is left-packed.
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

/// A data row with a thin line under it; [highlight] marks the reported /
/// shown row; [selected] draws a bar on the left (the ladder row whose
/// taxon the crops table shows); [below] spans the whole row.
class _TableRow extends StatelessWidget {
  final List<_Col> cols;
  final Map<String, double> widths;
  final List<Widget> cells;
  final bool highlight;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? below;
  final double? flexWidth;
  const _TableRow({
    required this.cols,
    required this.widths,
    required this.cells,
    this.highlight = false,
    this.selected = false,
    this.onTap,
    this.below,
    this.flexWidth,
  });

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
        // The selection bar is painted in the foreground so it takes no
        // layout width (a border did, and overflowed a sideways-scrolling
        // table by exactly its 3 px).
        foregroundDecoration: selected
            ? const BoxDecoration(border: Border(left: BorderSide(color: _cropBoxColor, width: 3)))
            : null,
        child: below == null ? row : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [row, below!]),
      ),
    );
  }
}

/// A slider-like indicator under a table that scrolls sideways (owner,
/// round 218: the stock scrollbar thumb spanned the width and lay over the
/// last row): a translucent track, a short thumb that follows the scroll
/// offset and can be dragged, and arrows at both ends that scroll a step.
class _ScrollGlider extends StatefulWidget {
  final ScrollController controller;
  const _ScrollGlider({required this.controller});

  @override
  State<_ScrollGlider> createState() => _ScrollGliderState();
}

class _ScrollGliderState extends State<_ScrollGlider> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    // The scroll extent is known only after the first layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _step(int dir) {
    final c = widget.controller;
    if (!c.hasClients || !c.position.hasContentDimensions) return;
    final page = c.position.viewportDimension * 0.8;
    c.animateTo(
      (c.offset + dir * page).clamp(0.0, c.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    // The position exists before its first layout; its extents do not.
    final ready = c.hasClients && c.position.hasContentDimensions;
    final max = ready ? c.position.maxScrollExtent : 0.0;
    final off = ready ? c.offset.clamp(0.0, max) : 0.0;
    final frac = max > 0 ? off / max : 0.0;
    return LayoutBuilder(
      builder: (_, box) {
        const arrow = 32.0;
        final trackW = (box.maxWidth - 2 * arrow).clamp(40.0, double.infinity);
        final thumbW = (trackW * 0.3).clamp(36.0, trackW);
        final left = (trackW - thumbW) * frac;
        return Row(
          children: [
            SizedBox(
              width: arrow,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.chevron_left, size: 20, color: Colors.white54),
                onPressed: off > 0 ? () => _step(-1) : null,
              ),
            ),
            SizedBox(
              width: trackW,
              height: 20,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  if (!c.hasClients || trackW <= thumbW) return;
                  c.jumpTo((c.offset + d.delta.dx * max / (trackW - thumbW)).clamp(0.0, max));
                },
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(height: 6, decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(3))),
                    Positioned(
                      left: left,
                      width: thumbW,
                      child: Container(height: 12, decoration: BoxDecoration(color: Colors.white38, borderRadius: BorderRadius.circular(6))),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: arrow,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.chevron_right, size: 20, color: Colors.white54),
                onPressed: off < max ? () => _step(1) : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Header + rows that fit the width when they can, and otherwise scroll
/// sideways with a glider under them (the flex column then gets [flexMin]).
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
        final hasFlex = widget.cols.any((c) => c.flex);
        final natural = _fixedWidth(widget.cols, widget.widths) + (hasFlex ? widget.flexMin : 0);
        if (natural <= box.maxWidth) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.build(null));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              controller: _h,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: natural,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.build(hasFlex ? widget.flexMin : null)),
              ),
            ),
            _ScrollGlider(controller: _h),
          ],
        );
      },
    );
  }
}

/// An explanation block for one table (owner, round 216): an intro, then
/// [heading] ("Columns of the table below:"), one line per column with the
/// column name in bold and a little space between the lines, then an outro.
class _ColumnsHelp extends StatelessWidget {
  final String? intro;
  final String heading;
  final List<(String, String)> cols;
  final String? outro;
  const _ColumnsHelp({this.intro, this.heading = 'Columns of the table below:', required this.cols, this.outro});

  @override
  Widget build(BuildContext context) {
    const bold = TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (intro != null) Text(intro!, style: helperTextStyle),
          Padding(
            padding: EdgeInsets.only(top: intro == null ? 0 : 6),
            child: Text(heading, style: bold),
          ),
          for (final (name, text) in cols)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text.rich(
                TextSpan(children: [TextSpan(text: '$name: ', style: bold), TextSpan(text: text)]),
                style: helperTextStyle,
              ),
            ),
          if (outro != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(outro!, style: helperTextStyle)),
        ],
      ),
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

/// A track id's ladder step at [rank] (null = its identified rank).
Map<String, dynamic>? _ladderStep(Map<String, dynamic> t, String? rank) {
  final r = rank ?? t['identified_rank'];
  if (r == null) return null;
  for (final s in (t['ladder'] as List).cast<Map<String, dynamic>>()) {
    if (s['rank'] == r) return s;
  }
  return null;
}

/// A track id's Conf. at [rank] (null = its identified rank).
double? _ladderP(Map<String, dynamic> t, String? rank) => (_ladderStep(t, rank)?['p'] as num?)?.toDouble();

/// "50 % (5/10)": share and count of crops whose top species falls under
/// the step's taxon; "?" when the file lacks it.
String _agreeText(Map<String, dynamic>? step, int n) {
  final s = (step?['support'] as num?)?.toDouble();
  if (s == null || n == 0) return '?';
  return '${_pct(s)} (${(s * n).round()}/$n)';
}

/// "Animalia > Arthropoda > Insecta > Diptera > Syrphidae": kingdom ..
/// family of a crop's top species (round 220); "–" for a "none of these"
/// entry, "?" when the file predates round 220.
String _treeText(Map<String, dynamic> crop) {
  final t = (crop['top1_tree'] as List?)?.cast<String>();
  if (t == null) return '?';
  if (t.isEmpty || t.first == kSinkKingdom) return '–';
  return t.where((s) => s.isNotEmpty).join(' > ');
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

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
    _Col('visits', 'Track ids', numeric: true),
    _Col('time', 'Time', numeric: true),
    _Col('conf', 'Med. Conf.', numeric: true),
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
  Map<String, dynamic> get _settings => ((_summary?['settings'] as Map?) ?? const {}).cast<String, dynamic>();
  double get _margin => (_settings['margin'] as num?)?.toDouble() ?? 0.15;
  double? get _tau => (_settings['tau'] as num?)?.toDouble();
  double? get _noneThreshold => (_settings['none_threshold'] as num?)?.toDouble();
  Map<String, dynamic> get _capture => ((_summary?['capture'] as Map?) ?? const {}).cast<String, dynamic>();

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
        'Track ids',
        '${s['tracks_total']}'
        '${merged > 0 ? ' ($merged joined from consecutive track ids, ${s['tracks_before_merge']} before joining)' : ''}',
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
        label: 'Track ids per taxon / rank',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperChild: _ColumnsHelp(
          intro:
              'One row per taxon. A track id is one tracked organism (what a pollination ecologist '
              'calls a visit); it has one or more crops (photos) that the model classified together '
              'into one answer. "As identified" gives one row per answer at the rank the model was '
              'sure about (a track id identified only to genus Bombus and one identified to Bombus '
              'terrestris are two rows). Pick a rank to count every track id under its order, family, '
              'genus or species instead; track ids the model did not resolve that deep land in a '
              '"not resolved" row.',
          cols: [
            ('Taxon', 'the taxon of the row.'),
            ('Rank', 'its taxonomic rank; the Rank filter above keeps only rows of one rank.'),
            ('Track ids', 'how many track ids the row holds.'),
            ('Time', 'the durations of those track ids added up (first to last detector frame of each).'),
            (
              'Med. Conf.',
              'the median of the model\'s confidence for this taxon across the row\'s track ids, rounded '
                  'to whole percent. It is the Conf. column of the list that opens when you tap the row, '
                  'where confidence is explained. Model confidence, not a measured accuracy: treat '
                  'species-level names as suggestions.',
            ),
          ],
          outro: 'Tap a column header to sort, a row to list its track ids, a track id for its full ladder.',
        ),
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
          title: Text('Include ${_plural(_suspectCount, 'suspect track id')}', style: const TextStyle(color: Colors.white)),
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
      if (filtered.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No track ids.', style: helperTextStyle)),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _visible.isEmpty ? null : () => _showVisits('All track ids', _visible, rank: null, showTaxon: true),
          icon: const Icon(Icons.list),
          label: Text('All ${_visible.length} track ids'),
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
      // A bucket row ("unidentified", "not resolved …") holds track ids of
      // different taxa, so its sheet keeps the taxon column.
      onTap: () => _showVisits(r.isBucket ? r.taxon : '${r.taxon} (${r.rank})', r.tracks, rank: r.isBucket ? null : r.rank, showTaxon: r.isBucket),
      cells: [
        _txt(r.taxon, style: style, bold: !r.isBucket, maxLines: 2),
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
        builder: (_, controller) => _TrackSheet(
          sessionDir: widget.sessionDir,
          track: t,
          margin: _margin,
          tau: _tau,
          noneThreshold: _noneThreshold,
          photoStepS: (_capture['photo_step_s'] as num?)?.toDouble(),
          photoDurationS: (_capture['photo_duration_s'] as num?)?.toDouble(),
          controller: controller,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// S3: the track ids of one taxon row (or all): numbered, sortable.
// ---------------------------------------------------------------------------

class _VisitsSheet extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> tracks;

  /// Rank whose Conf. the sheet shows (the taxon row's rank); null = each
  /// track id's own identified rank (the "All track ids" list, bucket rows).
  final String? rank;

  /// False when every track id is the same taxon (the title says it).
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
  // Without a taxon column there is no flex column: the table stays
  // left-packed instead of spreading one column over the free width.
  late final List<_Col> _cols = [
    const _Col('no', 'No.'),
    const _Col('id', 'Track id'),
    if (widget.showTaxon) const _Col('taxon', 'Taxon', flex: true),
    const _Col('crops', 'Crops', numeric: true),
    const _Col('time', 'Time', numeric: true),
    const _Col('conf', 'Conf.', numeric: true),
    const _Col('agree', 'Agree', numeric: true),
  ];
  String _sortKey = 'no';
  bool _asc = true;
  late final List<(int, Map<String, dynamic>)> _rows = [for (var i = 0; i < widget.tracks.length; i++) (i + 1, widget.tracks[i])];
  final _h = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    super.dispose();
  }

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
        'agree' => _cmpNum(_ladderStep(a.$2, widget.rank)?['support'] as num?, _ladderStep(b.$2, widget.rank)?['support'] as num?),
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
          'agree' => _agreeText(_ladderStep(t, widget.rank), (t['crops'] as List).length),
          _ => _pct(_p(t)),
        },
    ], MediaQuery.textScalerOf(context));
    final taxonWord = widget.rank == null ? 'the taxon it was identified to' : widget.title.replaceAll(RegExp(r' \(.*\)$'), '');
    final median = _median([for (final t in widget.tracks) ?_p(t)]);
    // The list is lazy, so the sideways-scroll fallback of _MiniTable is
    // applied to the whole list instead: when the measured columns do not
    // fit (large system fonts, many-digit ids), the list scrolls sideways.
    final hasFlex = _cols.any((c) => c.flex);
    final natural = _fixedWidth(_cols, widths) + (hasFlex ? 110 : 0) + 32;
    return LayoutBuilder(
      builder: (_, box) {
        final list = _list(context, widths, taxonWord, median);
        if (natural <= box.maxWidth) return list;
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _h,
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: natural, child: list),
              ),
            ),
            _ScrollGlider(controller: _h),
          ],
        );
      },
    );
  }

  Widget _list(BuildContext context, Map<String, double> widths, String taxonWord, double? median) {
    return ListView.builder(
      controller: widget.controller,
      padding: _sheetPadding(context),
      itemCount: _rows.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.title} · ${_plural(widget.tracks.length, 'track id')}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              _ColumnsHelp(
                intro: 'One row per track id (one tracked organism, what a pollination ecologist calls a visit).',
                cols: [
                  ('No.', 'row number in this list.'),
                  ('Track id', 'the id the detector and tracker gave the organism (ids can jump).'),
                  if (widget.showTaxon) ('Taxon', 'the taxon it was identified to, with its rank.'),
                  ('Crops', 'how many of its photos were classified.'),
                  ('Time', 'first to last detector frame.'),
                  (
                    'Conf.',
                    'the model\'s confidence that this track id belongs to $taxonWord: its crops\' own values '
                        'averaged, a crop that is sure of its answer counting more (explained on the next screen).',
                  ),
                  (
                    'Agree',
                    'how many of its crops, judged one by one, put their top species inside $taxonWord: '
                        'share and count, e.g. 50 % (5/10).',
                  ),
                ],
                outro: widget.rank == null || median == null
                    ? 'Tap a row for the full ladder, photo and crops.'
                    : 'Median Conf. across these ${_plural(widget.tracks.length, 'track id')}: ${_pct(median)} '
                          '(the Med. Conf. shown in the table before). Tap a row for the full ladder, photo and crops.',
              ),
              const SizedBox(height: 6),
              _SortHeader(cols: _cols, widths: widths, sortKey: _sortKey, asc: _asc, onSort: _sort),
            ],
          );
        }
        final (no, t) = _rows[i - 1];
        final dim = t['headline'] == 'no organism' || t['headline'] == 'unidentified';
        final suspect = t['suspect'] == true;
        return _TableRow(
          cols: _cols,
          widths: widths,
          onTap: () => widget.onOpen(t),
          cells: [
            _txt('$no', style: _dimCellStyle),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _txt(_idText(t)),
                if (suspect && !widget.showTaxon) const Text('suspect', style: TextStyle(color: Colors.amber, fontSize: 11)),
              ],
            ),
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
            _txt(_agreeText(_ladderStep(t, widget.rank), (t['crops'] as List).length), right: true, style: _dimCellStyle),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// S4: one track id: ladder, flags, photo with boxes, crops table.
// ---------------------------------------------------------------------------

class _TrackSheet extends StatefulWidget {
  final Directory sessionDir;
  final Map<String, dynamic> track;
  final double margin;
  final double? tau;
  final double? noneThreshold;
  final double? photoStepS;
  final double? photoDurationS;
  final ScrollController controller;
  const _TrackSheet({
    required this.sessionDir,
    required this.track,
    required this.margin,
    required this.tau,
    required this.noneThreshold,
    required this.photoStepS,
    required this.photoDurationS,
    required this.controller,
  });

  @override
  State<_TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<_TrackSheet> {
  static const _ladderCols = [
    _Col('rank', 'Rank'),
    _Col('taxon', 'Taxon', flex: true),
    _Col('p', 'Conf.', numeric: true),
    _Col('support', 'Agree', numeric: true),
  ];

  late final List<Map<String, dynamic>> _crops = (widget.track['crops'] as List).cast<Map<String, dynamic>>();
  late final List<Map<String, dynamic>> _ladder = (widget.track['ladder'] as List).cast<Map<String, dynamic>>();
  late final List<(int, Map<String, dynamic>)> _cropRows = [for (var i = 0; i < _crops.length; i++) (i + 1, _crops[i])];
  String _sortKey = 'no';
  bool _asc = true;
  late int _shown = _bestIndex();
  bool _showBoxes = true;
  final _zoom = TransformationController();

  /// Ladder row whose taxon the crops table's confidence column shows;
  /// starts at the reported rank (or the deepest rank when unidentified).
  late int _sel = _rank == null ? math.max(0, _ladder.length - 1) : kRankNames.indexOf(_rank!);

  String? get _rank => widget.track['identified_rank'] as String?;
  String get _selTaxon => _sel < _ladder.length ? '${_ladder[_sel]['taxon']}' : '';
  String get _selRank => _sel < _ladder.length ? '${_ladder[_sel]['rank']}' : '';

  /// This crop's own Conf. for the selected ladder taxon (null for files
  /// written before round 215).
  double? _mass(Map<String, dynamic> c) {
    final l = (c['p_ladder'] as List?)?.cast<num>();
    if (l == null || _sel >= l.length) return null;
    return l[_sel].toDouble();
  }

  List<_Col> get _cropCols => [
    const _Col('no', 'No.'),
    _Col('mass', 'Conf. $_selTaxon', numeric: true),
    const _Col('agrees', 'Agree', numeric: true),
    const _Col('top1', 'Top species', flex: true),
    const _Col('p', 'Species conf.', numeric: true),
    const _Col('side', 'Side px', numeric: true),
    const _Col('tree', 'Taxonomic tree'),
  ];

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
        _asc = key == 'no' || key == 'top1' || key == 'tree';
      }
      int cmp((int, Map<String, dynamic>) a, (int, Map<String, dynamic>) b) => switch (_sortKey) {
        'mass' => _cmpNum(_mass(a.$2), _mass(b.$2)),
        'side' => _cmpNum(a.$2['crop_px'] as num?, b.$2['crop_px'] as num?),
        'p' => _cmpNum(a.$2['top1_p'] as num?, b.$2['top1_p'] as num?),
        'agrees' => (a.$2['agrees'] == true ? 1 : 0).compareTo(b.$2['agrees'] == true ? 1 : 0),
        'top1' => '${a.$2['top1']}'.compareTo('${b.$2['top1']}'),
        'tree' => _treeText(a.$2).compareTo(_treeText(b.$2)),
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
    final ids = (t['track_ids'] as List?)?.cast<num>() ?? const [];
    final flags = (t['flags'] as List).cast<String>();
    final title = t['track_id'] == null
        ? 'Crop'
        : 'Track id #${t['track_id']}${ids.length > 1 ? ' (joined ${ids.skip(1).map((i) => '#${i.toInt()}').join(', ')})' : ''}';
    final n = _crops.length;
    final scaler = MediaQuery.textScalerOf(context);
    final ladderWidths = _fitWidths(_ladderCols, (c) => [
      for (final s in _ladder)
        switch (c.key) {
          'rank' => '${s['rank']}',
          'p' => _pct(s['p'] as num?),
          _ => _agreeText(s, n),
        },
    ], scaler);
    final step = widget.photoStepS, dur = widget.photoDurationS;
    final schedule = step != null && dur != null
        ? 'this session: one every ${step.toStringAsFixed(step == step.roundToDouble() ? 0 : 1)} s during the first '
              '${dur.toStringAsFixed(dur == dur.roundToDouble() ? 0 : 1)} s of a track id'
        : 'e.g. one every second during the first 10 s of a track id';
    final best = widget.track['best_view'] as Map<String, dynamic>?;
    final bestSpecies = best == null ? '' : '${best['species']}';
    final bestAgree = bestSpecies.isEmpty ? 0 : _crops.where((c) => '${c['top1']}' == bestSpecies).length;
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
        Text(
          'Time = first to last detector frame of the track id. Detector frames = every frame the live '
          'detector saw it in (several per second). Photos = the frames saved on the photo schedule '
          '($schedule) plus frames another organism triggered while this one was in view; each saved '
          'photo gives one crop.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 12),
        HelpLabel(
          label: 'Ladder',
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperChild: _ColumnsHelp(
            intro:
                'The taxon chosen at every rank on one path from kingdom to species. The highlighted row is '
                'the deepest rank whose Conf. reached the threshold'
                '${widget.tau == null ? '' : ' (${_pct(widget.tau)})'}: the reported identification; the rows '
                'below it are suggestions. Tap a row to make the crops table show each crop\'s own confidence '
                'for that taxon (bar on the left = selected).',
            cols: [
              (
                'Conf.',
                'the model\'s confidence that this track id belongs to the taxon. How it is made: the model '
                    'turns each crop into a description (a list of numbers); the descriptions are averaged, '
                    'a crop the model is sure about counting more (its Species conf.) and crops it is far '
                    'less sure about left out; the average is classified once and the species under the '
                    'taxon are added up. Photos that agree therefore reinforce each other, and Conf. can be '
                    'higher than any single photo\'s value in the crops table; it is NOT an average of that '
                    'column. Photos that disagree pull the average apart and lower every Conf.',
              ),
              (
                'Agree',
                'how many crops, each on its own, have their top species inside the taxon, as share and '
                    'count (e.g. 50 % (5/10)). A second, count-based signal next to Conf.',
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _MiniTable(
          cols: _ladderCols,
          widths: ladderWidths,
          flexMin: 110,
          build: (fw) => [
            _SortHeader(cols: _ladderCols, widths: ladderWidths, flexWidth: fw),
            for (var k = 0; k < _ladder.length; k++)
              _TableRow(
                cols: _ladderCols,
                widths: ladderWidths,
                flexWidth: fw,
                highlight: _ladder[k]['rank'] == _rank,
                selected: k == _sel,
                onTap: () => setState(() => _sel = k),
                cells: [
                  _txt('${_ladder[k]['rank']}', style: _dimCellStyle, bold: _ladder[k]['rank'] == _rank),
                  _txt('${_ladder[k]['taxon']}', bold: _ladder[k]['rank'] == _rank, maxLines: 2),
                  _txt(_pct(_ladder[k]['p'] as num?), right: true, bold: _ladder[k]['rank'] == _rank),
                  _txt(_agreeText(_ladder[k], n), right: true, style: _dimCellStyle, bold: _ladder[k]['rank'] == _rank),
                ],
              ),
          ],
        ),
        if (bestSpecies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Best single photo: $bestSpecies ${_pct(best!['p'] as num?)} (crop No. ${_bestIndex() + 1}); '
              '$bestAgree of ${_plural(n, 'photo')} name this species.',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
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
            helperChild: _ColumnsHelp(
              intro:
                  'Flags describe the whole track id (all its crops together), not single crops, so '
                  'neither table has a column for them; the same flags are in the flags column of '
                  'tracks_<pack>.csv. none, unidentified, weak_id and path_conflict concern the ladder '
                  'above; the others concern the track itself.',
              heading: 'What each flag means:',
              cols: [
                ('merged', 'joined from consecutive track ids.'),
                ('short', 'below the duration or detections threshold.'),
                ('low_det', 'mean detector confidence below the threshold.'),
                ('weak_id', 'order-level Conf. below the threshold.'),
                ('suspect', 'short AND weakly supported; likely a false detection (kept, never deleted).'),
                (
                  'none',
                  'the label pack\'s "none of these" entries (flower, leaf, shadow …) together got more than '
                      '${widget.noneThreshold == null ? 'the "No organism" threshold' : '${_pct(widget.noneThreshold)} (the "No organism" threshold)'}, '
                      'so this track id is reported as "no organism": the detector most likely fired on '
                      'something that is not an organism. The flag is named after those entries; it does '
                      'NOT mean "no flags".',
                ),
                (
                  'unidentified',
                  'no taxonomic rank reached the confidence threshold'
                      '${widget.tau == null ? '' : ' (${_pct(widget.tau)})'}, not even kingdom, the highest '
                      'rank, so no identification is reported and no ladder row is highlighted. In a pack of '
                      'animals only (all current packs), kingdom Conf. is 100 % minus the "none of these" '
                      'share, so this happens when that share is large but not above the "No organism" '
                      'threshold.',
                ),
                (
                  'path_conflict',
                  'at some rank the single most probable taxon is NOT inside the taxon chosen one rank above '
                      '(say the most probable family overall belongs to a different order than the most '
                      'probable order). The ladder always follows the path from the top down, so from that '
                      'rank on it shows the best taxon inside the chosen parent, which has a lower Conf. than '
                      'the one it had to skip. A sign that the crops point in two directions.',
                ),
                ('single_crop', 'only one crop, so there is no agreement to measure.'),
              ],
            ),
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
            'Opens on the BEST VIEW: the crop whose own top species has the highest Species conf., i.e. '
            'the single photo the model is surest about on its own (it need not agree with the track '
            'id\'s answer). Tap a row of the crops table to show another crop.\n'
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
    final cols = _cropCols;
    final widths = _fitWidths(cols, (c) => [
      for (final (no, cr) in _cropRows)
        switch (c.key) {
          'no' => '$no',
          'mass' => _mass(cr) == null ? '?' : _pct(_mass(cr)),
          'agrees' => '✓',
          'p' => _pct(cr['top1_p'] as num?),
          'tree' => _treeText(cr),
          _ => '${cr['crop_px']}',
        },
    ], scaler);
    final missing =
        _crops.any((c) => c['agrees'] == null || _mass(c) == null || c['top1_tree'] == null) || _ladder.any((s) => s['p_max'] == null);
    final sel = _selTaxon.isEmpty ? 'the selected taxon' : '$_selTaxon ($_selRank)';
    return [
      HelpLabel(
        label: 'Crops',
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperChild: _ColumnsHelp(
          intro: 'One row per crop = one photo of this track id, in capture order.',
          cols: [
            ('No.', 'capture order; the camera icon marks the crop shown in the photo above.'),
            (
              'Conf. $_selTaxon',
              'this crop\'s own confidence for $sel, the ladder row selected above'
                  '${_selRank == 'species' ? ': at species level there is nothing to add up, so it is simply the crop\'s probability for this species (equal to Species conf. when this is the crop\'s top species)' : ': the crop\'s probabilities for all species under it added up'}. '
                  'Tap another ladder row to change the taxon. This column is evidence, not the arithmetic '
                  'behind the ladder: the track id\'s Conf. comes from the averaged descriptions, so it can '
                  'be higher than every value here when the crops agree, or lower when they disagree.',
            ),
            ('Agree', '✓ when the crop\'s top species is inside $sel.'),
            ('Top species', 'the species with the highest probability for this crop alone.'),
            (
              'Species conf.',
              'that probability (one species, nothing added up). It also decides how much the crop '
                  'counts in the combined answer: a crop that is sure of its answer counts more, and a '
                  'crop far less sure than the surest one (below it divided by the factor set under '
                  'Advanced settings) is left out and marked "left out" here. The ladder\'s species row '
                  'is the best species of the combined answer and can differ from every crop\'s own.',
            ),
            ('Side px', 'side of the square crop in photo pixels (box + margin); small crops are blurry after enlargement to the model\'s 224 px.'),
            (
              'Taxonomic tree',
              'the higher taxonomic ranks of the Top species: kingdom > phylum > class > order > family '
                  '(the genus is the first word of the species name). Shows where a crop that does not '
                  'agree with the ladder points instead, e.g. to which order. "–" for a "none of these" '
                  'entry.',
            ),
          ],
          outro: 'Tap a row to show that crop in the photo; tap a header to sort; drag sideways if the table is wider than the screen.',
        ),
      ),
      const SizedBox(height: 4),
      if (missing)
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            '"?" = a value an older app version did not store (some per-crop values before round 217, '
            'the taxonomic tree before round 220). "Re-score with this pack" on the Identify screen '
            'recomputes everything with the current rule in seconds.',
            style: TextStyle(color: Colors.amber, fontSize: 12),
          ),
        ),
      _MiniTable(
        cols: cols,
        widths: widths,
        flexMin: 150,
        build: (fw) => [
          _SortHeader(cols: cols, widths: widths, sortKey: _sortKey, asc: _asc, onSort: _sort, flexWidth: fw),
          for (final (no, c) in _cropRows)
            _TableRow(
              cols: cols,
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
                _txt(_treeText(c), style: _dimCellStyle),
              ],
              below: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${c['src']}${c['counted'] == false ? '  ·  left out of the combined answer' : ''}',
                  style: TextStyle(color: c['counted'] == false ? Colors.amber : Colors.white38, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
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
