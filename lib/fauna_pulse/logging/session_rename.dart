// FaunaPulse — post-hoc rename of a recorded session (round 182).
//
// A session's identity is its folder name under `sessions/`. The owner
// requirement is that a rename updates the name EVERYWHERE it appears,
// especially in the session's text outputs. The name lives in exactly three
// places:
//   1. the folder itself — what the home list, the summary's "Saved to" path
//      and every fresh scan show;
//   2. `config.folderName` inside the start record of session.jsonl — what
//      the summary's Setup tab shows and what pandas/R scripts read;
//   3. nothing else: photo files and post_detections.jsonl reference photos
//      by bare file name (never the folder), and the gallery-export album
//      name is derived from the folder at export time.
// Besides updating (2) in place, a `session_renamed` audit record is
// appended (old name, new name, when): the log is otherwise append-only, and
// an undocumented history edit would be bad science. Parsers that skip
// unknown record types are unaffected.
//
// The rewrite is crash-safe: the updated log is written to a temp file in
// the same folder and atomically renamed over session.jsonl, so a crash
// mid-rewrite leaves the original log intact.

import 'dart:convert';
import 'dart:io';

import 'session_logger.dart' show isoWithOffset;

/// Mirrors `SessionRecorder._resolveSessionDir`'s sanitisation, so a renamed
/// folder can never contain characters a fresh recording would have refused:
/// anything outside letters, digits, `_`, `-` and space becomes `_`.
String sanitizeSessionName(String raw) =>
    raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '_');

/// A rename that could not be performed; [message] is user-showable.
class SessionRenameException implements Exception {
  final String message;
  const SessionRenameException(this.message);
  @override
  String toString() => message;
}

/// Renames [sessionDir] (a folder containing session.jsonl) to [newName]
/// and updates the name inside the log (see the file comment for the full
/// list of places). Returns the renamed directory. A no-op when the
/// sanitised new name equals the current one. Throws [SessionRenameException]
/// with a plain-language message when the rename cannot be done.
Future<Directory> renameSession(Directory sessionDir, String newName) async {
  final safe = sanitizeSessionName(newName);
  if (safe.isEmpty) {
    throw const SessionRenameException('The session name cannot be empty.');
  }
  final oldName = sessionDir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  if (safe == oldName) return sessionDir;
  final targetPath = '${sessionDir.parent.path}/$safe';
  if (Directory(targetPath).existsSync() || File(targetPath).existsSync()) {
    throw SessionRenameException('A session called "$safe" already exists.');
  }
  if (!sessionDir.existsSync()) {
    throw const SessionRenameException(
      'The session folder no longer exists (was it deleted or moved?).',
    );
  }

  // 1. The folder — the primary identity.
  final Directory newDir;
  try {
    newDir = await sessionDir.rename(targetPath);
  } catch (e) {
    throw SessionRenameException('Could not rename the folder: $e');
  }

  // 2 + audit record. The folder rename above already succeeded; a failure
  // here leaves a renamed session whose log still carries the old name,
  // which the error message says so the user can simply rename again.
  try {
    await _updateLog(File('${newDir.path}/session.jsonl'), oldName, safe);
  } catch (e) {
    throw SessionRenameException(
      'The folder was renamed, but its data log could not be updated ($e). '
      'Renaming the session again will retry the log update.',
    );
  }
  return newDir;
}

/// Streams session.jsonl to a temp file, updating `config.folderName` in the
/// start record and appending the `session_renamed` audit record, then
/// atomically replaces the original. Missing log = nothing to update (a
/// crashed session may have an empty folder); missing/unparsable start
/// record or config block = the audit record is still appended.
Future<void> _updateLog(File log, String oldName, String newName) async {
  if (!log.existsSync()) return;
  final tmp = File('${log.path}.rename_tmp');
  final sink = tmp.openWrite();
  var startUpdated = false;
  try {
    final lines = log
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      var out = line;
      if (!startUpdated && line.contains('"start_of_session"')) {
        startUpdated = true; // only the first start record is touched
        try {
          final rec = jsonDecode(line) as Map<String, dynamic>;
          final config = rec['config'];
          if (config is Map<String, dynamic> &&
              config.containsKey('folderName')) {
            config['folderName'] = newName;
            out = jsonEncode(rec);
          }
        } catch (_) {
          // A line truncated by a crash stays byte-identical.
        }
      }
      sink.writeln(out);
    }
    final now = DateTime.now();
    sink.writeln(
      jsonEncode({
        'type': 'session_renamed',
        'time_ms': now.millisecondsSinceEpoch,
        'time_iso': isoWithOffset(now),
        'old_name': oldName,
        'new_name': newName,
      }),
    );
    await sink.flush();
    await sink.close();
    await tmp.rename(log.path); // atomic within the same folder
  } catch (e) {
    // Leave the original log untouched; remove the partial temp file.
    try {
      await sink.close();
    } catch (_) {}
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
    rethrow;
  }
}
