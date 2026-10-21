// FaunaPulse (round 319, part 3): a small note in the app's files folder that keeps a chained
// identification ("Also identify them") when Android closes the app.
//
// While such a run waits for the app (too little free memory in the background) or loads its
// model in the background, it lives only in memory: on the 3.6 GB test phone MIUI's cleaner closed
// the waiting app after 62 s, and a tap on "Animals found" then opened Home with nothing started.
// The run writes this note first ([write]); Home reads it when the app opens or comes to the front
// ([takeOnOpen]) and starts the run again. `attempts` is set to 1 BEFORE that start, so a start
// during which the app is closed again is not repeated by itself: the next opening only says that
// the identification did not finish. The run's end deletes the note ([clear]), as does deleting
// the session.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_error_hooks.dart';
import '../services/analysis_keepalive.dart';

/// What the next opening does with a note: start the run again, or say that it did not finish.
typedef WaitingIdentification = ({Directory sessionDir, String? chain, bool start});

class IdentifyWaitNote {
  IdentifyWaitNote._();

  static const String fileName = 'identify_waiting.json';

  /// An older note is deleted without a start: a run that starts by itself a day later would
  /// surprise the user.
  static const Duration maxAge = Duration(hours: 24);

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/$fileName');
  }

  /// Writes the note for [sessionDir] ([chain]: "videos" or "photos", the Find screen that started
  /// it). False when it could not be written; never throws.
  static Future<bool> write(
    Directory sessionDir, {
    required String? chain,
    required int attempts,
    DateTime? created,
  }) async {
    try {
      final f = await _file();
      // Written aside and renamed: a kill while writing leaves the old note or none, never half.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'session_dir': sessionDir.path,
          'created': (created ?? DateTime.now()).toUtc().toIso8601String(),
          'chain': chain,
          'attempts': attempts,
        }),
        flush: true,
      );
      await tmp.rename(f.path);
      return true;
    } catch (e) {
      logSwallowed('identify_wait_note_write', e);
      return false;
    }
  }

  /// The note (empty when it cannot be read), or null when there is none.
  @visibleForTesting
  static Future<Map<String, dynamic>?> read() async {
    final File f;
    try {
      f = await _file();
      if (!await f.exists()) return null;
    } catch (e) {
      logSwallowed('identify_wait_note_read', e);
      return null;
    }
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, dynamic> ? j : {};
    } catch (e) {
      logSwallowed('identify_wait_note_read', e);
      return {};
    }
  }

  static Future<void> _delete() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (e) {
      logSwallowed('identify_wait_note_delete', e);
    }
  }

  /// Deletes the note when it is about [sessionDir] (a note of another session stays). Never
  /// throws.
  static Future<void> clear(Directory sessionDir) async {
    final j = await read();
    if (j != null && j['session_dir'] == sessionDir.path) await _delete();
  }

  /// When the app opens or comes to the front, with no identification going on: what to do with
  /// the note. Null: nothing (no note, too old, its session is gone; such a note is deleted). Else
  /// the note was taken: with `start`, `attempts` is 1 on disk already; without, it is deleted.
  /// The "Animals found" notification is removed in every case with a note.
  static Future<WaitingIdentification?> takeOnOpen() async {
    final j = await read();
    if (j == null) return null;
    await AnalysisKeepAlive.cancelIdentifyReminder();
    final path = j['session_dir'];
    final created = DateTime.tryParse('${j['created']}');
    final attempts = j['attempts'] is num ? (j['attempts'] as num).toInt() : 1;
    final chain = j['chain'] is String ? j['chain'] as String : null;
    final age = created == null ? null : DateTime.now().difference(created).abs();
    if (path is! String || age == null || age > maxAge || !await Directory(path).exists()) {
      debugPrint('identify_wait_note: ignored (${path is String ? 'age ${age?.inMinutes} min' : 'unreadable'})');
      await _delete();
      return null;
    }
    final dir = Directory(path);
    if (attempts >= 1) {
      debugPrint('identify_wait_note: the app was closed during the last start; not started again');
      await _delete();
      return (sessionDir: dir, chain: chain, start: false);
    }
    // Not started when the count cannot be saved: a start that closes the app would then repeat.
    if (!await write(dir, chain: chain, attempts: attempts + 1, created: created)) {
      await _delete();
      return (sessionDir: dir, chain: chain, start: false);
    }
    debugPrint('identify_wait_note: the app was closed while the identification waited; it starts again');
    return (sessionDir: dir, chain: chain, start: true);
  }
}
