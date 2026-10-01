// FaunaPulse (round 274): sessions the device checks build from a clip,
// shared by photo_visits_check_test.dart and find_and_identify_check_test.dart
// (moved out of the first).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart' show roiPhotoFileName;
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

String _rec(String type, int ms, Map<String, dynamic> m) =>
    jsonEncode({'type': type, 'time_ms': ms, 'time_iso': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(), ...m});

/// A time-lapse session `<sessions>/<name>` made from [src]: the middle
/// square of the picture saved every [stepMs] as photos, in 15-s bursts
/// (the second shown 60 s later), with the session.jsonl records a
/// time-lapse session writes. Returns the folder, the photo count and the
/// photo side in pixels.
Future<({Directory dir, int photos, int side})> timeLapseSessionFromClip(
  File src,
  Directory sessions,
  String name, {
  int stepMs = 200,
}) async {
  final dir = Directory('${sessions.path}/$name')..createSync(recursive: true);
  final frames = Directory('${dir.path}/roi_frames')..createSync();
  final info = await VideoFrameSource.info(src.path);
  final upW = info.rotation % 180 == 0 ? info.width : info.height;
  final upH = info.rotation % 180 == 0 ? info.height : info.width;
  final side = min(upW, upH);
  final roi = [(upW - side) ~/ 2, (upH - side) ~/ 2, side, side];
  final t0 = DateTime(2026, 9, 26, 12).millisecondsSinceEpoch;
  final pts = [for (var t = 0; t < (info.durationMs ?? 30000) - 300; t += stepMs) t];
  int wallOf(int t) => t0 + t + (t >= 15000 ? 60000 : 0);
  final names = [for (final t in pts) roiPhotoFileName(wallOf(t), 'chk')];
  await VideoFrameSource.openFrames(src.path, roiPx: roi);
  var done = 0;
  while (done < pts.length) {
    final chunk = await VideoFrameSource.saveFrames(
      ptsUs: [for (final t in pts.skip(done)) t * 1000],
      paths: [for (final n in names.skip(done)) '${frames.path}/$n'],
    );
    expect(chunk.processed, greaterThan(0));
    done += chunk.processed;
  }
  await VideoFrameSource.close();
  File('${dir.path}/session.jsonl').writeAsStringSync(
    '${[
      _rec('start_of_session', t0, {
        'file_token': 'chk',
        'config': {'captureTrigger': 'timelapse', 'stepSeconds': stepMs / 1000, 'durationSeconds': 15.0},
      }),
      for (var i = 0; i < pts.length; i++) ...[
        _rec('timelapse_capture', wallOf(pts[i]), {'jpeg': names[i], 'captured_at_ms': wallOf(pts[i])}),
        _rec('capture', wallOf(pts[i]), {'file': names[i], 'captured_at_ms': wallOf(pts[i]), 'saved_px': side}),
      ],
      _rec('end_of_session', wallOf(pts.last) + 1000, {'ended_normally': true}),
    ].join('\n')}\n',
  );
  return (dir: dir, photos: pts.length, side: side);
}
