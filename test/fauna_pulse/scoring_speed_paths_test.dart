// Round 348 (perf review H4b): the faster scoring paths give the answers of the plain ones:
// the four-lane dot product against the scalar loop, the pooled logits against the pooled
// vector, and the roll-up on rank ids against the string keys.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/track_fusion.dart';

Float32List _unit(math.Random rnd, int dim, {Float32List? near, double noise = 1}) {
  final v = Float32List(dim);
  var n = 0.0;
  for (var d = 0; d < dim; d++) {
    v[d] = (near == null ? 0 : near[d]) + noise * (rnd.nextDouble() * 2 - 1);
    n += v[d] * v[d];
  }
  n = math.sqrt(n);
  for (var d = 0; d < dim; d++) {
    v[d] /= n;
  }
  return v;
}

/// Random unit rows in a 7-rank taxonomy (3 species per genus, 3 genera per family, ...),
/// the last row a sink row, every other row cut at genus (no species name).
LabelPack _randomPack(math.Random rnd, {int rows = 120, int dim = 768}) {
  final m = Float32List(rows * dim);
  final labels = <LabelRow>[];
  for (var r = 0; r < rows; r++) {
    m.setRange(r * dim, (r + 1) * dim, _unit(rnd, dim));
    if (r == rows - 1) {
      labels.add(const LabelRow(['none', '', '', '', '', '', 'flower'], ''));
    } else {
      final g = 'Genus${r ~/ 3}';
      labels.add(LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Order${r ~/ 27}', 'Family${r ~/ 9}', g, r % 7 == 0 ? '' : '$g sp$r'], ''));
    }
  }
  return LabelPack(packId: 't', modelId: 'm', dim: dim, rows: rows, sinkRows: 1, logitScale: 100, temperature: 1, labels: labels, matrix: m, header: const {});
}

void main() {
  final rnd = math.Random(7);

  test('dotsInto matches the scalar dot within 1e-5 on aligned 768-dim vectors', () {
    final pack = _randomPack(rnd);
    final e = _unit(rnd, pack.dim);
    final out = Float64List(pack.rows);
    pack.dotsInto(e, out);
    for (var r = 0; r < pack.rows; r++) {
      expect(out[r], closeTo(pack.dot(e, r), 1e-5));
    }
    // A query that is not 16-byte aligned takes the scalar path and agrees exactly.
    final longer = Float32List(pack.dim + 1)..setRange(1, pack.dim + 1, e);
    pack.dotsInto(Float32List.sublistView(longer, 1), out);
    for (var r = 0; r < pack.rows; r++) {
      expect(out[r], pack.dot(e, r));
    }
  });

  test('a dim that is not a multiple of 4 takes the scalar path', () {
    final pack = _randomPack(rnd, rows: 20, dim: 5);
    final e = _unit(rnd, 5);
    final out = Float64List(pack.rows);
    pack.dotsInto(e, out);
    for (var r = 0; r < pack.rows; r++) {
      expect(out[r], pack.dot(e, r));
    }
  });

  test('the pooled logits give the pooled vector\'s probabilities and ladder (the rule before round 348)', () {
    final pack = _randomPack(rnd);
    final s = Scorer(pack);
    final target = Float32List.sublistView(pack.matrix, 11 * pack.dim, 12 * pack.dim);
    final crops = [for (var i = 0; i < 4; i++) CropEmbedding(jpeg: 'c$i.jpg', trackId: 1, vector: _unit(rnd, pack.dim, near: target, noise: 0.03 * (i + 1)))];
    final f = s.fuse(crops, dropFactor: 1);
    // Reference: the certainty-weighted pooled vector, scored directly.
    final perCrop = [for (final c in crops) s.probs(c.vector)];
    final weights = [for (final p in perCrop) s.topK(p, 1).probs.first];
    final wsum = weights.fold<double>(0, (a, b) => a + b);
    final pooled = Float32List(pack.dim);
    for (var i = 0; i < crops.length; i++) {
      for (var d = 0; d < pack.dim; d++) {
        pooled[d] += (weights[i] / wsum * crops[i].vector[d]).toDouble();
      }
    }
    final ref = s.probs(pooled);
    final rolled = s.rollUp(ref);
    expect(f.ladder, isNotEmpty);
    for (var k = 0; k < f.ladder.length; k++) {
      expect(f.ladder[k].mass, closeTo(rolled[k][f.ladder[k].key]!, 1e-6), reason: f.ladder[k].key);
    }
    expect(f.pooledTop.rows.first, s.topK(ref, 1).rows.first);
    expect(f.pooledTop.probs.first, closeTo(ref[f.pooledTop.rows.first], 1e-6));
    expect(f.ladder.last.key, pack.labels[11].keyAt(6));
  });

  test('rollUp on rank ids equals the string-key version: same keys, order and sums', () {
    final pack = _randomPack(rnd, rows: 60, dim: 8);
    final s = Scorer(pack);
    final p = s.probs(_unit(rnd, 8));
    p[5] = 0; // a row without mass is left out
    final reference = List.generate(7, (_) => <String, double>{});
    for (var r = 0; r < pack.rows; r++) {
      final v = p[r];
      if (v <= 0) continue;
      final row = pack.labels[r];
      for (var k = 0; k < 7; k++) {
        if (row.ranks[k].isEmpty) break;
        final key = row.keyAt(k);
        reference[k][key] = (reference[k][key] ?? 0) + v;
      }
    }
    final got = s.rollUp(p);
    for (var k = 0; k < 7; k++) {
      expect(got[k].keys.toList(), reference[k].keys.toList(), reason: 'rank $k');
      expect(got[k].values.toList(), reference[k].values.toList(), reason: 'rank $k');
    }
    expect(got[6].containsKey(pack.labels[5].keyAt(6)), isFalse);
    expect(got[0]['none'], closeTo(p[59], 1e-9));
  });
}
