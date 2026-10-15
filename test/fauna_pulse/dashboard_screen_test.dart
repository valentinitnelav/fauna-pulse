// Widget tests for the Dashboard (round 304): the number tiles take the
// height of their text (they overflowed at phone width), no rate per hour
// from a few seconds of video, videos without a known filming time stay out
// of the charts by time, and the names card counts the identification per
// rank. Round 305: the rate from 1 h as a rough estimate with its (i), the
// two activity charts always there, track lengths from the first sighting.
// Sessions are real folders in a temp directory (fixture IO is SYNC,
// frames are pumped outside short runAsync waits: see
// summary_bottom_inset_test.dart).

import 'dart:convert';
import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/screens/dashboard_screen.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/mini_bar_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'summary_bottom_inset_test.dart' show expectAboveBottomInset, simulateBottomSystemBar;

final _now = DateTime(2026, 10, 12, 23);
int _ms(DateTime t) => t.millisecondsSinceEpoch;

String _detections(int ms, List<int> ids) => jsonEncode({
  'type': 'detections',
  'time_ms': ms,
  'frame_ms': ms,
  'tracks': [
    for (final id in ids)
      {
        'track_id': id,
        'class_name': 'Arthropod',
        'confidence': 0.8,
        'box_in_roi': {'left': 0.1, 'top': 0.1, 'right': 0.4, 'bottom': 0.4},
      },
  ],
});

const _top = ['Animalia', 'Arthropoda', 'Insecta'];
const _ranks = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species'];

Map<String, dynamic> _named(int id, List<String> below, {bool suspect = false}) {
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

void _identify(Directory session, List<Map<String, dynamic>> tracks, {int? runId}) {
  final dir = Directory('${session.path}/identification')..createSync();
  File('${dir.path}/tracks_p.json').writeAsStringSync(jsonEncode({'tracks': tracks}));
  File('${dir.path}/summary_p.json').writeAsStringSync(
    jsonEncode({
      'pack_id': 'p',
      if (runId != null) 'capture': {'track_ids_run_id': runId},
    }),
  );
}

/// The phone's session: a 6 s imported video whose filming time is the
/// copy's time, one track ID, identified as Bombus (genus). The tracker
/// first saw it at 0.0 s and confirmed it at 0.8 s (5 frames at 5 fps).
void _shortVideo(Directory root) {
  final dir = Directory('${root.path}/video_20261012')..createSync();
  final t0 = _ms(DateTime(2026, 10, 12, 22, 12, 32));
  File('${dir.path}/session.jsonl').writeAsStringSync(
    [
      jsonEncode({'type': 'start_of_session', 'time_ms': t0, 'source': 'imported_video'}),
      jsonEncode({
        'type': 'video_clip',
        'time_ms': t0,
        'file': 'videos/bumblebee.mp4',
        'start_time_source': 'file_time',
        'start_time_weak': true,
        'duration_ms': 5933,
      }),
      jsonEncode({'type': 'end_of_session', 'time_ms': t0 + 5933, 'ended_normally': true}),
    ].join('\n'),
  );
  File('${dir.path}/post_tracks.jsonl').writeAsStringSync(
    [
      jsonEncode({
        'type': 'post_track_start',
        'time_ms': t0,
        'run_id': 7,
        'observed_ms': 6024,
        'clips': ['bumblebee.mp4'],
        'occlusion_seconds': 3.0,
        'min_hits_seconds': 1.0,
      }),
      _detections(t0 + 800, [1]),
      jsonEncode({
        'type': 'track_event',
        'time_ms': t0 + 800,
        'event': 'created',
        'track_id': 1,
        'frame_ms': t0 + 800,
        'clip': 'bumblebee.mp4',
        'hits': 5,
        'first_seen_ms': t0,
        'last_seen_ms': t0 + 800,
      }),
      _detections(t0 + 5100, [1]),
      jsonEncode({'type': 'post_track_end', 'time_ms': t0 + 9000, 'run_id': 7, 'track_ids': 1}),
    ].join('\n'),
  );
  _identify(dir, [
    _named(1, const ['Hymenoptera', 'Apidae', 'Bombus']),
  ], runId: 7);
}

/// A two-day live session with eight track IDs,
/// identified at several ranks (one suspect, one unidentified).
void _liveSession(Directory root) {
  final dir = Directory('${root.path}/live_20261001')..createSync();
  final start = DateTime(2026, 10, 1, 9);
  // Oct 1: 10:00, 10:30, 11:00, 12:00, 13:00; Oct 2: 14:00, 15:00, 16:00.
  const times = [(1, 10, 0), (1, 10, 30), (1, 11, 0), (1, 12, 0), (1, 13, 0), (2, 14, 0), (2, 15, 0), (2, 16, 0)];
  final ids = [
    for (var i = 0; i < times.length; i++)
      _detections(_ms(DateTime(2026, 10, times[i].$1, times[i].$2, times[i].$3)), [i + 1]),
  ];
  File('${dir.path}/session.jsonl').writeAsStringSync(
    [
      jsonEncode({
        'type': 'start_of_session',
        'time_ms': _ms(start),
        'config': {'captureTrigger': 'detector'},
      }),
      ...ids,
      jsonEncode({'type': 'end_of_session', 'time_ms': _ms(start.add(const Duration(hours: 34)))}),
    ].join('\n'),
  );
  _identify(dir, [
    for (final id in [1, 2, 3]) _named(id, const ['Hymenoptera', 'Apidae', 'Bombus', 'Bombus terrestris']),
    for (final id in [4, 5]) _named(id, const ['Diptera', 'Syrphidae', 'Episyrphus', 'Episyrphus balteatus']),
    _named(6, const ['Hymenoptera', 'Averyveryverylongfamilynamethatgoesonandonandonidae']),
    _named(7, const ['Hymenoptera', 'Apidae'], suspect: true),
    {
      'track_id': 8,
      'track_ids': [8],
      'suspect': false,
      'headline': 'unidentified',
      'identified_rank': null,
      'ladder': const [],
    },
  ]);
}

/// A motion session: photos, no track IDs.
void _motionSession(Directory root) {
  final dir = Directory('${root.path}/motion_20261011')..createSync();
  final t0 = _ms(DateTime(2026, 10, 11, 10));
  File('${dir.path}/session.jsonl').writeAsStringSync(
    [
      jsonEncode({
        'type': 'start_of_session',
        'time_ms': t0,
        'config': {'captureTrigger': 'motion'},
      }),
      jsonEncode({'type': 'end_of_session', 'time_ms': t0 + 600000}),
    ].join('\n'),
  );
}

/// Both charts' line when there is nothing to count.
const _noTrackIds = 'No track IDs in this period yet: the bars appear once track IDs are recorded.';

/// The Xiaomi: 1080 px wide at 440 dpi = 393 logical pixels.
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1080 / 393;
  addTearDown(tester.view.reset);
}

/// The big number.
String? _total() => (find.byKey(const ValueKey('dashboard_total')).evaluate().single.widget as Text).data;

Directory _root() {
  final root = Directory.systemTemp.createTempSync('dashboard_screen');
  addTearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });
  return root;
}

Future<void> _pump(WidgetTester tester, Directory root) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: DashboardScreen(sessionsDir: () async => root, now: () => _now),
    ),
  );
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the phone\'s case: one track ID in 6 s of video, at phone width', (tester) async {
    _phone(tester);
    final root = _root();
    _shortVideo(root);
    await _pump(tester, root);

    expect(tester.takeException(), isNull, reason: 'no tile overflows');
    expect(_total(), '1');
    expect(find.text('track ID in 1 session'), findsOneWidget);
    expect(find.text('6 s'), findsOneWidget, reason: 'watch time in seconds, not "0 min"');
    expect(find.text('–'), findsOneWidget, reason: 'no rate from 6 s');
    expect(find.text('shown from 1 h watched'), findsOneWidget);
    // From the first sighting, as track_ids.csv (0.0 to 5.1 s), not from
    // the first box (0.8 s).
    expect(find.text('5.1 s'), findsNWidgets(2), reason: 'typical and longest track');
    // The filming time is a guess: both chart cards stay, empty, and say why.
    expect(find.text('Track IDs by time of day'), findsOneWidget);
    expect(find.text('Track IDs by day'), findsOneWidget);
    expect(find.textContaining('No times to show: this track ID comes from videos'), findsNWidgets(2));
    expect(find.byType(MiniBarChart), findsNWidgets(2));
    expect(find.text('Live detection sessions'), findsNothing);
    // Names: no species chip (identified to genus), family first.
    await tester.scrollUntilVisible(find.text('Named: 1 of 1 track ID.'), 200);
    expect(find.text('Order (1)'), findsOneWidget);
    expect(find.text('Family (1)'), findsOneWidget);
    expect(find.text('Genus (1)'), findsOneWidget);
    expect(find.textContaining('Species'), findsNothing);
    expect(find.text('Apidae'), findsOneWidget);
    expect(find.text('Named: 1 of 1 track ID.'), findsOneWidget);
  });

  testWidgets('360 px, large font, bottom bar: nothing overflows and the end is reachable', (tester) async {
    simulateBottomSystemBar(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final root = _root();
    _shortVideo(root);
    _liveSession(root);
    _motionSession(root);
    await _pump(tester, root);
    expect(tester.takeException(), isNull);

    expect(_total(), '9');
    expect(find.text('track IDs in 2 sessions'), findsOneWidget);
    expect(find.text('Track IDs by time of day'), findsOneWidget);
    expect(find.textContaining('Most at 10:00–11:00.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Track IDs by day'), 200);
    expect(find.textContaining('Record day: 2026-10-01 (5 track IDs)'), findsOneWidget);

    // Family is the default rank: suspects left out, the long name cut.
    await tester.scrollUntilVisible(find.text('Track IDs by name'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Apidae'), findsOneWidget);
    expect(find.text('Syrphidae'), findsOneWidget);
    expect(find.text('Species (2)'), findsOneWidget);
    await tester.tap(find.text('Species (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Bombus terrestris'), findsOneWidget);
    expect(find.text('not resolved to species'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final last = find.textContaining('Not counted: 1 session without track IDs');
    await tester.scrollUntilVisible(last, 200);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expectAboveBottomInset(tester, last, label: 'the last note');
    expect(find.textContaining('Named: 7 of 9 track IDs.'), findsOneWidget);
    expect(find.textContaining('Not in the charts by time: 1 track ID'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 px with font size 1.5: every part fits while scrolling through', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final root = _root();
    _shortVideo(root);
    _liveSession(root);
    _motionSession(root);
    await _pump(tester, root);
    for (var i = 0; i < 12; i++) {
      expect(tester.takeException(), isNull, reason: 'scroll step $i');
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Not counted: 1 session'), findsOneWidget, reason: 'scrolled to the end');
  });

  testWidgets('320 px with font size 1.5: the rate (i) opens under the tiles, which keep their height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final root = _root();
    _liveSession(root);
    await _pump(tester, root);
    final label = find.text('track IDs per hour watched');
    await tester.scrollUntilVisible(label, 100);
    await tester.pumpAndSettle();
    final watchedTile = find.ancestor(of: find.text('watched'), matching: find.byType(Container)).first;
    final rateTile = find.ancestor(of: label, matching: find.byType(Container)).first;
    final before = tester.getSize(watchedTile);
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final help = find.textContaining('divided by the hours those sessions watched');
    expect(help, findsOneWidget);
    expect(tester.getSize(watchedTile), before, reason: 'the open help does not stretch the row');
    expect(tester.getSize(help).width, greaterThan(tester.getSize(rateTile).width), reason: 'full width');
    expect(tester.getTopLeft(label).dy, tester.getTopLeft(find.text('watched')).dy, reason: 'labels line up');
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(help, findsNothing);
  });

  testWidgets('a live session without animals: no lengths, no names card, empty charts', (tester) async {
    _phone(tester);
    final root = _root();
    final dir = Directory('${root.path}/live_empty')..createSync();
    final t0 = _ms(DateTime(2026, 10, 12, 9));
    File('${dir.path}/session.jsonl').writeAsStringSync(
      [
        jsonEncode({'type': 'start_of_session', 'time_ms': t0, 'config': {'captureTrigger': 'detector'}}),
        jsonEncode({'type': 'end_of_session', 'time_ms': t0 + 70 * 60000}),
      ].join('\n'),
    );
    await _pump(tester, root);
    expect(_total(), '0');
    expect(find.text('1.1 h'), findsOneWidget);
    expect(find.text('0.0 s'), findsNothing);
    expect(find.text('–'), findsNWidgets(2), reason: 'both track length tiles');
    expect(find.text('0.0'), findsOneWidget, reason: 'the rate: no track ID in 70 min');
    expect(find.text('rough estimate'), findsOneWidget);
    expect(find.text('Track IDs by name'), findsNothing);
    expect(find.textContaining('Identify organisms'), findsNothing);
    expect(find.textContaining('No times to show'), findsNothing);
    expect(find.text('Track IDs by time of day'), findsOneWidget);
    expect(find.text('Track IDs by day'), findsOneWidget);
    expect(find.byType(MiniBarChart), findsNWidgets(2));
    expect(find.text(_noTrackIds), findsNWidgets(2));
  });

  testWidgets('below 1 h the rate tile shows a dash; its (i) explains the estimate', (tester) async {
    final root = _root();
    final dir = Directory('${root.path}/live_short')..createSync();
    final t0 = _ms(DateTime(2026, 10, 12, 9));
    File('${dir.path}/session.jsonl').writeAsStringSync(
      [
        jsonEncode({'type': 'start_of_session', 'time_ms': t0, 'config': {'captureTrigger': 'detector'}}),
        _detections(t0 + 60000, [1]),
        jsonEncode({'type': 'end_of_session', 'time_ms': t0 + 59 * 60000}),
      ].join('\n'),
    );
    await _pump(tester, root);
    expect(find.text('59 min'), findsOneWidget);
    expect(find.text('shown from 1 h watched'), findsOneWidget);
    expect(find.text('rough estimate'), findsNothing);
    final help = find.textContaining('divided by the hours those sessions watched');
    expect(help, findsNothing);
    await tester.tap(find.text('track IDs per hour watched'));
    await tester.pumpAndSettle();
    expect(help, findsOneWidget);
    expect(find.textContaining('a few minutes scaled up to an hour mostly show chance'), findsOneWidget);
  });

  testWidgets('an identification whose track IDs were all suspect says so', (tester) async {
    final root = _root();
    _shortVideo(root);
    _identify(Directory('${root.path}/video_20261012'), [
      _named(1, const ['Hymenoptera', 'Apidae', 'Bombus'], suspect: true),
    ], runId: 7);
    await _pump(tester, root);
    await tester.scrollUntilVisible(find.text('Track IDs by name'), 200);
    expect(find.textContaining('No names yet'), findsNothing);
    expect(
      find.textContaining('Named: 0 of 1 track ID. 1 suspect track ID (likely false detections) left out'),
      findsOneWidget,
    );
  });

  testWidgets('7 days with no session: the empty state and both charts with 7 empty days', (tester) async {
    _phone(tester);
    final root = _root();
    _liveSession(root);
    await _pump(tester, root);
    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No sessions in this period yet'), findsOneWidget);
    expect(find.byType(MiniBarChart), findsNWidgets(2));
    final days = tester.widgetList<MiniBarChart>(find.byType(MiniBarChart)).last;
    expect(days.values, List.filled(7, 0));
    expect([days.xLabelFor(0), days.xLabelFor(6)], ['2026-10-06', '2026-10-12']);
    expect(find.text(_noTrackIds), findsNWidgets(2));
  });

  testWidgets('the period counts calendar days, and the default is all time', (tester) async {
    final root = _root();
    _shortVideo(root);
    _liveSession(root);
    await _pump(tester, root);
    expect(_total(), '9');
    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();
    expect(_total(), '1', reason: 'the live session of Oct 1 is older');
    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(_total(), '9');
  });

  testWidgets('while reading, no numbers are shown', (tester) async {
    final root = _root();
    _shortVideo(root);
    await tester.pumpWidget(
      MaterialApp(home: DashboardScreen(sessionsDir: () async => root, now: () => _now)),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('watched'), findsNothing);
    expect(find.text('0'), findsNothing);
    // Let the reading finish before the folder goes.
    await _pump(tester, root);
  });

  testWidgets('no sessions: the empty state with both charts, empty, above the bottom bar', (tester) async {
    simulateBottomSystemBar(tester);
    await _pump(tester, _root());
    expect(find.textContaining('No sessions in this period yet'), findsOneWidget);
    expect(find.text('watched'), findsNothing);
    expect(find.byKey(const ValueKey('dashboard_total')), findsNothing);
    expect(find.text('Track IDs by time of day'), findsOneWidget);
    expect(find.byType(MiniBarChart), findsNWidgets(2));
    expect(find.text(_noTrackIds), findsNWidgets(2));
    final dayChart = find.text('Track IDs by day');
    await tester.scrollUntilVisible(dayChart, 200);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expectAboveBottomInset(tester, find.byType(MiniBarChart).last, label: 'the day chart');
    expect(tester.takeException(), isNull);
  });
}
