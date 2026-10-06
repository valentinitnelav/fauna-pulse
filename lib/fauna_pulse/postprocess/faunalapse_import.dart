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

  Map<String, dynamic> get settings => (start['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
  bool get isVideo => settings['mode'] == 'video';
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
        photos.add(FaunaLapsePhoto(file, t.millisecondsSinceEpoch, (r['saved_side_px'] as num?)?.toInt(), burst < 0 ? 0 : burst));
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
  const FaunaLapseImportResult(this.folder, this.photos, this.missingPhotos, this.sitePhotos);
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
    final log = parseFaunaLapseLog(const LineSplitter().convert(utf8.decode(entries['$folder/session.jsonl']!.content)));
    if (log == null) throw const FaunaLapseImportError('The session record is not a FaunaLapse record.');
    if (log.isVideo) {
      throw const FaunaLapseImportError(
        'This is a FaunaLapse video session: import its video files with "Import videos…" instead.',
      );
    }
    final dir = Directory('${sessionsRoot.path}/$folder');
    if (dir.existsSync()) throw FaunaLapseImportError('A session named $folder is already here.');
    final frames = Directory('${dir.path}/roi_frames')..createSync(recursive: true);

    const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
    final seed = log.startMs;
    final token = String.fromCharCodes([for (var i = 0; i < 4; i++) alphabet.codeUnitAt((seed ~/ (1 << (5 * i))) % 36)]);
    final logger = SessionLogger(File('${dir.path}/session.jsonl'))..open();
    final start = log.start;
    logger.logStart({
      'session_id': '${log.startMs}',
      'file_token': token,
      'source': 'faunalapse',
      'imported_at': isoWithOffset(DateTime.now()),
      'config': faunaLapseConfig(log, folder).toJson(),
      'device': {'manufacturer': (start['field'] as Map?)?['phone_maker'], 'model': (start['field'] as Map?)?['phone_model']},
      if (faunaLapseLocation(start) case final Map<String, dynamic> loc) 'location': loc,
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
    for (final p in log.photos) {
      final src = entries['$folder/${p.file}'];
      if (src == null) {
        missing++;
        continue;
      }
      final name = roiPhotoFileName(p.takenAtMs, token);
      final out = OutputFileStream('${frames.path}/$name');
      src.writeContent(out);
      await out.close();
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
    }, at: DateTime.fromMillisecondsSinceEpoch(log.endMs ?? lastPhoto));
    await logger.close();
    return FaunaLapseImportResult(folder, written, missing, sitePhotos);
  } finally {
    for (final s in streams) {
      await s.close();
    }
  }
}
