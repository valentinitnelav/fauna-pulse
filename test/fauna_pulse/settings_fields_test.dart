// Round 313 (owner: "I cannot change the New-track confidence value, it is set
// at 0.6 and when I try to reduce it to 0.5 then 0.6 is shown immediately
// instead ... I want to be sure that the user can set / tune such settings on
// the screens and that they take effect"). The audit of that round found the
// same few causes behind many settings: a box that silently replaced a typed
// number, a setting that silently rewrote ANOTHER stored setting (also from
// the half-typed number on the way, "2" on the way to "20"), and values that
// never reached what uses them.
//
// This test drives every control of every settings screen the way a person
// does (one character at a time) and checks, for each one:
//  1. after it loses focus the box shows what was typed (no jump back);
//  2. exactly one stored setting changed (no hidden link to another one,
//     unless listed below with the reason);
//  3. typing the old value back gives back every stored value (no one-way
//     "ratchet");
//  4. a number above the box's maximum stores nothing, and the box says what
//     is allowed.
// Switches and drop-down lists are switched and switched back, sliders moved
// and moved back, with checks 2 and 3. A new control is covered without
// changing this file; a new stored setting that no control changes must be
// added to the list of settings without a control here, with the reason.
// "Take effect" is checked where the values are used: tracker_effect_test.dart.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart' show IdentifyPrefs;
import 'package:fauna_pulse/fauna_pulse/models/session_config.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identify_settings_fields.dart';
import 'package:fauna_pulse/fauna_pulse/screens/settings_sheet.dart';
import 'package:fauna_pulse/fauna_pulse/screens/video_analysis_screen.dart' show VideoAnalysisPrefs;
import 'package:fauna_pulse/fauna_pulse/screens/video_tuning_screen.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/byte_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/c_biou_track.dart';
import 'package:fauna_pulse/fauna_pulse/tracking/tracker.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/numeric_setting_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef Snapshot = Future<Map<String, Object?>> Function();

/// Nested maps become "a.b" keys; lists stay whole (compared by value).
Map<String, Object?> flatten(Map<dynamic, dynamic> m, [String prefix = '']) => {
  for (final MapEntry(:key, :value) in m.entries)
    if (value is Map) ...flatten(value, '$prefix$key.') else '$prefix$key': value is List ? value.toString() : value,
};

/// How many number boxes, switches, check boxes and lists are on screen.
List<int> controlsShown() => [
  for (final t in [NumericSettingField, Switch, Checkbox]) find.byType(t).evaluate().length,
  find.byWidgetPredicate((w) => w is DropdownButton).evaluate().length,
];

Set<String> changedKeys(Map<String, Object?> a, Map<String, Object?> b) => {
  for (final k in {...a.keys, ...b.keys})
    if (a[k] != b[k]) k,
};

/// A box whose valid numbers follow a rule the generic pick cannot know.
class BoxRule {
  final String? target;
  final Set<String> alsoChanges;
  final String why;

  const BoxRule({this.target, this.alsoChanges = const {}, required this.why});
}

String _fmt(NumericSettingField w, double v) =>
    (w.isInt || w.decimals <= 0) ? v.round().toString() : v.toStringAsFixed(w.decimals);

/// A valid number for [w] other than its value: about a third into its range.
String _pickTarget(NumericSettingField w) {
  for (final f in [0.3, 0.6, 0.0, 1.0]) {
    final t = _fmt(w, w.min + (w.max - w.min) * f);
    final v = double.parse(t);
    if (t != _fmt(w, w.value) && v >= w.min - 1e-9 && v <= w.max + 1e-9) return t;
  }
  throw StateError('${w.label}: no other valid value');
}

/// Clears the box and types [text] one character at a time.
Future<void> typeLikeAPerson(WidgetTester tester, Finder box, String text) async {
  await tester.enterText(box, '');
  await tester.pump();
  for (var i = 1; i <= text.length; i++) {
    await tester.enterText(box, text.substring(0, i));
    await tester.pump();
  }
}

Future<void> unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

/// Opens every fold (nested ones too); a fold that was open already (its
/// content shrank on the tap) is opened again.
Future<void> openAllFolds(WidgetTester tester) async {
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final opened = <String>{};
  for (var round = 0; round < 6; round++) {
    var any = false;
    for (final tile in find.byType(ExpansionTile).evaluate().toList()) {
      if (!tile.mounted) continue;
      final w = find.byWidget(tile.widget);
      final title = find.descendant(of: w, matching: find.byType(Text)).first;
      final label = tester.widget<Text>(title).data ?? '';
      if (!opened.add(label)) continue;
      final before = find.descendant(of: w, matching: find.byType(Text)).evaluate().length;
      await tester.ensureVisible(title);
      await tester.tap(title, warnIfMissed: false);
      await settle();
      if (w.evaluate().isNotEmpty && find.descendant(of: w, matching: find.byType(Text)).evaluate().length < before) {
        await tester.tap(title, warnIfMissed: false);
        await settle();
      }
      any = true;
    }
    if (!any) break;
  }
}

/// Checks 1 to 4 (see the file header) on every number box now on screen;
/// returns the stored settings the boxes changed.
Future<Set<String>> checkNumberBoxes(
  WidgetTester tester,
  Snapshot snap, {
  Map<String, BoxRule> rules = const {},
  Set<String> skip = const {},
}) async {
  final changed = <String>{};
  final labels = [for (final w in tester.widgetList<NumericSettingField>(find.byType(NumericSettingField))) w.label];
  final seen = <String, int>{};
  for (final label in labels) {
    final index = seen[label] = (seen[label] ?? -1) + 1;
    if (skip.contains(label)) continue;
    final field = find.byWidgetPredicate((w) => w is NumericSettingField && w.label == label);
    if (field.evaluate().length <= index) continue; // hidden by an earlier change; others cover it
    final one = field.at(index);
    final w = tester.widget<NumericSettingField>(one);
    if (!w.enabled) continue;
    final box = find.descendant(of: one, matching: find.byType(TextField));
    String text() => tester.widget<TextField>(box).controller!.text;
    final original = _fmt(w, w.value);
    final rule = rules[label];
    final target = rule?.target ?? _pickTarget(w);
    final before = await snap();

    await typeLikeAPerson(tester, box, target);
    await unfocus(tester);
    expect(text(), target, reason: '"$label": shows the typed $target after leaving the box (no jump back)');
    final after = await snap();
    final diff = changedKeys(before, after);
    expect(diff.length, inInclusiveRange(1, 1 + (rule?.alsoChanges.length ?? 0)),
        reason: '"$label" typed $target changed $diff: one setting each (or list the link and why)');
    if (rule != null) {
      expect(diff.difference(rule.alsoChanges).length, 1, reason: '"$label" changed $diff');
    }
    changed.addAll(diff);

    await typeLikeAPerson(tester, box, original);
    await unfocus(tester);
    expect(text(), original, reason: '"$label": the old value can be typed again');
    expect(await snap(), before, reason: '"$label": typing $original back restores every setting (no ratchet)');

    // A shorter number on the way may be valid ("6" of "61" in a 5 to 60
    // box): the refused number puts the value from before back at once.
    final tooBig = _fmt(w, w.max + 1);
    await typeLikeAPerson(tester, box, tooBig);
    expect(find.descendant(of: one, matching: find.textContaining('Allowed: ')), findsOneWidget,
        reason: '"$label": says what is allowed');
    expect(await snap(), before, reason: '"$label": $tooBig refused: the old value is back at once');
    await unfocus(tester);
    expect(text(), original, reason: '"$label": shows the kept value after a refused number');
    expect(await snap(), before, reason: '"$label": $tooBig is above the maximum and must not be stored');
  }
  return changed;
}

/// Switches each enabled switch or check box and back: the second change must
/// give back every stored value.
Future<Set<String>> checkSwitches(
  WidgetTester tester,
  Snapshot snap, {
  Map<String, Set<String>> links = const {},
  Set<String> notStored = const {},
}) async {
  final changed = <String>{};
  bool isToggle(Widget w) => (w is Switch && w.onChanged != null) || (w is Checkbox && w.onChanged != null);
  final toggles = find.byWidgetPredicate(isToggle);
  final count = toggles.evaluate().length;
  for (var i = 0; i < count; i++) {
    final all = find.byWidgetPredicate(isToggle);
    if (all.evaluate().length <= i) break;
    final s = all.at(i);
    // Greyed out (NotApplicable, a locked tab): taps never reach it.
    if (find.ancestor(of: s, matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring)).evaluate().isNotEmpty) {
      continue;
    }
    final tile = find.ancestor(of: s, matching: find.byWidgetPredicate((w) => w is ListTile)).evaluate();
    // The tile's first text is its title.
    final titleText = tile.isEmpty
        ? null
        : find.descendant(of: find.byWidget(tile.first.widget), matching: find.byType(Text)).evaluate().firstOrNull;
    final title = (titleText?.widget as Text?)?.data;
    final before = await snap();
    await tester.ensureVisible(s);
    await tester.tap(s);
    await tester.pump(const Duration(milliseconds: 50));
    final after = await snap();
    final diff = changedKeys(before, after);
    final allowed = {for (final k in diff) ...?links[k]};
    if (!notStored.contains(title)) expect(diff, isNotEmpty, reason: 'switch $i ("$title") stored nothing');
    expect(diff.difference(allowed).length, lessThanOrEqualTo(1), reason: 'switch $i changed $diff');
    changed.addAll(diff);
    final again = find.byWidgetPredicate(isToggle);
    if (again.evaluate().length > i) {
      await tester.ensureVisible(again.at(i));
      await tester.tap(again.at(i));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(await snap(), before, reason: 'switch $i: switching back restores every setting (changed $diff)');
  }
  return changed;
}

/// Chooses every other entry of each enabled drop-down list, then the first
/// one again: nothing else may stay changed. A list is found again by its
/// entries (a choice can add or remove lists above it).
Future<Set<String>> checkDropdowns(WidgetTester tester, Snapshot snap) async {
  final changed = <String>{};
  // Read through `dynamic`: the list's own value type is only known at run
  // time, and a typed read of its onChanged fails Dart's type check.
  String entries(dynamic dd) => [for (final dynamic it in (dd.items as List? ?? const [])) '${it.value}'].join('|');
  final lists = [
    for (final e in find.byWidgetPredicate((w) => w is DropdownButton).evaluate()) entries(e.widget),
  ];
  for (final sig in lists.toSet()) {
    Finder same() => find.byWidgetPredicate((w) => w is DropdownButton && entries(w) == sig);
    if (same().evaluate().length != 1) continue; // two lists with the same entries: not told apart here
    final dynamic dd = tester.widget(same());
    final List items = (dd.items as List?) ?? const [];
    if (dd.onChanged == null || items.length < 2) continue;
    final Object? original = dd.value;
    final before = await snap();
    void choose(Object? value) {
      final dynamic now = tester.widget(same());
      now.onChanged(value);
    }

    for (final dynamic item in items) {
      if (item.value == original) continue;
      choose(item.value);
      await tester.pump(const Duration(milliseconds: 50));
      changed.addAll(changedKeys(before, await snap()));
      if (same().evaluate().length != 1) fail('the list ($sig) is gone after choosing ${item.value}');
      choose(original);
      await tester.pump(const Duration(milliseconds: 50));
      expect(await snap(), before, reason: 'list ($sig): ${item.value} and back to $original restores every setting');
    }
  }
  return changed;
}

/// Moves each enabled slider to both ends and back.
Future<Set<String>> checkSliders(WidgetTester tester, Snapshot snap) async {
  final changed = <String>{};
  final count = find.byType(Slider).evaluate().length;
  for (var i = 0; i < count; i++) {
    final s = tester.widget<Slider>(find.byType(Slider).at(i));
    if (s.onChanged == null) continue;
    final before = await snap();
    for (final v in [s.min, s.max]) {
      tester.widget<Slider>(find.byType(Slider).at(i)).onChanged!(v);
      await tester.pump();
    }
    tester.widget<Slider>(find.byType(Slider).at(i)).onChangeEnd?.call(s.max);
    await tester.pump();
    changed.addAll(changedKeys(before, await snap()));
    tester.widget<Slider>(find.byType(Slider).at(i)).onChanged!(s.value);
    tester.widget<Slider>(find.byType(Slider).at(i)).onChangeEnd?.call(s.value);
    await tester.pump();
    expect(await snap(), before, reason: 'slider $i: moved to both ends and back restores every setting');
  }
  return changed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('faunapulse_settings_fields');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => tmp.path,
    );
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    tmp.deleteSync(recursive: true);
  });

  /// A tall phone, so every row of a list is built at once.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 24000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // ---------------------------------------------------------------- camera
  /// Stored settings no control of the Settings sheet changes, with the reason.
  const notOnTheSheet = {
    'modelPath': 'needs a model file on the phone (none in this test)',
    'task': 'follows the chosen model',
    'selectedLensZoom': 'the lens button on the camera screen',
    'scheduleWindows': 'time pickers (system dialogs)',
    'folderName': 'a free text box (the session length test types into it)',
    'sessionMinutes': 'its own box and unit toggle (test below)',
    'trackerParams.trackBuffer': 'derived from the occlusion tolerance at the frame rate',
    'trackerParams.minHitsToConfirm': 'derived from the minimum track length',
    'cbiouParams.trackBuffer': 'derived from the occlusion tolerance',
    'cbiouParams.minHitsToConfirm': 'derived from the minimum track length',
    'streamWidth': 'the stream size list (pairs with streamHeight)',
    'streamHeight': 'the stream size list',
    'streamResolutionExplicit': 'the stream size list',
    'diagnosticsEnabled': 'kept for old sessions; no control since round 160',
  };

  /// Links a control has on purpose (setting -> what it also changes).
  const sheetBoxRules = {
    // The saved photo size drives the automatic stream size, which is part
    // of the same choice (a function of it, not a ratchet: typing the old
    // value back gives it back, check 3).
    // A multiple of 32 (the box snaps to it).
    'Saved photo side (px)': BoxRule(target: '704', alsoChanges: {'streamWidth', 'streamHeight'}, why: 'auto stream size'),
  };

  Future<void> openSheet(WidgetTester tester, SessionConfig config, SettingsDraft draft) async {
    tall(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        // Sizes as a phone's camera reports them, so "Auto" can choose one.
        home: Scaffold(
          body: SettingsSheet(
            config: config,
            draft: draft,
            streamResolutions: const ['640x480', '1280x720', '1280x960', '1920x1080', '1920x1440'],
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // The stored stream size is what "Auto" picks for the saved photo side from
  // the list above (the camera screen keeps it so on the phone).
  const autoSize = SessionConfig(streamWidth: 1920, streamHeight: 1080);
  final starts = <String, SessionConfig>{
    'live detection, ByteTrack': autoSize,
    // New-track close to the confidence: a control that raised it with the
    // confidence (the round-313 bug) changes two settings and fails here.
    'live detection, New-track 0.35': autoSize.copyWith(
      trackerParams: const ByteTrackParams(highThresh: 0.35),
      cbiouParams: const CBiouParams(highThresh: 0.35),
    ),
    'live detection, C-BIoU, gate on, live video': autoSize.copyWith(
      trackerAlgorithm: TrackerAlgorithm.cbiou,
      motionGateEnabled: true,
      liveAiVideo: true,
    ),
    'time-lapse video, schedule, torch': autoSize.copyWith(
      captureTrigger: CaptureTrigger.timelapse,
      timeLapseSaveAs: TimeLapseSaveAs.video,
      scheduleEnabled: true,
      timeLapseTorch: true,
      autoThrottle: true,
    ),
    'motion photos, fixed rate': autoSize.copyWith(
      captureTrigger: CaptureTrigger.motion,
      autoThrottle: false,
      gtFramesEnabled: true,
    ),
  };

  group('camera Settings', () {
  final covered = <String>{};
  // Checked once every start below ran (not when the group is filtered).
  tearDownAll(() {
    if (covered.isEmpty) return;
    final all = flatten(const SessionConfig().toJson()).keys.toSet();
    final missing = all.difference(covered).difference(notOnTheSheet.keys.toSet());
    expect(missing, isEmpty,
        reason: 'no control changed these: give them a control (AGENTS: expose new tunables) or list them in '
            'notOnTheSheet with the reason');
  });
  for (final MapEntry(key: name, value: config) in starts.entries) {
    testWidgets('($name): every control changes one setting and can be changed back', (tester) async {
      final draft = SettingsDraft();
      await openSheet(tester, config, draft);
      Future<Map<String, Object?>> snap() async => flatten(draft.value!.toJson());
      for (final tab in ['Setup', 'Detection', 'Photos', 'Power']) {
        await tester.tap(find.text(tab).first);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        await openAllFolds(tester);
        final shown = controlsShown();
        covered.addAll(await checkNumberBoxes(tester, snap, rules: sheetBoxRules));
        // Typing changed every box and back, so the same controls must show:
        // an open fold that closed by itself (round 313: a warning line above
        // it made Flutter build it new) would hide some.
        expect(controlsShown(), shown, reason: '$tab tab: the same controls show after typing into every box');
        covered.addAll(await checkSwitches(tester, snap));
        covered.addAll(await checkDropdowns(tester, snap));
        // A fold that a switch hid and showed again opens closed, as on the
        // phone; open them before counting.
        await openAllFolds(tester);
        expect(controlsShown(), shown, reason: '$tab tab: the same controls show after changing everything back');
      }
      expect(tester.takeException(), isNull);
    });
  }

  });

  // The owner's report (round 313), on the camera: with Confidence at 0.50,
  // New-track confidence 0.50 could not be typed, and a trip of Confidence
  // up and down left New-track raised for good.
  testWidgets('camera Settings: New-track confidence 0.50 with Confidence 0.50, and no ratchet (r313)', (tester) async {
    final draft = SettingsDraft();
    await openSheet(tester, autoSize.copyWith(confidenceThreshold: 0.5, trackerParams: const ByteTrackParams(highThresh: 0.6)), draft);
    await tester.tap(find.text('Detection').first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await openAllFolds(tester);
    Finder boxOf(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is NumericSettingField && w.label == label),
      matching: find.byType(TextField),
    );
    await typeLikeAPerson(tester, boxOf('New-track confidence'), '0,5');
    await unfocus(tester);
    expect(draft.value!.trackerParams.highThresh, 0.5, reason: 'typed with a comma, stored as typed');
    expect(find.textContaining('Not above the Confidence threshold (0.50)'), findsOneWidget);
    await typeLikeAPerson(tester, boxOf('Confidence threshold'), '0.9');
    await typeLikeAPerson(tester, boxOf('Confidence threshold'), '0.25');
    await unfocus(tester);
    expect(draft.value!.confidenceThreshold, 0.25);
    expect(draft.value!.trackerParams.highThresh, 0.5, reason: 'never raised by the confidence');
    expect(find.textContaining('above the Confidence threshold'), findsNothing);
  });

  testWidgets('camera Settings: Reset while a box holds a refused number resets everything (r313 review)', (tester) async {
    final draft = SettingsDraft();
    await openSheet(
      tester,
      autoSize.copyWith(trackerParams: const ByteTrackParams(matchThresh: 0.3, velocitySmoothing: 0.8)),
      draft,
    );
    await tester.tap(find.text('Detection').first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await openAllFolds(tester);
    final box = find.descendant(
      of: find.byWidgetPredicate((w) => w is NumericSettingField && w.label == 'Match overlap (IoU)'),
      matching: find.byType(TextField),
    );
    await typeLikeAPerson(tester, box, '0.95'); // 0.9 is valid on the way, 0.95 is not
    final reset = find.text('Reset tracking to defaults');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(draft.value!.trackerParams.toJson(), const ByteTrackParams().toJson());
    expect(tester.widget<TextField>(box).controller!.text, '0.10');
    expect(find.textContaining('Not changed'), findsNothing, reason: 'the reset value is shown without an old note');
  });

  testWidgets('camera Settings: the session length unit changes how it is shown, never the length', (tester) async {
    final draft = SettingsDraft();
    await openSheet(tester, const SessionConfig(sessionMinutes: 90), draft);
    final box = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '60');
    expect(tester.widget<TextField>(box).controller!.text, '90');
    await tester.tap(find.text('Hours'));
    await tester.pump();
    expect(tester.widget<TextField>(box).controller!.text, '1.5');
    expect(draft.value!.sessionMinutes, 90, reason: 'before round 313, 60 minutes became 60 h here');
    await typeLikeAPerson(tester, box, '0');
    expect(draft.value!.sessionMinutes, 90, reason: '0 is refused');
    expect(find.textContaining('At least 1 minute'), findsOneWidget);
    await typeLikeAPerson(tester, box, '2');
    expect(draft.value!.sessionMinutes, 120);
    // The folder name box (a free text box) changes only the folder name.
    final before = flatten(draft.value!.toJson());
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'session'), 'meadow');
    await tester.pump();
    expect(changedKeys(before, flatten(draft.value!.toJson())), {'folderName'});
    expect(draft.value!.folderName, 'meadow');
  });

  // ---------------------------------------------------------------- videos
  testWidgets('Find animals in videos settings: every control changes one setting and can be changed back', (tester) async {
    tall(tester);
    final prefs = VideoAnalysisPrefs();
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: VideoTuningScreen(prefs: prefs, alsoIdentify: true)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Everything the screen stores, in SharedPreferences (video_analysis_*
    // and the identification settings it shares with Identify organisms).
    Future<Map<String, Object?>> snap() async {
      await tester.pump();
      final p = await SharedPreferences.getInstance();
      return {for (final k in p.getKeys()) k: p.get(k)};
    }

    // Save once so every key exists before the first comparison.
    await prefs.save();
    await (await IdentifyPrefs.load()).save();
    await openAllFolds(tester);
    final shown = controlsShown();
    final changed = <String>{
      ...await checkNumberBoxes(tester, snap),
      ...await checkSliders(tester, snap),
      ...await checkSwitches(tester, snap),
      ...await checkDropdowns(tester, snap),
    };
    expect(changed, containsAll(['video_analysis_confidence', 'video_analysis_bytetrack', 'video_analysis_occlusion_s']));
    await openAllFolds(tester);
    expect(controlsShown(), shown, reason: 'the same controls show after changing everything back');
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------- identification
  testWidgets('Identify organisms settings: every control changes one setting and can be changed back', (tester) async {
    tall(tester);
    // Merging on: its boxes show and are typed too.
    final prefs = IdentifyPrefs(mergeVisits: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [IdentifySettingsFields(prefs: prefs, onEdit: (change) => setState(change))],
            ),
          ),
        ),
      ),
    );
    Future<Map<String, Object?>> snap() async => flatten(prefs.toJson());
    await openAllFolds(tester);
    final changed = <String>{
      ...await checkNumberBoxes(tester, snap),
      ...await checkSwitches(tester, snap),
      ...await checkDropdowns(tester, snap),
    };
    expect(changed, isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
