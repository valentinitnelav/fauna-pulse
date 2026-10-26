// Tests for the per-track-id pooling math (round 208, rule changed round
// 217): softmax scoring, certainty weights, the ladder, support, tau, sink
// mass, path conflicts, and the identity between the reported mass and the
// crops' own masses. Round 322: the name rules of the v2 label packs need no
// code change (rows cut to genus or family count only above the cut).

import 'dart:convert';
import 'dart:io';
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

  group('class list (round 266)', () {
    final file = File('test/fauna_pulse/fixtures/tiny_classes.fpack');
    final pack = LabelPack.parseBytes(file.readAsBytesSync());

    test('scores match Python (fpack.py class_probabilities) on the fixture', () {
      final s = Scorer(pack);
      final scores = (pack.header['test_scores'] as List).cast<List>();
      final expected = (pack.header['test_probs'] as List).cast<List>();
      for (var i = 0; i < scores.length; i++) {
        final p = s.probs(Float32List.fromList([for (final v in scores[i]) (v as num).toDouble()]));
        for (var r = 0; r < pack.rows; r++) {
          expect(p[r], closeTo((expected[i][r] as num).toDouble(), 2e-6));
        }
      }
    });

    // Levels: [Diptera, Hymenoptera, Vegetation] + [Syrphidae, Eristalis tenax, Apis mellifera, Vegetation].
    CropEmbedding raw(List<double> v, {String jpeg = 'a.jpg'}) =>
        CropEmbedding(jpeg: jpeg, trackId: 1, vector: Float32List.fromList(v));

    test('a sure species; a family-level class stops the ladder at its family', () {
      final s = Scorer(pack);
      final eristalis = s.fuse([raw([6, -3, -3, 0, 6, -3, -3])]);
      expect(eristalis.identifiedRank, 'species');
      expect(eristalis.headline, 'Eristalis tenax');
      expect(pack.classNames[eristalis.pooledTop.rows.first], 'Eristalis tenax');
      final syrphid = s.fuse([raw([6, -3, -3, 6, 0, -3, -3])]);
      expect(syrphid.identifiedRank, 'family');
      expect(syrphid.headline, 'Syrphidae');
      expect(syrphid.stepAt('family')!.mass, greaterThan(0.99)); // both classes are Syrphidae
      expect(syrphid.bestViewTaxon, 'Syrphidae');
    });

    test('levels that disagree lower the answer; vegetation is no organism', () {
      final s = Scorer(pack);
      // Level 2 says Eristalis, level 1 says Hymenoptera: neither species is likely.
      final torn = s.fuse([raw([-3, 6, -3, 0, 6, -3, -3])]);
      expect(torn.stepAt('species')?.mass ?? 0, lessThan(0.6));
      final plant = s.fuse([raw([-3, -3, 6, -3, -3, -3, 6])]);
      expect(plant.headline, 'no organism');
    });

    test('the crops of a track ID are pooled by averaging their raw scores', () {
      final s = Scorer(pack);
      final a = raw([6, -3, -3, 0, 6, -3, -3]), b = raw([6, -3, -3, 6, 0, -3, -3], jpeg: 'b.jpg');
      final f = s.fuse([a, b], dropFactor: 1);
      final mean = Float32List.fromList([for (var i = 0; i < 7; i++) (a.vector[i] + b.vector[i]) / 2]);
      // Equal certainty weights, so the pooled answer is the mean vector's.
      expect(f.stepAt('family')!.mass, closeTo(s.fuse([raw(mean)]).stepAt('family')!.mass, 1e-6));
      expect(f.headline, 'Syrphidae');
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

    test('a sure crop dominates; a far less sure one is left out (rounds 217/219)', () {
      final s = Scorer(tinyPack(logitScale: 20));
      final sureBee = crop([0, 0, 1, 0, 0]); // top-1 ~ 1.0
      final unsureFly = crop([1, 1, 0, 0, 0], jpeg: 'b.jpg'); // split between two Syrphidae: top-1 ~ 0.5
      final f = s.fuse([sureBee, unsureFly]);
      expect(f.perCrop[0].probs.first, greaterThan(0.99));
      expect(f.perCrop[1].probs.first, closeTo(0.5, 0.02));
      // 0.5 >= 1.0 / 10: both crops count; the average description sits
      // nearer the bee (weight 1.0 vs 0.5) and the pooled answer follows it.
      expect(f.counted, [true, true]);
      expect(f.stepAt('order')!.taxon, 'Hymenoptera');
      expect(f.stepAt('order')!.mass, greaterThan(0.5));
      expect(f.stepAt('order')!.support, 0.5);
      expect(f.bestViewIndex, 0);
      expect(f.bestViewTaxon, 'Apis mellifera');
      expect(f.bestViewProb, greaterThan(0.99));
      // With a factor of 1.5 the fly (0.5 < 1.0 / 1.5) is left out and the
      // answer is the bee's own.
      final g = s.fuse([sureBee, unsureFly], dropFactor: 1.5);
      expect(g.counted, [true, false]);
      expect(g.stepAt('species')!.mass, closeTo(s.fuse([sureBee]).stepAt('species')!.mass, 1e-6));
      expect(g.identifiedRank, 'species'); // >= 0.6 default tau
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

    test('agreeing crops reinforce each other: pooled mass above the plain mean (round 219)', () {
      final s = Scorer(tinyPack(logitScale: 12));
      // Three views that all lean to Apis but are individually unsure.
      final f = s.fuse([crop([0.3, 0, 1, 0.3, 0]), crop([0, 0.3, 1, 0.3, 0], jpeg: 'b.jpg'), crop([0.2, 0.2, 1, 0.2, 0], jpeg: 'c.jpg')]);
      final sp = f.stepAt('species')!;
      expect(sp.taxon, 'Apis mellifera');
      expect(sp.mass, greaterThan(sp.meanMass));
      expect(sp.support, 1.0);
      expect(sp.agreeMass, closeTo(sp.meanMass, 1e-9)); // every crop agrees
    });

    test('a clueless crop is left out by the drop rule; with factor 1 it dilutes', () {
      final s = Scorer(tinyPack(logitScale: 20));
      final sure = crop([0, 0, 1, 0, 0]);
      // Equal similarity to every row: top-1 = 1/5 = 0.2 in this 5-row pack
      // (near 0 in a 38 000-name pack, where the default factor 10 drops it);
      // here a factor of 3 (0.2 < 1.0 / 3) is needed to leave it out.
      final flat = crop([1, 1, 1, 1, 1], jpeg: 'b.jpg');
      final alone = s.fuse([sure]);
      final withFlat = s.fuse([sure, flat], dropFactor: 3);
      expect(withFlat.counted, [true, false]);
      expect(withFlat.stepAt('species')!.mass, closeTo(alone.stepAt('species')!.mass, 1e-6));
      final all = s.fuse([sure, flat], dropFactor: 1);
      expect(all.counted, [true, true]);
      expect(all.stepAt('species')!.mass, lessThan(alone.stepAt('species')!.mass));
    });

    test('path conflict: the rank\'s overall winner outside the path is kept as the rival (round 221)', () {
      final s = Scorer(tinyPack(logitScale: 20));
      // Diptera's mass is split over two genera, Hymenoptera's sits in one:
      // Diptera wins the order, Apis (Hymenoptera) the genus rank.
      final f = s.fuse([crop([1, 1, 1.03, 0, 0])], tau: 0.55);
      expect(f.stepAt('order')!.taxon, 'Diptera');
      expect(f.identifiedRank, 'family');
      expect(f.pathConflict, isTrue);
      expect(f.stepAt('family')!.rival, isNull);
      final g = f.stepAt('genus')!;
      expect(g.taxon, isNot('Apis'));
      expect(g.rival, 'Apis');
      expect(g.rivalMass, greaterThan(g.mass));
      expect(g.rivalLineage, ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae']);
      expect(f.stepAt('species')!.rival, 'Apis mellifera');
      expect(g.toJson()['rival'], 'Apis');
      expect(f.stepAt('family')!.toJson().containsKey('rival'), isFalse);
    });

    test('per-rank alternatives and JSON keys (rounds 217/219)', () {
      final f = Scorer(tinyPack(logitScale: 8)).fuse(threeCrops(), tau: 0.8, dropFactor: 1);
      for (var k = 0; k < f.ladder.length; k++) {
        var plain = 0.0, mx = 0.0, agreeSum = 0.0;
        var agreeN = 0;
        for (var i = 0; i < 3; i++) {
          final m = f.perCropMass[i][k];
          plain += m;
          if (m > mx) mx = m;
          final top1 = f.perCrop[i].rows.first;
          if (tinyPack().labels[top1].ranks[k].isNotEmpty && tinyPack().labels[top1].keyAt(k) == f.ladder[k].key) {
            agreeSum += m;
            agreeN++;
          }
        }
        expect(f.ladder[k].meanMass, closeTo(plain / 3, 1e-6));
        expect(f.ladder[k].maxMass, closeTo(mx, 1e-6));
        expect(f.ladder[k].support, closeTo(agreeN / 3, 1e-9));
        expect(f.ladder[k].agreeMass, closeTo(agreeN == 0 ? 0 : agreeSum / agreeN, 1e-6));
      }
      expect(f.ladder.first.toJson().keys, containsAll(['rank', 'taxon', 'p', 'p_mean', 'p_max', 'p_agree', 'support']));
      expect(f.counted.length, 3);
    });
  });

  // Round 322: the v2 label packs (fauna-pulse-models, build_label_pack.py
  // --name-rules higher-rank) leave the slots below genus or family empty for
  // rows not in the plain form, and write kingdom Metazoa as Animalia. The
  // app needed no change for it: a row counts only down to the rank above its
  // first empty slot (rollUp, massesAt), and its name is its deepest named rank.
  group('v2 name rules (round 322)', () {
    LabelPack rulesPack() {
      const dim = 7;
      final m = Float32List(dim * dim);
      for (var r = 0; r < dim; r++) {
        m[r * dim + r] = 1;
      }
      return LabelPack(
        packId: 'bioclip-2_rules_v2',
        modelId: 'bioclip-2',
        dim: dim,
        rows: dim,
        sinkRows: 1,
        logitScale: 100,
        temperature: 1.0,
        labels: const [
          LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Lepidoptera', 'Nymphalidae', 'Vanessa', 'cardui'], 'Painted lady'),
          // two_genera: used down to family (genus, species and common name left empty).
          LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Lepidoptera', 'Nymphalidae', '', ''], ''),
          // species_not_plain ("Bombus spec"): used down to genus.
          LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', ''], ''),
          LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'terrestris'], ''),
          // metazoa: kingdom read as Animalia, used down to family.
          LabelRow(['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', '', ''], ''),
          // A gap in the source taxonomy (no order): counts only down to the class.
          LabelRow(['Animalia', 'Chordata', 'Aves', '', 'Corvidae', 'Corvus', 'corax'], 'Raven'),
          LabelRow(['none', '', '', '', '', '', 'flower'], 'a photo of a flower.'),
        ],
        matrix: m,
        header: const {},
      );
    }

    List<double> axis(int i) => [for (var k = 0; k < 7; k++) k == i ? 1.0 : 0.0];

    test('a cut row shows its deepest named rank', () {
      final l = rulesPack().labels;
      expect([for (final r in l.take(5)) r.speciesName], ['Vanessa cardui', 'Nymphalidae', 'Bombus', 'Bombus terrestris', 'Apidae']);
    });

    test('a cut row counts for the ranks above the cut only (rollUp and massesAt agree)', () {
      final s = Scorer(rulesPack());
      final p = s.probs(unit([0, 0, 1, 1, 1, 0, 0])); // the three Apidae rows alike
      final m = s.rollUp(p);
      const apidae = 'Animalia|Arthropoda|Insecta|Hymenoptera|Apidae';
      expect(m[4][apidae], closeTo(p[2] + p[3] + p[4], 1e-6), reason: 'the Metazoa row counts for its family');
      expect(m[5]['$apidae|Bombus'], closeTo(p[2] + p[3], 1e-6), reason: '"Bombus spec" counts for Bombus');
      expect(m[6].keys.toSet(), {'Animalia|Arthropoda|Insecta|Lepidoptera|Nymphalidae|Vanessa|cardui', '$apidae|Bombus|terrestris'},
          reason: 'species only from the plain rows (the raven stops at its class)');
      expect(m[6]['$apidae|Bombus|terrestris'], closeTo(p[3], 1e-6));
      expect(m[0].keys.toSet(), {'Animalia', 'none'}, reason: 'one animal kingdom');
      expect(m[3].keys.where((k) => k.contains('Aves')), isEmpty, reason: 'the gap row stops at its class');
      final masses = s.massesAt(p, ['Animalia', 'Animalia|Arthropoda', 'Animalia|Arthropoda|Insecta',
          'Animalia|Arthropoda|Insecta|Hymenoptera', apidae, '$apidae|Bombus', '$apidae|Bombus|terrestris']);
      expect(masses[4], closeTo(m[4][apidae]!, 1e-6));
      expect(masses[5], closeTo(m[5]['$apidae|Bombus']!, 1e-6));
      expect(masses[6], closeTo(m[6]['$apidae|Bombus|terrestris']!, 1e-6));
    });

    test('a track ID on a cut row is named down to that rank, not deeper', () {
      final s = Scorer(rulesPack());
      FusedTrack on(int row) => s.fuse([crop(axis(row)), crop(axis(row), jpeg: 'b.jpg')]);
      expect((on(2).identifiedRank, on(2).headline), ('genus', 'Bombus'));
      expect((on(1).identifiedRank, on(1).headline), ('family', 'Nymphalidae'));
      expect(on(1).bestViewTaxon, 'Nymphalidae');
      expect((on(4).identifiedRank, on(4).headline), ('family', 'Apidae'));
      expect(on(4).ladder.first.taxon, 'Animalia');
      expect((on(5).identifiedRank, on(5).headline), ('class', 'Aves'));
      expect((on(3).identifiedRank, on(3).headline), ('species', 'Bombus terrestris'), reason: 'plain rows as before');
    });

    test('the v2 header keys are read and kept (name_rules, source checksums)', () async {
      final header = {
        'kind': 'label_pack',
        'pack_id': 'bioclip-2_rules_v2',
        'model_id': 'bioclip-2',
        'dim': 2,
        'rows': 2,
        'dtype': 'f32',
        'logit_scale': 100.0,
        'temperature': 1.0,
        'sink_rows': 0,
        'labels': [
          ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', '', ''],
          ['Animalia', 'Arthropoda', 'Insecta', 'Hymenoptera', 'Apidae', 'Bombus', 'terrestris', ''],
        ],
        'source': {'names_file_sha256': 'ab' * 32, 'species_csv_sha256': 'cd' * 32},
        'name_rules': {
          'set': 'higher-rank',
          'counts': {'metazoa': 0, 'two_genera': 0, 'species_not_plain': 1},
          'rows': [
            {'pack_row': 0, 'tol_row': 7, 'rule': 'species_not_plain', 'published': ['Animalia', '', '', '', '', 'Bombus', 'spec', '']},
          ],
        },
      };
      final h = utf8.encode(jsonEncode(header));
      final bytes = (BytesBuilder()
            ..add(ascii.encode('FPK1'))
            ..add((ByteData(4)..setUint32(0, h.length, Endian.little)).buffer.asUint8List())
            ..add(h)
            ..add(Float32List.fromList([1, 0, 0, 1]).buffer.asUint8List()))
          .toBytes();
      final pack = LabelPack.parseBytes(bytes);
      expect(pack.labels.map((l) => l.speciesName), ['Bombus', 'Bombus terrestris']);
      expect((pack.header['name_rules'] as Map)['rows'], hasLength(1));
      final dir = Directory.systemTemp.createTempSync('fpack_v2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bioclip-2_rules_v2.fpack')..writeAsBytesSync(bytes);
      final read = await LabelPack.readHeader(file);
      expect((read['name_rules'] as Map)['rows'], hasLength(1), reason: 'the models screen counts these');
      expect((read['source'] as Map)['names_file_sha256'], 'ab' * 32);
    });
  });
}
