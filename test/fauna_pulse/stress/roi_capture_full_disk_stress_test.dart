// Full-disk photo write (stress finding D2c): with "Keep free storage" = 0 a
// photo write can stop half way with "No space left on device". The capture
// must report the error AND remove the truncated JPEG, so the photos folder
// only holds readable photos that the session log counts.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/roi_capture.dart';
import 'package:fauna_pulse/fauna_pulse/models/roi.dart';
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/models/track.dart';

/// Writes the first half of the bytes for real, then fails like a full disk.
/// Other File members are not used by the capture's write path.
class _HalfWriteFile implements File {
  _HalfWriteFile(this._real);
  final File _real;

  @override
  String get path => _real.path;
  @override
  Directory get parent => _real.parent;
  @override
  bool existsSync() => _real.existsSync();
  @override
  void deleteSync({bool recursive = false}) => _real.deleteSync();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await _real.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
    throw FileSystemException(
      'No space left on device',
      path,
      const OSError('No space left on device', 28),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test('a photo write cut by a full disk leaves no truncated JPEG', () async {
    final dir = Directory.systemTemp.createTempSync('full_disk_photo');
    addTearDown(() => dir.deleteSync(recursive: true));
    final errors = <String>[];
    final s = RoiCaptureScheduler(
      framesDir: dir,
      sessionToken: 'S',
      stepMs: 1000,
      durationMs: 5000,
      mode: RoiCaptureMode.fast,
      targetPx: 640,
      fastCaptureFn: () async => Uint8List(4096),
      highResCaptureFn: () async => null,
      roiProvider: () => Roi.defaultRoi,
      streamDims: () => (1280, 960),
      highResDims: () => (0, 0),
      onError: (fileName, error) => errors.add(fileName),
    );
    final pending = s.evaluate([
      Track(
        id: 1,
        box: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
        confidence: 0.9,
        classIndex: 0,
        className: 'bee',
        firstSeenMs: 0,
        lastSeenMs: 0,
      ),
    ], 10000)!;
    // Built outside the override zone, so it is a plain dart:io File.
    final real = File('${dir.path}/${pending.fileName}');
    await IOOverrides.runZoned(
      () => s.capture(pending),
      // Fast mode writes only this one file; File(p) here would recurse.
      createFile: (p) => p == real.path
          ? _HalfWriteFile(real)
          : throw StateError('unexpected file $p'),
    );
    expect(errors, [pending.fileName]);
    expect(real.existsSync(), isFalse);
  });
}
