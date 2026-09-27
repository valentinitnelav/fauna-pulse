// FaunaPulse (round 228): the exports of offline tracking of videos
// (video_tracker.dart), written next to the session's other files.
//
//  * visits.csv: one row per visit (a confirmed track id), for spreadsheets
//    and R. start_s / end_s are seconds from the start of the clip the visit
//    began in (the position a video player shows), so every row can be
//    found in the video; start_time is the wall-clock time. A visit that
//    runs on into the next clip (clips recorded back to back) keeps the
//    first clip's clock, so its end_s can exceed that clip's length.
//  * mot/<clip>.txt: every tracked box in the MOTChallenge text format,
//    `frame,id,x,y,w,h,conf,-1,-1,-1`: frames counted from 1 in display
//    order, box left/top/width/height in video pixels. Tracking benchmarks
//    read it as is; tool/video_eval/mot_to_cvat.py converts it for CVAT.
//
// As in live sessions, a track shows up only once confirmed (after the
// minimum visit length, 0.2 s by default), so the MOT files lack each
// visit's first frames. visits.csv starts a visit at the tracker's first
// sighting, before confirmation; its n_frames counts the boxes in the MOT
// file (from confirmation on).

import 'dart:io';

import '../logging/session_logger.dart' show isoWithOffset;

/// One box of the MOT export: frame counted from 1, box in video pixels.
typedef MotRow = ({int frame, int id, double x, double y, double w, double h, double conf});

/// One visit, built up frame by frame while tracking.
class VideoVisit {
  final int trackId;

  /// Clip the visit began in, and that clip's start (epoch ms).
  final String clip;
  final int clipStartMs;

  /// The tracker's first sighting and last matched frame (epoch ms).
  final int firstSeenMs;
  int lastSeenMs;

  /// Frames with a box from confirmation on (the MOT rows of this id).
  int frames = 0;
  double _confSum = 0;
  final Map<String, int> _classFrames = {};

  VideoVisit({required this.trackId, required this.clip, required this.clipStartMs, required this.firstSeenMs})
    : lastSeenMs = firstSeenMs;

  void addFrame(double confidence, String className) {
    frames++;
    _confSum += confidence;
    _classFrames[className] = (_classFrames[className] ?? 0) + 1;
  }

  double get meanConfidence => frames == 0 ? 0 : _confSum / frames;

  /// The class seen in most frames (the first one on a tie).
  String get className {
    String? best;
    for (final e in _classFrames.entries) {
      if (best == null || e.value > _classFrames[best]!) best = e.key;
    }
    return best ?? '';
  }
}

class TrackExport {
  static const visitsFileName = 'visits.csv';
  static const motDirName = 'mot';

  static String visitsCsv(Iterable<VideoVisit> visits) {
    final sorted = visits.toList()..sort((a, b) => a.trackId.compareTo(b.trackId));
    final b = StringBuffer('track_id,clip,start_time,start_s,end_s,duration_s,n_frames,mean_conf,class\n');
    for (final v in sorted) {
      final startS = (v.firstSeenMs - v.clipStartMs) / 1000;
      final endS = (v.lastSeenMs - v.clipStartMs) / 1000;
      b.writeln(
        [
          v.trackId,
          _csvCell(v.clip),
          isoWithOffset(DateTime.fromMillisecondsSinceEpoch(v.firstSeenMs)),
          startS.toStringAsFixed(3),
          endS.toStringAsFixed(3),
          (endS - startS).toStringAsFixed(3),
          v.frames,
          v.meanConfidence.toStringAsFixed(3),
          _csvCell(v.className),
        ].join(','),
      );
    }
    return b.toString();
  }

  static String motText(Iterable<MotRow> rows) {
    final sorted = rows.toList()
      ..sort((a, b) => a.frame != b.frame ? a.frame.compareTo(b.frame) : a.id.compareTo(b.id));
    final b = StringBuffer();
    for (final r in sorted) {
      b.writeln(
        '${r.frame},${r.id},${r.x.toStringAsFixed(2)},${r.y.toStringAsFixed(2)},'
        '${r.w.toStringAsFixed(2)},${r.h.toStringAsFixed(2)},${r.conf.toStringAsFixed(4)},-1,-1,-1',
      );
    }
    return b.toString();
  }

  /// MOT file name per clip: the clip's name without its extension, or the
  /// full name when two clips share a stem (`a.mp4`, `a.mov`).
  static Map<String, String> motFileNames(Iterable<String> clips) {
    final stems = <String, int>{};
    String stem(String c) => c.contains('.') ? c.substring(0, c.lastIndexOf('.')) : c;
    for (final c in clips) {
      stems[stem(c)] = (stems[stem(c)] ?? 0) + 1;
    }
    return {for (final c in clips) c: '${stems[stem(c)]! > 1 ? c : stem(c)}.txt'};
  }

  /// Writes visits.csv and one MOT file per tracked clip (clips without a
  /// box get an empty file), replacing the previous run's files.
  static Future<void> write(
    Directory sessionDir, {
    required Iterable<VideoVisit> visits,
    required List<String> clips,
    required Map<String, List<MotRow>> mot,
  }) async {
    await writeAtomic(File('${sessionDir.path}/$visitsFileName'), visitsCsv(visits));
    final dir = Directory('${sessionDir.path}/$motDirName');
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.txt'))) {
        f.deleteSync();
      }
    } else {
      dir.createSync(recursive: true);
    }
    final names = motFileNames(clips);
    for (final c in clips) {
      await writeAtomic(File('${dir.path}/${names[c]}'), motText(mot[c] ?? const []));
    }
  }

  /// Writes [content] under a temporary name, then renames it over [file],
  /// so a crash never leaves a half file in place of a good one.
  static Future<void> writeAtomic(File file, String content) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }
}

String _csvCell(Object? v) {
  final s = v == null ? '' : '$v';
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}
