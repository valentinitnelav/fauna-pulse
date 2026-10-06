// FaunaPulse (round 302): photos of the site, taken with the phone's camera app.
//
// Idea from the sister app FaunaLapse (card 2): a few photos of the whole setup (the plant, the
// phone on its tripod, the surroundings) help to understand a session later. They wait in the
// app's own folder until a recording starts, then move into that session's `site_photos/`
// folder and are listed in the start record (`field.site_photos`). File names are the time the
// photo was taken (`yyyyMMdd_HHmmss_SSS.jpg`), as in FaunaLapse.

import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_error_hooks.dart';

/// Where site photos wait until a recording starts (the app's own folder).
Future<Directory> sitePhotosWaitingDir() async {
  final base = (await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory();
  return Directory('${base.path}/site_photos_waiting');
}

/// The waiting site photos, oldest first.
Future<List<File>> waitingSitePhotos({Directory? dir}) async {
  final d = dir ?? await sitePhotosWaitingDir();
  if (!d.existsSync()) return const [];
  final files = d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.jpg')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// `yyyyMMdd_HHmmss_SSS` of [t], as FaunaLapse names its files.
String sitePhotoStem(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}_'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// Opens the phone's camera app; the photo joins the waiting ones. Null when cancelled.
Future<File?> takeSitePhoto() async {
  try {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90);
    if (x == null) return null;
    final dir = await sitePhotosWaitingDir();
    dir.createSync(recursive: true);
    final out = File('${dir.path}/${sitePhotoStem(DateTime.now())}.jpg');
    await File(x.path).copy(out.path);
    try {
      await File(x.path).delete();
    } catch (_) {}
    return out;
  } catch (e) {
    logSwallowed('site_photo_take', e);
    return null;
  }
}

/// Moves the waiting site photos into `<sessionDir>/site_photos/` and returns their names.
/// A photo that cannot be moved stays waiting (logged), so it goes with the next session.
Future<List<String>> moveSitePhotosInto(Directory sessionDir, {Directory? waitingDir}) async {
  final files = await waitingSitePhotos(dir: waitingDir);
  if (files.isEmpty) return const [];
  final target = Directory('${sessionDir.path}/site_photos')..createSync(recursive: true);
  final moved = <String>[];
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    try {
      try {
        await f.rename('${target.path}/$name');
      } on FileSystemException {
        await f.copy('${target.path}/$name');
        await f.delete();
      }
      moved.add(name);
    } catch (e) {
      logSwallowed('site_photo_move', e);
    }
  }
  return moved;
}
