// FaunaPulse (round 208, reworked rounds 209 and 214): results of an
// identification run for one session.
//
// Reads tracks_<pack>.json (full detail) and summary_<pack>.json (counts).
// Screen = key/value header, then a per-taxon TABLE (taxon, rank, visits,
// time, median confidence; sortable by any column, filterable by rank,
// grouped "as identified" or by a fixed rank). A row opens the visits
// behind it (numbered 1..N, the tracker's ids in their own column,
// sortable); a visit opens its detail sheet: the ladder as an aligned
// table with the chosen rank highlighted, flags with explanations, the
// photo with the detector box and the square crop drawn (toggle, zoom),
// and the crops table (tap a row to show that crop). Percentages are
// model confidence, not accuracy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../identification/crop_worker.dart' show planSquareCrop;
import '../identification/label_pack.dart' show kRankNames;
import '../identification/taxa_table.dart';
import '../logging/app_error_hooks.dart';
import '../widgets/setting_help.dart';

const _cellStyle = TextStyle(color: Colors.white, fontSize: 13);
const _dimCellStyle = TextStyle(color: Colors.white54, fontSize: 13);
const _detectorBoxColor = Colors.amber;
/// Horizontal space between table columns.
const double _gutter = 8;
const _cropBoxColor = Colors.cyanAccent;

String _pct(num? v) => v == null ? '–' : '${(v * 100).round()} %';

/// One column of a small table: fixed [width] or the remaining space.
class _Col {
  final String key;
  final String label;
  final double? width;
  final bool right;
  const _Col(this.key, this.label, {this.width, this.right = false});
}

/// A tappable, bold header row; the active sort column shows an arrow.
/// The line under it is thicker than the row dividers.
class _SortHeader extends StatelessWidget {
  final List<_Col> cols;
  final String sortKey;
  final bool asc;
  final void Function(String key) onSort;
  const _SortHeader({required this.cols, required this.sortKey, required this.asc, required this.onSort});

  @override
  Widget build(BuildContext context) {
    Widget cell(_Col c) {
      final active = c.key == sortKey;
      final text = Text(
        active ? '${c.label} ${asc ? '▲' : '▼'}' : c.label,
        textAlign: c.right ? TextAlign.right : TextAlign.left,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
      );
      final w = InkWell(onTap: () => onSort(c.key), child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: text));
      return c.width == null ? Expanded(child: w) : SizedBox(width: c.width, child: w);
    }

    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white54, width: 1.5))),
      // A gutter between columns: a right-aligned number next to a
      // left-aligned text otherwise reads as one string (owner, round 214).
      child: Row(children: [for (var i = 0; i < cols.length; i++) ...[if (i > 0) const SizedBox(width: _gutter), cell(cols[i])]]),
    );
  }
}

/// A data row laid out on the same [cols] as its header, with a thin line
/// under it; [highlight] draws the chosen/selected row.
class _TableRow extends StatelessWidget {
  final List<_Col> cols;
  final List<Widget> cells;
  final bool highlight;
  final VoidCallback? onTap;
  final Widget? below;
  const _TableRow({required this.cols, required this.cells, this.highlight = false, this.onTap, this.below});

  @override
  Widget build(BuildContext context) {
    assert(cells.length == cols.length);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < cols.length; i++) ...[
          if (i > 0) const SizedBox(width: _gutter),
          cols[i].width == null
              ? Expanded(child: cells[i])
              : SizedBox(width: cols[i].width, child: Align(alignment: cols[i].right ? Alignment.centerRight : Alignment.centerLeft, child: cells[i])),
        ],
      ],
    );
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
  // Fixed columns kept narrow so the taxon (long scientific names, plus the
  // lineage line, which may wrap) gets the space (owner, round 214).
  static const _cols = [
    _Col('taxon', 'Taxon'),
    _Col('rank', 'Rank', width: 56),
    _Col('visits', 'Visits', width: 42, right: true),
    _Col('time', 'Time', width: 46, right: true),
    _Col('conf', 'Conf.', width: 42, right: true),
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
                  ..._table(),
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

  List<Widget> _table() {
    final ranksPresent = <String>{for (final r in _rows) r.isBucket ? 'unresolved' : r.rank};
    final filtered = _rankFilter == null
        ? _rows
        : _rows.where((r) => (r.isBucket ? 'unresolved' : r.rank) == _rankFilter).toList();
    final shown = _allRows ? filtered : filtered.take(_rowsFolded).toList();
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
            'Time: the row\'s visit durations added up (first to last detection of each).\n'
            'Conf.: median confidence of the row\'s visits. Confidence is the probability the model '
            'gives that taxon, combining all crops of the visit. The model scores every name in the '
            'label pack (mostly species); FaunaPulse then adds those up the tree: a genus\'s probability '
            'is the sum of its species, a family\'s the sum of its genera, and so on. It is not a measured '
            'accuracy: treat species-level names as suggestions.\n'
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
          title: Text('Include $_suspectCount suspect visits', style: const TextStyle(color: Colors.white)),
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
      _SortHeader(cols: _cols, sortKey: _sortKey, asc: _sortAsc, onSort: _setSort),
      for (final r in shown) _taxonRow(r),
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
          onPressed: _visible.isEmpty ? null : () => _showVisits('All visits', _visible),
          icon: const Icon(Icons.list),
          label: Text('All ${_visible.length} visits'),
        ),
      ),
    ];
  }

  Widget _taxonRow(TaxonRow r) {
    final style = r.isBucket ? _dimCellStyle : _cellStyle;
    return _TableRow(
      cols: _cols,
      onTap: () => _showVisits(r.isBucket ? r.taxon : '${r.taxon} (${r.rank})', r.tracks),
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

  void _showVisits(String title, List<Map<String, dynamic>> tracks) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, controller) => _VisitsSheet(
          title: title,
          tracks: tracks,
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
  final ScrollController controller;
  final void Function(Map<String, dynamic>) onOpen;
  const _VisitsSheet({required this.title, required this.tracks, required this.controller, required this.onOpen});

  @override
  State<_VisitsSheet> createState() => _VisitsSheetState();
}

class _VisitsSheetState extends State<_VisitsSheet> {
  static const _cols = [
    _Col('no', 'No.', width: 30, right: true),
    _Col('id', 'Track id', width: 58),
    _Col('taxon', 'Taxon'),
    _Col('crops', 'Crops', width: 44, right: true),
    _Col('time', 'Time', width: 46, right: true),
    _Col('conf', 'Conf.', width: 44, right: true),
  ];
  String _sortKey = 'no';
  bool _asc = true;
  late List<(int, Map<String, dynamic>)> _rows; // (No., track)

  @override
  void initState() {
    super.initState();
    _rows = [for (var i = 0; i < widget.tracks.length; i++) (i + 1, widget.tracks[i])];
  }

  double? _p(Map<String, dynamic> t) {
    final rank = t['identified_rank'];
    if (rank == null) return null;
    for (final s in (t['ladder'] as List).cast<Map<String, dynamic>>()) {
      if (s['rank'] == rank) return (s['p'] as num).toDouble();
    }
    return null;
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
    return ListView.builder(
      controller: widget.controller,
      padding: _sheetPadding(context),
      itemCount: _rows.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${widget.title} · ${widget.tracks.length} visits', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              const Text(
                'No. = row number here; Track id = the id the detector and tracker gave the visit '
                '(ids can jump). Tap a row for the full ladder, photo and crops.',
                style: helperTextStyle,
              ),
              const SizedBox(height: 6),
              _SortHeader(cols: _cols, sortKey: _sortKey, asc: _asc, onSort: _sort),
            ],
          );
        }
        final (no, t) = _rows[i - 1];
        final dim = t['headline'] == 'no organism' || t['headline'] == 'unidentified';
        final ids = (t['track_ids'] as List?)?.cast<num>() ?? const [];
        final idText = t['track_id'] == null ? 'crop' : (ids.length > 1 ? '#${ids.first.toInt()}+${ids.length - 1}' : '#${t['track_id']}');
        final flags = (t['flags'] as List).cast<String>().where((f) => f != 'single_crop').join(', ');
        return _TableRow(
          cols: _cols,
          onTap: () => widget.onOpen(t),
          cells: [
            _txt('$no', right: true, style: _dimCellStyle),
            _txt(idText, style: _cellStyle),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _txt('${t['headline']}', style: dim ? _dimCellStyle : _cellStyle, maxLines: 2),
                if (t['identified_rank'] != null || flags.isNotEmpty)
                  // Wraps (owner, round 214): the flag list is often longer
                  // than the column and was cut to "class · short, pa…".
                  Text(
                    [if (t['identified_rank'] != null) '${t['identified_rank']}', if (flags.isNotEmpty) flags].join(' · '),
                    style: helperTextStyle,
                    softWrap: true,
                  ),
              ],
            ),
            _txt('${(t['crops'] as List).length}', right: true, style: _dimCellStyle),
            _txt(t['duration_s'] == null ? '–' : '${(t['duration_s'] as num).toStringAsFixed(1)} s', right: true, style: _dimCellStyle),
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
    _Col('rank', 'Rank', width: 62),
    _Col('taxon', 'Taxon'),
    _Col('p', 'Conf.', width: 48, right: true),
    _Col('support', 'Agree', width: 48, right: true),
  ];
  static const _cropCols = [
    _Col('no', 'No.', width: 26, right: true),
    _Col('side', 'Side px', width: 48, right: true),
    _Col('weight', 'Weight', width: 46, right: true),
    _Col('p', 'Conf.', width: 40, right: true),
    _Col('agrees', 'Agree', width: 40, right: true),
    _Col('top1', 'Best guess'),
  ];

  late final List<Map<String, dynamic>> _crops = (widget.track['crops'] as List).cast<Map<String, dynamic>>();
  late final List<(int, Map<String, dynamic>)> _cropRows = [for (var i = 0; i < _crops.length; i++) (i + 1, _crops[i])];
  String _sortKey = 'no';
  bool _asc = true;
  late int _shown = _bestIndex();
  bool _showBoxes = true;
  final _zoom = TransformationController();

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
    return ListView(
      controller: widget.controller,
      padding: _sheetPadding(context),
      children: [
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        Text(
          '${t['headline']}'
          '${t['identified_rank'] != null ? ' (${t['identified_rank']})' : ''}'
          '${t['duration_s'] != null ? ' · ${(t['duration_s'] as num).toStringAsFixed(1)} s' : ''}'
          '${t['detections'] != null ? ' · ${t['detections']} detector frames' : ''}'
          ' · ${_crops.length} photos (crops)',
          style: const TextStyle(color: Colors.white70),
        ),
        const Text(
          'Detector frames = how often the live detector saw this track id (many per second); '
          'photos = the ones saved on the photo schedule and used for identification.',
          style: helperTextStyle,
        ),
        const SizedBox(height: 12),
        const HelpLabel(
          label: 'Ladder',
          labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          helperText:
              'The taxon chosen at every rank, kingdom to species, on one consistent path.\n'
              'Conf.: the probability the model gives that taxon, combining all crops of the visit; it '
              'can only shrink going down the ladder.\n'
              'Agree: how many of the visit\'s photos, each judged ON ITS OWN, would place the organism '
              'in that taxon (or below it). 5/5 = every photo alone says so; 2/5 = only two do, the '
              'combined answer is carried by those (usually the sharper, larger) photos. The Agree '
              'column of the crops table shows which photos agree at the reported rank.\n'
              'The highlighted row is the deepest rank whose confidence reached the threshold: the '
              'reported identification. Rows below it are suggestions.',
        ),
        const SizedBox(height: 4),
        _SortHeader(cols: _ladderCols, sortKey: '', asc: true, onSort: (_) {}),
        for (final s in ladder)
          _TableRow(
            cols: _ladderCols,
            highlight: s['rank'] == t['identified_rank'],
            cells: [
              _txt('${s['rank']}', style: _dimCellStyle, bold: s['rank'] == t['identified_rank']),
              _txt('${s['taxon']}', bold: s['rank'] == t['identified_rank'], maxLines: 2),
              _txt(_pct(s['p'] as num?), right: true, bold: s['rank'] == t['identified_rank']),
              _txt(
                '${((s['support'] as num? ?? 0) * _crops.length).round()}/${_crops.length}',
                right: true,
                style: _dimCellStyle,
                bold: s['rank'] == t['identified_rank'],
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
                'weak_id: order-level probability below the threshold.\n'
                'suspect: short AND weakly supported; likely a false detection (kept, never deleted).\n'
                'none: "none of these" entries won; unidentified: not even the class reached the threshold.\n'
                'path_conflict: the best taxon at some rank does not sit under the best taxon of the rank '
                'above (the ladder keeps the consistent path).\n'
                'rule_conflict: the cross-check that averages the crops\' probabilities instead of their '
                'embeddings picks another taxon at the CSV rank.\n'
                'single_crop: only one crop, so no agreement to measure.',
          ),
        ],
        const SizedBox(height: 14),
        ..._photoSection(),
        const SizedBox(height: 14),
        ..._cropsSection(),
      ],
    );
  }

  List<Widget> _photoSection() {
    final c = _crops.isEmpty ? null : _crops[_shown];
    final best = widget.track['best_view'] as Map<String, dynamic>?;
    final file = c == null ? null : File('${widget.sessionDir.path}/roi_frames/${c['src']}');
    final isBest = best != null && c != null && c['src'] == best['src'];
    return [
      const HelpLabel(
        label: 'Photo',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Opens on the BEST SINGLE VIEW: the crop that, judged alone, gives the highest species '
            'probability (usually the sharpest, largest, least cut-off view). Tap a row of the crops '
            'table to show that crop instead.\n'
            'Yellow box: the detector\'s box for this organism. Cyan box: the square (box + margin) '
            'that was cut out and shown to the identification model. The eye button hides the boxes, '
            'pinch or double-tap zooms, the reset button returns to full view.',
      ),
      const SizedBox(height: 4),
      if (c != null)
        Row(
          children: [
            Expanded(
              child: Text(
                '${c['src']}${isBest ? ' (best view)' : ''}',
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

  List<Widget> _cropsSection() {
    return [
      const HelpLabel(
        label: 'Crops',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            'Every photo of this visit that was shown to the model, in capture order (No.).\n'
            'Side px: side of the square crop in photo pixels (box plus margin); small crops are blurry '
            'after enlargement to the model\'s 224 px.\n'
            'Weight: how much this crop counted in the combined answer (0 to 1): larger, sharper crops '
            'with a confident detection and little padding at the ROI edge weigh more.\n'
            'Best guess / Conf.: the species this crop alone would suggest and its probability; the '
            'combined answer above can differ.\n'
            'Agree: ✓ when this crop\'s own best guess falls under the reported taxon (the ladder\'s '
            'highlighted row); – when it does not.\n'
            'Tap a row to show that crop in the photo above; tap a header to sort.',
      ),
      const SizedBox(height: 4),
      if (_crops.any((c) => c['agrees'] == null))
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text(
            'Agree shows "?" because this result file was written by an older app version; '
            '"Re-score with this pack" on the Identify screen fills it in seconds.',
            style: TextStyle(color: Colors.amber, fontSize: 12),
          ),
        ),
      _SortHeader(cols: _cropCols, sortKey: _sortKey, asc: _asc, onSort: _sort),
      for (final (no, c) in _cropRows)
        _TableRow(
          cols: _cropCols,
          highlight: _crops.indexOf(c) == _shown,
          onTap: () => setState(() {
            _shown = _crops.indexOf(c);
            _zoom.value = Matrix4.identity();
          }),
          cells: [
            _txt('$no', right: true, style: _dimCellStyle),
            _txt('${c['crop_px']}', right: true, style: _dimCellStyle),
            _txt((c['weight'] as num).toStringAsFixed(2), right: true, style: _dimCellStyle),
            _txt(_pct(c['top1_p'] as num?), right: true),
            _txt(c['agrees'] == null ? '?' : (c['agrees'] == true ? '✓' : '–'), right: true, style: c['agrees'] == true ? _cellStyle : _dimCellStyle),
            _txt('${c['top1']}', maxLines: 2),
          ],
          below: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('${c['src']}', style: const TextStyle(color: Colors.white38, fontSize: 11), overflow: TextOverflow.ellipsis),
          ),
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
