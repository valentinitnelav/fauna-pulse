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
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import '../capture/photo_header.dart';
import '../capture/roi_capture.dart' show roiPhotoFileName;
import '../logging/device_storage.dart' show formatBytes, freeStorageClause;
import '../logging/session_logger.dart';
import '../logging/session_rename.dart' show sanitizeSessionName;
import '../models/model_file_security.dart' show isNoSpaceLeft;
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
  final reader = _LogReader();
  lines.forEach(reader.add);
  return reader.finish();
}

/// [parseFaunaLapseLog] one line at a time, so the import never holds the whole record.
class _LogReader {
  Map<String, dynamic>? start;
  Map<String, dynamic>? end;
  final photos = <FaunaLapsePhoto>[];
  var burst = -1;

  void add(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> r;
    try {
      r = (jsonDecode(line) as Map).cast<String, dynamic>();
    } catch (_) {
      return; // a cut-off last line
    }
    switch (r['event']) {
      case 'session_start':
        start ??= r;
      case 'burst_start':
        burst++;
      case 'photo':
        final t = DateTime.tryParse('${r['time']}');
        final file = r['file'];
        if (t == null || file is! String || r['error'] != null) return;
        // Type check, not a cast: this runs outside the try above, so a cast would let one
        // hand-edited line (size as text) reject the whole record. The photo itself is real,
        // so keep it and only drop the size (it is just copied into the frame line).
        final px = r['saved_side_px'];
        photos.add(FaunaLapsePhoto(file, t.millisecondsSinceEpoch, px is num ? px.toInt() : null, burst < 0 ? 0 : burst));
      case 'session_end':
        end = r;
    }
  }

  FaunaLapseLog? finish() {
    final s = start;
    if (s == null || DateTime.tryParse('${s['time']}') == null) return null;
    return FaunaLapseLog(s, photos, end);
  }
}

/// Limits for a zip that someone may have made or changed by hand (round 327): the sizes
/// that a zip states can lie, and a few hundred KB of packed data can unpack to gigabytes (a
/// "zip bomb"). FaunaLapse stores its photos unpacked, at most 4096 px square (a few MB), and
/// its record holds about 210 bytes per photo. A session can be long (steps from 0.2 s, runs up
/// to 720 h): one million photos is eleven days at one photo per second, a 210 MB record. The
/// import then holds about 0.8 KB per photo in memory (the zip's list of entries and the
/// record's photo lines), so one million photos take about 800 MB.
const kMaxFaunaLapseRecordBytes = 256 << 20;
const kMaxFaunaLapsePhotoBytes = 64 << 20;
const kMaxFaunaLapsePhotos = 1000000;

/// Site photos come from the phone's camera app at full size, so they get more room; they are
/// streamed to their file, never held in memory whole.
const _maxSitePhotoBytes = 512 << 20;

/// Free storage that an import leaves for everything else, so the phone is never filled to
/// the last byte (other apps still need to save).
const _storageReserveBytes = 50 << 20;

/// FaunaLapse's longest record line, the session start with the field notes, has a few KB (its
/// notes are capped at 5,000 characters).
const _maxRecordLineBytes = 256 << 10;

/// FaunaLapse folder names have about 30 characters; a longer one comes from a hand-made zip.
const _maxFolderNameLength = 80;

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
  /// Photos left out because their bytes did not match the checksum stored in the zip, they
  /// could not be unpacked, they are not photos, or they are far too large for a photo (over
  /// 64 MB or 120 MP).
  final int damagedPhotos;

  /// Site photos left out for the same reasons (over 512 MB instead of 64 MB).
  final int damagedSitePhotos;
  const FaunaLapseImportResult(
    this.folder,
    this.photos,
    this.missingPhotos,
    this.sitePhotos, {
    this.damagedPhotos = 0,
    this.damagedSitePhotos = 0,
  });
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
Future<FaunaLapseImportResult> importFaunaLapseZipsInBackground(
  List<String> zipPaths,
  Directory sessionsRoot, {
  int? freeBytes,
}) => Isolate.run(() => importFaunaLapseZips(zipPaths, sessionsRoot, freeBytes: freeBytes));

/// Imports the zips of ONE FaunaLapse photo session (all its parts) into [sessionsRoot].
/// Throws [FaunaLapseImportError] with a plain reason. Runs fine in a background isolate.
/// [freeBytes]: the free storage where [sessionsRoot] lives, read by the caller (reading it
/// needs a platform channel, which a background isolate does not have); null skips the check.
Future<FaunaLapseImportResult> importFaunaLapseZips(
  List<String> zipPaths,
  Directory sessionsRoot, {
  int? freeBytes,
}) async {
  // Every file entry of every zip, by its path inside the zip.
  final entries = <String, ZipFile>{};
  final streams = <InputFileStream>[];
  // The new session folder while it is only partly written, and its record. Any error after
  // the folder is made (disk full while copying photos) must remove it again (see the finally
  // below): a leftover folder blocks the next try with "already here".
  Directory? halfMade;
  SessionLogger? logger;
  try {
    for (final p in zipPaths) {
      final input = InputFileStream(p);
      streams.add(input);
      // The zip's list of entries only, not ZipDecoder: while it reads the list, the decoder
      // also unpacks every entry marked as a link into memory (package:archive 4.0.9), with no
      // size limit. FaunaLapse writes no links, and the entries used are unpacked by [_unpack].
      final zip = ZipDirectory();
      try {
        zip.read(input);
      } catch (_) {
        throw FaunaLapseImportError('${p.split('/').last} is not a readable zip file.');
      }
      for (final h in zip.fileHeaders) {
        // The size from the zip's central directory: when the size also follows the data (zips
        // written as a stream), ZipFile reads it there as a 32-bit number, so a zip64 entry
        // would read as 0 bytes and be refused.
        final f = h.file?..uncompressedSize = h.uncompressedSize;
        if (f != null && !f.filename.endsWith('/')) entries[f.filename] = f;
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
    final record = entries['$folder/session.jsonl']!;
    // Read line by line as it unpacks, so the record is never in memory as a whole. Damaged
    // compressed data (bad SD card, broken copy) or a record that is not UTF-8 throws here; the
    // user should get a plain reason instead. Nothing is written yet, so nothing to clean up.
    final FaunaLapseLog? log;
    try {
      final reader = _LogReader();
      final text = utf8.decoder.startChunkedConversion(
        const LineSplitter().startChunkedConversion(
          _EachSink<String>((line) {
            reader.add(line);
            if (reader.photos.length > kMaxFaunaLapsePhotos) throw const _TooLarge();
          }),
        ),
      );
      // A line longer than any FaunaLapse line is refused before the JSON reader sees it: a long
      // line of "[" would make jsonDecode build one list per bracket (about 3.3 GB for 63 MB).
      // The checksum is counted on the way: damage inside a stored record would otherwise drop
      // photo lines silently (dart:io's zlib also returns cut data without an error).
      var lineBytes = 0;
      var crc = 0;
      _unpack(record, kMaxFaunaLapseRecordBytes, (chunk) {
        for (final b in chunk) {
          lineBytes = b == 0x0A ? 0 : lineBytes + 1;
          if (lineBytes > _maxRecordLineBytes) throw const _TooLarge();
        }
        crc = getCrc32(chunk, crc);
        text.add(chunk);
      });
      text.close();
      if (crc != record.crc32) throw const FormatException('the record does not match its checksum');
      log = reader.finish();
    } on _TooLarge {
      throw FaunaLapseImportError(
        'The session record (session.jsonl) is too large to import (over '
        '${kMaxFaunaLapseRecordBytes >> 20} MB, more than ${_count(kMaxFaunaLapsePhotos)} photos, or a line '
        'over ${_maxRecordLineBytes >> 10} KB). FaunaPulse imports FaunaLapse sessions of up to '
        '${_count(kMaxFaunaLapsePhotos)} photos (for example eleven days at one photo per second).',
      );
    } on _Unreadable catch (e) {
      throw FaunaLapseImportError(
        'The session record (session.jsonl) cannot be read: ${e.message}. FaunaLapse never packs '
        'its zips this way.',
      );
    } catch (_) {
      throw const FaunaLapseImportError('The session record (session.jsonl) is damaged and cannot be read.');
    }
    if (log == null) throw const FaunaLapseImportError('The session record is not a FaunaLapse record.');
    if (log.isVideo) {
      throw const FaunaLapseImportError(
        'This is a FaunaLapse video session: import its video files with "Import videos…" instead.',
      );
    }
    final name = _sessionFolderName(folder);
    final dir = Directory('${sessionsRoot.path}/$name');
    if (dir.existsSync()) throw FaunaLapseImportError('A session named $name is already here.');
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
      config = faunaLapseConfig(log, name).toJson();
      location = faunaLapseLocation(start);
      final field = start['field'] as Map?;
      device = {'manufacturer': field?['phone_maker'], 'model': field?['phone_model']};
    } on TypeError {
      throw const FaunaLapseImportError('The session record has a value of the wrong kind (it may have been edited by hand).');
    }
    // The site photos to copy. Zip slip guard: zip names are untrusted text, so a hand-made zip
    // with `site_photos/../../x` would write (or overwrite) files of other sessions or models.
    // FaunaLapse never writes such names, so skip the entry instead of failing the whole import
    // (the time-lapse photos matter more). A plain segment check, because package:path is not
    // a direct dependency.
    final siteEntries = <String, ZipFile>{
      for (final e in entries.entries)
        if (e.key.startsWith('$folder/site_photos/') && _isSafeRelativePath(e.key.substring(folder.length + 1)))
          e.key.substring(folder.length + 1): e.value,
    };
    // Each zip entry is copied at most once: FaunaLapse writes one line per photo, and a
    // hand-made record naming one entry thousands of times would otherwise write thousands of
    // copies until the storage is full.
    final firstUse = <String>{};
    var needed = _onDisk(record.uncompressedSize);
    for (final p in log.photos) {
      final src = entries['$folder/${p.file}'];
      if (src == null || !firstUse.add(p.file) || !_fits(src, kMaxFaunaLapsePhotoBytes)) continue;
      needed += _onDisk(src.uncompressedSize) + 600; // and its two lines in the new record
    }
    for (final e in siteEntries.values) {
      if (_fits(e, _maxSitePhotoBytes)) needed += _onDisk(e.uncompressedSize);
    }
    // From the sizes the zip states; [_unpack] stops any entry that unpacks to more.
    if (freeBytes != null && freeBytes < needed + _storageReserveBytes) {
      throw FaunaLapseImportError(
        'Not enough free storage on this phone: the session needs ${formatBytes(needed)} and '
        '${_storageReserveBytes >> 20} MB must stay free, but ${freeStorageClause(freeBytes, unitOf: needed)}. '
        'Delete some files (for example old sessions), then try again.',
      );
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
    final copied = <String>{};
    // roi_frames/ is new and empty (made above), so names used in this loop are all that exist.
    final usedNames = <String>{};
    for (final p in log.photos) {
      final src = entries['$folder/${p.file}'];
      if (src == null) {
        missing++;
        continue;
      }
      if (!copied.add(p.file)) continue; // see firstUse above
      // [_unpack] does not compare the zip's stored CRC with the data, so bit damage inside a
      // stored JPEG (failing SD card or USB stick, bad transfer) would be copied silently. Check
      // it here and leave such photos out, counted apart from missing ones. A photo is at most
      // 64 MB, so holding one in memory is fine. Done before the name is taken, so names stay
      // compact. A photo whose header gives no picture size (not a JPEG or PNG; FaunaLapse writes
      // JPEGs), or claims more than [kMaxPhotoPixels], is left out the same way: it is no
      // FaunaLapse photo, and "Find animals in photos" could not use it.
      final Uint8List bytes;
      try {
        bytes = _unpackBytes(src, kMaxFaunaLapsePhotoBytes);
      } on _TooLarge {
        damaged++;
        continue;
      } on FormatException {
        damaged++;
        continue;
      }
      final dims = photoDimensions(bytes);
      if (getCrc32(bytes) != src.crc32 || dims == null || !photoFitsPixelLimit(dims)) {
        damaged++;
        continue;
      }
      // roi_ names show local wall-clock time to the millisecond, so two photos can share one:
      // the repeated hour at the end of summer time, a zip imported in another time zone, or a
      // hand-made log. Writing to a used name would silently overwrite the first photo, so move the
      // name on by 1 ms until it is free. captured_at_ms below keeps the true time, and the
      // name keeps the documented roi_ pattern (no suffix), so downstream parsing still works.
      var nameMs = p.takenAtMs;
      var fileName = roiPhotoFileName(nameMs, token);
      while (!usedNames.add(fileName)) {
        fileName = roiPhotoFileName(++nameMs, token);
      }
      File('${frames.path}/$fileName').writeAsBytesSync(bytes);
      final at = DateTime.fromMillisecondsSinceEpoch(p.takenAtMs);
      logger.logTimeLapseCapture({'jpeg': fileName, 'captured_at_ms': p.takenAtMs, 'burst': p.burst, 'original_name': p.file}, at: at);
      logger.logCapture({
        'file': fileName,
        'captured_at_ms': p.takenAtMs,
        'path': 'still',
        'saved_px': p.savedPx,
        'bytes': src.uncompressedSize,
      }, at: at);
      written++;
    }
    // Site photos are streamed to their file and checked against the zip's CRC on the way; a
    // damaged or oversized one is removed again and counted, so the result can say so.
    var sitePhotos = 0;
    var siteLeftOut = 0;
    for (final e in siteEntries.entries) {
      final out = File('${dir.path}/${e.key}');
      final RandomAccessFile raf;
      try {
        out.parent.createSync(recursive: true);
        raf = out.openSync(mode: FileMode.write);
      } on FileSystemException catch (err) {
        // A hand-made zip can name both `site_photos/a` and `site_photos/a/b.jpg`, and one path
        // cannot be a file and a folder: leave such a photo out. A full storage still fails.
        if (isNoSpaceLeft(err)) rethrow;
        siteLeftOut++;
        continue;
      }
      var crc = 0;
      var ok = false;
      try {
        _unpack(e.value, _maxSitePhotoBytes, (chunk) {
          crc = getCrc32(chunk, crc);
          raf.writeFromSync(chunk);
        });
        ok = crc == e.value.crc32;
      } on _TooLarge {
        // left out below
      } on FormatException {
        // left out below
      } finally {
        raf.closeSync();
      }
      if (ok) {
        sitePhotos++;
      } else {
        out.deleteSync();
        siteLeftOut++;
      }
    }
    final keep = File('${dir.path}/faunalapse_session.jsonl').openSync(mode: FileMode.write);
    try {
      _unpack(record, kMaxFaunaLapseRecordBytes, keep.writeFromSync);
    } finally {
      keep.closeSync();
    }
    final lastPhoto = log.photos.isEmpty ? log.startMs : log.photos.last.takenAtMs;
    logger.logEnd({
      'ended_normally': log.end != null,
      'source': 'faunalapse',
      if (log.end?['reason'] != null) 'faunalapse_reason': log.end!['reason'],
      'imported_photos': written,
      if (missing > 0) 'missing_photos': missing,
      if (damaged > 0) 'damaged_photos': damaged,
      if (siteLeftOut > 0) 'damaged_site_photos': siteLeftOut,
    }, at: DateTime.fromMillisecondsSinceEpoch(log.endMs ?? lastPhoto));
    await logger.close();
    halfMade = null; // complete: keep it
    return FaunaLapseImportResult(
      name,
      written,
      missing,
      sitePhotos,
      damagedPhotos: damaged,
      damagedSitePhotos: siteLeftOut,
    );
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

/// The new session's folder: the zip's folder name, cleaned like a typed session name. A
/// hand-made zip may name it anything (a leading dot hides it, a line break splits a list).
String _sessionFolderName(String folder) {
  var safe = sanitizeSessionName(folder);
  if (safe.length > _maxFolderNameLength) safe = safe.substring(0, _maxFolderNameLength).trim();
  // Only letters, digits or spaces make a name; "__" (from "..") would read as an empty one.
  return safe.contains(RegExp(r'[A-Za-z0-9]')) ? safe : 'faunalapse';
}

/// True when [rel] (`site_photos/...`) stays inside the session folder.
bool _isSafeRelativePath(String rel) {
  final parts = rel.split('/');
  return !rel.contains('\\') && !rel.contains('\u0000') && !parts.skip(1).any((s) => s.isEmpty || s == '.' || s == '..');
}

String _count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// True when the size that [f] states is a real size within [limit].
bool _fits(ZipFile f, int limit) => f.uncompressedSize >= 0 && f.uncompressedSize <= limit;

/// What [bytes] take on the phone's storage: whole 4 KB blocks, and one more for the file's own
/// entry (f2fs, the usual Android file system). Over many small photos this adds up to more
/// than the 50 MB kept free.
int _onDisk(int bytes) => ((bytes + 4095) & ~4095) + 4096;

/// An entry that this import cannot unpack at all (a FormatException, so the photo loops
/// count it as damaged; the record reader names the reason).
class _Unreadable extends FormatException {
  const _Unreadable(super.message);
}

/// An entry above the import's size limit (or a record with too many photos).
class _TooLarge implements Exception {
  const _TooLarge();
}

/// Unpacks [f] piece by piece into [onBytes]. Throws [_TooLarge] when the zip states more
/// than [limit] bytes, and a FormatException when the entry unpacks to more than the zip
/// states (so never more than [limit]) or is damaged, and [_Unreadable] when it is locked with a
/// password or packed with bzip2. Not
/// ArchiveFile.content or writeContent: with dart:io, package:archive (4.0.9) collects a
/// whole entry in memory before it hands anything on, whatever size the zip states.
void _unpack(ZipFile f, int limit, void Function(List<int>) onBytes) {
  // A hand-made zip64 size can read as a negative number (package:archive reads 64 bits as a
  // signed int), which would also slip past the storage check ([_fits]).
  if (!_fits(f, limit)) throw const _TooLarge();
  if (f.flags & 1 != 0) throw const _Unreadable('it is locked with a password');
  var seen = 0;
  final out = _EachSink<List<int>>((chunk) {
    // Counted before it is passed on, so a "zip bomb" stops at the stated size.
    if ((seen += chunk.length) > f.uncompressedSize) {
      throw const FormatException('the zip entry unpacks to more than the zip states');
    }
    onBytes(chunk);
  });
  final Sink<List<int>> sink = switch (f.compressionMethod) {
    CompressionType.none => out,
    CompressionType.deflate => ZLibCodec(raw: true).decoder.startChunkedConversion(out),
    CompressionType.bzip2 => throw const _Unreadable('it is packed with bzip2, which this app does not read'),
  };
  final raw = f.getStream(decompress: false);
  final from = raw.position;
  try {
    while (!raw.isEOS) {
      sink.add(raw.readBytes(min(1 << 16, raw.length)).toUint8List());
    }
    sink.close();
  } finally {
    raw.setPosition(from);
  }
}

/// [_unpack] into one byte list (for photos, at most [limit] bytes).
Uint8List _unpackBytes(ZipFile f, int limit) {
  final b = BytesBuilder(copy: false);
  _unpack(f, limit, b.add);
  return b.takeBytes();
}

/// A sink that hands each piece to a function.
class _EachSink<T> implements Sink<T> {
  final void Function(T) _each;
  _EachSink(this._each);
  @override
  void add(T data) => _each(data);
  @override
  void close() {}
}
