// FaunaPulse (round 208): files of the identification feature inside a
// session folder, and the readers/writers for them.
//
//   <session>/identification/
//     embeddings_<model>.jsonl   one `crop` record per embedded crop (+ skips,
//                                identify_start / identify_end); append-only,
//                                so a run is resumable
//     embeddings_<model>.bin     the vectors, float32 little-endian, row-major,
//                                row = the record's `row`
//     predictions_<pack>.jsonl   per crop: top rows of the pack with probabilities
//     tracks_<pack>.json         per track: ladder, crops, flags (full detail)
//     tracks_<pack>.csv          one row per track; the leading columns follow the
//                                `_classified_final.csv` of insect-detect-post
//                                (Sittinger 2026, AGPL-3.0, Zenodo
//                                10.5281/zenodo.21822140) so both tools' outputs
//                                can be analysed alike, plus per-rank
//                                probability/support columns of our own
//     summary_<pack>.json        counts for the results screen and home badge
//     README_identification.txt  column dictionary + the run's parameters
//
// Strict one-JSON-object-per-line files, never pretty-printed (like session.jsonl).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'label_pack.dart';
import 'track_fusion.dart';

/// Base name without extension, safe for use inside other file names.
String stemOf(String fileName) {
  final base = fileName.split('/').last;
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  return stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

class IdentificationPaths {
  final Directory sessionDir;
  const IdentificationPaths(this.sessionDir);

  static const dirName = 'identification';
  Directory get dir => Directory('${sessionDir.path}/$dirName');

  File embeddingsBin(String modelStem) =>
      File('${dir.path}/embeddings_$modelStem.bin');
  File embeddingsJsonl(String modelStem) =>
      File('${dir.path}/embeddings_$modelStem.jsonl');
  File predictionsJsonl(String packStem) =>
      File('${dir.path}/predictions_$packStem.jsonl');
  File tracksJson(String packStem) => File('${dir.path}/tracks_$packStem.json');
  File tracksCsv(String packStem) => File('${dir.path}/tracks_$packStem.csv');
  File summaryJson(String packStem) =>
      File('${dir.path}/summary_$packStem.json');
  File get readme => File('${dir.path}/README_identification.txt');

  /// Every summary file present (one per pack the session was scored with).
  List<File> existingSummaries() {
    if (!dir.existsSync()) return const [];
    final out = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.split('/').last.startsWith('summary_') && f.path.endsWith('.json'))
        .toList();
    out.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return out;
  }
}

/// One `crop` record of `embeddings_<model>.jsonl`.
class EmbeddingRecord {
  final String key;
  final String source;
  final String photo;
  final String boxSource;
  final int? trackId;
  final List<double> box;
  final int cropPx;
  final double padFrac;
  final double sharpness;
  final double detConf;
  final int? capturedAtMs;
  final int row;

  const EmbeddingRecord({
    required this.key,
    required this.source,
    required this.photo,
    required this.boxSource,
    required this.trackId,
    required this.box,
    required this.cropPx,
    required this.padFrac,
    required this.sharpness,
    required this.detConf,
    required this.capturedAtMs,
    required this.row,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'src': source,
    'photo': photo,
    'box_source': boxSource,
    'track_id': trackId,
    'box': [for (final v in box) double.parse(v.toStringAsFixed(4))],
    'crop_px': cropPx,
    'pad_frac': double.parse(padFrac.toStringAsFixed(3)),
    'sharpness': double.parse(sharpness.toStringAsFixed(2)),
    'det_conf': double.parse(detConf.toStringAsFixed(3)),
    'captured_at_ms': capturedAtMs,
    'row': row,
  };

  static EmbeddingRecord? fromJson(Map<String, dynamic> j) {
    final row = (j['row'] as num?)?.toInt();
    final key = j['key'] as String?;
    if (row == null || key == null) return null;
    return EmbeddingRecord(
      key: key,
      source: (j['src'] as String?) ?? '',
      photo: (j['photo'] as String?) ?? '',
      boxSource: (j['box_source'] as String?) ?? '',
      trackId: (j['track_id'] as num?)?.toInt(),
      box: [for (final v in (j['box'] as List? ?? const [])) (v as num).toDouble()],
      cropPx: (j['crop_px'] as num?)?.toInt() ?? 0,
      padFrac: (j['pad_frac'] as num?)?.toDouble() ?? 0,
      sharpness: (j['sharpness'] as num?)?.toDouble() ?? 0,
      detConf: (j['det_conf'] as num?)?.toDouble() ?? 1,
      capturedAtMs: (j['captured_at_ms'] as num?)?.toInt(),
      row: row,
    );
  }
}

/// What an existing `embeddings_<model>.jsonl` says (resume state).
class EmbeddingIndex {
  final List<EmbeddingRecord> records;
  final Set<String> skippedKeys;
  final int? dim;
  final String? modelId;

  const EmbeddingIndex({
    required this.records,
    required this.skippedKeys,
    required this.dim,
    required this.modelId,
  });

  Set<String> get doneKeys => {for (final r in records) r.key};

  /// Rows are contiguous 0..n-1 when the file is intact.
  int get rows => records.isEmpty ? 0 : records.map((r) => r.row).reduce((a, b) => a > b ? a : b) + 1;

  bool get contiguous {
    final seen = <int>{for (final r in records) r.row};
    return seen.length == records.length && seen.length == rows;
  }

  static EmbeddingIndex parse(String jsonl) {
    final records = <EmbeddingRecord>[];
    final skipped = <String>{};
    int? dim;
    String? modelId;
    for (final line in const LineSplitter().convert(jsonl)) {
      if (line.trim().isEmpty) continue;
      Map<String, dynamic> rec;
      try {
        rec = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        continue; // truncated tail line after a kill
      }
      switch (rec['type']) {
        case 'crop':
          final r = EmbeddingRecord.fromJson(rec);
          if (r != null) records.add(r);
        case 'crop_skipped':
          final k = rec['key'];
          if (k is String) skipped.add(k);
        case 'identify_start':
          dim ??= (rec['dim'] as num?)?.toInt();
          modelId ??= rec['model'] as String?;
      }
    }
    return EmbeddingIndex(records: records, skippedKeys: skipped, dim: dim, modelId: modelId);
  }
}

/// Reads the whole vector file (rows × dim float32 little-endian).
Float32List readEmbeddingRows(File bin, int rows, int dim) {
  final bytes = bin.readAsBytesSync();
  final n = rows * dim;
  if (bytes.length < n * 4) {
    throw StateError('embeddings .bin is shorter than its record count');
  }
  final out = Float32List(n);
  final data = ByteData.sublistView(bytes, 0, n * 4);
  for (var i = 0; i < n; i++) {
    out[i] = data.getFloat32(i * 4, Endian.little);
  }
  return out;
}

/// Little-endian float32 bytes of [v] (what the .bin stores).
Uint8List vectorBytes(Float32List v) {
  final data = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    data.setFloat32(i * 4, v[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

String _iso(int? ms) =>
    ms == null ? '' : DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();

String _csvCell(Object? v) {
  final s = v == null ? '' : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// One scored track with everything the writers need.
class ScoredTrack {
  final FusedTrack fused;
  final List<EmbeddingRecord> crops;
  final int? startMs;
  final int? endMs;
  const ScoredTrack({
    required this.fused,
    required this.crops,
    required this.startMs,
    required this.endMs,
  });
}

/// Writes predictions/tracks/summary/README for one pack. Returns the summary
/// map (also written to `summary_<pack>.json`).
Map<String, dynamic> writeOutputs({
  required IdentificationPaths paths,
  required String packStem,
  required LabelPack pack,
  required String modelId,
  required String sessionId,
  required String deviceId,
  required List<ScoredTrack> tracks,
  required Map<String, dynamic> settings,
  required String appVersion,
}) {
  paths.dir.createSync(recursive: true);
  final targetRank = (settings['target_rank'] as String?) ?? 'family';
  final noneThreshold = (settings['none_threshold'] as num?)?.toDouble() ?? 0.5;
  final now = DateTime.now();

  // --- predictions_<pack>.jsonl: per crop top rows ---
  // Built in memory and written synchronously: an async IOSink could still be
  // flushing when the scoring isolate returns, losing the tail of the file.
  final pred = StringBuffer();
  for (final t in tracks) {
    for (var i = 0; i < t.crops.length; i++) {
      final rec = t.crops[i];
      final top = t.fused.perCrop[i];
      pred.writeln(
        jsonEncode({
          'type': 'prediction',
          'key': rec.key,
          'src': rec.source,
          'track_id': rec.trackId,
          'weight': double.parse(t.fused.weights[i].toStringAsFixed(3)),
          'top': [
            for (var j = 0; j < top.rows.length; j++)
              {
                'row': top.rows[j],
                'name': pack.labels[top.rows[j]].speciesName,
                'family': pack.labels[top.rows[j]].ranks[4],
                'order': pack.labels[top.rows[j]].ranks[3],
                'p': double.parse(top.probs[j].toStringAsFixed(4)),
              },
          ],
        }),
      );
    }
  }
  paths.predictionsJsonl(packStem).writeAsStringSync(pred.toString());

  // --- tracks_<pack>.json + .csv ---
  final rankIdx = kRankNames.indexOf(targetRank).clamp(0, 6);
  final jsonTracks = <Map<String, dynamic>>[];
  final csv = StringBuffer();
  final header = <String>[
    'device_id',
    'session_id',
    'track_id',
    'track_imgs',
    'pred_imgs',
    'pred',
    'pred_prob_weighted',
    'pred_prob_mean',
    'start_time',
    'end_time',
    'duration_s',
    'det_conf_mean',
    for (final r in kRankNames) 'bioclip_$r',
    for (final r in kRankNames) 'p_$r',
    'identified_rank',
    'headline',
    for (final r in kRankNames) 'support_$r',
    'n_crops_used',
    'none_p',
    'best_view_photo',
    'best_view_species',
    'best_view_p',
    'flags',
    'model_id',
    'pack_id',
  ];
  csv.writeln(header.join(','));
  final byRank = <String, int>{};
  final taxaOrder = <String, int>{};
  final taxaFamily = <String, int>{};
  var noneCount = 0, unidentified = 0;

  for (final t in tracks) {
    final f = t.fused;
    final step = rankIdx < f.ladder.length ? f.ladder[rankIdx] : null;
    final isNone = f.noneMass > noneThreshold;
    final headline = isNone
        ? 'no organism'
        : (f.identifiedRank == null ? 'unidentified' : f.stepAt(f.identifiedRank!)!.taxon);
    if (isNone) {
      noneCount++;
    } else if (f.identifiedRank == null) {
      unidentified++;
    } else {
      byRank[f.identifiedRank!] = (byRank[f.identifiedRank!] ?? 0) + 1;
      final o = f.stepAt('order');
      final fam = f.stepAt('family');
      if (o != null && _reached(f, 'order')) {
        taxaOrder[o.taxon] = (taxaOrder[o.taxon] ?? 0) + 1;
      }
      if (fam != null && _reached(f, 'family')) {
        taxaFamily[fam.taxon] = (taxaFamily[fam.taxon] ?? 0) + 1;
      }
    }
    // pred_prob_mean: mean over crops of the mass their top rows put under
    // the predicted taxon (approximate: from each crop's top-5 rows).
    var predMeanSum = 0.0;
    var predImgs = 0;
    if (step != null) {
      for (final top in f.perCrop) {
        var m = 0.0;
        for (var j = 0; j < top.rows.length; j++) {
          final row = pack.labels[top.rows[j]];
          if (row.ranks[rankIdx].isNotEmpty && row.keyAt(rankIdx) == step.key) m += top.probs[j];
        }
        if (m > 0) {
          predMeanSum += m;
          predImgs++;
        }
      }
    }
    final detConfMean = t.crops.isEmpty
        ? 0.0
        : t.crops.map((c) => c.detConf).reduce((a, b) => a + b) / t.crops.length;
    final flags = <String>[
      if (isNone) 'none',
      if (f.identifiedRank == null && !isNone) 'unidentified',
      if (f.pathConflict) 'path_conflict',
      if (f.ruleConflict) 'rule_conflict',
      if (t.crops.length == 1) 'single_crop',
    ];
    final bestCrop = t.crops[f.bestViewIndex];
    final durationS = (t.startMs != null && t.endMs != null)
        ? (t.endMs! - t.startMs!) / 1000
        : null;
    final bio = {for (var k = 0; k < 7; k++) 'bioclip_${kRankNames[k]}': k < f.ladder.length ? f.ladder[k].taxon : ''};
    final pr = {for (var k = 0; k < 7; k++) 'p_${kRankNames[k]}': k < f.ladder.length ? f.ladder[k].mass.toStringAsFixed(4) : ''};
    final sup = {for (var k = 0; k < 7; k++) 'support_${kRankNames[k]}': k < f.ladder.length ? f.ladder[k].support.toStringAsFixed(3) : ''};
    final row = <Object?>[
      deviceId,
      sessionId,
      f.trackId,
      t.crops.length,
      predImgs,
      step?.taxon ?? '',
      step == null ? '' : step.mass.toStringAsFixed(4),
      predImgs == 0 ? '' : (predMeanSum / predImgs).toStringAsFixed(4),
      _iso(t.startMs),
      _iso(t.endMs),
      durationS?.toStringAsFixed(2) ?? '',
      detConfMean.toStringAsFixed(3),
      ...bio.values,
      ...pr.values,
      f.identifiedRank ?? '',
      headline,
      ...sup.values,
      t.crops.length,
      f.noneMass.toStringAsFixed(4),
      bestCrop.source,
      f.bestViewTaxon,
      f.bestViewProb.toStringAsFixed(4),
      flags.join(';'),
      modelId,
      pack.packId,
    ];
    csv.writeln(row.map(_csvCell).join(','));
    jsonTracks.add({
      'track_id': f.trackId,
      'headline': headline,
      'identified_rank': f.identifiedRank,
      'none_p': double.parse(f.noneMass.toStringAsFixed(4)),
      'start_ms': t.startMs,
      'end_ms': t.endMs,
      'duration_s': durationS,
      'det_conf_mean': double.parse(detConfMean.toStringAsFixed(3)),
      'ladder': [for (final s in f.ladder) s.toJson()],
      'flags': flags,
      'best_view': {
        'src': bestCrop.source,
        'species': f.bestViewTaxon,
        'p': double.parse(f.bestViewProb.toStringAsFixed(4)),
      },
      'crops': [
        for (var i = 0; i < t.crops.length; i++)
          {
            'src': t.crops[i].source,
            'box': t.crops[i].box,
            'weight': double.parse(f.weights[i].toStringAsFixed(3)),
            'crop_px': t.crops[i].cropPx,
            'sharpness': double.parse(t.crops[i].sharpness.toStringAsFixed(1)),
            'top1': pack.labels[f.perCrop[i].rows.first].speciesName,
            'top1_p': double.parse(f.perCrop[i].probs.first.toStringAsFixed(4)),
          },
      ],
    });
  }
  paths.tracksCsv(packStem).writeAsStringSync(csv.toString());

  final summary = <String, dynamic>{
    'generated_ms': now.millisecondsSinceEpoch,
    'generated_iso': now.toIso8601String(),
    'app_version': appVersion,
    'model_id': modelId,
    'pack_id': pack.packId,
    'pack_rows': pack.rows,
    'settings': settings,
    'tracks_total': tracks.length,
    'by_identified_rank': byRank,
    'none': noneCount,
    'unidentified': unidentified,
    'taxa_order': taxaOrder,
    'taxa_family': taxaFamily,
    'tracks': [
      for (final t in jsonTracks)
        {
          'track_id': t['track_id'],
          'headline': t['headline'],
          'identified_rank': t['identified_rank'],
          'p': t['identified_rank'] == null
              ? null
              : (t['ladder'] as List).cast<Map<String, dynamic>>().firstWhere((s) => s['rank'] == t['identified_rank'])['p'],
          'n_crops': (t['crops'] as List).length,
        },
    ],
  };
  paths.tracksJson(packStem).writeAsStringSync(
    jsonEncode({
      'session_id': sessionId,
      'device_id': deviceId,
      'model_id': modelId,
      'pack_id': pack.packId,
      'settings': settings,
      'generated_iso': now.toIso8601String(),
      'tracks': jsonTracks,
    }),
  );
  paths.summaryJson(packStem).writeAsStringSync(jsonEncode(summary));
  paths.readme.writeAsStringSync(readmeText(settings: settings, modelId: modelId, packId: pack.packId));
  return summary;
}

bool _reached(FusedTrack f, String rank) {
  final id = f.identifiedRank;
  if (id == null) return false;
  return kRankNames.indexOf(id) >= kRankNames.indexOf(rank);
}

String readmeText({
  required Map<String, dynamic> settings,
  required String modelId,
  required String packId,
}) =>
    '''
FaunaPulse identification output (generated by the app)

Model: $modelId    Label pack: $packId
Run settings: ${jsonEncode(settings)}

Files
  embeddings_<model>.jsonl / .bin  one record + one float32 vector per crop (row = vector index)
  predictions_<pack>.jsonl         per crop: the most probable pack rows with probabilities
  tracks_<pack>.json               per track: the full "ladder" (kingdom..species with mass and support),
                                   crops with weights, best single view, flags
  tracks_<pack>.csv                one row per track (visit); columns below
  summary_<pack>.json              counts used by the app's results screen

tracks_<pack>.csv columns
  device_id, session_id, track_id      identifiers (track_id empty for no-AI sessions: one row per crop)
  track_imgs                          crops used for this track
  pred, pred_prob_weighted            the taxon at the chosen target rank and its probability mass
  pred_imgs, pred_prob_mean           crops whose own top rows include that taxon, and their mean mass
                                      (approximate, from each crop's top-5 rows)
  start_time, end_time, duration_s    from the session log's track span
  det_conf_mean                       mean detector confidence of the crops
  bioclip_<rank>                      the taxon chosen at each rank on a consistent top-down path
  p_<rank>                            probability mass of that taxon (model confidence, calibrated only
                                      if the pack carries a fitted temperature)
  identified_rank                     deepest rank whose mass reached tau
  headline                            the taxon at identified_rank, or "unidentified" / "no organism"
  support_<rank>                      share of crops whose own top-1 falls under that taxon
  none_p                              mass on the "none of these" rows (flower, leaf, shadow, ...)
  best_view_*                         the single crop with the most confident species suggestion
  flags                               none | unidentified | path_conflict | rule_conflict | single_crop
  model_id, pack_id                   provenance

How it is computed (plan section 11.3): each crop is embedded with the BioCLIP image
tower; a track's crops are averaged (quality-weighted: size, sharpness, detector
confidence, padding), the average is scored against the pack, and species masses are
summed up the taxonomy. Percentages are model confidence, not accuracy.
''';
