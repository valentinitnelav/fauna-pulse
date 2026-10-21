// Shared helpers of the parser fuzz tests in this folder (stress run, round
// "P2"). Not a test itself (no _test suffix). Everything is seeded: the same
// seed always gives the same mutated files, so a failing case can be
// replayed. Sizes are capped (no mutated file is larger than a few MB).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// One mutated file: a short name for the kind of damage, and its bytes.
typedef Mutant = (String, Uint8List);

/// Wrong values a field may hold when a file was edited by hand, written by
/// another app version or damaged.
const List<Object?> kWrongValues = [
  null,
  '',
  'text',
  '1',
  0,
  -1,
  1.5,
  true,
  false,
  <Object?>[],
  <String, Object?>{},
  <Object?>[1, 2],
  <String, Object?>{'a': 1},
  4294967296,
  -4294967296,
];

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Byte-level damage of [source] (a JSONL or JSON file): the empty file, a
/// BOM, CRLF line ends, a cut at a random byte, flipped bytes, repeated
/// lines, invalid UTF-8, NUL bytes, one very long line, deep nesting.
/// [perKind] random variants of each random kind. A very long line is
/// capped at [longLineBytes].
List<Mutant> byteMutants(Uint8List source, Random rnd, {int perKind = 20, int longLineBytes = 1 << 20}) {
  final out = <Mutant>[];
  final text = utf8.decode(source, allowMalformed: true);
  final lines = const LineSplitter().convert(text);

  out.add(('empty file', Uint8List(0)));
  out.add(('only newlines', _utf8('\n\n\n\n')));
  out.add(('BOM + original', Uint8List.fromList([0xEF, 0xBB, 0xBF, ...source])));
  out.add(('CRLF line ends', _utf8('${lines.join('\r\n')}\r\n')));
  out.add(('no final newline', _utf8(lines.join('\n'))));
  out.add(('NUL bytes appended', Uint8List.fromList([...source, 0, 0, 0, 0, 10])));
  out.add(('whole file is one NUL run', Uint8List(4096)));
  out.add(('deep nesting line', _utf8('${'[' * 50000}${']' * 50000}\n$text')));
  out.add(('deep object nesting line', _utf8('${'{"a":' * 20000}1${'}' * 20000}\n$text')));
  out.add(('long line, no newline', Uint8List.fromList([...source, ..._utf8('{"type":"x","v":"'), ...List.filled(longLineBytes, 0x61)])));
  out.add((
    'long valid line',
    _utf8('$text\n{"type":"note","v":"${'a' * longLineBytes}"}\n'),
  ));
  out.add(('lone newline-less garbage', _utf8('}{][,,,"\u0000')));
  out.add(('invalid UTF-8 first', Uint8List.fromList([0xFF, 0xFE, 0xC0, 0x80, 10, ...source])));

  for (var i = 0; i < perKind; i++) {
    // Cut at a random byte (the crash case: a half-written last line).
    final cut = source.isEmpty ? 0 : rnd.nextInt(source.length + 1);
    out.add(('cut at byte $cut', Uint8List.sublistView(source, 0, cut)));
  }
  for (var i = 0; i < perKind; i++) {
    final b = Uint8List.fromList(source);
    final n = 1 + rnd.nextInt(8);
    for (var k = 0; k < n && b.isNotEmpty; k++) {
      b[rnd.nextInt(b.length)] = rnd.nextInt(256);
    }
    out.add(('flip $n bytes #$i', b));
  }
  for (var i = 0; i < perKind; i++) {
    // Invalid UTF-8 inside the file.
    final b = BytesBuilder();
    final at = source.isEmpty ? 0 : rnd.nextInt(source.length);
    b.add(Uint8List.sublistView(source, 0, at));
    const bad = [
      [0xFF],
      [0xC0, 0x80],
      [0x80],
      [0xE2, 0x82],
      [0xF0, 0x9F, 0x90],
      [0xED, 0xA0, 0x80],
    ];
    b.add(bad[rnd.nextInt(bad.length)]);
    b.add(Uint8List.sublistView(source, at));
    out.add(('invalid UTF-8 at byte $at', b.toBytes()));
  }
  for (var i = 0; i < perKind && lines.isNotEmpty; i++) {
    // Repeat and drop whole lines.
    final l = List<String>.of(lines);
    final k = 1 + rnd.nextInt(4);
    for (var j = 0; j < k; j++) {
      final from = rnd.nextInt(l.length);
      l.insert(rnd.nextInt(l.length + 1), l[from]);
    }
    out.add(('repeat $k lines #$i', _utf8('${l.join('\n')}\n')));
    final d = List<String>.of(lines)..removeAt(rnd.nextInt(lines.length));
    out.add(('drop one line #$i', _utf8('${d.join('\n')}\n')));
  }
  return out;
}

/// JSON-level damage of the lines of a JSONL file: in one random line a
/// random value is replaced by a value of another type ([kWrongValues]), or
/// and sometimes (1 case in 6) one more number by a number too large for 64 bits. Each result is the
/// full list of lines. Lines that are not JSON are copied unchanged.
List<(String, List<String>)> typeMutants(List<String> lines, Random rnd, {int count = 200}) {
  final out = <(String, List<String>)>[];
  if (lines.isEmpty) return out;
  for (var i = 0; i < count; i++) {
    final idx = rnd.nextInt(lines.length);
    final line = lines[idx];
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      continue;
    }
    // Collect every value position as a path.
    final paths = <List<Object>>[];
    void walk(Object? v, List<Object> path) {
      paths.add(path);
      if (v is Map) {
        for (final k in v.keys) {
          walk(v[k], [...path, k as String]);
        }
      } else if (v is List) {
        for (var j = 0; j < v.length && j < 12; j++) {
          walk(v[j], [...path, j]);
        }
      }
    }

    walk(decoded, const []);
    final path = paths[rnd.nextInt(paths.length)];
    final wrong = kWrongValues[rnd.nextInt(kWrongValues.length)];
    final replaced = _replaceAt(decoded, path, wrong);
    var text = jsonEncode(replaced);
    var label = 'line $idx, ${path.isEmpty ? 'whole record' : path.join('.')} := ${jsonEncode(wrong)}';
    if (rnd.nextInt(6) == 0) {
      // A number outside 64 bits ("1e999" reads as infinity in Dart).
      final huge = const ['1e999', '-1e999', '99999999999999999999999', '1e30'][rnd.nextInt(4)];
      final m = RegExp(r'(?<=[:\[,])-?\d+(\.\d+)?(?=[,}\]])').allMatches(text).toList();
      if (m.isNotEmpty) {
        final pick = m[rnd.nextInt(m.length)];
        text = text.replaceRange(pick.start, pick.end, huge);
        label = '$label; AND number at ${pick.start} := $huge';
      }
    }
    final copy = List<String>.of(lines)..[idx] = text;
    out.add((label, copy));
  }
  return out;
}

Object? _replaceAt(Object? v, List<Object> path, Object? wrong) {
  if (path.isEmpty) return wrong;
  final head = path.first;
  final rest = path.sublist(1);
  if (v is Map && head is String) {
    return {
      for (final e in v.entries) e.key: e.key == head ? _replaceAt(e.value, rest, wrong) : e.value,
    };
  }
  if (v is List && head is int) {
    return [
      for (var i = 0; i < v.length; i++) i == head ? _replaceAt(v[i], rest, wrong) : v[i],
    ];
  }
  return v;
}

/// What a fuzz loop found: one entry per distinct (error type, message start)
/// with the first mutation that caused it.
class FuzzReport {
  final Map<String, String> _first = {};
  final Map<String, int> _count = {};
  int cases = 0;
  Duration slowest = Duration.zero;
  String slowestCase = '';

  /// Records one case. [error] null = the parser returned. [okErrors] are the
  /// error types the parser documents (usually FormatException).
  void add(String caseName, Object? error, Duration took, {bool Function(Object e)? ok}) {
    cases++;
    if (took > slowest) {
      slowest = took;
      slowestCase = caseName;
    }
    if (error == null || (ok != null && ok(error))) return;
    final msg = '$error'.replaceAll(RegExp(r'\s+'), ' ');
    final key = '${error.runtimeType}: ${msg.length > 90 ? msg.substring(0, 90) : msg}';
    _first.putIfAbsent(key, () => caseName);
    _count[key] = (_count[key] ?? 0) + 1;
  }

  bool get clean => _first.isEmpty;

  @override
  String toString() =>
      'cases=$cases slowest=${slowest.inMilliseconds} ms ($slowestCase)\n'
      '${_first.entries.map((e) => '  ${_count[e.key]}x ${e.key}\n      first: ${e.value}').join('\n')}';
}
