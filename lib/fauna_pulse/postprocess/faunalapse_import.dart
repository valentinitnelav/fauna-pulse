// FaunaPulse (round 300): imports a photo session recorded with the sister app FaunaLapse.
//
// FaunaLapse records time-lapse photos on any phone without AI (light, long sessions); its
// "Pack" button stores each photo session as a zip that holds the session folder
// (`<folder>/session.jsonl`, the photos `<yyyyMMdd_HHmmss_SSS>.jpg`, `site_photos/`), split
// into `_part2`, `_part3` zips when large. This turns one or more such zips into a FaunaPulse
// time-lapse session, so "Find animals in photos" and identification run on it afterwards:
//
//   sessions/<folder>/roi_frames/roi_<token>_<date>_<time>.jpg   the photos, renamed
//   sessions/<folder>/site_photos/...                              unchanged
//   sessions/<folder>/faunalapse_session.jsonl                     FaunaLapse's own record
//   sessions/<folder>/session.jsonl   start_of_session {source: faunalapse, config, field, ...}
//                                     timelapse_capture + capture per photo (original times)
//                                     end_of_session
//
// FaunaLapse video sessions need nothing new: "Import videos…" reads the start time from
// FaunaLapse's file names. The parsing below is pure and unit tested.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import '../capture/roi_capture.dart' show roiPhotoFileName;
import '../logging/session_logger.dart';
import '../models/session_config.dart';

/// One FaunaLapse photo: its file name, when it was taken, its saved side and burst.
class FaunaLapsePhoto {
  final String file;
  final int takenAtMs;
  final int? savedPx;
  final int burst;
  const FaunaLapsePhoto(this.file, this.takenAtMs, this.savedPx, this.burst);
}

/// What the import needs from a FaunaLapse `session.jsonl`.
class FaunaLapseLog {
  final Map<String, dynamic> start;
  final List<FaunaLapsePhoto> photos;
  final Map<String, dynamic>? end;
  const FaunaLapseLog(this.start, this.photos, this.end);

  // Throws a TypeError when settings is not an object: the import reads it inside its
  // TypeError guard and refuses such a record with a plain message.
  Map<String, dynamic> get settings => (start['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
  // Type check, not [settings]: the import asks this before its TypeError guard, so a cast here
  // would show a hand-edited record (settings as text) to the user as a raw Dart error.
  bool get isVideo {
    final s = start['settings'];
    return s is Map && s['mode'] == 'video';
  }
  int get startMs => DateTime.parse(start['time'] as String).millisecondsSinceEpoch;
  int? get endMs => end == null ? null : DateTime.tryParse('${end!['time']}')?.millisecondsSinceEpoch;
}

/// Reads a FaunaLapse record; null when it is not one (no `session_start` first).
FaunaLapseLog? parseFaunaLapseLog(Iterable<String> lines) {
  Map<String, dynamic>? start;
  Map<String, dynamic>? end;
  final photos = <FaunaLapsePhoto>[];
  var burst = -1;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> r;
    try {
      r = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      continue; // a cut-off last line
    }
    switch (r['event']) {
      case 'session_start':
        start ??= r;
      case 'burst_start':
        burst++;
      case 'photo':
        final t = DateTime.tryParse('${r['time']}');
        final file = r['file'];
        if (t == null || file is! String || r['error'] != null) continue;
        // Type check, not a cast: this runs outside the try above, so a cast would let one
        // hand-edited line (size as text) reject the whole record. The photo itself is real,
        // so keep it and only drop the size (it is just copied into the frame line).
        final px = r['saved_side_px'];
        photos.add(FaunaLapsePhoto(file, t.millisecondsSinceEpoch, px is num ? px.toInt() : null, burst < 0 ? 0 : burst));
      case 'session_end':
        end = r;
    }
  }
  if (start == null || DateTime.tryParse('${start['time']}') == null) return null;
  return FaunaLapseLog(start, photos, end);
}

/// The FaunaPulse settings closest to a FaunaLapse photo session's, so the summary's Setup
/// tab and the session list read it like a recorded time-lapse.
SessionConfig faunaLapseConfig(FaunaLapseLog log, String folderName) {
  final s = log.settings;
  double? n(String k) => (s[k] as num?)?.toDouble();
  return const SessionConfig().copyWith(
    captureTrigger: CaptureTrigger.timelapse,
    timeLapseSaveAs: TimeLapseSaveAs.photos,
    captureMode: RoiCaptureMode.highRes,
    stepSeconds: n('photo_step_s'),
    durationSeconds: n('burst_s'),
    timeLapseGapSeconds: n('break_min') == null ? null : n('break_min')! * 60,
    targetRoiSavedPx: (s['saved_side_px'] as num?)?.toInt(),
    sessionMinutes: (s['run_min'] as num?)?.toInt(),
    folderName: folderName,
  );
}

/// FaunaPulse's top-level `location` from FaunaLapse's `field.location`, or null.
Map<String, dynamic>? faunaLapseLocation(Map<String, dynamic> start) {
  final loc = (start['field'] as Map?)?['location'];
  if (loc is! Map) return null;
  final lat = (loc['latitude'] as num?)?.toDouble();
  final lon = (loc['longitude'] as num?)?.toDouble();
  if (lat == null || lon == null) return null;
  final fix = DateTime.tryParse('${loc['fix_time']}');
  return {
    'lat': lat,
    'lon': lon,
    if (loc['coordinate_uncertainty_m'] is num) 'accuracy_m': (loc['coordinate_uncertainty_m'] as num).toDouble(),
    'fix_time_ms': fix?.millisecondsSinceEpoch ?? 0,
    'source': loc['source'] == 'typed' ? 'manual' : 'gps',
  };
}

/// What an import did.
class FaunaLapseImportResult {
  final String folder;
  final int photos;
  final int missingPhotos;
  final int sitePhotos;
  /// Photos left out because their bytes did not match the checksum stored in the zip.
  final int damagedPhotos;
  const FaunaLapseImportResult(this.folder, this.photos, this.missingPhotos, this.sitePhotos, {this.damagedPhotos = 0});
}

/// A plain-language reason the zips cannot be imported.
class FaunaLapseImportError implements Exception {
  final String message;
  const FaunaLapseImportError(this.message);
  @override
  String toString() => message;
}

/// [importFaunaLapseZips] in a background isolate. A top-level function on purpose: a closure
/// written inside a widget method would also capture the widget's context, which an isolate
/// cannot receive (found by the device check).
Future<FaunaLapseImportResult> importFaunaLapseZipsInBackground(List<String> zipPaths, Directory sessionsRoot) =>
    Isolate.run(() => importFaunaLapseZips(zipPaths, sessionsRoot));

/// Imports the zips of ONE FaunaLapse photo session (all its parts) into [sessionsRoot].
/// Throws [FaunaLapseImportError] with a plain reason. Runs fine in a background isolate.
Future<FaunaLapseImportResult> importFaunaLapseZips(List<String> zipPaths, Directory sessionsRoot) async {
  // Every entry of every zip, by its path inside the zip.
  final entries = <String, ArchiveFile>{};
  final streams = <InputFileStream>[];
  // The new session folder while it is only partly written, and its record. Any error after
  // the folder is made (disk full while copying photos, a damaged photo entry) must remove it
  // again (see the finally below): a leftover folder blocks the next try with "already here".
  Directory? halfMade;
  SessionLogger? logger;
  try {
    for (final p in zipPaths) {
      final input = InputFileStream(p);
      streams.add(input);
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (_) {
        throw FaunaLapseImportError('${p.split('/').last} is not a readable zip file.');
      }
      for (final f in archive.files) {
        if (f.isFile) entries[f.name] = f;
      }
    }
    final logs = entries.keys.where((n) => n.split('/').length == 2 && n.endsWith('/session.jsonl')).toList();
    if (logs.isEmpty) {
      throw const FaunaLapseImportError(
        'No FaunaLapse session record (session.jsonl) in the chosen files. Choose the zip that '
        'FaunaLapse made of one photo session (and all its "_part" zips).',
      );
    }
    final folders = logs.map((n) => n.split('/').first).toSet();
    if (folders.length > 1) {
      throw const FaunaLapseImportError('The chosen zips hold more than one session: import them one at a time.');
    }
    final folder = folders.single;
    // Damaged compressed data (bad SD card, broken copy) or a record that is not UTF-8 throws
    // archive or FormatException errors here; the user should get a plain reason instead.
    // Nothing is written yet, so there is nothing to clean up.
    final FaunaLapseLog? log;
    try {
      log = parseFaunaLapseLog(const LineSplitter().convert(utf8.decode(entries['$folder/session.jsonl']!.content)));
    } catch (_) {
      throw const FaunaLapseImportError('The session record (session.jsonl) is damaged and cannot be read.');
    }
    if (log == null) throw const FaunaLapseImportError('The session record is not a FaunaLapse record.');
    if (log.isVideo) {
      throw const FaunaLapseImportError(
        'This is a FaunaLapse video session: import its video files with "Import videos…" instead.',
      );
    }
    final dir = Directory('${sessionsRoot.path}/$folder');
    if (dir.existsSync()) throw FaunaLapseImportError('A session named $folder is already here.');
    // Read every typed value of the start record before anything is written: a hand-edited or
    // foreign record (text where FaunaLapse writes a number or an object) fails here with a
    // plain message instead of a raw Dart TypeError.
    final start = log.start;
    final int startMs;
    final Map<String, dynamic> config;
    final Map<String, dynamic>? location;
    final Map<String, dynamic> device;
    try {
      startMs = log.startMs;
      config = faunaLapseConfig(log, folder).toJson();
      location = faunaLapseLocation(start);
      final field = start['field'] as Map?;
      device = {'manufacturer': field?['phone_maker'], 'model': field?['phone_model']};
    } on TypeError {
      throw const FaunaLapseImportError('The session record has a value of the wrong kind (it may have been edited by hand).');
    }
    // Deleting it on failure is safe: the check above proved this call made the folder.
    halfMade = dir;
    final frames = Directory('${dir.path}/roi_frames')..createSync(recursive: true);

    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final seed = startMs;
    final token = String.fromCharCodes([for (var i = 0; i < 4; i++) alphabet.codeUnitAt((seed ~/ (1 << (5 * i))) % 36)]);
    logger = SessionLogger(File('${dir.path}/session.jsonl'))..open();
    logger.logStart({
      'session_id': '$startMs',
      'file_token': token,
      'source': 'faunalapse',
      'imported_at': isoWithOffset(DateTime.now()),
      'config': config,
      'device': device,
      'location': ?location,
      'field': start['field'],
      'phone_state': start['phone_state'],
      'faunalapse': {
        'folder': folder,
        'app_version': start['app_version'],
        'settings': start['settings'],
        'camera_api': start['camera_api'],
      },
    }, at: DateTime.fromMillisecondsSinceEpoch(log.startMs));

    var written = 0;
    var missing = 0;
    var damaged = 0;
    // roi_frames/ is new and empty (made above), so names used in this loop are all that exist.
    final usedNames = <String>{};
    for (final p in log.photos) {
      final src = entries['$folder/${p.file}'];
      if (src == null) {
        missing++;
        continue;
      }
      // package:archive (4.0.x) does not compare the zip's stored CRC with the data, so bit damage
      // inside a stored JPEG (failing SD card or USB stick, bad transfer) would be copied silently.
      // Check it here and leave such photos out, counted apart from missing ones. Photos are a few
      // MB, so holding one in memory is fine. Done before the name is taken, so names stay compact.
      // writeContent into memory, not src.content: that getter keeps every photo cached in its
      // ArchiveFile until the import ends, which for a long session would not fit in memory.
      final mem = OutputMemoryStream();
      src.writeContent(mem);
      final bytes = mem.getBytes();
      if (src.crc32 != null && getCrc32(bytes) != src.crc32) {
        damaged++;
        continue;
      }
      // roi_ names show local wall-clock time to the millisecond, so two photos can share one:
      // the repeated hour at the end of summer time, a zip imported in another time zone, or a
      // hand-made log. Writing to a used name would silently overwrite the first photo, so move the
      // name on by 1 ms until it is free. captured_at_ms below keeps the true time, and the
      // name keeps the documented roi_ pattern (no suffix), so downstream parsing still works.
      var nameMs = p.takenAtMs;
      var name = roiPhotoFileName(nameMs, token);
      while (!usedNames.add(name)) {
        name = roiPhotoFileName(++nameMs, token);
      }
      File('${frames.path}/$name').writeAsBytesSync(bytes);
      final at = DateTime.fromMillisecondsSinceEpoch(p.takenAtMs);
      logger.logTimeLapseCapture({'jpeg': name, 'captured_at_ms': p.takenAtMs, 'burst': p.burst, 'original_name': p.file}, at: at);
      logger.logCapture({
        'file': name,
        'captured_at_ms': p.takenAtMs,
        'path': 'still',
        'saved_px': p.savedPx,
        'bytes': src.size,
      }, at: at);
      written++;
    }
    var sitePhotos = 0;
    for (final e in entries.entries) {
      if (!e.key.startsWith('$folder/site_photos/')) continue;
      final rel = e.key.substring(folder.length + 1);
      // Zip slip guard: zip names are untrusted text and OutputFileStream makes any missing
      // parent folders, so a hand-made zip with `site_photos/../../x` would write (or
      // overwrite) files of other sessions or models. FaunaLapse never writes such names, so
      // skip the entry instead of failing the whole import (the time-lapse photos matter more).
      // A plain segment check, because package:path is not a direct dependency.
      final parts = rel.split('/');
      if (rel.contains('\\') || rel.contains('\u0000') ||
          parts.skip(1).any((s) => s.isEmpty || s == '.' || s == '..')) {
        continue;
      }
      final out = OutputFileStream('${dir.path}/$rel');
      e.value.writeContent(out);
      await out.close();
      sitePhotos++;
    }
    final keep = OutputFileStream('${dir.path}/faunalapse_session.jsonl');
    entries['$folder/session.jsonl']!.writeContent(keep);
    await keep.close();
    final lastPhoto = log.photos.isEmpty ? log.startMs : log.photos.last.takenAtMs;
    logger.logEnd({
      'ended_normally': log.end != null,
      'source': 'faunalapse',
      if (log.end?['reason'] != null) 'faunalapse_reason': log.end!['reason'],
      'imported_photos': written,
      if (missing > 0) 'missing_photos': missing,
      if (damaged > 0) 'damaged_photos': damaged,
    }, at: DateTime.fromMillisecondsSinceEpoch(log.endMs ?? lastPhoto));
    await logger.close();
    halfMade = null; // complete: keep it
    return FaunaLapseImportResult(folder, written, missing, sitePhotos, damagedPhotos: damaged);
  } finally {
    if (halfMade != null) {
      // Best effort: the original error is the one the user must see, so cleanup errors are dropped.
      try {
        await logger?.close();
      } catch (_) {}
      try {
        halfMade.deleteSync(recursive: true);
      } catch (_) {}
    }
    for (final s in streams) {
      await s.close();
    }
  }
}
