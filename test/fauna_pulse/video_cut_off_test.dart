// Round 243: clips cut off because the app was killed while recording. Android writes an
// MP4's index (the `moov` box) only when a recording is closed, so such a file cannot be
// read. The analysis leaves it out instead of retrying it on every run, and Free storage
// can delete it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/postprocess/clip_cleanup.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_detector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'video_detector_test.dart' show FakeBackend, config, records;
import 'package:fauna_pulse/fauna_pulse/logging/device_thermal.dart';

/// One MP4 box: 32-bit size, type, payload.
List<int> box(String type, int payloadBytes, {int? sizeField}) {
  final size = payloadBytes + 8;
  final b = ByteData(8)
    ..setUint32(0, sizeField ?? size)
    ..setUint8(4, type.codeUnitAt(0))
    ..setUint8(5, type.codeUnitAt(1))
    ..setUint8(6, type.codeUnitAt(2))
    ..setUint8(7, type.codeUnitAt(3));
  return [...b.buffer.asUint8List(), ...List.filled(payloadBytes, 0)];
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('video_cut_off');
    Directory('${dir.path}/videos').createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String name, List<int> bytes) => File('${dir.path}/videos/$name')..writeAsBytesSync(bytes);

  test('an MP4 with its index is readable; one cut off before it is not', () {
    final done = write('done.mp4', [...box('ftyp', 16), ...box('mdat', 1000), ...box('moov', 200)]);
    final streamable = write('front.mp4', [...box('ftyp', 16), ...box('moov', 200), ...box('mdat', 1000)]);
    // What MediaMuxer leaves when the app dies: the data box's size is still its placeholder.
    final cut = write('cut.mp4', [...box('ftyp', 16), ...box('mdat', 1000, sizeField: 0)]);
    final cutNoTail = write('cut2.mp4', [...box('ftyp', 16), ...box('free', 8), ...box('mdat', 1000)]);
    final empty = write('empty.mp4', const []);
    // A 64-bit size (size field 1, the real size in the next 8 bytes) is followed.
    final big = ByteData(16)
      ..setUint32(0, 1)
      ..setUint8(4, 'm'.codeUnitAt(0))
      ..setUint8(5, 'd'.codeUnitAt(0))
      ..setUint8(6, 'a'.codeUnitAt(0))
      ..setUint8(7, 't'.codeUnitAt(0))
      ..setUint64(8, 16 + 500);
    final large = write('large.mp4', [...box('ftyp', 16), ...big.buffer.asUint8List(), ...List.filled(500, 0), ...box('moov', 50)]);
    expect(VideoDetector.isReadableVideo(done), isTrue);
    expect(VideoDetector.isReadableVideo(streamable), isTrue);
    expect(VideoDetector.isReadableVideo(cut), isFalse);
    expect(VideoDetector.isReadableVideo(cutNoTail), isFalse);
    expect(VideoDetector.isReadableVideo(empty), isFalse);
    expect(VideoDetector.isReadableVideo(large), isTrue);
    // Not recognisably an MP4, or another container: left to the decoder.
    expect(VideoDetector.isReadableVideo(write('odd.mp4', utf8.encode('video'))), isTrue);
    expect(VideoDetector.isReadableVideo(write('c.mkv', const [1, 2, 3])), isTrue);
    expect(VideoDetector.cutOffClipsOf(dir).map((f) => f.uri.pathSegments.last).toSet(), {'cut.mp4', 'cut2.mp4', 'empty.mp4'});
  });

  test('the analysis leaves a cut-off clip out and says so; Free storage deletes it', () async {
    write('a.mp4', [...box('ftyp', 16), ...box('mdat', 100), ...box('moov', 20)]);
    write('b.mp4', [...box('ftyp', 16), ...box('mdat', 100, sizeField: 0)]);
    final backend = FakeBackend({'a.mp4': 2, 'b.mp4': 2});
    final result = await VideoDetector(
      backend: backend,
      thermal: () async => const ThermalReading(batteryTempC: 30),
      pausePoll: Duration.zero,
    ).run(dir, config: config);
    expect(backend.opens.keys, ['a.mp4']);
    expect(result.clipsFailed, 0);
    final start = records(dir).first;
    expect(start['clips_total'], 1);
    expect(start['clips_cut_off'], 1);

    final plan = await ClipCleanup.planCutOff(dir);
    expect(plan.mode, ClipCleanup.modeCutOff);
    expect(plan.deleteNames, ['b.mp4']);
    File('${dir.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session","time_ms":1}\n');
    expect(await ClipCleanup.run(dir, plan), 1);
    expect(File('${dir.path}/videos/b.mp4').existsSync(), isFalse);
    expect(File('${dir.path}/videos/a.mp4').existsSync(), isTrue);
    expect(File('${dir.path}/session.jsonl').readAsStringSync(), contains('"mode":"cut_off"'));
  });
}
