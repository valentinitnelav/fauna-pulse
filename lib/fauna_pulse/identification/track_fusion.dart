// FaunaPulse (round 208): scoring one crop and fusing a track's crops.
//
// Pure Dart, no I/O, unit-tested. The math follows plan section 11.3:
//   * per crop: softmax over the pack of (logit_scale / T) * cosine similarity
//     (as pybioclip's predict, Imageomics)
//   * per track: quality-weighted MEAN EMBEDDING (re-normalised), scored once,
//     rolled up through the taxonomy (mass of a family = sum of its species,
//     as pybioclip's format_grouped_probs)
//   * a consistent top-down "ladder" (best child of the chosen parent) with
//     per-rank mass and "support" (share of crops whose own top-1 agrees)
//   * cross-check: weighted mean of the per-crop probabilities; a different
//     winner at the user's rank is flagged, never hidden
//   * "identified rank" = deepest ladder rank with mass >= tau
//   * sink rows (kingdom `none`) collect the "no organism" mass

import 'dart:math' as math;
import 'dart:typed_data';

import 'label_pack.dart';

/// Quality weight of one crop in the track average (plan 11.3), clipped to
/// [0.05, 1] so a fully blurred track still gets an answer. [sharpness] is
/// relative to the sharpest crop of the same track ([maxSharpness]).
double qualityWeight({
  required int cropPx,
  required double sharpness,
  required double maxSharpness,
  required double detConf,
  required double padFrac,
}) {
  final size = math.min(1.0, cropPx / 160.0);
  final sharp = maxSharpness > 0
      ? math.max(0.2, sharpness / maxSharpness)
      : 1.0;
  final conf = detConf.isNaN ? 1.0 : detConf.clamp(0.0, 1.0);
  final w = size * sharp * conf * (1 - padFrac.clamp(0.0, 1.0));
  return w.clamp(0.05, 1.0);
}

/// One embedded crop of a track, as the fusion sees it.
class CropEmbedding {
  final String jpeg;
  final int? trackId;
  final Float32List vector;
  final int cropPx;
  final double sharpness;
  final double detConf;
  final double padFrac;

  const CropEmbedding({
    required this.jpeg,
    required this.trackId,
    required this.vector,
    required this.cropPx,
    required this.sharpness,
    required this.detConf,
    required this.padFrac,
  });
}

/// Top-k rows of one probability vector.
class TopK {
  final List<int> rows;
  final List<double> probs;
  const TopK(this.rows, this.probs);
}

/// One rung of a track's ladder.
class LadderStep {
  final String rank;
  final String taxon;
  final String key;
  final double mass;

  /// Share of the track's crops whose own top-1 falls under this taxon.
  final double support;

  const LadderStep({
    required this.rank,
    required this.taxon,
    required this.key,
    required this.mass,
    required this.support,
  });

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'taxon': taxon,
    'p': double.parse(mass.toStringAsFixed(4)),
    'support': double.parse(support.toStringAsFixed(3)),
  };
}

class FusedTrack {
  final int? trackId;
  final int nCrops;
  final List<double> weights;
  final List<LadderStep> ladder;

  /// Deepest rank with mass >= tau, or null when even the kingdom is unsure
  /// or the sink rows win.
  final String? identifiedRank;
  final double noneMass;
  final bool pathConflict;
  final bool ruleConflict;

  /// The crop whose single view is most confident (index into the input list),
  /// with the species it suggests and that probability.
  final int bestViewIndex;
  final String bestViewTaxon;
  final double bestViewProb;
  final Float32List fusedEmbedding;

  /// Per-crop top-1 row (for the per-crop records).
  final List<TopK> perCrop;

  const FusedTrack({
    required this.trackId,
    required this.nCrops,
    required this.weights,
    required this.ladder,
    required this.identifiedRank,
    required this.noneMass,
    required this.pathConflict,
    required this.ruleConflict,
    required this.bestViewIndex,
    required this.bestViewTaxon,
    required this.bestViewProb,
    required this.fusedEmbedding,
    required this.perCrop,
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

  /// Fuses a track's crops. [tau] = mass needed to count as identified;
  /// [userRank] = rank at which the rule cross-check is evaluated.
  FusedTrack fuse(
    List<CropEmbedding> crops, {
    double tau = 0.8,
    String userRank = 'family',
    int topK = 5,
  }) {
    assert(crops.isNotEmpty);
    final dim = pack.dim;
    var maxSharp = 0.0;
    for (final c in crops) {
      if (c.sharpness > maxSharp) maxSharp = c.sharpness;
    }
    final weights = [
      for (final c in crops)
        qualityWeight(
          cropPx: c.cropPx,
          sharpness: c.sharpness,
          maxSharpness: maxSharp,
          detConf: c.detConf,
          padFrac: c.padFrac,
        ),
    ];

    // Weighted mean embedding, re-normalised.
    final fused = Float32List(dim);
    var wsum = 0.0;
    for (var i = 0; i < crops.length; i++) {
      final w = weights[i];
      wsum += w;
      final v = crops[i].vector;
      for (var d = 0; d < dim; d++) {
        fused[d] += (w * v[d]).toDouble();
      }
    }
    var norm = 0.0;
    for (var d = 0; d < dim; d++) {
      fused[d] /= wsum;
      norm += fused[d] * fused[d];
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (var d = 0; d < dim; d++) {
        fused[d] /= norm;
      }
    }

    // Per-crop probabilities (for support, cross-check and best view).
    final perCropProbs = [for (final c in crops) probs(c.vector)];
    final perCropTop = [for (final p in perCropProbs) this.topK(p, topK)];
    final pbar = Float32List(pack.rows);
    for (var i = 0; i < crops.length; i++) {
      final w = weights[i] / wsum;
      final p = perCropProbs[i];
      for (var r = 0; r < pack.rows; r++) {
        pbar[r] += w * p[r];
      }
    }

    final pFused = probs(fused);
    final masses = rollUp(pFused);
    final massesBar = rollUp(pbar);

    // Consistent top-down path.
    final ladder = <LadderStep>[];
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
      final taxon = k == 6 ? _speciesDisplay(bestKey) : name;
      var agree = 0;
      for (final t in perCropTop) {
        final top1 = pack.labels[t.rows.first];
        if (top1.ranks[k].isNotEmpty && top1.keyAt(k) == bestKey) agree++;
      }
      ladder.add(
        LadderStep(
          rank: kRankNames[k],
          taxon: taxon,
          key: bestKey,
          mass: best,
          support: agree / crops.length,
        ),
      );
      parentKey = bestKey;
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

    // Cross-check at the user's rank.
    final userIdx = kRankNames.indexOf(userRank).clamp(0, 6);
    var ruleConflict = false;
    final ownStep = userIdx < ladder.length ? ladder[userIdx] : null;
    if (ownStep != null) {
      String? barKey;
      var barBest = -1.0;
      for (final e in massesBar[userIdx].entries) {
        if (e.value > barBest) {
          barBest = e.value;
          barKey = e.key;
        }
      }
      ruleConflict = barKey != null && barKey != ownStep.key;
    }

    // Best single view among decent-quality crops (species rows only).
    var bestIdx = 0;
    var bestProb = -1.0;
    var bestTaxon = '';
    final wThreshold = weights.any((w) => w >= 0.5) ? 0.5 : 0.0;
    for (var i = 0; i < crops.length; i++) {
      if (weights[i] < wThreshold) continue;
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
      nCrops: crops.length,
      weights: weights,
      ladder: ladder,
      identifiedRank: identified,
      noneMass: noneMass,
      pathConflict: pathConflict,
      ruleConflict: ruleConflict,
      bestViewIndex: bestIdx,
      bestViewTaxon: bestTaxon,
      bestViewProb: math.max(0, bestProb),
      fusedEmbedding: fused,
      perCrop: perCropTop,
    );
  }

  static String _speciesDisplay(String key) {
    final parts = key.split('|');
    if (parts.length < 7) return parts.last;
    if (parts[0] == kSinkKingdom) return parts.last;
    return '${parts[5]} ${parts[6]}'.trim();
  }
}
