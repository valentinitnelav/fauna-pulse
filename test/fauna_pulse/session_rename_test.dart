// Unit tests for renameSession (round 182): the folder is renamed, the start
// record's config.folderName is updated in place, every other line stays
// byte-identical, and a `session_renamed` audit record documents the change.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/logging/session_rename.dart';

const _startLine =
    '{"type":"start_of_session","time_ms":1000,"session_id":"1000",'
    '"config":{"folderName":"session","confidenceThreshold":0.25}}';
const _detLine =
    '{"type":"detections","time_ms":2000,"frame_ms":2000,"tracks":[]}';
const _endLine =
    '{"type":"end_of_session","time_ms":3000,"ended_normally":true}';

Directory _makeSession(
  Directory root,
  String name, {
  List<String> lines = const [_startLine, _detLine, _endLine],
  bool withLog = true,
}) {
  final dir = Directory('${root.path}/$name')..createSync(recursive: true);
  if (withLog) {
    File('${dir.path}/session.jsonl').writeAsStringSync('${lines.join('\n')}\n');
  }
  return dir;
}

List<Map<String, dynamic>> _records(Directory dir) =>
    File('${dir.path}/session.jsonl')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rename_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('renames the folder, updates folderName, appends the audit record',
      () async {
    final dir = _makeSession(tmp, 'session_3');
    final photo = File('${dir.path}/roi_frames/roi_ab12_x.jpg')
      ..createSync(recursive: true);

    final newDir = await renameSession(dir, 'campanula south');

    expect(newDir.path, '${tmp.path}/campanula south');
    expect(dir.existsSync(), isFalse);
    // Photos moved with the folder, names untouched.
    expect(photo.existsSync(), isFalse);
    expect(
      File('${newDir.path}/roi_frames/roi_ab12_x.jpg').existsSync(),
      isTrue,
    );

    final recs = _records(newDir);
    expect(recs, hasLength(4));
    expect(recs[0]['type'], 'start_of_session');
    expect((recs[0]['config'] as Map)['folderName'], 'campanula south');
    // Untouched fields survive the re-encode; other lines are unchanged.
    expect((recs[0]['config'] as Map)['confidenceThreshold'], 0.25);
    expect(jsonEncode(recs[1]), jsonEncode(jsonDecode(_detLine)));
    expect(recs[2]['type'], 'end_of_session');
    expect(recs[3]['type'], 'session_renamed');
    expect(recs[3]['old_name'], 'session_3');
    expect(recs[3]['new_name'], 'campanula south');
    expect(recs[3]['time_ms'], isA<int>());
    expect(recs[3]['time_iso'], isA<String>());
  });

  test('sanitizes filesystem-unsafe characters the recorder would refuse',
      () async {
    final dir = _makeSession(tmp, 'a');
    final newDir = await renameSession(dir, ' bee/visits*июль ');
    // '/', '*' and the four Cyrillic letters each become one '_'.
    expect(newDir.path.split('/').last, 'bee_visits_____');
  });

  test('rejects an empty name and a name that only sanitizes to nothing', () {
    final dir = _makeSession(tmp, 'a');
    expect(() => renameSession(dir, '   '), throwsA(isA<SessionRenameException>()));
  });

  test('rejects a name an existing session already uses', () {
    _makeSession(tmp, 'taken');
    final dir = _makeSession(tmp, 'a');
    expect(
      () => renameSession(dir, 'taken'),
      throwsA(isA<SessionRenameException>()),
    );
    // The original is untouched by the failed attempt.
    expect(dir.existsSync(), isTrue);
  });

  test('same name (after sanitizing) is a no-op', () async {
    final dir = _makeSession(tmp, 'my session');
    final newDir = await renameSession(dir, '  my session ');
    expect(newDir.path, dir.path);
    // No audit record for a no-op.
    expect(_records(dir), hasLength(3));
  });

  test('a folder without session.jsonl still renames (crashed session)',
      () async {
    final dir = _makeSession(tmp, 'a', withLog: false);
    final newDir = await renameSession(dir, 'b');
    expect(newDir.existsSync(), isTrue);
    expect(File('${newDir.path}/session.jsonl').existsSync(), isFalse);
  });

  test('a truncated start record stays byte-identical; audit still appended',
      () async {
    const broken = '{"type":"start_of_session","time_ms":1000,"conf';
    final dir = _makeSession(tmp, 'a', lines: const [broken, _detLine]);
    final newDir = await renameSession(dir, 'b');
    final lines = File('${newDir.path}/session.jsonl').readAsLinesSync();
    expect(lines[0], broken);
    expect(
      (jsonDecode(lines[2]) as Map<String, dynamic>)['type'],
      'session_renamed',
    );
  });
}
