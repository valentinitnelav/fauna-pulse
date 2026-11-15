// FaunaPulse (round 208, rule changed rounds 217 and 219): scoring one crop
// and pooling a track id's crops.
//
// Pure Dart, no I/O, unit-tested.
//   * per crop: softmax over the pack of (logit_scale / T) * cosine similarity
//     (as pybioclip's predict, Imageomics); T = the pack's calibration
//     temperature, 1.0 until one is fitted on labelled crops
//   * per track id (round 219, "Average Logit" of Dussert et al. 2025, RSEC
//     11:88-99, adapted): the crops' unit embeddings are averaged, each crop
//     weighted by its own top-1 probability (its certainty), crops whose
//     certainty is below the surest crop's divided by [dropFactor] left out;
//     the average (NOT re-normalised, so disagreement shortens it and lowers
//     every confidence) is scored once against the pack and rolled up through
//     the taxonomy (mass of a family = sum of its species, as pybioclip's
//     format_grouped_probs). For a similarity-scored model this equals
//     averaging the crops' logits before the softmax, the rule that benchmark
//     found best calibrated; the certainty weights and the drop rule are
//     FaunaPulse additions. Checked on expert-named pollinator photos (the
//     smartphone time-lapse set, Zenodo 10.5281/zenodo.15096610, 1,281 track
//     ids): they name the insects as well as the plain average, not better
//     (differences inside the test's uncertainty, about 2 points), so they
//     stay only because a change gains nothing. A threshold fitted for one
//     pooling rule does not hold for another: change the rule and tau
//     together (docs/IDENTIFICATION.md, "Validation status").
//   * a consistent top-down "ladder" (best child of the chosen parent) with,
//     per rank, the pooled mass, the plain mean / maximum / agreeing-crops
//     mean of the crops' own masses, and "support" (share of crops whose own
//     top-1 agrees)
//   * "identified rank" = deepest ladder rank with mass >= tau (default 0.6)
//   * sink rows (kingdom `none`) collect the "no organism" mass
//   * the unit-length pooled embedding is kept solely for the visit-merge
//     similarity check (visit_merge.dart)
//   * round 266, class lists (fixed-class classifiers such as insectDCT, see
//     label_pack.dart): a crop's vector is the model's raw class scores. Each
//     output layer ("head") becomes log-probabilities; a row (finest class)
//     scores the mean of its classes' log-probabilities over the heads, so it
//     only scores high when every level agrees and K heads are not K
//     independent votes; one softmax over the rows (fpack.py
//     class_probabilities in fauna-pulse-models, the same formula, checked by a shared fixture).
//     The crops' raw scores are averaged like BioCLIP's vectors (per head the
//     "Average Logit"); everything after that is unchanged.
//   * round 373, country lists (a pack's `regions` block, label_pack.dart): the names can
//     be narrowed to the species GBIF lists in a country and its neighbours. Only what is
//     SHOWN is narrowed (the ladder, the identified rank, each crop's candidates, the best
//     view). The share of the "none of these" rows, the crops' certainty weights, the drop
//     rule and the merge check keep reading the scores over every name of the pack, so
//     they are the same for every country choice. Rule, per crop and for the pooled
//     scores l: none_p = the sink rows' mass of the softmax over ALL rows; a species row
//     outside the list gets 0; a species row i in the list gets
//     (1 - none_p) * exp(l_i - logsumexp(l over the listed species rows)). Why not simply
//     mask before the softmax: none_p would then be N / (N + K) (N = the sink rows' mass,
//     K = the listed species' mass, both over the whole pack), which rises as the list
//     gets shorter. Measured in fauna-pulse-models on 784 crops: flower crops without an
//     insect flagged "no organism" were 0 % with the whole pack, 0.5 % with Germany's
//     list and 8.7 % with Malta's (310 names); with the rule above 0 % for every list.
//     Idea of a regional list: BioCLIP's documentation ("Geo-Restricted Taxon List
//     Predictions", Imageomics). Whether a country list names insects better than the
//     whole list is not measured yet (docs/IDENTIFICATION.md, "Validation status").

import 'dart:math' as math;
import 'dart:typed_data';

import 'label_pack.dart';

/// One embedded crop of a track id, as the pooling sees it.
class CropEmbedding {
  final String jpeg;
  final int? trackId;
  final Float32List vector;

  /// Round 359: the crop's scaled scores against the pack when the caller computed them for
  /// several crops at once ([Scorer.logitsMany]); null, and [Scorer.fuse] computes them.
  final Float64List? logits;

  const CropEmbedding({required this.jpeg, required this.trackId, required this.vector, this.logits});
}

/// Top-k rows of one probability vector.
class TopK {
  final List<int> rows;
  final List<double> probs;
  const TopK(this.rows, this.probs);
}

/// One rung of a track id's ladder.
class LadderStep {
  final String rank;
  final String taxon;
  final String key;

  /// The reported confidence: mass under this taxon of the pooled
  /// distribution (round 219: the crops' embeddings averaged with certainty
  /// weights, scored once). Can exceed every single crop's own mass when the
  /// crops agree.
  final double mass;

  /// Share of the track id's crops whose own top-1 falls under this taxon.
  final double support;

  /// Plain (unweighted) mean over ALL crops of their own mass under this
  /// taxon, the highest single crop's mass, and the mean over the crops whose
  /// own top-1 falls under it (0 when none); exported so other pooling rules
  /// (e.g. insect-detect-post's vote share x mean = support x agreeMass) can
  /// be compared without re-scoring.
  final double meanMass;
  final double maxMass;
  final double agreeMass;

  /// Round 221 (path_conflict): the taxon with the highest mass of this rank
  /// overall when it lies outside the taxon chosen one rank up, else null;
  /// its mass and its ancestors (kingdom .. one rank up), so a screen can say
  /// where it leaves the ladder's path.
  final String? rival;
  final double rivalMass;
  final List<String> rivalLineage;

  const LadderStep({
    required this.rank,
    required this.taxon,
    required this.key,
    required this.mass,
    required this.support,
    required this.meanMass,
    required this.maxMass,
    required this.agreeMass,
    this.rival,
    this.rivalMass = 0,
    this.rivalLineage = const [],
  });

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'taxon': taxon,
    'p': double.parse(mass.toStringAsFixed(4)),
    'p_mean': double.parse(meanMass.toStringAsFixed(4)),
    'p_max': double.parse(maxMass.toStringAsFixed(4)),
    'p_agree': double.parse(agreeMass.toStringAsFixed(4)),
    'support': double.parse(support.toStringAsFixed(3)),
    if (rival != null) ...{
      'rival': rival,
      'rival_p': double.parse(rivalMass.toStringAsFixed(4)),
      'rival_lineage': rivalLineage,
    },
  };
}

class FusedTrack {
  final int? trackId;
  final int nCrops;
  final List<LadderStep> ladder;

  /// Deepest rank with mass >= tau, or null when even the kingdom is unsure
  /// or the sink rows win.
  final String? identifiedRank;
  final double noneMass;
  final bool pathConflict;

  /// The crop whose own top species has the highest (non-sink) probability:
  /// the single photo the model is surest about, agreeing with the track
  /// id's answer or not (round 217); that species and that probability.
  final int bestViewIndex;
  final String bestViewTaxon;
  final double bestViewProb;

  /// Certainty-weighted mean embedding, re-normalised. Used ONLY by the
  /// visit-merge similarity check (visit_merge.dart).
  final Float32List fusedEmbedding;

  /// Per-crop top-k rows, among the names on offer (round 373: a country list narrows them).
  final List<TopK> perCrop;

  /// Each crop's certainty weight in the pooling: its top-1 probability over every name of
  /// the pack, also when a country list narrows what is shown (then it differs from
  /// `perCrop[i].probs.first`). Same length as [perCrop].
  final List<double> weights;

  /// Each crop's own mass on the "none of these" rows, over every name of the pack.
  final List<double> perCropNone;

  /// Round 373, for the merge check only (visit_merge.dart): the identified rank and the
  /// ladder keys (index = rank) of the answer over every name of the pack. They equal
  /// [identifiedRank] and the [ladder]'s keys unless a country list narrows the names; the
  /// merge reads these so that the country choice never changes which track IDs are joined.
  final String? mergeRank;
  final List<String> mergeKeys;

  /// Round 266: the most probable rows of the pooled distribution (for a
  /// class list, the model's own class of the track ID: LabelPack.classNames).
  final TopK pooledTop;

  /// Round 219: false for crops left out of the pooled answer (certainty below
  /// the surest crop's divided by the drop factor). Same length as [perCrop].
  final List<bool> counted;

  /// For every crop, its OWN mass under each ladder taxon (index = rank,
  /// same length as [ladder]); the number every screen value traces to.
  final List<List<double>> perCropMass;

  const FusedTrack({
    required this.trackId,
    required this.nCrops,
    required this.ladder,
    required this.identifiedRank,
    required this.noneMass,
    required this.pathConflict,
    required this.bestViewIndex,
    required this.bestViewTaxon,
    required this.bestViewProb,
    required this.fusedEmbedding,
    required this.perCrop,
    required this.weights,
    required this.perCropNone,
    required this.mergeRank,
    required this.mergeKeys,
    required this.perCropMass,
    required this.counted,
    required this.pooledTop,
  });

  LadderStep? stepAt(String rank) {
    for (final s in ladder) {
      if (s.rank == rank) return s;
    }
    return null;
  }

  /// "no organism" / "unidentified" / the identified rank's taxon.
  String get headline {
    if (noneMass > 0.5) return 'no organism';
    if (identifiedRank == null) return 'unidentified';
    return stepAt(identifiedRank!)!.taxon;
  }
}

/// The consistent top-down path through one distribution's masses (index = rank).
class _Path {
  final keys = <String>[];
  final mass = <double>[];
  final rivalKey = <String?>[];
  final rivalMass = <double>[];
  var conflict = false;

  /// Deepest rank whose mass reaches [tau] (every rank above it does too), or null when even
  /// the kingdom is unsure or the sink rows win.
  String? identifiedRank(double tau) {
    if (keys.isEmpty || keys.first == kSinkKingdom) return null;
    String? rank;
    for (var k = 0; k < keys.length && mass[k] >= tau; k++) {
      rank = kRankNames[k];
    }
    return rank;
  }
}

class Scorer {
  final LabelPack pack;

  /// Effective softmax scale: logit_scale / temperature (plan 11.4).
  final double scale;

  /// Round 373: the species rows on offer when a country list narrows the names (file
  /// header); null = every row.
  final Int32List? _kept;
  late final Int32List _sinkRows = Int32List.fromList([
    for (var r = 0; r < pack.rows; r++)
      if (pack.labels[r].isSink) r,
  ]);

  /// [allowedRows]: one bit per pack row ([PackRegions.rowBits]) to narrow the names to a
  /// country list; null = the whole pack. Sink rows are always on offer.
  Scorer(this.pack, {double? temperature, Uint8List? allowedRows})
    : scale = pack.logitScale / (temperature ?? pack.temperature),
      _kept = _keptRows(pack, allowedRows);

  static Int32List? _keptRows(LabelPack pack, Uint8List? bits) {
    if (bits == null || pack.isClassList || bits.length * 8 < pack.rows) return null;
    final rows = [
      for (var r = 0; r < pack.rows; r++)
        if (!pack.labels[r].isSink && PackRegions.hasRow(bits, r)) r,
    ];
    // A list without a single name of the pack never narrows: there would be nothing to answer.
    return rows.isEmpty ? null : Int32List.fromList(rows);
  }

  /// Whether a country list narrows the names this scorer shows.
  bool get narrowed => _kept != null;

  /// Mass of [p] on the "none of these" rows.
  double noneOf(Float32List p) {
    var s = 0.0;
    for (final r in _sinkRows) {
      s += p[r];
    }
    return s;
  }

  /// [whole] (the probabilities of [logits] over every row) narrowed to the names on offer
  /// (round 373, rule in the file header); [whole] itself when nothing narrows. The sink rows
  /// keep their values.
  Float32List narrow(Float64List logits, Float32List whole) {
    final kept = _kept;
    if (kept == null) return whole;
    final out = Float32List(whole.length);
    var none = 0.0;
    for (final r in _sinkRows) {
      out[r] = whole[r];
      none += whole[r];
    }
    // exp(l_i - logsumexp over the listed rows) = whole_i / (the listed rows' whole-pack mass),
    // so the probabilities at hand are rescaled: no second pass of exponentials (measured on a
    // session of 9,193 crops with a 28,000-name list: that pass made the scoring 22 % slower).
    var listed = 0.0;
    for (final r in kept) {
      listed += whole[r];
    }
    if (listed > 1e-30) {
      final f = math.max(0.0, 1 - none) / listed;
      for (final r in kept) {
        out[r] = whole[r] * f;
      }
      return out;
    }
    // A list whose names all score so far below the pack's best name that their probabilities
    // are zero in 32 bits: from the scores, in log space, so the result is not 0 / 0.
    var maxL = -double.infinity;
    for (final r in kept) {
      if (logits[r] > maxL) maxL = logits[r];
    }
    final ex = Float64List(kept.length);
    var sum = 0.0;
    for (var i = 0; i < kept.length; i++) {
      final v = math.exp(logits[kept[i]] - maxL);
      ex[i] = v;
      sum += v;
    }
    final f = math.max(0.0, 1 - none) / sum;
    for (var i = 0; i < kept.length; i++) {
      out[kept[i]] = ex[i] * f;
    }
    return out;
  }

  // Round 215: an integer id per row and rank for the row's taxonomy key,
  // built once per pack, so the mass of a distribution under a ladder taxon
  // is one integer comparison per row (rollUp joins strings per row and is
  // far too slow to run per crop).
  List<Int32List>? _rankIds;
  List<Map<String, int>>? _keyToId;
  List<List<String>>? _idToKey; // round 348: id -> key per rank, for rollUp
  List<List<int>>? _parentOf; // round 373: id -> the id of its taxon one rank up, for _wholePath

  void _buildRankIds() {
    final ids = List.generate(7, (_) => Int32List(pack.rows));
    final maps = List.generate(7, (_) => <String, int>{});
    final names = List.generate(7, (_) => <String>[]);
    final parents = List.generate(7, (_) => <int>[]);
    for (var r = 0; r < pack.rows; r++) {
      final row = pack.labels[r];
      for (var k = 0; k < 7; k++) {
        if (row.ranks[k].isEmpty) {
          for (var j = k; j < 7; j++) {
            ids[j][r] = -1;
          }
          break;
        }
        final key = row.keyAt(k);
        ids[k][r] = maps[k].putIfAbsent(key, () {
          names[k].add(key);
          parents[k].add(k == 0 ? -1 : ids[k - 1][r]);
          return names[k].length - 1;
        });
      }
    }
    _rankIds = ids;
    _keyToId = maps;
    _idToKey = names;
    _parentOf = parents;
  }

  /// Probability mass of [p] under each ladder key in [keys] (index = rank;
  /// shorter ladders allowed). Keys nest, so a row outside the key at one
  /// rank is outside every deeper key too.
  List<double> massesAt(Float32List p, List<String> keys) {
    if (_rankIds == null) _buildRankIds();
    final ids = _rankIds!, maps = _keyToId!;
    final target = [for (var k = 0; k < keys.length; k++) maps[k][keys[k]] ?? -2];
    final out = List<double>.filled(keys.length, 0);
    for (var r = 0; r < pack.rows; r++) {
      final v = p[r];
      for (var k = 0; k < target.length; k++) {
        if (ids[k][r] != target[k]) break;
        out[k] += v;
      }
    }
    return out;
  }

  /// Softmax over all pack rows for unit vector [e] (a class list: the
  /// model's raw scores, see the file header).
  Float32List probs(Float32List e) => softmax(logits(e));

  /// The scaled score of [e] against every pack row: the softmax input (round 348, perf review
  /// H4b: one pass over the pack with [LabelPack.dotsInto]).
  Float64List logits(Float32List e) {
    final n = pack.rows;
    final out = Float64List(n);
    if (pack.isClassList) {
      final heads = _headLogProbs(e);
      final k = pack.headSizes.length;
      for (var r = 0; r < n; r++) {
        var s = 0.0;
        for (var h = 0; h < k; h++) {
          s += heads[h][pack.headIndex[r * k + h]];
        }
        out[r] = scale * s / k;
      }
    } else {
      pack.dotsInto(e, out);
      for (var r = 0; r < n; r++) {
        out[r] *= scale;
      }
    }
    return out;
  }

  /// [logits] of several vectors in one pass over the pack (round 359, [LabelPack.dotsIntoMany]):
  /// the scoring's main cost, 2.7 times cheaper per vector than one call each.
  List<Float64List> logitsMany(List<Float32List> es) {
    if (pack.isClassList) return [for (final e in es) logits(e)];
    final outs = [for (var i = 0; i < es.length; i++) Float64List(pack.rows)];
    pack.dotsIntoMany(es, outs);
    for (final out in outs) {
      for (var r = 0; r < out.length; r++) {
        out[r] *= scale;
      }
    }
    return outs;
  }

  /// The probabilities of [logits] (one per pack row); [logits] is left as it is.
  Float32List softmax(Float64List logits) {
    final n = logits.length;
    var maxL = -double.infinity;
    for (var r = 0; r < n; r++) {
      if (logits[r] > maxL) maxL = logits[r];
    }
    final ex = Float64List(n);
    var sum = 0.0;
    for (var r = 0; r < n; r++) {
      final v = math.exp(logits[r] - maxL);
      ex[r] = v;
      sum += v;
    }
    final out = Float32List(n);
    for (var r = 0; r < n; r++) {
      out[r] = ex[r] / sum;
    }
    return out;
  }

  /// Each head's slice of the raw scores [e] as log-probabilities (log-softmax).
  List<Float64List> _headLogProbs(Float32List e) {
    final out = <Float64List>[];
    var start = 0;
    for (final size in pack.headSizes) {
      var mx = -double.infinity;
      for (var i = 0; i < size; i++) {
        if (e[start + i] > mx) mx = e[start + i].toDouble();
      }
      var sum = 0.0;
      for (var i = 0; i < size; i++) {
        sum += math.exp(e[start + i] - mx);
      }
      final lse = mx + math.log(sum);
      out.add(Float64List.fromList([for (var i = 0; i < size; i++) e[start + i] - lse]));
      start += size;
    }
    return out;
  }

  /// The [k] most probable rows of [p] (descending).
  TopK topK(Float32List p, int k) {
    final kk = math.min(k, p.length);
    final rows = <int>[];
    final probs = <double>[];
    for (var r = 0; r < p.length; r++) {
      final v = p[r];
      if (rows.length < kk) {
        var i = rows.length;
        rows.add(r);
        probs.add(v);
        while (i > 0 && probs[i - 1] < probs[i]) {
          _swap(rows, probs, i - 1, i);
          i--;
        }
      } else if (v > probs[kk - 1]) {
        rows[kk - 1] = r;
        probs[kk - 1] = v;
        var i = kk - 1;
        while (i > 0 && probs[i - 1] < probs[i]) {
          _swap(rows, probs, i - 1, i);
          i--;
        }
      }
    }
    return TopK(rows, probs);
  }

  static void _swap(List<int> a, List<double> b, int i, int j) {
    final t = a[i];
    a[i] = a[j];
    a[j] = t;
    final u = b[i];
    b[i] = b[j];
    b[j] = u;
  }

  /// Mass per hierarchy key at every rank (index = rank, map key -> mass).
  ///
  /// Round 348 (perf review H4b): summed per integer rank id (built once per pack) and named
  /// afterwards; joining the string key per row and rank took about 0.1 s per call on a
  /// 35,000-name pack. Rows with no mass are left out and the keys keep the order of their
  /// first row with mass, as before.
  List<Map<String, double>> rollUp(Float32List p) {
    if (_rankIds == null) _buildRankIds();
    final ids = _rankIds!, names = _idToKey!;
    final acc = [for (var k = 0; k < 7; k++) Float64List(names[k].length)];
    final order = List.generate(7, (_) => <int>[]);
    for (var r = 0; r < pack.rows; r++) {
      final v = p[r];
      if (v <= 0) continue;
      for (var k = 0; k < 7; k++) {
        final id = ids[k][r];
        if (id < 0) break; // unknown below this rank
        if (acc[k][id] == 0) order[k].add(id);
        acc[k][id] += v;
      }
    }
    return [
      for (var k = 0; k < 7; k++) {for (final id in order[k]) names[k][id]: acc[k][id]},
    ];
  }

  /// Pools a track id's crops (round 219 rule, see the file header). [tau] =
  /// mass needed to count as identified; [dropFactor] = crops whose certainty
  /// is below the surest crop's divided by this are left out (<= 1: none).
  FusedTrack fuse(List<CropEmbedding> crops, {double tau = 0.6, double dropFactor = 10, int topK = 5}) {
    assert(crops.isNotEmpty);
    final dim = pack.dim;
    final n = crops.length;

    // Every crop scored on its own. Round 348 (perf review H4b): the logits are kept, because
    // the pooled vector's logits are their certainty-weighted mean (a dot product is linear in
    // the vector), which saves the pooled vector's pass over the pack. A class list keeps the
    // pooled-vector pass: its scores go through a log-softmax per head first, which is not
    // linear.
    final perCropLogits = [for (final c in crops) c.logits ?? logits(c.vector)];
    // Over every name of the pack: the weights, the drop rule and the "none of these" shares
    // read these, whatever country list is set (round 373, file header).
    final perCropWhole = [for (final l in perCropLogits) softmax(l)];
    // What is shown: narrowed to the country list when one is set.
    final perCropProbs = _kept == null
        ? perCropWhole
        : [for (var i = 0; i < n; i++) narrow(perCropLogits[i], perCropWhole[i])];
    final perCropTop = [for (final p in perCropProbs) this.topK(p, topK)];

    // Certainty weight = the crop's top-1 probability (always > 0); crops far
    // less certain than the surest one are left out.
    final weights = [for (final p in perCropWhole) _maxOf(p)];
    var maxW = 0.0;
    for (final w in weights) {
      if (w > maxW) maxW = w;
    }
    final counted = [for (final w in weights) dropFactor <= 1 || w >= maxW / dropFactor];
    var wsum = 0.0;
    for (var i = 0; i < n; i++) {
      if (counted[i]) wsum += weights[i];
    }

    // Pooled embedding: certainty-weighted mean of the counted crops' unit
    // vectors, deliberately not re-normalised (average logit).
    final pooled = Float32List(dim);
    final pooledLogits = Float64List(pack.isClassList ? 0 : pack.rows);
    for (var i = 0; i < n; i++) {
      if (!counted[i]) continue;
      final w = weights[i] / wsum;
      final v = crops[i].vector;
      for (var d = 0; d < dim; d++) {
        pooled[d] += (w * v[d]).toDouble();
      }
      if (!pack.isClassList) {
        final l = perCropLogits[i];
        for (var r = 0; r < pooledLogits.length; r++) {
          pooledLogits[r] += w * l[r];
        }
      }
    }
    // Over every name of the pack: the "none of these" share and the merge check read this.
    final wholeBar = pack.isClassList ? probs(pooled) : softmax(pooledLogits);
    final pbar = narrow(pooledLogits, wholeBar);
    final masses = rollUp(pbar);

    // Unit-length copy for the merge similarity check only.
    final fused = Float32List(dim);
    var norm = 0.0;
    for (var d = 0; d < dim; d++) {
      norm += pooled[d] * pooled[d];
    }
    norm = math.sqrt(norm);
    for (var d = 0; d < dim; d++) {
      fused[d] = norm > 0 ? pooled[d] / norm : pooled[d];
    }

    final path = _pathOf(masses);
    final keys = path.keys;

    // Each crop's own mass under the ladder taxa (evidence for the tables and
    // the per-rank alternatives p_mean / p_max / p_agree).
    final perCropMass = [for (final p in perCropProbs) massesAt(p, keys)];
    final ladder = <LadderStep>[];
    for (var k = 0; k < keys.length; k++) {
      var sum = 0.0, mx = 0.0, agreeSum = 0.0;
      var agreeN = 0;
      for (var i = 0; i < n; i++) {
        final m = perCropMass[i][k];
        sum += m;
        if (m > mx) mx = m;
        final top1 = pack.labels[perCropTop[i].rows.first];
        if (top1.ranks[k].isNotEmpty && top1.keyAt(k) == keys[k]) {
          agreeSum += m;
          agreeN++;
        }
      }
      final rival = path.rivalKey[k];
      ladder.add(
        LadderStep(
          rank: kRankNames[k],
          taxon: k == 6 ? _speciesDisplay(keys[k]) : keys[k].split('|').last,
          key: keys[k],
          mass: path.mass[k],
          support: agreeN / n,
          meanMass: sum / n,
          maxMass: mx,
          agreeMass: agreeN == 0 ? 0 : agreeSum / agreeN,
          rival: rival == null ? null : (k == 6 ? _speciesDisplay(rival) : rival.split('|').last),
          rivalMass: path.rivalMass[k],
          rivalLineage: rival == null ? const [] : rival.split('|').take(k).toList(),
        ),
      );
    }

    final identified = path.identifiedRank(tau);
    final (mergeRank, mergeKeys) = identical(pbar, wholeBar) ? (identified, keys) : _wholePath(wholeBar, tau);

    // Best single view: the crop the model is surest about on its own
    // (highest top-1 non-sink probability), no quality gate (round 217).
    var bestIdx = 0;
    var bestProb = -1.0;
    var bestTaxon = '';
    for (var i = 0; i < n; i++) {
      final t = perCropTop[i];
      for (var j = 0; j < t.rows.length; j++) {
        final row = pack.labels[t.rows[j]];
        if (row.isSink) continue;
        if (t.probs[j] > bestProb) {
          bestProb = t.probs[j];
          bestIdx = i;
          bestTaxon = row.speciesName;
        }
        break; // only the best non-sink row of this crop
      }
    }

    return FusedTrack(
      trackId: crops.first.trackId,
      nCrops: n,
      ladder: ladder,
      identifiedRank: identified,
      noneMass: noneOf(wholeBar),
      pathConflict: path.conflict,
      bestViewIndex: bestIdx,
      bestViewTaxon: bestTaxon,
      bestViewProb: math.max(0, bestProb),
      fusedEmbedding: fused,
      perCrop: perCropTop,
      weights: weights,
      perCropNone: [for (final p in perCropWhole) noneOf(p)],
      mergeRank: mergeRank,
      mergeKeys: mergeKeys,
      perCropMass: perCropMass,
      counted: counted,
      pooledTop: this.topK(pbar, 3),
    );
  }

  static double _maxOf(Float32List p) {
    var m = 0.0;
    for (var r = 0; r < p.length; r++) {
      if (p[r] > m) m = p[r];
    }
    return m;
  }

  /// The identified rank and the ladder keys of [p], as [rollUp], [_pathOf] and
  /// [_Path.identifiedRank] give them, without the maps of names per rank (round 373). With a
  /// country list every track ID needs this second path over the whole pack for the merge
  /// check, and building the maps of tens of thousands of names twice made the pooling half
  /// as slow again. Same order of the candidates (first row with mass first), same first-wins
  /// rule on equal masses.
  (String?, List<String>) _wholePath(Float32List p, double tau) {
    if (_rankIds == null) _buildRankIds();
    final ids = _rankIds!, names = _idToKey!, parents = _parentOf!;
    final acc = [for (var k = 0; k < 7; k++) Float64List(names[k].length)];
    final order = List.generate(7, (_) => <int>[]);
    for (var r = 0; r < pack.rows; r++) {
      final v = p[r];
      if (v <= 0) continue;
      for (var k = 0; k < 7; k++) {
        final id = ids[k][r];
        if (id < 0) break;
        if (acc[k][id] == 0) order[k].add(id);
        acc[k][id] += v;
      }
    }
    final keys = <String>[];
    String? rank;
    var reaching = true;
    var parent = -1;
    for (var k = 0; k < 7; k++) {
      var bestId = -1;
      var best = -1.0;
      for (final id in order[k]) {
        if ((k == 0 || parents[k][id] == parent) && acc[k][id] > best) {
          best = acc[k][id];
          bestId = id;
        }
      }
      if (bestId < 0) break;
      keys.add(names[k][bestId]);
      if (k == 0 && names[0][bestId] == kSinkKingdom) reaching = false;
      if (reaching && best >= tau) {
        rank = kRankNames[k];
      } else {
        reaching = false;
      }
      parent = bestId;
    }
    return (rank, keys);
  }

  /// The consistent top-down path through [masses] ([rollUp]): at every rank the child of the
  /// taxon chosen one rank up with the most mass. The taxon with the most mass of the rank
  /// overall is its rival when it lies outside that parent (path_conflict, round 221).
  _Path _pathOf(List<Map<String, double>> masses) {
    final path = _Path();
    var parentKey = '';
    for (var k = 0; k < 7; k++) {
      String? bestKey;
      var best = -1.0;
      String? argmaxKey;
      var argmax = -1.0;
      for (final e in masses[k].entries) {
        if (e.value > argmax) {
          argmax = e.value;
          argmaxKey = e.key;
        }
        final isChild = k == 0 || e.key.startsWith('$parentKey|');
        if (isChild && e.value > best) {
          best = e.value;
          bestKey = e.key;
        }
      }
      if (bestKey == null) break;
      final conflict = argmaxKey != bestKey;
      if (conflict) path.conflict = true;
      path.keys.add(bestKey);
      path.mass.add(best);
      path.rivalKey.add(conflict ? argmaxKey : null);
      path.rivalMass.add(conflict ? argmax : 0);
      parentKey = bestKey;
    }
    return path;
  }

  static String _speciesDisplay(String key) {
    final parts = key.split('|');
    if (parts.length < 7) return parts.last;
    if (parts[0] == kSinkKingdom) return parts.last;
    return '${parts[5]} ${parts[6]}'.trim();
  }
}
