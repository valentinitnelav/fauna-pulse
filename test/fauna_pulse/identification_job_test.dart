// End-to-end test of the identification job (round 208) with a fake embedder:
// planning from a synthetic session, cropping real JPEGs, resumable records,
// scoring against the Python-written fixture pack, outputs, cancel, thermal
// pause. No native channel involved.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:fauna_pulse/fauna_pulse/identification/crop_worker.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';

const _log = '''
{"type":"start_of_session","time_ms":1000,"config":{},"device":{"model":"TestPhone"}}
{"type":"detections","time_ms":2000,"tracks":[{"track_id":1,"confidence":0.9,"box_in_roi":{"left":0.2,"top":0.2,"right":0.6,"bottom":0.6},"jpeg":"roi_t_2026-07-14_120000_000.jpg"}]}
{"type":"detections","time_ms":2500,"tracks":[{"track_id":1,"confidence":0.8,"box_in_roi":{"left":0.25,"top":0.2,"right":0.65,"bottom":0.6},"jpeg":"roi_t_2026-07-14_120000_500.jpg"}]}
{"type":"detections","time_ms":3000,"tracks":[{"track_id":2,"confidence":0.7,"box_in_roi":{"left":0.3,"top":0.3,"right":0.7,"bottom":0.7},"jpeg":"roi_t_2026-07-14_120001_000.jpg"}]}
{"type":"end_of_session","time_ms":4000,"ended_normally":true}
''';

Uint8List _jpeg(int r, int g, int b) {
  final im = img.Image(width: 160, height: 160, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

void main() {
  late Directory tmp;
  late File packFile;
  late LabelPack pack;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('identify_job_test');
    packFile = File('test/fauna_pulse/fixtures/tiny_pack.fpack');
    pack = LabelPack.parseBytes(packFile.readAsBytesSync());
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Directory makeSession(String name) {
    final dir = Directory('${tmp.path}/$name')..createSync();
    File('${dir.path}/session.jsonl').writeAsStringSync(_log);
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    File('${frames.path}/roi_t_2026-07-14_120000_000.jpg').writeAsBytesSync(_jpeg(220, 30, 30));
    File('${frames.path}/roi_t_2026-07-14_120000_500.jpg').writeAsBytesSync(_jpeg(200, 40, 40));
    File('${frames.path}/roi_t_2026-07-14_120001_000.jpg').writeAsBytesSync(_jpeg(30, 30, 220));
    return dir;
  }

  /// Red crops embed as pack row 0 (Eristalis tenax), blue as row 2 (Apis).
  Future<List<Float32List>> fakeEmbed(List<Uint8List> rgb) async {
    return [
      for (final buf in rgb)
        Float32List.sublistView(pack.matrix, (buf[0] > buf[2] ? 0 : 2) * pack.dim, ((buf[0] > buf[2] ? 0 : 2) + 1) * pack.dim),
    ];
  }

  IdentifyRunSettings settings() => const IdentifyRunSettings(
    modelName: 'fake_model.tflite',
    modelId: 'fake',
    packName: 'tiny_pack.fpack',
    inputSize: 32,
    dim: 4,
    accelerator: 'CPU',
    minCropPx: 16,
  );

  test('plans, embeds, scores and writes outputs; a second run resumes', () async {
    final session = makeSession('s1');
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => const ThermalReading(batteryTempC: 30),
    );
    final progress = <IdentifyProgress>[];
    final r = await job.run(
      session,
      settings: settings(),
      packFile: packFile,
      appVersion: '0.7.0+12',
      onProgress: progress.add,
    );
    expect(r.error, isNull);
    expect(r.planned, 3);
    expect(r.embedded, 3);
    expect(r.skipped, 0);
    expect(r.cancelled, isFalse);
    expect(progress.map((p) => p.stage), contains('scoring'));
    expect(progress.last.stage, 'done');

    final paths = IdentificationPaths(session);
    final index = EmbeddingIndex.parse(paths.embeddingsJsonl('fake_model').readAsStringSync());
    expect(index.rows, 3);
    expect(index.contiguous, isTrue);
    expect(index.dim, 4);
    expect(paths.embeddingsBin('fake_model').lengthSync(), 3 * 4 * 4);
    expect(index.records.first.trackId, 1);
    expect(index.records.first.cropPx, 64); // 0.4 × 160
    expect(index.records.first.boxSource, 'trigger');

    final summary = r.summary!;
    expect(summary['tracks_total'], 2);
    expect((summary['by_identified_rank'] as Map)['species'], 2);
    expect(summary['no_organism'], 0);

    final tracks = (jsonDecode(paths.tracksJson('tiny_pack').readAsStringSync())['tracks'] as List).cast<Map<String, dynamic>>();
    expect(tracks.length, 2);
    expect(tracks[0]['track_id'], 1);
    expect(tracks[0]['headline'], 'Eristalis tenax');
    expect((tracks[0]['crops'] as List).first['agrees'], isTrue); // round 214
    // Round 215: per-crop mass under every ladder taxon, the ladder's
    // weighted-mean column, and the per-crop CSV.
    final crop0 = (tracks[0]['crops'] as List).first as Map<String, dynamic>;
    expect(crop0['p_ladder'], hasLength((tracks[0]['ladder'] as List).length));
    expect((crop0['p_ladder'] as List).first, greaterThan(0.9)); // kingdom mass of a clear crop
    expect((tracks[0]['ladder'] as List).first['p_mean'], greaterThan(0.9));
    // Round 217: p_max exported, no per-crop weight (top1_p is the weight).
    expect((tracks[0]['ladder'] as List).first['p_max'], greaterThan(0.9));
    expect(crop0.containsKey('weight'), isFalse);
    expect(crop0['top1_p'], greaterThan(0.9));
    expect(paths.predictionsJsonl('tiny_pack').readAsLinesSync().first, isNot(contains('"weight"')));
    final cropsCsv = paths.cropsCsv('tiny_pack');
    expect(cropsCsv.existsSync(), isTrue);
    final cropLines = cropsCsv.readAsStringSync().trim().split('\n');
    expect(cropLines.first, startsWith('session_id,track_id,crop_no,photo,box_left'));
    expect(cropLines.first, endsWith(',p_species'));
    expect(cropLines.first, isNot(contains(',weight,')));
    expect(cropLines.first, contains(',pad_frac,top1_species,'));
    // Round 220: the top species' higher ranks, per crop.
    expect(cropLines.first, contains(',top1_p,top1_kingdom,top1_phylum,top1_class,top1_order,top1_family,agrees,'));
    expect(crop0['top1_tree'], hasLength(5));
    expect(cropLines.first, contains(',agrees,counted,'));
    expect(crop0['counted'], isTrue);
    // Round 223: each crop's detector confidence (the log's 0.9 and 0.8);
    // det_conf_mean is their mean.
    expect([for (final c in tracks[0]['crops'] as List) c['det_conf']], unorderedEquals([0.9, 0.8]));
    expect(tracks[0]['det_conf_mean'], 0.85);
    expect(cropLines.length, 4); // header + 3 crops
    expect((tracks[0]['crops'] as List).length, 2);
    expect(tracks[1]['headline'], 'Apis mellifera');
    expect((tracks[0]['ladder'] as List).length, 7);
    expect(tracks[0]['start_ms'], 2000);
    expect(tracks[0]['end_ms'], 2500);

    final csvLines = paths.tracksCsv('tiny_pack').readAsLinesSync();
    expect(csvLines.length, 3);
    expect(csvLines.first, startsWith('device_id,session_id,track_id,track_imgs,pred_imgs,pred,pred_prob_weighted,pred_prob_mean,'));
    final header = csvLines.first;
    expect(header, contains(',p_species,p_mean_kingdom,'));
    expect(header, contains(',p_max_species,p_agree_kingdom,'));
    expect(header, contains(',p_agree_species,identified_rank,headline,agree_kingdom,'));
    expect(header, isNot(contains('support_')));
    expect(csvLines.first, contains('bioclip_species'));
    expect(csvLines[1], contains('TestPhone,s1,1,2,'));
    expect(csvLines[1], contains('Syrphidae')); // family at target rank 'family'
    expect(paths.readme.existsSync(), isTrue);
    expect(paths.predictionsJsonl('tiny_pack').readAsLinesSync().length, 3);
    expect(paths.existingSummaries().length, 1);

    // Resume: nothing new to embed, outputs rewritten.
    final r2 = await job.run(session, settings: settings(), packFile: packFile);
    expect(r2.embedded, 0);
    expect(r2.resumedDone, 3);
    expect(r2.summary!['tracks_total'], 2);
    expect(EmbeddingIndex.parse(paths.embeddingsJsonl('fake_model').readAsStringSync()).rows, 3);
  });

  test('cancel before the first photo keeps files consistent and skips scoring', () async {
    final session = makeSession('s2');
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => const ThermalReading(batteryTempC: 30),
    );
    final r = await job.run(session, settings: settings(), packFile: packFile, isCancelled: () => true);
    expect(r.cancelled, isTrue);
    expect(r.embedded, 0);
    expect(r.summary, isNull);
    final paths = IdentificationPaths(session);
    final index = EmbeddingIndex.parse(paths.embeddingsJsonl('fake_model').readAsStringSync());
    expect(index.rows, 0);
    expect(paths.embeddingsJsonl('fake_model').readAsStringSync(), contains('"identify_end"'));
  });

  test('a warm battery pauses the run until it cools', () async {
    final session = makeSession('s3');
    var calls = 0;
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => ThermalReading(batteryTempC: ++calls <= 2 ? 45 : 30),
      pausePoll: const Duration(milliseconds: 1),
    );
    final stages = <String>[];
    final r = await job.run(
      session,
      settings: settings(),
      packFile: packFile,
      onProgress: (p) => stages.add(p.stage),
    );
    expect(r.thermalPauses, 1);
    expect(stages, contains('paused'));
    expect(r.embedded, 3);
  });

  test('tiny boxes are skipped and recorded, not embedded', () async {
    final session = makeSession('s4');
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => const ThermalReading(batteryTempC: 30),
    );
    final r = await job.run(
      session,
      settings: const IdentifyRunSettings(
        modelName: 'fake_model.tflite',
        modelId: 'fake',
        packName: 'tiny_pack.fpack',
        inputSize: 32,
        dim: 4,
        accelerator: 'CPU',
        minCropPx: 100, // boxes are 64 px
      ),
      packFile: packFile,
    );
    expect(r.embedded, 0);
    expect(r.skipped, 3);
    final index = EmbeddingIndex.parse(IdentificationPaths(session).embeddingsJsonl('fake_model').readAsStringSync());
    expect(index.skippedKeys.length, 3);
    expect(index.tooSmallPx.length, 3);
    expect(index.minCropPx, 100);

    // Round 213: lowering the threshold retries the too-small crops instead
    // of keeping them skipped forever.
    final r2 = await job.run(session, settings: settings(), packFile: packFile);
    expect(r2.embedded, 3);
    expect(r2.skipped, 0);
  });

  test('restart recomputes every crop; the index remembers the margin (round 213)', () async {
    final session = makeSession('s5');
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => const ThermalReading(batteryTempC: 30),
    );
    final r1 = await job.run(session, settings: settings(), packFile: packFile);
    expect(r1.embedded, 3);
    final stored = await IdentificationJob.storedIndex(session, 'fake_model.tflite');
    expect(stored!.margin, closeTo(0.15, 1e-9));
    // A plain re-run reuses everything.
    final r2 = await job.run(session, settings: settings(), packFile: packFile);
    expect(r2.embedded, 0);
    expect(r2.resumedDone, 3);
    // A restart starts from an empty file.
    final r3 = await job.run(session, settings: settings(), packFile: packFile, restart: true);
    expect(r3.embedded, 3);
    expect(r3.resumedDone, 0);
    expect(EmbeddingIndex.parse(IdentificationPaths(session).embeddingsJsonl('fake_model').readAsStringSync()).rows, 3);
  });

  // Round 210: opt-in joining of consecutive track ids. Tracks 1 and 3 are
  // both red (Eristalis) with a 1 s gap and same-size boxes; track 2 (blue,
  // Apis) sits between them in id but AFTER them in time.
  const mergeLog = '''
{"type":"start_of_session","time_ms":1000,"config":{},"device":{"model":"TestPhone"}}
{"type":"detections","time_ms":2000,"tracks":[{"track_id":1,"confidence":0.9,"box_in_roi":{"left":0.2,"top":0.2,"right":0.6,"bottom":0.6},"jpeg":"roi_t_2026-07-14_120000_000.jpg"}]}
{"type":"detections","time_ms":2500,"tracks":[{"track_id":1,"confidence":0.8,"box_in_roi":{"left":0.25,"top":0.2,"right":0.65,"bottom":0.6},"jpeg":"roi_t_2026-07-14_120000_500.jpg"}]}
{"type":"detections","time_ms":3500,"tracks":[{"track_id":3,"confidence":0.85,"box_in_roi":{"left":0.3,"top":0.3,"right":0.7,"bottom":0.7},"jpeg":"roi_t_2026-07-14_120001_500.jpg"}]}
{"type":"detections","time_ms":9000,"tracks":[{"track_id":2,"confidence":0.7,"box_in_roi":{"left":0.3,"top":0.3,"right":0.7,"bottom":0.7},"jpeg":"roi_t_2026-07-14_120001_000.jpg"}]}
{"type":"end_of_session","time_ms":10000,"ended_normally":true}
''';

  Directory makeMergeSession(String name) {
    final dir = Directory('${tmp.path}/$name')..createSync();
    File('${dir.path}/session.jsonl').writeAsStringSync(mergeLog);
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    File('${frames.path}/roi_t_2026-07-14_120000_000.jpg').writeAsBytesSync(_jpeg(220, 30, 30));
    File('${frames.path}/roi_t_2026-07-14_120000_500.jpg').writeAsBytesSync(_jpeg(200, 40, 40));
    File('${frames.path}/roi_t_2026-07-14_120001_500.jpg').writeAsBytesSync(_jpeg(210, 35, 35));
    File('${frames.path}/roi_t_2026-07-14_120001_000.jpg').writeAsBytesSync(_jpeg(30, 30, 220));
    return dir;
  }

  Future<Map<String, dynamic>> runMerge(
    Directory session, {
    required bool merge,
    double gapS = 3,
    double flagMinDetConf = 0.2,
  }) async {
    final job = IdentificationJob(
      embed: fakeEmbed,
      crop: (a) async => cropBatchSync(a),
      thermal: () async => const ThermalReading(batteryTempC: 30),
    );
    final r = await job.run(
      session,
      settings: IdentifyRunSettings(
        modelName: 'fake_model.tflite',
        modelId: 'fake',
        packName: 'tiny_pack.fpack',
        inputSize: 32,
        dim: 4,
        accelerator: 'CPU',
        minCropPx: 16,
        mergeVisits: merge,
        mergeGapS: gapS,
        flagMinDetConf: flagMinDetConf,
      ),
      packFile: packFile,
    );
    expect(r.error, isNull);
    return r.summary!;
  }

  test('merge consecutive visits joins compatible, non-overlapping track ids', () async {
    final session = makeMergeSession('m1');
    final off = await runMerge(session, merge: false);
    expect(off['tracks_total'], 3);
    expect(off['visits_merged'], 0);
    // Every track is short here (≤ 2 detections, < 2 s) but none is weakly
    // supported at the default thresholds, so nothing is suspect.
    expect(off['suspect'], 0);

    final on = await runMerge(session, merge: true);
    expect(on['tracks_total'], 2);
    expect(on['visits_merged'], 1);
    expect(on['tracks_before_merge'], 3);
    final paths = IdentificationPaths(session);
    final tracks = (jsonDecode(paths.tracksJson('tiny_pack').readAsStringSync())['tracks'] as List).cast<Map<String, dynamic>>();
    final joined = tracks.firstWhere((t) => (t['track_ids'] as List).length > 1);
    expect(joined['track_ids'], [1, 3]);
    expect(joined['track_id'], 1);
    expect(joined['headline'], 'Eristalis tenax');
    expect((joined['crops'] as List).length, 3);
    expect(joined['flags'], contains('merged'));
    expect(joined['duration_s'], closeTo(1.5, 1e-6)); // 2000 .. 3500 ms
    final csv = paths.tracksCsv('tiny_pack').readAsStringSync();
    expect(csv.split('\n').first, contains(',merged_track_ids,'));
    expect(csv, contains('1;3'));
    // The compact summary list carries the ids for the Photos tab.
    final lite = (on['tracks'] as List).cast<Map<String, dynamic>>();
    expect(lite.firstWhere((t) => t['track_id'] == 1)['track_ids'], [1, 3]);

    // A gap shorter than the real one (1 s) keeps them apart.
    final tight = await runMerge(session, merge: true, gapS: 0.5);
    expect(tight['tracks_total'], 3);
  });

  // Round 212: suspect = short AND weakly supported. Raising the detector
  // confidence threshold above track 2's 0.7 makes that single-frame track
  // suspect; tracks 1 and 3 (0.85 / 0.9) stay clean although equally short.
  test('suspect flags mark short, weakly supported visits without dropping them', () async {
    final session = makeMergeSession('m2');
    final s = await runMerge(session, merge: false, flagMinDetConf: 0.75);
    expect(s['tracks_total'], 3);
    expect(s['suspect'], 1);
    final paths = IdentificationPaths(session);
    final tracks = (jsonDecode(paths.tracksJson('tiny_pack').readAsStringSync())['tracks'] as List).cast<Map<String, dynamic>>();
    final t2 = tracks.firstWhere((t) => t['track_id'] == 2);
    expect(t2['suspect'], isTrue);
    expect(t2['detections'], 1);
    expect(t2['flags'], containsAll(['short', 'low_det', 'suspect']));
    final t1 = tracks.firstWhere((t) => t['track_id'] == 1);
    expect(t1['suspect'], isFalse);
    expect(t1['flags'], contains('short'));
    expect(t1['flags'], isNot(contains('suspect')));
    final csv = paths.tracksCsv('tiny_pack').readAsStringSync();
    expect(csv.split('\n').first, endsWith(',merged_track_ids,n_detections,suspect,rival_rank,rival_taxon,rival_p'));
    // The compact summary list carries the verdict for the Photos tab.
    final lite = (s['tracks'] as List).cast<Map<String, dynamic>>();
    expect(lite.firstWhere((t) => t['track_id'] == 2)['suspect'], isTrue);
  });
}
