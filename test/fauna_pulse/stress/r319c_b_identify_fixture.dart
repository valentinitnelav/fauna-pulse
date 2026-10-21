// A session ready for "Identify organisms" (a model, a name list, one insect with its track ID
// found), shared by the r319c_b tests of this folder. Not a test itself.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/photo_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

final _s0 = DateTime(2026, 7, 1, 10).millisecondsSinceEpoch;

String _rec(String type, Map<String, dynamic> m) => jsonEncode({'type': type, 'time_ms': _s0, ...m});

/// [base]: the app's files folder (path_provider's answer in the test). A time-lapse session (a
/// photo every 0.2 s for 4 s), every photo analyzed, one insect from 1 s to 3 s.
Future<Directory> identifySession(WidgetTester tester, Directory base, [String name = 'Salvia']) async {
  final m = Directory('${base.path}/identification/models')..createSync(recursive: true);
  final p = Directory('${base.path}/identification/packs')..createSync(recursive: true);
  File('${m.path}/test-model.tflite').writeAsBytesSync([0]);
  File('test/fauna_pulse/fixtures/tiny_pack.fpack').copySync('${p.path}/tiny_pack.fpack');
  final dir = Directory('${base.path}/sessions/$name')..createSync(recursive: true);
  final times = [for (var t = 0; t < 4000; t += 200) t];
  String photo(int t) => roiPhotoFileName(_s0 + t, 'tok');
  File('${dir.path}/session.jsonl').writeAsStringSync('${[
    _rec('start_of_session', {
      'file_token': 'tok',
      'config': {'captureTrigger': 'timelapse', 'stepSeconds': 0.2, 'durationSeconds': 4.0},
    }),
    for (final t in times) ...[
      _rec('timelapse_capture', {'jpeg': photo(t), 'captured_at_ms': _s0 + t}),
      _rec('capture', {'file': photo(t), 'captured_at_ms': _s0 + t, 'saved_px': 640}),
    ],
    _rec('end_of_session', {'time_ms': _s0 + 5000, 'ended_normally': true}),
  ].join('\n')}\n');
  File('${dir.path}/post_detections.jsonl').writeAsStringSync('${[
    _rec('post_start', {'model': 'm.tflite', 'model_name': 'm', 'confidence': 0.25, 'iou': 0.7}),
    for (final t in times)
      _rec('post_detection', {
        'jpeg': photo(t),
        'captured_at_ms': _s0 + t,
        'boxes': [
          if (t >= 1000 && t <= 3000)
            {
              'class_name': 'bee',
              'conf': 0.8,
              'box': [0.3, 0.3, 0.6, 0.6],
            },
        ],
      }),
  ].join('\n')}\n');
  final frames = Directory('${dir.path}/roi_frames')..createSync();
  final im = img.Image(width: 320, height: 320, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(200, 60, 40));
  final jpeg = Uint8List.fromList(img.encodeJpg(im, quality: 90));
  for (final t in times) {
    File('${frames.path}/${photo(t)}').writeAsBytesSync(jpeg);
  }
  await tester.runAsync(() => PhotoTracker.run(dir, const SessionConfig()));
  return dir;
}

/// Lets real file work finish inside a widget test until [done] (fails with [what] if never).
Future<void> pumpUntilDone(WidgetTester tester, bool Function() done, String what, {int rounds = 300}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: 'never happened: $what');
}
