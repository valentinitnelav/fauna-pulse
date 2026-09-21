// FaunaPulse (round 208, reworked round 209): results of an identification
// run for one session.
//
// Reads tracks_<pack>.json (full detail) and summary_<pack>.json (counts).
// The centre piece is a per-taxon TABLE (one row per identified taxon with
// visits, time and median confidence) so a session with thousands of
// visits still fits on one screen; the visits behind a row open on tap in a
// lazily built sheet, and a visit opens its "ladder" (kingdom .. species
// with the model's confidence and how many crops agree), the crops with
// their weights and the best single view. Percentages are model
// confidence, not accuracy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../identification/label_pack.dart' show kRankNames;
import '../identification/taxa_table.dart';
import '../logging/app_error_hooks.dart';
import '../widgets/setting_help.dart';

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
  /// Rows shown before "Show all rows" is tapped: keeps a 200-taxon pack
  /// from producing a page-long table by default.
  static const int _rowsFolded = 25;

  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _tracks = const [];
  List<TaxonRow> _rows = const [];
  String _groupRank = kGroupAsIdentified;
  bool _allRows = false;
  String? _error;

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
        _rows = aggregateTracks(tracks, groupRank: _groupRank);
      });
    } catch (e) {
      logSwallowed('identify_results_load', e);
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setGroup(String rank) {
    setState(() {
      _groupRank = rank;
      _allRows = false;
      _rows = aggregateTracks(_tracks, groupRank: rank);
    });
  }

  double? _identifiedP(Map<String, dynamic> t) {
    final rank = t['identified_rank'];
    if (rank == null) return null;
    for (final s in (t['ladder'] as List).cast<Map<String, dynamic>>()) {
      if (s['rank'] == rank) return (s['p'] as num).toDouble();
    }
    return null;
  }

  String _pct(num? v) => v == null ? '–' : '${(v * 100).round()} %';

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final name = widget.sessionDir.path.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text('Identification — $name'),
        actions: [
          IconButton(
            tooltip: 'Share the CSV',
            icon: const Icon(Icons.share_outlined),
            onPressed: widget.tracksCsv.existsSync()
                ? () => SharePlus.instance.share(ShareParams(files: [XFile(widget.tracksCsv.path)]))
                : null,
          ),
        ],
      ),
      // SafeArea + bottom padding: the app is edge-to-edge, an explicitly
      // padded ListView otherwise hides its last row under the system bar.
      body: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
            : s == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  ..._header(s),
                  const Divider(height: 32, color: Colors.white24),
                  ..._table(),
                ],
              ),
      ),
    );
  }

  List<Widget> _header(Map<String, dynamic> s) {
    final byRank = (s['by_identified_rank'] as Map).cast<String, dynamic>();
    return [
      Text(
        'Model ${s['model_id']} · pack ${s['pack_id']} (${s['pack_rows']} names) · '
        '${s['generated_iso'].toString().substring(0, 16).replaceFirst('T', ' ')}',
        style: helperTextStyle,
      ),
      const SizedBox(height: 8),
      Text('${s['tracks_total']} visits', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(
        [
          for (final e in byRank.entries) '${e.value} identified to ${e.key}',
          if (s['unidentified'] != 0) '${s['unidentified']} unidentified',
          if (s['none'] != 0) '${s['none']} no organism',
        ].join(' · '),
        style: const TextStyle(color: Colors.white70),
      ),
      const SizedBox(height: 6),
      const Text(
        'Confidence = the model\'s probability mass for that taxon, combined over the visit\'s crops. '
        'It is not a measured accuracy; treat species-level names as suggestions to verify.',
        style: helperTextStyle,
      ),
    ];
  }

  List<Widget> _table() {
    final shown = _allRows ? _rows : _rows.take(_rowsFolded).toList();
    return [
      const HelpLabel(
        label: 'Visits per taxon',
        labelStyle: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        helperText:
            '"As identified" gives one row per answer at the rank the model was sure about '
            '(a visit identified only to genus Bombus and one identified to Bombus terrestris '
            'are two rows). Pick a rank to count every visit under its order, family, genus or '
            'species instead; visits the model did not resolve that deep land in a '
            '"not resolved" row. Time = the visits\' durations added up; Conf. = median '
            'confidence of the row\'s visits. Tap a row for its visits, a visit for its full ladder.',
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
              onSelected: (_) => _setGroup(value),
            ),
        ],
      ),
      const SizedBox(height: 8),
      _tableHeader(),
      const Divider(height: 8, color: Colors.white24),
      for (final r in shown) _taxonRow(r),
      if (_rows.length > shown.length)
        TextButton(
          onPressed: () => setState(() => _allRows = true),
          child: Text('Show all ${_rows.length} rows'),
        ),
      if (_rows.isEmpty) const Text('No visits.', style: helperTextStyle),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _tracks.isEmpty ? null : () => _showVisits('All visits', _tracks),
          icon: const Icon(Icons.list),
          label: Text('All ${_tracks.length} visits'),
        ),
      ),
    ];
  }

  static const _colVisits = 52.0, _colTime = 58.0, _colConf = 50.0;

  Widget _tableHeader() => const Row(
    children: [
      Expanded(child: Text('Taxon', style: helperTextStyle)),
      SizedBox(width: _colVisits, child: Text('Visits', textAlign: TextAlign.right, style: helperTextStyle)),
      SizedBox(width: _colTime, child: Text('Time', textAlign: TextAlign.right, style: helperTextStyle)),
      SizedBox(width: _colConf, child: Text('Conf.', textAlign: TextAlign.right, style: helperTextStyle)),
    ],
  );

  Widget _taxonRow(TaxonRow r) {
    final dim = r.isBucket;
    final title = r.isBucket ? r.taxon : '${r.taxon}  (${r.rank})';
    return InkWell(
      onTap: () => _showVisits(r.isBucket ? r.taxon : '${r.taxon} (${r.rank})', r.tracks),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: dim ? Colors.white54 : Colors.white, fontWeight: FontWeight.w600),
                  ),
                  if (r.lineage.isNotEmpty)
                    Text(r.lineage.join(' › '), style: helperTextStyle, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            SizedBox(width: _colVisits, child: Text('${r.visits}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.white))),
            SizedBox(
              width: _colTime,
              child: Text(formatVisitTime(r.totalS), textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70)),
            ),
            SizedBox(
              width: _colConf,
              child: Text(_pct(r.medianP), textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }

  /// The visits behind one table row (or all of them), built lazily so a
  /// thousand-visit session opens instantly.
  void _showVisits(String title, List<Map<String, dynamic>> tracks) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (_, controller) => ListView.builder(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: tracks.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('$title · ${tracks.length} visits', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              );
            }
            return _visitTile(tracks[i - 1]);
          },
        ),
      ),
    );
  }

  Widget _visitTile(Map<String, dynamic> t) {
    final dim = t['headline'] == 'no organism' || t['headline'] == 'unidentified';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 48,
        child: Text(t['track_id'] == null ? 'crop' : '#${t['track_id']}', style: const TextStyle(color: Colors.white70)),
      ),
      title: Text(
        '${t['headline']}'
        '${t['identified_rank'] != null ? ' (${t['identified_rank']}, ${_pct(_identifiedP(t))})' : ''}',
        style: TextStyle(color: dim ? Colors.white54 : Colors.white),
      ),
      subtitle: Text(
        '${(t['crops'] as List).length} crops'
        '${t['duration_s'] != null ? ' · ${(t['duration_s'] as num).toStringAsFixed(1)} s' : ''}'
        '${(t['flags'] as List).isNotEmpty ? ' · ${(t['flags'] as List).join(', ')}' : ''}',
        style: helperTextStyle,
      ),
      onTap: () => _showTrack(t),
    );
  }

  void _showTrack(Map<String, dynamic> t) {
    final ladder = (t['ladder'] as List).cast<Map<String, dynamic>>();
    final crops = (t['crops'] as List).cast<Map<String, dynamic>>();
    final best = t['best_view'] as Map<String, dynamic>?;
    final bestFile = best == null ? null : File('${widget.sessionDir.path}/roi_frames/${best['src']}');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(
              t['track_id'] == null ? 'Crop' : 'Visit #${t['track_id']}: ${t['headline']}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Ladder (rank · taxon · confidence · crops agreeing)', style: helperTextStyle),
            for (final s in ladder)
              Row(
                children: [
                  SizedBox(width: 70, child: Text('${s['rank']}', style: const TextStyle(color: Colors.white70))),
                  Expanded(
                    child: Text(
                      '${s['taxon']}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: s['rank'] == t['identified_rank'] ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                  SizedBox(width: 52, child: Text(_pct(s['p'] as num?), textAlign: TextAlign.right)),
                  SizedBox(width: 52, child: Text(_pct(s['support'] as num?), textAlign: TextAlign.right, style: helperTextStyle)),
                ],
              ),
            if ((t['none_p'] as num? ?? 0) > 0.05)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('"None of these" mass: ${_pct(t['none_p'] as num?)}', style: helperTextStyle),
              ),
            if ((t['flags'] as List).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Flags: ${(t['flags'] as List).join(', ')}', style: helperTextStyle),
              ),
            if (best != null) ...[
              const SizedBox(height: 12),
              Text('Best single view: ${best['species']} (${_pct(best['p'] as num?)}) in ${best['src']}', style: const TextStyle(color: Colors.white70)),
              if (bestFile != null && bestFile.existsSync())
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Image.file(bestFile, height: 220, fit: BoxFit.contain, cacheWidth: 600),
                ),
            ],
            const SizedBox(height: 12),
            const Text('Crops (weight · own top-1)', style: helperTextStyle),
            for (final c in crops)
              Text(
                '${c['src']} · w ${(c['weight'] as num).toStringAsFixed(2)} · ${c['crop_px']} px · ${c['top1']} ${_pct(c['top1_p'] as num?)}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }
}
