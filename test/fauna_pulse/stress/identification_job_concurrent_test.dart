// Stress test (2026-10-20, races): two identification jobs on ONE session at
// the same time (possible because the Identify organisms screen does not stop
// its job on Back, and Start can be tapped twice; see
// identification_screen_race_test.dart). Both jobs append to the same
// embeddings_<model>.jsonl and .bin, each numbering rows from what it read at
// its start. Here the store must stay consistent: each crop record's row must
// point at that crop's own vector.

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

// Three photos: two red (track 1), one blue (track 2).
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
  final packFile = File('test/fauna_pulse/fixtures/tiny_pack.fpack');
  final pack = LabelPack.parseBytes(packFile.readAsBytesSync());

  setUp(() => tmp = Directory.systemTemp.createTempSync('identify_concurrent'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory makeSession() {
    final dir = Directory('${tmp.path}/meadow')..createSync();
    File('${dir.path}/session.jsonl').writeAsStringSync(_log);
    final frames = Directory('${dir.path}/roi_frames')..createSync();
    File('${frames.path}/roi_t_2026-07-14_120000_000.jpg').writeAsBytesSync(_jpeg(220, 30, 30));
    File('${frames.path}/roi_t_2026-07-14_120000_500.jpg').writeAsBytesSync(_jpeg(200, 40, 40));
    File('${frames.path}/roi_t_2026-07-14_120001_000.jpg').writeAsBytesSync(_jpeg(30, 30, 220));
    return dir;
  }

  int packRowOf(Uint8List rgb) => rgb[0] > rgb[2] ? 0 : 2;

  /// Red crops embed as pack row 0, blue as row 2; [delayMs] per batch, so
  /// two jobs interleave.
  IdentificationJob job(int delayMs) => IdentificationJob(
    embed: (rgb) async {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      return [
        for (final buf in rgb)
          Float32List.fromList(pack.matrix.sublist(packRowOf(buf) * pack.dim, (packRowOf(buf) + 1) * pack.dim)),
      ];
    },
    crop: (a) async => cropBatchSync(a),
    thermal: () async => const ThermalReading(batteryTempC: 30),
  );

  IdentifyRunSettings settings() => const IdentifyRunSettings(
    modelName: 'fake_model.tflite',
    modelId: 'fake',
    packName: 'tiny_pack.fpack',
    inputSize: 32,
    dim: 4,
    accelerator: 'CPU',
    minCropPx: 16,
    batchSize: 1,
  );

  /// Problems in the stored crops: a row used twice, a row past the vectors,
  /// or a row whose vector is not the crop's own (the photo's colour).
  List<String> storeProblems(Directory session) {
    final paths = IdentificationPaths(session);
    final jsonl = paths.embeddingsJsonl('fake_model');
    final bin = paths.embeddingsBin('fake_model');
    final vectors = Float32List.view(Uint8List.fromList(bin.readAsBytesSync()).buffer);
    final problems = <String>[];
    final seen = <int>{};
    for (final line in jsonl.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> r;
      try {
        r = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        problems.add('torn line: ${line.length > 60 ? line.substring(0, 60) : line}');
        continue;
      }
      if (r['type'] != 'crop') continue;
      final row = (r['row'] as num).toInt();
      final photo = r['photo'] as String;
      if (!seen.add(row)) problems.add('row $row used twice');
      if ((row + 1) * pack.dim > vectors.length) {
        problems.add('row $row past the ${vectors.length ~/ pack.dim} stored vectors');
        continue;
      }
      final want = photo.contains('120001_000') ? 2 : 0;
      final got = vectors.sublist(row * pack.dim, (row + 1) * pack.dim);
      final expected = pack.matrix.sublist(want * pack.dim, (want + 1) * pack.dim);
      for (var i = 0; i < pack.dim; i++) {
        if ((got[i] - expected[i]).abs() > 1e-6) {
          problems.add('row $row ($photo) holds another crop\'s vector');
          break;
        }
      }
    }
    return problems;
  }

  /// The run's result, or the refusal text when another job holds the session.
  Future<Object> runOrError(IdentificationJob j, Directory session) async {
    try {
      return await j.run(session, settings: settings(), packFile: packFile);
    } on Exception catch (e) {
      return '$e';
    }
  }

  group('stress: two identification jobs on one session', () {
    test('one job: every crop record points at its own vector (reference)', () async {
      final session = makeSession();
      final r = await job(5).run(session, settings: settings(), packFile: packFile);
      expect(r.error, isNull);
      expect(storeProblems(session), isEmpty);
    });

    test('two jobs at once leave a consistent store', () async {
      final session = makeSession();
      // The second job on the same session is refused at once (it throws, so
      // the Identify screen shows the reason); the first one runs normally.
      final runs = await Future.wait([
        runOrError(job(5), session),
        runOrError(job(7), session),
      ]);
      // ignore: avoid_print
      print('runs: $runs; problems: ${storeProblems(session)}');
      expect(runs.whereType<IdentifyResult>().single.error, isNull);
      expect(runs.whereType<String>().single, contains('already being identified'));
      expect(storeProblems(session), isEmpty);
      // A later run (the user starts again) must still work and fix the store.
      final again = await job(1).run(session, settings: settings(), packFile: packFile);
      expect(again.error, isNull);
      expect(storeProblems(session), isEmpty);
    });

    test('after two jobs at once, the next run starts the store over and ends consistent', () async {
      final session = makeSession();
      await Future.wait([runOrError(job(5), session), runOrError(job(7), session)]);
      final again = await job(1).run(session, settings: settings(), packFile: packFile);
      // ignore: avoid_print
      print('third run error: ${again.error}; problems after it: ${storeProblems(session)}');
      expect(again.error, isNull);
      expect(storeProblems(session), isEmpty);
    });
  });
}
