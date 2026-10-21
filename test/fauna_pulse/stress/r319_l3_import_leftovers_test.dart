// Round 319 (round-318 fixer note n52): an import that stops half way left a
// session folder with videos but no finished session.jsonl. No list shows
// such a folder (Home and Sessions need session.jsonl), so its videos took
// storage for ever. Two ways in: a copy that fails (storage full) and an app
// kill during the copy or the rewrite of a fragmented MP4 (a hidden .part
// file). The photo picker's own copies in the app's cache are also left when
// the app is killed while picking or on the "Import videos" screen.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_import.dart';
import 'package:fauna_pulse/fauna_pulse/postprocess/video_start_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart' show VideoInfo;

void main() {
  late Directory tmp, cache, sessions;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r319_l3_leftovers');
    cache = Directory('${tmp.path}/cache')..createSync();
    sessions = Directory('${tmp.path}/sessions')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ImportClip clip(String name, {bool fragmented = false}) {
    final f = File('${cache.path}/$name')..writeAsStringSync('video $name');
    const info = VideoInfo(durationMs: 30000, width: 1920, height: 1080, mime: 'video/avc', frameCount: 900);
    return ImportClip(
      path: f.path,
      name: name,
      sizeBytes: f.lengthSync(),
      info: info,
      guess: guessClipStart(fileName: name, storedMs: null, durationMs: 30000, fileModifiedMs: 1),
      fragmented: fragmented,
    );
  }

  test('a copy that fails half way leaves no hidden session folder', () async {
    final a = clip('VID_20260924_155954.mp4');
    final b = clip('VID_20260924_160100.mp4');
    File(b.path).deleteSync(); // the copy of the second clip fails
    await expectLater(
      importVideos(sessionsDir: sessions, sessionName: 'Meadow', clips: [a, b]),
      throwsA(isA<FileSystemException>()),
    );
    expect(sessions.listSync(), isEmpty);
  });

  /// Copies [from] into [to], as the folder stood at the moment of a kill.
  void snapshot(Directory from, Directory to) {
    for (final e in from.listSync(recursive: true).whereType<File>()) {
      final rel = e.path.substring(from.path.length);
      File('${to.path}$rel')
        ..createSync(recursive: true)
        ..writeAsBytesSync(e.readAsBytesSync());
    }
  }

  test('an app kill during the copy: the next start deletes the hidden folder', () async {
    final killed = Directory('${tmp.path}/killed')..createSync();
    await importVideos(
      sessionsDir: sessions,
      sessionName: 'Meadow',
      clips: [clip('VID_20260924_155954.mp4'), clip('VID_20260924_160100.mp4')],
      onProgress: (done, total, name) {
        if (done == 1) snapshot(sessions, killed); // clip 1 copied, clip 2 not yet
      },
    );
    // The finished import is listed and keeps nothing hidden.
    expect(File('${sessions.path}/Meadow/$kImportUnfinishedMarker').existsSync(), isFalse);
    expect((await scanPastSessions(root: sessions)).map((s) => s.name), ['Meadow']);

    // The state at the kill: videos but no log, so no list shows it.
    expect(File('${killed.path}/Meadow/videos/VID_20260924_155954.mp4').existsSync(), isTrue);
    expect(await scanPastSessions(root: killed), isEmpty);
    // A recorded session and a folder of unknown origin without a log stay.
    snapshot(sessions, Directory('${killed.path}/kept')..createSync());
    File('${killed.path}/other/videos/clip.mp4').createSync(recursive: true);

    expect(deleteUnfinishedImports(killed), 1);
    final left = killed.listSync().map((e) => e.path.split('/').last).toList()..sort();
    expect(left, ['kept', 'other']);
  });

  test('an app kill while a fragmented clip is rewritten (hidden .part file)', () async {
    final killed = Directory('${tmp.path}/killed')..createSync();
    await expectLater(
      importVideos(
        sessionsDir: sessions,
        sessionName: 'Meadow',
        clips: [clip('VID_20260924_155954.mp4', fragmented: true)],
        remux: (src, dst) async {
          File(dst).writeAsStringSync('half');
          snapshot(sessions, killed);
          throw StateError('stopped');
        },
      ),
      throwsA(isA<ImportRewriteFailed>()),
    );
    expect(sessions.listSync(), isEmpty); // the error path cleans up itself
    expect(File('${killed.path}/Meadow/videos/VID_20260924_155954.mp4.part').existsSync(), isTrue);
    expect(deleteUnfinishedImports(killed), 1);
    expect(killed.listSync(), isEmpty);
  });

  test('killed after the log was finished: the session stays, only the marker goes', () async {
    final dir = await importVideos(sessionsDir: sessions, sessionName: 'Meadow', clips: [clip('VID_20260924_155954.mp4')]);
    File('${dir.path}/$kImportUnfinishedMarker').createSync();
    // A cut log (the kill came while writing it) is not finished.
    final cut = Directory('${sessions.path}/Cut')..createSync();
    File('${cut.path}/$kImportUnfinishedMarker').createSync();
    File('${cut.path}/session.jsonl').writeAsStringSync('{"type":"start_of_session"}\n{"type":"end_of_ses');

    expect(deleteUnfinishedImports(sessions), 1);
    expect(sessions.listSync().map((e) => e.path.split('/').last), ['Meadow']);
    expect(File('${dir.path}/$kImportUnfinishedMarker').existsSync(), isFalse);
    expect(File('${dir.path}/session.jsonl').existsSync(), isTrue);
  });

  test("the picker's leftover copies: only its video folders are deleted", () {
    final a = Directory('${cache.path}/6dfd8a5c-b57a-4025-b0c0-506bc01e7476')..createSync();
    File('${a.path}/1000095497.mp4').writeAsBytesSync(List.filled(3000, 1));
    Directory('${cache.path}/786c9472-9b0e-4e45-94b5-9ac87c20712a').createSync(); // copy never started
    final shot = Directory('${cache.path}/0b7a3c1e-1111-4222-8333-944455556666')..createSync();
    File('${shot.path}/screenshot.jpg').writeAsStringSync('picture'); // a picked screenshot
    Directory('${cache.path}/data').createSync();
    Directory('${cache.path}/link_download').createSync();
    File('${cache.path}/loose.mp4').writeAsStringSync('not in a picker folder');

    expect(deletePickerCopies(pickerVideoCopyFolders(cache)), 3000);
    final left = cache.listSync().map((e) => e.path.split('/').last).toList()..sort();
    expect(left, ['0b7a3c1e-1111-4222-8333-944455556666', 'data', 'link_download', 'loose.mp4']);
  });
}
