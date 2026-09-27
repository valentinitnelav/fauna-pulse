// FaunaPulse (round 229): which file holds a session's visits.
//
// A live AI session follows insects while it records: its visits are the
// `detections` records inside session.jsonl. Imported videos are followed
// afterwards, on the "Run AI on videos" screen: their visits are in
// post_tracks.jsonl (video_tracker.dart). Every reader of visits (summary,
// dashboard, identification) asks trackSourceOf which file to read and reads
// only that one. The two are never mixed: a session with both (live AI plus
// a video, a later option) would otherwise count every insect twice.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The visits file written by "Find visits" (video_tracker.dart).
const postTracksFileName = 'post_tracks.jsonl';

enum TrackSource {
  /// Tracked while recording (session.jsonl).
  live,

  /// Found afterwards from the session's videos (post_tracks.jsonl).
  afterwards,
}

/// Did the live tracker run? `captureTrigger` exists since round 97
/// ('detector' | 'motion' | 'timelapse'); before that the r95
/// `motionOnlyCapture` bool marks the only no-AI mode; anything older is
/// always an AI session. No readable config (an imported-video session, or a
/// start record lost to a crash) means no live tracker.
bool liveTrackerRan(dynamic config) {
  if (config is! Map) return false;
  final trigger = config['captureTrigger'];
  if (trigger is String) return trigger == 'detector';
  return config['motionOnlyCapture'] != true;
}

/// Afterwards when [sessionDir] has a post_tracks.jsonl and its live tracker
/// never ran; live otherwise. Reads only the head of session.jsonl.
TrackSource trackSourceOf(Directory sessionDir) {
  if (!File('${sessionDir.path}/$postTracksFileName').existsSync()) {
    return TrackSource.live;
  }
  return liveTrackerRan(_startConfig(File('${sessionDir.path}/session.jsonl')))
      ? TrackSource.live
      : TrackSource.afterwards;
}

/// The file [trackSourceOf] points at.
File tracksFileOf(Directory sessionDir) =>
    trackSourceOf(sessionDir) == TrackSource.afterwards
    ? File('${sessionDir.path}/$postTracksFileName')
    : File('${sessionDir.path}/session.jsonl');

/// The start record's `config`, from the first 64 KB of the log (the start
/// record is its first line), or null.
dynamic _startConfig(File log) {
  try {
    final raf = log.openSync();
    try {
      final head = utf8.decode(
        raf.readSync(min(65536, raf.lengthSync())),
        allowMalformed: true,
      );
      for (final line in const LineSplitter().convert(head)) {
        if (!line.contains('"start_of_session"')) continue;
        return (jsonDecode(line) as Map)['config'];
      }
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    // Missing or unreadable log: no config.
  }
  return null;
}
