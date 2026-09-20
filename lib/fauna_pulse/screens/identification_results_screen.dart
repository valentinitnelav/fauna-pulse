// FaunaPulse (round 208): results of an identification run for one session.
//
// Reads tracks_<pack>.json (full detail) and summary_<pack>.json (counts).
// Shows the counts, the taxa with the most visits, and one row per track
// id; tapping a row opens the "ladder" (kingdom .. species with the model's
// confidence and how many crops agree), the crops with their weights and
// the best single view. Percentages are model confidence, not accuracy.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

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
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _tracks = const [];
  String? _error;
  double _minP = 0;

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
      });
    } catch (e) {
      logSwallowed('identify_results_load', e);
      if (mounted) setState(() => _error = '$e');
    }
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
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
          : s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ..._header(s),
                const Divider(height: 32, color: Colors.white24),
                ..._taxaBars('Visits per order', s['taxa_order'] as Map),
                ..._taxaBars('Visits per family', s['taxa_family'] as Map),
                const Divider(height: 32, color: Colors.white24),
                ..._trackList(),
              ],
            ),
    );
  }

  List<Widget> _header(Map<String, dynamic> s) {
    final byRank = (s['by_identified_rank'] as Map).cast<String, dynamic>();
    return [
      Text(
        'Model ${s['model_id']} · pack ${s['pack_id']} (${s['pack_rows']} names) · ${s['generated_iso'].toString().substring(0, 16).replaceFirst('T', ' ')}',
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

  List<Widget> _taxaBars(String title, Map counts) {
    if (counts.isEmpty) return const [];
    final entries = counts.entries.map((e) => MapEntry('${e.key}', (e.value as num).toInt())).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxV = entries.first.value;
    return [
      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      for (final e in entries.take(12))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(width: 140, child: Text(e.key, style: const TextStyle(color: Colors.white), overflow: TextOverflow.ellipsis)),
              Expanded(
                child: LinearProgressIndicator(value: e.value / maxV, minHeight: 10, backgroundColor: Colors.white12),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 36, child: Text('${e.value}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.white))),
            ],
          ),
        ),
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _trackList() {
    final shown = _tracks.where((t) {
      final p = _identifiedP(t);
      return _minP == 0 || (p != null && p >= _minP);
    }).toList();
    return [
      Row(
        children: [
          const Text('Visits', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const Spacer(),
          const Text('min. confidence', style: helperTextStyle),
          Slider(
            value: _minP,
            min: 0,
            max: 0.95,
            divisions: 19,
            label: _pct(_minP),
            onChanged: (v) => setState(() => _minP = v),
          ),
        ],
      ),
      for (final t in shown)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 44,
            child: Text(
              t['track_id'] == null ? '·' : '#${t['track_id']}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          title: Text(
            '${t['headline']}'
            '${t['identified_rank'] != null ? ' (${t['identified_rank']}, ${_pct(_identifiedP(t))})' : ''}',
            style: TextStyle(
              color: t['headline'] == 'no organism' || t['headline'] == 'unidentified' ? Colors.white54 : Colors.white,
            ),
          ),
          subtitle: Text(
            '${(t['crops'] as List).length} crops'
            '${t['duration_s'] != null ? ' · ${(t['duration_s'] as num).toStringAsFixed(1)} s' : ''}'
            '${(t['flags'] as List).isNotEmpty ? ' · ${(t['flags'] as List).join(', ')}' : ''}',
            style: helperTextStyle,
          ),
          onTap: () => _showTrack(t),
        ),
      if (shown.isEmpty) const Text('No visits above this confidence.', style: helperTextStyle),
    ];
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
          padding: const EdgeInsets.all(16),
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
