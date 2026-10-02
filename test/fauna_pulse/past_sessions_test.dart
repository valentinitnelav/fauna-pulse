// Round 277: the session list moved out of the home screen
// (logging/past_sessions.dart) and learnt how each session was recorded; the
// Sessions screen's search, filters and order (logging/session_filter.dart).

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart';
import 'package:fauna_pulse/fauna_pulse/logging/session_filter.dart';
import 'package:flutter_test/flutter_test.dart';

PastSession session(
  String name,
  DateTime start, {
  Duration? duration,
  int bytes = 0,
  RecordingKind kind = RecordingKind.liveDetection,
  bool found = false,
  bool identified = false,
}) => PastSession(
  name,
  File('/sessions/$name/session.jsonl'),
  start,
  duration: duration,
  end: duration == null ? null : start.add(duration),
  sizeBytes: bytes,
  kind: kind,
  hasAnalysis: found,
  hasIdentification: identified,
);

void main() {
  test('how a session was recorded, from its start record', () {
    expect(recordingKindOf(null), RecordingKind.liveDetection);
    expect(recordingKindOf({'config': <String, dynamic>{}}), RecordingKind.liveDetection);
    expect(recordingKindOf({'config': {'captureTrigger': 'detector'}}), RecordingKind.liveDetection);
    expect(recordingKindOf({'config': {'captureTrigger': 'motion'}}), RecordingKind.motion);
    expect(recordingKindOf({'config': {'motionOnlyCapture': true}}), RecordingKind.motion, reason: 'round 95 flag');
    expect(recordingKindOf({'config': {'captureTrigger': 'timelapse'}}), RecordingKind.timeLapse);
    expect(recordingKindOf({'source': 'imported_video', 'config': {'captureTrigger': 'timelapse'}}), RecordingKind.importedVideos);
  });

  group('scanPastSessions', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('past_sessions'));
    tearDown(() => root.deleteSync(recursive: true));

    Directory make(String name, String log) {
      final d = Directory('${root.path}/$name')..createSync();
      File('${d.path}/session.jsonl').writeAsStringSync(log);
      return d;
    }

    test('reads each session folder, newest first', () async {
      make(
        'live',
        '{"type":"start_of_session","time_ms":1000000,"config":{"captureTrigger":"detector"}}\n'
            '{"type":"detection","time_ms":1500000}\n'
            '{"type":"end_of_session","time_ms":1600000,"ended_normally":true}\n',
      );
      final motion = make('motion', '{"type":"start_of_session","time_ms":3000000,"config":{"captureTrigger":"motion"}}\n');
      File('${motion.path}/post_detections.jsonl').writeAsStringSync('{}\n');
      final videos = make(
        'videos',
        '{"type":"start_of_session","time_ms":2000000,"source":"imported_video","config":{}}\n'
            '{"type":"end_of_session","time_ms":2060000,"ended_normally":true,"source":"imported_video"}\n',
      );
      Directory('${videos.path}/videos').createSync();
      File('${videos.path}/videos/clip.mp4').writeAsBytesSync(List.filled(1000, 0));
      IdentificationPaths(videos).dir.createSync(recursive: true);
      File('${IdentificationPaths(videos).dir.path}/summary_x.json').writeAsStringSync('{}');
      Directory('${root.path}/not_a_session').createSync();

      final all = await scanPastSessions(root: root);
      expect(all.map((s) => s.name), ['motion', 'videos', 'live']);
      final live = all.last;
      expect(live.kind, RecordingKind.liveDetection);
      expect(live.duration, const Duration(seconds: 600));
      expect(live.endedNormally, isTrue);
      expect(live.hasAnalysis || live.hasVideos || live.hasIdentification, isFalse);
      final m = all.first;
      expect(m.kind, RecordingKind.motion);
      expect(m.end, isNull, reason: 'no end record');
      expect(m.duration, isNull);
      expect(m.hasAnalysis, isTrue);
      final v = all[1];
      expect(v.kind, RecordingKind.importedVideos);
      expect(v.hasVideos, isTrue);
      expect(v.hasIdentification, isTrue);
      expect(v.sizeBytes, greaterThan(1000));
      expect(v.dir.path, videos.path);
    });

    test('a missing sessions folder gives an empty list', () async {
      expect(await scanPastSessions(root: Directory('${root.path}/none')), isEmpty);
    });
  });

  group('SessionFilter', () {
    final now = DateTime(2026, 10, 2, 12);
    final all = [
      session('Meadow_A', DateTime(2026, 10, 2, 8), duration: const Duration(minutes: 5), bytes: 10, kind: RecordingKind.timeLapse),
      session('meadow_b', DateTime(2026, 9, 27, 8), duration: const Duration(minutes: 30), bytes: 300, found: true),
      session('river', DateTime(2026, 9, 10, 8), duration: const Duration(hours: 2), bytes: 20, kind: RecordingKind.importedVideos, found: true, identified: true),
      session('crashed', DateTime(2026, 8, 1, 8), bytes: 5, kind: RecordingKind.motion),
    ];
    List<String> names(SessionFilter f, [SessionSort sort = SessionSort.newest]) => [
      for (final s in f.apply(all, sort, now)) s.name,
    ];

    test('search by part of the name, any case', () {
      expect(names(const SessionFilter(query: 'MEADOW')), ['Meadow_A', 'meadow_b']);
      expect(names(const SessionFilter(query: '  riv ')), ['river']);
      expect(const SessionFilter(query: 'x').panelCount, 0, reason: 'the search is not a panel filter');
    });

    test('dates are calendar days ending today', () {
      expect(names(const SessionFilter(date: DateFilter.today)), ['Meadow_A']);
      expect(names(const SessionFilter(date: DateFilter.last7Days)), ['Meadow_A', 'meadow_b']);
      expect(names(const SessionFilter(date: DateFilter.last30Days)), ['Meadow_A', 'meadow_b', 'river']);
      final range = SessionFilter(date: DateFilter.range, from: DateTime(2026, 9, 10), to: DateTime(2026, 9, 27));
      expect(names(range), ['meadow_b', 'river'], reason: 'both days included');
      expect(range.dateLabel, '2026-09-10 to 2026-09-27');
    });

    test('length, kind and what was done afterwards', () {
      expect(names(const SessionFilter(length: LengthFilter.under10Min)), ['Meadow_A']);
      expect(names(const SessionFilter(length: LengthFilter.tenTo60Min)), ['meadow_b']);
      expect(names(const SessionFilter(length: LengthFilter.over1Hour)), ['river']);
      expect(names(const SessionFilter(kinds: {RecordingKind.motion, RecordingKind.timeLapse})), ['Meadow_A', 'crashed']);
      expect(names(const SessionFilter(findDone: true)), ['meadow_b', 'river']);
      expect(names(const SessionFilter(findDone: true, identified: true)), ['river']);
    });

    test('active filters as chips, each removable', () {
      final f = SessionFilter(
        query: 'mea',
        date: DateFilter.last7Days,
        length: LengthFilter.tenTo60Min,
        kinds: const {RecordingKind.timeLapse, RecordingKind.liveDetection},
        identified: true,
      );
      expect(f.chips().map((c) => c.label), ['Last 7 days', '10 to 60 min', 'Live detection, Time-lapse', 'Identified']);
      expect(f.panelCount, 4);
      final noDate = f.chips().first.without;
      expect(noDate.date, DateFilter.any);
      expect(noDate.query, 'mea');
      expect(noDate.panelCount, 3);
      expect(f.panelCleared.panelCount, 0);
      expect(f.panelCleared.query, 'mea');
      expect(const SessionFilter().isEmpty, isTrue);
    });

    test('orders: newest, oldest, longest (no length last), largest', () {
      expect(names(const SessionFilter()), ['Meadow_A', 'meadow_b', 'river', 'crashed']);
      expect(names(const SessionFilter(), SessionSort.oldest), ['crashed', 'river', 'meadow_b', 'Meadow_A']);
      expect(names(const SessionFilter(), SessionSort.longest), ['river', 'meadow_b', 'Meadow_A', 'crashed']);
      expect(names(const SessionFilter(), SessionSort.largest), ['meadow_b', 'river', 'Meadow_A', 'crashed']);
    });
  });
}
