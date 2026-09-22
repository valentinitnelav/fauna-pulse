// Tests for the per-track-id pooling math (round 208, rule changed round
// 217): softmax scoring, certainty weights, the ladder, support, tau, sink
// mass, path conflicts, and the identity between the reported mass and the
// crops' own masses.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/identification/track_fusion.dart';

/// A synthetic pack: 4 species + 1 sink row in a 5-D space where every row
/// is one axis (the sink row is its own axis, e4), so a crop "at" an axis is
/// unambiguous.
LabelPack tinyPack({double logitScale = 100}) {
  final labels = [
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Eristalis', 'tenax'], 'Drone fly'),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Diptera', 'Syrphidae', 'Episyrphus', 'balteatus'], ''),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Apis', 'mellifera'], 'Honey bee'),
    const LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'terrestris'], ''),
    const LabelRow(['none', '', '', '', '', '', 'flower'], 'a photo of a flower.'),
  ];
  const dim = 5;
  final m = Float32List(5 * dim);
  for (var r = 0; r < 5; r++) {
    m[r * dim + r] = 1;
  }
  return LabelPack(
    packId: 't',
    modelId: 'm',
    dim: dim,
    rows: 5,
    sinkRows: 1,
    logitScale: logitScale,
    temperature: 1.0,
    labels: labels,
    matrix: m,
    header: const {},
  );
}

Float32List unit(List<double> v) {
  final n = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
  return Float32List.fromList([for (final x in v) x / n]);
}

CropEmbedding crop(List<double> v, {int? track = 1, String jpeg = 'a.jpg'}) =>
    CropEmbedding(jpeg: jpeg, trackId: track, vector: unit(v));

void main() {
  group('Scorer', () {
    test('softmax puts the mass on the matching axis and topK sorts', () {
      final s = Scorer(tinyPack());
      final p = s.probs(unit([1, 0, 0, 0, 0]));
      expect(p[0], greaterThan(0.99));
      final top = s.topK(p, 3);
      expect(top.rows.first, 0);
      expect(top.probs.first, p[0]);
      expect(top.rows.length, 3);
      expect(top.probs[0] >= top.probs[1] && top.probs[1] >= top.probs[2], isTrue);
    });

    test('rollUp sums species under family and order', () {
      final s = Scorer(tinyPack(logitScale: 10));
      final p = s.probs(unit([1, 1, 0, 0, 0])); // between the two Syrphidae
      final m = s.rollUp(p);
      final fam = m[4]['Animalia|Arthropoda|Insecta|Diptera|Syrphidae']!;
      expect(fam, closeTo(p[0] + p[1], 1e-6));
      expect(m[3]['Animalia|Arthropoda|Insecta|Diptera'], closeTo(fam, 1e-6));
      expect(m[0]['none'], closeTo(p[4], 1e-6));
    });
  });

  group('fuse', () {
    test('two views of one hoverfly: family confident, species undecided', () {
      final s = Scorer(tinyPack(logitScale: 20));
      // One crop looks like Eristalis, the other like Episyrphus (same family).
      final f = s.fuse([crop([1, 0.2, 0, 0, 0]), crop([0.2, 1, 0, 0, 0], jpeg: 'b.jpg')], tau: 0.8);
      expect(f.nCrops, 2);
      expect(f.stepAt('order')!.taxon, 'Diptera');
      expect(f.stepAt('family')!.taxon, 'Syrphidae');
      expect(f.stepAt('family')!.mass, greaterThan(0.9));
      expect(f.stepAt('species')!.mass, lessThan(0.8));
      expect(f.identifiedRank, 'family');
      expect(f.headline, 'Syrphidae');
      expect(f.stepAt('family')!.support, 1.0); // both crops' top-1 are Syrphidae
      expect(f.noneMass, lessThan(0.1));
      expect(f.pathConflict, isFalse);
    });

    test('a sure crop outweighs an unsure one; tau 0.6 is the default (round 217)', () {
      final s = Scorer(tinyPack(logitScale: 20));
      final sureBee = crop([0, 0, 1, 0, 0]); // top-1 ~ 1.0
      final unsureFly = crop([1, 1, 0, 0, 0], jpeg: 'b.jpg'); // split between two Syrphidae: top-1 ~ 0.5
      final f = s.fuse([sureBee, unsureFly]);
      expect(f.perCrop[0].probs.first, greaterThan(0.99));
      expect(f.perCrop[1].probs.first, closeTo(0.5, 0.02));
      expect(f.stepAt('order')!.taxon, 'Hymenoptera');
      // (1.0 * 1 + 0.5 * 0) / 1.5
      expect(f.stepAt('order')!.mass, closeTo(2 / 3, 0.02));
      expect(f.stepAt('order')!.support, 0.5);
      expect(f.identifiedRank, 'species'); // 0.667 >= 0.6
      expect(s.fuse([sureBee, unsureFly], tau: 0.8).identifiedRank, 'class');
      expect(f.bestViewIndex, 0);
      expect(f.bestViewTaxon, 'Apis mellifera');
      expect(f.bestViewProb, greaterThan(0.99));
    });

    test('a flower crop lands on the sink row', () {
      final s = Scorer(tinyPack(logitScale: 30));
      final f = s.fuse([crop([0, 0, 0, 0, 1])], tau: 0.8);
      expect(f.ladder.first.key, 'none');
      expect(f.noneMass, greaterThan(0.9));
      expect(f.identifiedRank, isNull);
      expect(f.headline, 'no organism');
    });

    test('unsure crop gives an unidentified track with mass spread', () {
      final s = Scorer(tinyPack(logitScale: 1)); // flat softmax
      final f = s.fuse([crop([1, 0, 0, 0, 0])], tau: 0.8);
      // Animalia keeps ~0.85 (all four species), Diptera only ~0.55.
      expect(f.identifiedRank, 'class');
      expect(f.headline, 'Insecta');
      expect(f.stepAt('order')!.mass, lessThan(0.8));
      expect(f.stepAt('order')!.taxon, 'Diptera');
    });

    List<CropEmbedding> threeCrops() => [
      crop([1, 0, 0.6, 0.6, 0]),
      crop([0, 0, 1, 0, 0], jpeg: 'b.jpg'),
      crop([0, 0, 0, 1, 0], jpeg: 'c.jpg'),
    ];

    test('ladder masses never increase down the path', () {
      final f = Scorer(tinyPack(logitScale: 8)).fuse(threeCrops(), tau: 0.8);
      for (var i = 1; i < f.ladder.length; i++) {
        expect(f.ladder[i].mass, lessThanOrEqualTo(f.ladder[i - 1].mass + 1e-6));
      }
      expect(f.ladder.map((e) => e.rank).toList(), kRankNames);
    });

    test('mass is the top-1-weighted mean of the crops\' own masses; p_mean and p_max (round 217)', () {
      final f = Scorer(tinyPack(logitScale: 8)).fuse(threeCrops(), tau: 0.8);
      final w = [for (final t in f.perCrop) t.probs.first];
      final wsum = w.reduce((a, b) => a + b);
      for (var k = 0; k < f.ladder.length; k++) {
        var weighted = 0.0, plain = 0.0, mx = 0.0;
        for (var i = 0; i < 3; i++) {
          final m = f.perCropMass[i][k];
          weighted += w[i] * m;
          plain += m;
          if (m > mx) mx = m;
        }
        expect(f.ladder[k].mass, closeTo(weighted / wsum, 1e-5));
        expect(f.ladder[k].meanMass, closeTo(plain / 3, 1e-6));
        expect(f.ladder[k].maxMass, closeTo(mx, 1e-6));
        expect(f.ladder[k].mass, lessThanOrEqualTo(f.ladder[k].maxMass + 1e-6));
      }
      expect(f.ladder.first.toJson().keys, containsAll(['rank', 'taxon', 'p', 'p_mean', 'p_max', 'support']));
    });
  });
}
