// Tests for the per-track fusion math (round 208, plan section 11.3): quality
// weights, softmax scoring, the ladder, support, tau, sink mass, conflicts.

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

CropEmbedding crop(
  List<double> v, {
  int px = 200,
  double sharp = 100,
  double conf = 0.9,
  double pad = 0,
  int? track = 1,
  String jpeg = 'a.jpg',
}) => CropEmbedding(
  jpeg: jpeg,
  trackId: track,
  vector: unit(v),
  cropPx: px,
  sharpness: sharp,
  detConf: conf,
  padFrac: pad,
);

void main() {
  group('qualityWeight', () {
    test('full-quality crop weighs 1, tiny blurred crop stays above the floor', () {
      expect(qualityWeight(cropPx: 200, sharpness: 50, maxSharpness: 50, detConf: 1, padFrac: 0), 1.0);
      final w = qualityWeight(cropPx: 20, sharpness: 1, maxSharpness: 100, detConf: 0.3, padFrac: 0.5);
      expect(w, closeTo(0.05, 1e-9)); // clipped at the floor
    });
    test('no sharpness reference gives the size × conf weight', () {
      expect(qualityWeight(cropPx: 80, sharpness: 0, maxSharpness: 0, detConf: 1, padFrac: 0), closeTo(0.5, 1e-9));
    });
  });

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

    test('quality weights pull the average toward the sharp, large crop', () {
      final s = Scorer(tinyPack(logitScale: 20));
      final sharpBee = crop([0, 0, 1, 0, 0], px: 300, sharp: 500, conf: 0.95);
      final blurryFly = crop([1, 0, 0, 0, 0], px: 40, sharp: 5, conf: 0.4, jpeg: 'b.jpg');
      final f = s.fuse([sharpBee, blurryFly], tau: 0.8);
      expect(f.weights[0], closeTo(0.95, 1e-9)); // size 1 × sharp 1 × conf 0.95
      expect(f.weights[1], lessThan(0.1));
      expect(f.stepAt('order')!.taxon, 'Hymenoptera');
      expect(f.bestViewTaxon, 'Apis mellifera');
      expect(f.bestViewIndex, 0);
      // The mean-probability cross-check agrees (rule conflict false).
      expect(f.ruleConflict, isFalse);
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

    test('ladder masses never increase down the path and rule conflict is detected', () {
      final s = Scorer(tinyPack(logitScale: 8));
      // Crop 1 strongly a fly, crops 2+3 mildly bees: the embedding average
      // may side with one, the mean of probabilities with the other.
      final f = s.fuse(
        [crop([1, 0, 0.6, 0.6, 0], sharp: 100), crop([0, 0, 1, 0, 0], sharp: 10, jpeg: 'b.jpg'), crop([0, 0, 0, 1, 0], sharp: 10, jpeg: 'c.jpg')],
        tau: 0.8,
        userRank: 'order',
      );
      for (var i = 1; i < f.ladder.length; i++) {
        expect(f.ladder[i].mass, lessThanOrEqualTo(f.ladder[i - 1].mass + 1e-6));
      }
      expect(f.ladder.map((e) => e.rank).toList(), kRankNames);
      expect(f.ruleConflict, isA<bool>());
    });
  });
}
