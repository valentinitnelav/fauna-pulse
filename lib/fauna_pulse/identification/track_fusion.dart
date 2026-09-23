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
//     FaunaPulse additions, not yet tested on pollinator data.
//   * a consistent top-down "ladder" (best child of the chosen parent) with,
//     per rank, the pooled mass, the plain mean / maximum / agreeing-crops
//     mean of the crops' own masses, and "support" (share of crops whose own
//     top-1 agrees)
//   * "identified rank" = deepest ladder rank with mass >= tau (default 0.6)
//   * sink rows (kingdom `none`) collect the "no organism" mass
//   * the unit-length pooled embedding is kept solely for the visit-merge
//     similarity check (visit_merge.dart)

import 'dart:math' as math;
import 'dart:typed_data';

import 'label_pack.dart';

/// One embedded crop of a track id, as the pooling sees it.
class CropEmbedding {
  final String jpeg;
  final int? trackId;
  final Float32List vector;

  const CropEmbedding({required this.jpeg, required this.trackId, required this.vector});
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

  const LadderStep({
    required this.rank,
    required this.taxon,
    required this.key,
    required this.mass,
    required this.support,
    required this.meanMass,
    required this.maxMass,
    required this.agreeMass,
  });

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'taxon': taxon,
    'p': double.parse(mass.toStringAsFixed(4)),
    'p_mean': double.parse(meanMass.toStringAsFixed(4)),
    'p_max': double.parse(maxMass.toStringAsFixed(4)),
    'p_agree': double.parse(agreeMass.toStringAsFixed(4)),
    'support': double.parse(support.toStringAsFixed(3)),
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

  /// Per-crop top-k rows; `perCrop[i].probs.first` is crop i's weight.
  final List<TopK> perCrop;

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
    required this.perCropMass,
    required this.counted,
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

class Scorer {
  final LabelPack pack;

  /// Effective softmax scale: logit_scale / temperature (plan 11.4).
  final double scale;

  Scorer(this.pack, {double? temperature})
    : scale = pack.logitScale / (temperature ?? pack.temperature);

  // Round 215: an integer id per row and rank for the row's taxonomy key,
  // built once per pack, so the mass of a distribution under a ladder taxon
  // is one integer comparison per row (rollUp joins strings per row and is
  // far too slow to run per crop).
  List<Int32List>? _rankIds;
  List<Map<String, int>>? _keyToId;

  void _buildRankIds() {
    final ids = List.generate(7, (_) => Int32List(pack.rows));
    final maps = List.generate(7, (_) => <String, int>{});
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
        ids[k][r] = maps[k].putIfAbsent(key, () => maps[k].length);
      }
    }
    _rankIds = ids;
    _keyToId = maps;
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

  /// Softmax over all pack rows for unit vector [e].
  Float32List probs(Float32List e) {
    final n = pack.rows;
    final logits = Float64List(n);
    var maxL = -double.infinity;
    for (var r = 0; r < n; r++) {
      final l = scale * pack.dot(e, r);
      logits[r] = l;
      if (l > maxL) maxL = l;
    }
    var sum = 0.0;
    for (var r = 0; r < n; r++) {
      final v = math.exp(logits[r] - maxL);
      logits[r] = v;
      sum += v;
    }
    final out = Float32List(n);
    for (var r = 0; r < n; r++) {
      out[r] = logits[r] / sum;
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
  List<Map<String, double>> rollUp(Float32List p) {
    final out = List.generate(7, (_) => <String, double>{});
    for (var r = 0; r < pack.rows; r++) {
      final v = p[r];
      if (v <= 0) continue;
      final row = pack.labels[r];
      for (var k = 0; k < 7; k++) {
        if (row.ranks[k].isEmpty) break; // unknown below this rank
        final key = row.keyAt(k);
        out[k][key] = (out[k][key] ?? 0) + v;
      }
    }
    return out;
  }

  /// Pools a track id's crops (round 219 rule, see the file header). [tau] =
  /// mass needed to count as identified; [dropFactor] = crops whose certainty
  /// is below the surest crop's divided by this are left out (<= 1: none).
  FusedTrack fuse(List<CropEmbedding> crops, {double tau = 0.6, double dropFactor = 10, int topK = 5}) {
    assert(crops.isNotEmpty);
    final dim = pack.dim;
    final n = crops.length;

    // Every crop scored on its own.
    final perCropProbs = [for (final c in crops) probs(c.vector)];
    final perCropTop = [for (final p in perCropProbs) this.topK(p, topK)];

    // Certainty weight = the crop's top-1 probability (always > 0); crops far
    // less certain than the surest one are left out.
    final weights = [for (final t in perCropTop) t.probs.first];
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
    for (var i = 0; i < n; i++) {
      if (!counted[i]) continue;
      final w = weights[i] / wsum;
      final v = crops[i].vector;
      for (var d = 0; d < dim; d++) {
        pooled[d] += (w * v[d]).toDouble();
      }
    }
    final pbar = probs(pooled);
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

    // Consistent top-down path.
    final keys = <String>[];
    final taxa = <String>[];
    final massAt = <double>[];
    final agreeAt = <List<bool>>[];
    var parentKey = '';
    var pathConflict = false;
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
      if (argmaxKey != bestKey) pathConflict = true;
      final name = bestKey.split('|').last;
      final agree = <bool>[];
      for (final t in perCropTop) {
        final top1 = pack.labels[t.rows.first];
        agree.add(top1.ranks[k].isNotEmpty && top1.keyAt(k) == bestKey);
      }
      keys.add(bestKey);
      taxa.add(k == 6 ? _speciesDisplay(bestKey) : name);
      massAt.add(best);
      agreeAt.add(agree);
      parentKey = bestKey;
    }

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
        if (agreeAt[k][i]) {
          agreeSum += m;
          agreeN++;
        }
      }
      ladder.add(
        LadderStep(
          rank: kRankNames[k],
          taxon: taxa[k],
          key: keys[k],
          mass: massAt[k],
          support: agreeN / n,
          meanMass: sum / n,
          maxMass: mx,
          agreeMass: agreeN == 0 ? 0 : agreeSum / agreeN,
        ),
      );
    }

    final noneMass = masses[0][kSinkKingdom] ?? 0.0;
    String? identified;
    if (ladder.isNotEmpty && ladder.first.key != kSinkKingdom) {
      for (final s in ladder) {
        if (s.mass >= tau) {
          identified = s.rank;
        } else {
          break;
        }
      }
    }

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
      noneMass: noneMass,
      pathConflict: pathConflict,
      bestViewIndex: bestIdx,
      bestViewTaxon: bestTaxon,
      bestViewProb: math.max(0, bestProb),
      fusedEmbedding: fused,
      perCrop: perCropTop,
      perCropMass: perCropMass,
      counted: counted,
    );
  }

  static String _speciesDisplay(String key) {
    final parts = key.split('|');
    if (parts.length < 7) return parts.last;
    if (parts[0] == kSinkKingdom) return parts.last;
    return '${parts[5]} ${parts[6]}'.trim();
  }
}
