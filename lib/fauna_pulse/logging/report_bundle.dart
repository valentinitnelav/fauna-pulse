// FaunaPulse — problem-report bundle (round 191).
//
// Two jobs, both born from an owner field test:
//
//  1. SAMPLING a chosen session's diagnostic files so a report carries what a
//     developer actually needs, not megabytes of redundancy. Measured on the
//     owner's example sessions (2026-08-05): a session.jsonl was 96%
//     per-frame `detections`/`track_event` records (18.7k lines, 6.8 MB);
//     the saved logcat files were 71–93% one repeated CameraX noise line
//     (`updateAcquireFence`) plus per-second PERF/FRAMEPERF lines that
//     duplicate the log's own `fps` records; post_detections.jsonl was 99%
//     per-photo records where only the per-run `post_start`/`post_end`
//     summaries matter. The samplers below keep the rare, high-signal lines
//     (events, errors, config, run summaries) with a bounded head+tail of
//     everything else.
//
//  2. ZIPPING the report .txt + screenshots + samples into ONE file. Sharing
//     several files of MIXED types (text/plain + image/*) makes some targets
//     drop every attachment (WhatsApp delivered only the caption in the
//     owner's test); a single application/zip goes through everywhere.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'app_error_hooks.dart';
import 'error_reporter.dart' show redactLocation;

/// One sampled diagnostic file, ready to become a zip member.
typedef ReportExtra = ({String name, String content});

/// Session-log lines worth carrying in a report: everything EXCEPT the
/// per-frame / per-photo flood types (which dominate the file and are
/// reconstructible from the summary anyway). Unknown/future record types are
/// deliberately KEPT — new diagnostics must never be silently dropped here.
bool keepSessionEventLine(String line) {
  const floodTypes = [
    '"type":"detections"',
    '"type":"detection"',
    '"type":"track_event"',
    '"type":"raw_detections"',
    '"type":"capture"',
    '"type":"gt_capture"',
    '"type":"motion_capture"',
    '"type":"timelapse_capture"',
  ];
  for (final t in floodTypes) {
    if (line.contains(t)) return false;
  }
  return true;
}

/// Logcat lines worth carrying: drops the three measured noise floods —
/// CameraX's repeated `updateAcquireFence` complaint and the app's own
/// per-second PERF / FRAMEPERF telemetry (whose content the session log's
/// `fps` records already carry).
bool keepLogcatLine(String line) =>
    !line.contains('updateAcquireFence') &&
    !line.contains(' PERF ') &&
    !line.contains('FRAMEPERF');

/// Noise filter for the report's LIVE logcat capture (round 192) — only the
/// pure CameraX noise is dropped there. PERF/FRAMEPERF stay: when the user
/// picks "No session data" the live capture is the report's only
/// performance record, so those lines can be the signal.
bool keepLiveLogcatLine(String line) => !line.contains('updateAcquireFence');

/// post_detections.jsonl lines worth carrying: the per-run summaries
/// (`post_start` / `post_end` / `post_cleanup`), not the per-photo records.
bool keepPostDetectionLine(String line) =>
    !line.contains('"type":"post_detection"');

/// Omission marker for `.jsonl` samples (round 192): itself a valid JSON
/// line, so the sampled file parses as real JSON Lines end to end (the owner
/// reads these with pandas — a plain-text marker would break `read_json`).
String jsonlOmissionMarker(int omitted) =>
    '{"type":"sample_omitted","omitted_lines":$omitted}';

/// Streams [file] line by line, keeps only lines passing [keep] (blank lines
/// always dropped), passes each kept line through [map] (e.g. location
/// redaction), and returns the first [head] + last [tail] of them with an
/// omission marker in between ([omissionMarker] overrides the plain-text
/// default — see [jsonlOmissionMarker]). Bounded memory (head list + tail
/// ring buffer), overlong lines capped like the report's other samplers.
/// Returns '' for a missing file and an error note instead of throwing.
Future<String> sampleFilteredFile(
  File file, {
  required bool Function(String) keep,
  String Function(String)? map,
  String Function(int omitted)? omissionMarker,
  int head = 150,
  int tail = 150,
  int maxLineChars = 2000,
}) async {
  if (!file.existsSync()) return '';
  final headLines = <String>[];
  final tailBuf = Queue<String>();
  var omitted = 0;
  try {
    final lines = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final raw in lines) {
      if (raw.trim().isEmpty || !keep(raw)) continue;
      var line = map == null ? raw : map(raw);
      if (line.length > maxLineChars) {
        line = '${line.substring(0, maxLineChars)}…[truncated]';
      }
      if (headLines.length < head) {
        headLines.add(line);
      } else {
        tailBuf.addLast(line);
        if (tailBuf.length > tail) {
          tailBuf.removeFirst();
          omitted++;
        }
      }
    }
  } catch (e) {
    logSwallowed('report_sample_file', e);
    headLines.add('… sampling failed: $e …');
  }
  return [
    ...headLines,
    if (omitted > 0)
      omissionMarker?.call(omitted) ?? '… $omitted lines omitted …',
    ...tailBuf,
  ].join('\n');
}

/// Samples the diagnostic files of [sessionDir] for a report: the session
/// log's event records (flood types filtered out, location redacted), both
/// saved logcat captures (noise filtered), and the post-hoc analysis run
/// summaries when present. Missing files are skipped; sampling never throws.
Future<List<ReportExtra>> collectSessionExtras(Directory sessionDir) async {
  final extras = <ReportExtra>[];
  Future<void> add(
    String fileName,
    String memberName,
    bool Function(String) keep, {
    String Function(String)? map,
    String Function(int)? omissionMarker,
    int head = 150,
    int tail = 150,
  }) async {
    final content = await sampleFilteredFile(
      File('${sessionDir.path}/$fileName'),
      keep: keep,
      map: map,
      omissionMarker: omissionMarker,
      head: head,
      tail: tail,
    );
    if (content.isNotEmpty) extras.add((name: memberName, content: content));
  }

  // Event records: config + end + every rare record (motion_gate,
  // camera_sleep, app_error, roi_update, fps/thermal/power series…).
  // Location is redacted, as in every report sample (protected sites, r126).
  // Member keeps the .jsonl extension (round 192, owner request) — the JSON
  // omission marker keeps the sample valid JSON Lines throughout.
  await add(
    'session.jsonl',
    'session_events_sample.jsonl',
    keepSessionEventLine,
    map: redactLocation,
    omissionMarker: jsonlOmissionMarker,
    head: 100,
    tail: 300,
  );
  await add(
    'logcat_start.txt',
    'logcat_start_sample.txt',
    keepLogcatLine,
  );
  await add('logcat_end.txt', 'logcat_end_sample.txt', keepLogcatLine);
  await add(
    'post_detections.jsonl',
    'post_detections_runs.jsonl',
    keepPostDetectionLine,
    omissionMarker: jsonlOmissionMarker,
    head: 40,
    tail: 40,
  );
  return extras;
}

/// Writes the single shareable bundle: the report text, the screenshot
/// copies and the sampled session files, zipped. Returns the zip file, or
/// null when writing failed (the caller then falls back to the bare .txt).
Future<File?> writeReportZip(
  File zipFile, {
  required File reportTxt,
  List<File> screenshots = const [],
  List<ReportExtra> extras = const [],
}) async {
  try {
    final archive = Archive();
    archive.addFile(
      ArchiveFile.bytes(
        reportTxt.uri.pathSegments.last,
        await reportTxt.readAsBytes(),
      ),
    );
    for (final shot in screenshots) {
      try {
        archive.addFile(
          ArchiveFile.bytes(
            shot.uri.pathSegments.last,
            await shot.readAsBytes(),
          ),
        );
      } catch (e) {
        logSwallowed('report_zip_shot', e);
      }
    }
    for (final extra in extras) {
      archive.addFile(ArchiveFile.string(extra.name, extra.content));
    }
    await zipFile.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    return zipFile;
  } catch (e) {
    logSwallowed('report_zip_write', e);
    return null;
  }
}
