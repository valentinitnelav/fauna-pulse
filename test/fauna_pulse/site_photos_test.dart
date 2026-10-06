// Round 302: site photos wait in the app's folder and move into the session at Start.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/field_notes.dart';
import 'package:fauna_pulse/fauna_pulse/session/site_photos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('names follow FaunaLapse (time of the photo)', () {
    expect(sitePhotoStem(DateTime(2026, 10, 7, 6, 5, 4, 3)), '20261007_060504_003');
  });

  test('waiting photos move into the session and are named in order', () async {
    final tmp = Directory.systemTemp.createTempSync('site_photos');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final waiting = Directory('${tmp.path}/waiting')..createSync();
    File('${waiting.path}/20261007_060600_000.jpg').writeAsBytesSync([2]);
    File('${waiting.path}/20261007_060500_000.jpg').writeAsBytesSync([1]);
    File('${waiting.path}/note.txt').writeAsStringSync('not a photo');
    expect((await waitingSitePhotos(dir: waiting)).map((f) => f.uri.pathSegments.last), [
      '20261007_060500_000.jpg',
      '20261007_060600_000.jpg',
    ]);
    final session = Directory('${tmp.path}/session')..createSync();
    final moved = await moveSitePhotosInto(session, waitingDir: waiting);
    expect(moved, ['20261007_060500_000.jpg', '20261007_060600_000.jpg']);
    expect(File('${session.path}/site_photos/20261007_060600_000.jpg').readAsBytesSync(), [2]);
    expect(await waitingSitePhotos(dir: waiting), isEmpty);
    expect(await moveSitePhotosInto(session, waitingDir: waiting), isEmpty);
  });

  test('the GPS goal: whole metres 0 to 1000, default 10, in the location block', () {
    const n = FieldNotes();
    expect(n.gpsGoalM, 10);
    expect(n.withGpsGoal('2.5'), isNull);
    expect(n.withGpsGoal('1001'), isNull);
    final five = n.withGpsGoal('5')!;
    expect(five.gpsGoalM, 5);
    expect(FieldNotes.fromJson(five.toJson()).gpsGoalM, 5);
    expect(n.withGpsGoal('')!.gpsGoalM, 10);
    final block = five.withText('site_photos_about', 'The patch from the north')!.recordBlock(sitePhotos: ['a.jpg']);
    expect(block['site_photos'], ['a.jpg']);
    expect(block['site_photos_about'], 'The patch from the north');
    expect(five.summary, isEmpty, reason: 'the goal and the photo note are not part of the summary line');
  });
}
