import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// The head of a session.jsonl, for readers that only need the start record
// (its first line, which carries the whole config). A fixed 64 KB read cut a
// start record with long field notes, so the session list showed the file
// time and no duration. These read 64 KB as before and keep reading 64 KB
// chunks only until the first newline, capped at 4 MB so a log without any
// newline is never read in full. Sync and async versions must stay in step.

const _chunk = 65536;
const _maxHead = 4 << 20;

/// The log text from the start up to at least the end of the first line.
String readLogHeadSync(RandomAccessFile raf) {
  raf.setPositionSync(0);
  final len = raf.lengthSync();
  final bytes = BytesBuilder(copy: false);
  while (bytes.length < min(len, _maxHead)) {
    final chunk = raf.readSync(min(_chunk, len - bytes.length));
    if (chunk.isEmpty) break;
    bytes.add(chunk);
    if (chunk.contains(10)) break; // '\n'
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

/// Async twin of [readLogHeadSync]; leaves the file position after the head.
Future<String> readLogHead(RandomAccessFile raf) async {
  await raf.setPosition(0);
  final len = await raf.length();
  final bytes = BytesBuilder(copy: false);
  while (bytes.length < min(len, _maxHead)) {
    final chunk = await raf.read(min(_chunk, len - bytes.length));
    if (chunk.isEmpty) break;
    bytes.add(chunk);
    if (chunk.contains(10)) break; // '\n'
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}
