// FaunaPulse (round 304): on-device check of the Dashboard. First with the
// phone's own sessions (as the owner sees it), then with a made-up season
// in a temporary folder (live sessions over five weeks with identifications
// at every rank, an outdated and a missing identification, a motion session
// and an imported video whose filming time is a guess), so the charts and a
// long "Track IDs by name" list are seen at real phone width and font.
//
// The phone's sessions are only read: opening the Dashboard writes its cache
// file `dashboard_stats.json` into each session folder, as the app does. The
// made-up season lives in the app's cache folder and is deleted at the end.
// Run:  flutter test integration_test/dashboard_check_test.dart -d <serial> --no-uninstall
// Always pass --no-uninstall (see video_decode_check_test.dart for why).
// Screenshots: "SHOT <name>" lines, as in models_screen_check_test.dart.
// Unlock the phone first; the check keeps the screen on while it runs.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fauna_pulse/fauna_pulse/logging/dashboard_stats.dart';
import 'package:fauna_pulse/fauna_pulse/logging/past_sessions.dart' show sessionsRoot;
import 'package:fauna_pulse/fauna_pulse/screens/dashboard_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ignore: avoid_print
void _log(String s) => print(s);

const _ranks = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'];
const _top = ['Animalia', 'Arthropoda', 'Insecta'];

/// Made-up names, from order down to the rank they were identified to.
const _names = [
  ['Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris'],
  ['Hymenoptera', 'Apidae', 'Bombus', 'Bombus pascuorum'],
  ['Hymenoptera', 'Apidae', 'Apis', 'Apis mellifera'],
  ['Hymenoptera', 'Apidae', 'Bombus'],
  ['Hymenoptera', 'Halictidae', 'Lasioglossum'],
  ['Hymenoptera', 'Andrenidae', 'Andrena'],
  ['Hymenoptera'],
  ['Diptera', 'Syrphidae', 'Episyrphus', 'Episyrphus balteatus'],
  ['Diptera', 'Syrphidae', 'Eristalis', 'Eristalis tenax'],
  ['Diptera', 'Syrphidae', 'Syrphus'],
  ['Diptera', 'Muscidae'],
  ['Lepidoptera', 'Nymphalidae', 'Aglais', 'Aglais io'],
  ['Coleoptera', 'Cerambycidae'],
];

String _detections(int ms, int id) => jsonEncode({
  'type': 'detections',
  'time_ms': ms,
  'frame_ms': ms,
  'tracks': [
    {
      'track_id': id,
      'class_name': 'Arthropod',
      'confidence': 0.8,
      'box_in_roi': {'left': 0.1, 'top': 0.1, 'right': 0.4, 'bottom': 0.4},
    },
  ],
});

Map<String, dynamic> _entry(int id, List<String>? below, {bool suspect = false}) {
  if (below == null) {
    return {'track_id': id, 'track_ids': [id], 'suspect': false, 'headline': 'unidentified', 'identified_rank': null, 'ladder': []};
  }
  final path = [..._top, ...below];
  return {
    'track_id': id,
    'track_ids': [id],
    'suspect': suspect,
    'headline': path.last,
    'identified_rank': _ranks[path.length - 1],
    'ladder': [
      for (var i = 0; i < path.length; i++) {'rank': _ranks[i], 'taxon': path[i], 'p': 0.9},
    ],
  };
}

/// Writes the made-up season into [root]; [today] is the phone's today.
void _season(Directory root, DateTime today) {
  final rnd = Random(304);
  for (var s = 0; s < 9; s++) {
    final day = DateTime(today.year, today.month, today.day - 36 + s * 4 + (s == 8 ? 3 : 0));
    final start = DateTime(day.year, day.month, day.day, 8 + rnd.nextInt(3));
    final dir = Directory('${root.path}/live_$s')..createSync();
    final n = 4 + rnd.nextInt(14);
    final lines = <String>[
      jsonEncode({'type': 'start_of_session', 'time_ms': start.millisecondsSinceEpoch, 'config': {'captureTrigger': 'detector'}}),
    ];
    final entries = <Map<String, dynamic>>[];
    for (var id = 1; id <= n; id++) {
      final t0 = start.add(Duration(minutes: rnd.nextInt(300))).millisecondsSinceEpoch;
      final len = 1000 + rnd.nextInt(rnd.nextInt(10) == 0 ? 240000 : 20000);
      lines
        ..add(_detections(t0, id))
        ..add(_detections(t0 + len, id));
      final pick = rnd.nextInt(_names.length + 2);
      entries.add(
        pick < _names.length
            ? _entry(id, _names[pick])
            : pick == _names.length
            ? _entry(id, null)
            : _entry(id, const ['Hymenoptera', 'Apidae'], suspect: true),
      );
    }
    lines.add(jsonEncode({'type': 'end_of_session', 'time_ms': start.add(const Duration(hours: 5)).millisecondsSinceEpoch}));
    File('${dir.path}/session.jsonl').writeAsStringSync(lines.join('\n'));
    if (s == 3) continue; // not identified yet
    final id = Directory('${dir.path}/identification')..createSync();
    File('${id.path}/tracks_p.json').writeAsStringSync(jsonEncode({'tracks': entries}));
    File('${id.path}/summary_p.json').writeAsStringSync(jsonEncode({'pack_id': 'p'}));
  }
  // A motion session (no track IDs) and an imported video with a guessed time.
  final motion = Directory('${root.path}/motion')..createSync();
  final m0 = DateTime(today.year, today.month, today.day - 2, 10).millisecondsSinceEpoch;
  File('${motion.path}/session.jsonl').writeAsStringSync([
    jsonEncode({'type': 'start_of_session', 'time_ms': m0, 'config': {'captureTrigger': 'motion'}}),
    jsonEncode({'type': 'end_of_session', 'time_ms': m0 + 3600000}),
  ].join('\n'));
  final video = Directory('${root.path}/video')..createSync();
  final v0 = DateTime(today.year, today.month, today.day, 7).millisecondsSinceEpoch;
  File('${video.path}/session.jsonl').writeAsStringSync([
    jsonEncode({'type': 'start_of_session', 'time_ms': v0, 'source': 'imported_video'}),
    jsonEncode({
      'type': 'video_clip',
      'time_ms': v0,
      'start_epoch_ms': v0,
      'duration_ms': 60000,
      'file': 'videos/a.mp4',
      'start_time_source': 'file_time',
      'start_time_weak': true,
    }),
    jsonEncode({'type': 'end_of_session', 'time_ms': v0 + 60000}),
  ].join('\n'));
  File('${video.path}/post_tracks.jsonl').writeAsStringSync([
    jsonEncode({'type': 'post_track_start', 'time_ms': v0, 'run_id': 2, 'observed_ms': 60000, 'clips': ['a.mp4'], 'occlusion_seconds': 3, 'min_hits_seconds': 1}),
    _detections(v0 + 1000, 1),
    _detections(v0 + 9000, 1),
    jsonEncode({'type': 'post_track_end', 'time_ms': v0 + 60000, 'run_id': 2, 'track_ids': 1}),
  ].join('\n'));
  // Identified before the track IDs were found again: outdated.
  final vid = Directory('${video.path}/identification')..createSync();
  File('${vid.path}/tracks_p.json').writeAsStringSync(jsonEncode({'tracks': [_entry(1, _names.first)]}));
  File('${vid.path}/summary_p.json').writeAsStringSync(jsonEncode({'pack_id': 'p', 'capture': {'track_ids_run_id': 1}}));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Dashboard on the phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 500));
      _log('SHOT $name');
      await tester.pump(const Duration(seconds: 4));
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> loaded() async {
      for (var i = 0; i < 600 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await settle();
    }

    Future<void> scrollTo(Finder f) async {
      await tester.scrollUntilVisible(f, 300, maxScrolls: 40);
      await settle();
    }

    // 1. The phone's own sessions, read once with the numbers logged.
    final root = await sessionsRoot();
    final dirs = root.existsSync()
        ? [for (final e in root.listSync()) if (e is Directory && File('${e.path}/session.jsonl').existsSync()) e]
        : <Directory>[];
    final stats = [for (final d in dirs) await DashboardStatsCache.forSession(d)];
    final agg = aggregateDashboard(stats);
    _log('PHONE ${dirs.length} sessions: ${agg.totalVisits} track IDs in ${agg.aiSessions}, '
        'watched ${agg.totalRecordedMs} ms, per hour ${agg.visitsPerHour}, named ${agg.namedVisits}, '
        'without clock ${agg.visitsWithoutClock}, other ${agg.otherSessions}');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: const DashboardScreen()));
    await loaded();
    expect(tester.takeException(), isNull);
    await shot('dash_phone');

    // 2. The made-up season.
    final tmp = Directory.systemTemp.createTempSync('dashboard_check');
    addTearDown(() => tmp.deleteSync(recursive: true));
    _season(tmp, DateTime.now());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DashboardScreen(sessionsDir: () async => tmp),
      ),
    );
    await loaded();
    expect(find.text('track IDs in 10 sessions'), findsOneWidget);
    await shot('dash_season_top');
    await scrollTo(find.text('Track IDs by day'));
    await shot('dash_season_charts');
    await scrollTo(find.text('Track IDs by name'));
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await settle();
    await shot('dash_season_names');
    final species = find.textContaining('Species (');
    await tester.tap(species);
    await settle();
    final all = find.textContaining('Show all');
    if (all.evaluate().isNotEmpty) {
      await scrollTo(all);
      await tester.tap(all);
      await settle();
    }
    await scrollTo(find.textContaining('Not counted'));
    expect(find.textContaining('Not in the charts by time: 1 track ID'), findsOneWidget);
    expect(find.textContaining('suspect track ID'), findsOneWidget);
    await shot('dash_season_species_end');
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await settle();
    await tester.tap(find.text('30 days'));
    await settle();
    await shot('dash_season_30days');
    expect(tester.takeException(), isNull);
  });
}
