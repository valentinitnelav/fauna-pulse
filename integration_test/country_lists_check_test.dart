// FaunaPulse (round 373): on-device check of a name list with country lists (GBIF keys and
// the names GBIF lists per country, label_pack.dart).
//
// Needs on the phone: the name list PACK in the app's identification/packs folder, and a
// session SESSION (folder under sessions/) with stored crops of the model MODEL. It
//   0. finds the country of POSITION (default: Leipzig) from the bundled borders, as a
//      session with that position would (round 374; a small test session is made and removed);
//   1. times the reading of the list's header (it runs at every listing of the name lists);
//   2. scores the session with the whole list, SMALL alone, COUNTRY with its neighbours and
//      once more with the country taken from the test session's position, and checks that
//      the "none of these" shares, the weights, the left-out crops, the "no organism" flags
//      and the joined track IDs are the same for all (the results of PACK in that session are
//      overwritten, last with COUNTRY and its neighbours);
//   3. opens Identify organisms on the test session (the country of its position and its
//      neighbours are the default) and on SESSION, reads what "Names of one country" says a run
//      will use, and chooses COUNTRY in the country list (the saved name list is set to PACK
//      and the saved country to COUNTRY: restore the saved settings afterwards, see
//      docs/AGENT_CHANGELOG_OVERVIEW.md, *Build and test*). PAGE_ONLY=true runs only this step.
// Run it as an installed build (no uninstall risk):
//   flutter build apk --debug --target-platform android-arm64 -t integration_test/country_lists_check_test.dart \
//     --dart-define=SESSION=<folder> --dart-define=PACK=<file>.fpack --dart-define=MODEL=<file>.tflite
//   adb -s <device-id> install -r build/app/outputs/flutter-apk/app-debug.apk   (stop if not "Success")
//   adb -s <device-id> shell am start -n com.faunapulse.app/com.ultralytics.yolo.MainActivity
//   adb -s <device-id> logcat -s flutter:I     (lines COUNTRY, HEADER, SCORE, FIXED, PAGE, then "All tests passed!")
// Afterwards rebuild and reinstall the normal app.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fauna_pulse/fauna_pulse/identification/country_lookup.dart';
import 'package:fauna_pulse/fauna_pulse/identification/country_names.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_job.dart';
import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart';
import 'package:fauna_pulse/fauna_pulse/identification/label_pack.dart';
import 'package:fauna_pulse/fauna_pulse/screens/identification_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _session = String.fromEnvironment('SESSION');
const _packName = String.fromEnvironment('PACK');
const _modelName = String.fromEnvironment('MODEL');
const _country = String.fromEnvironment('COUNTRY', defaultValue: 'DE');
const _small = String.fromEnvironment('SMALL', defaultValue: 'MT');
const _position = String.fromEnvironment('POSITION', defaultValue: '51.34,12.37'); // lat,lon in COUNTRY
// --dart-define=PAGE_ONLY=true: only step 3 (seconds instead of the minutes of step 2).
const _pageOnly = bool.fromEnvironment('PAGE_ONLY');

// ignore: avoid_print
void _log(String s) => print(s);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a name list with country lists on this phone', (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await WakelockPlus.enable();
    addTearDown(WakelockPlus.disable);
    final session = Directory('${(await getExternalStorageDirectory())!.path}/sessions/$_session');
    final pack = File('${(await IdentificationAssets.packsDir()).path}/$_packName');
    expect(session.existsSync(), isTrue, reason: 'no session $_session');
    expect(pack.existsSync(), isTrue, reason: 'no name list $_packName in identification/packs');

    // 0. The country of a session's position, from the borders the app carries.
    final here = Directory('${(await getExternalStorageDirectory())!.path}/country_lists_check/session with a position')
      ..createSync(recursive: true);
    addTearDown(() => here.parent.deleteSync(recursive: true));
    final latLon = _position.split(',');
    File('${here.path}/session.jsonl').writeAsStringSync(
      '{"type":"start_of_session","time_ms":1000,"config":{},"location":{"lat":${latLon[0]},"lon":${latLon[1]},"source":"manual"}}\n',
    );
    final lookups = <String>[];
    for (var i = 0; i < 2; i++) {
      final sw = Stopwatch()..start();
      final code = await tester.runAsync(() => sessionCountryOf(here));
      lookups.add('$code in ${sw.elapsedMilliseconds} ms');
    }
    _log('COUNTRY of $_position: $lookups (the first reads the borders)');
    expect(await tester.runAsync(() => sessionCountryOf(here)), _country);

    // 1. The header, read as every listing reads it.
    final times = <int>[];
    late Map<String, dynamic> header;
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      header = (await tester.runAsync(() => LabelPack.readHeader(pack)))!;
      times.add(sw.elapsedMilliseconds);
    }
    final regions = PackRegions.tryParse(header['regions'], header['rows'] as int);
    expect(regions, isNotNull, reason: '$_packName has no country lists');
    _log('HEADER read in $times ms; ${header['rows']} rows, ${regions!.countries.length} countries');

    // 2. Three country choices, with the phone's own identification settings.
    final prefs = await IdentifyPrefs.load();
    final paths = IdentificationPaths(session);
    final stem = stemOf(_packName);
    List<List<String>> table(File f) => [for (final l in f.readAsLinesSync()) l.split(',')];
    final fixed = <String, String>{}, tableMd5 = <String, String>{};
    for (final (label, scope, country) in [
      if (!_pageOnly) ...[
        ('whole', 'all', ''),
        ('$_small alone', 'country', _small),
        ('country of the position', 'neighbours', ''),
        ('$_country+neighbours', 'neighbours', _country),
      ],
    ]) {
      final sw = Stopwatch()..start();
      final summary = (await tester.runAsync(
        () => IdentificationJob.scoreSession(
          session,
          modelName: _modelName,
          modelId: stemOf(_modelName),
          packFile: pack,
          settings: {...prefs.toJson(), 'model': _modelName, 'pack': _packName, 'name_list_scope': scope, 'name_list_country': country},
          // SESSION itself may have no position: the test session's position stands in.
          countryOf: (_) => sessionCountryOf(here),
        ),
      ))!;
      final t = table(paths.tracksCsv(stem)), c = table(paths.cropsCsv(stem));
      int tc(String n) => t.first.indexOf(n);
      int cc(String n) => c.first.indexOf(n);
      fixed[label] = md5
          .convert(
            utf8.encode(
              jsonEncode([
                for (final r in t.skip(1)) [r[tc('track_id')], r[tc('none_p')], r[tc('flags')].split(';').contains('no_organism'), r[tc('merged_track_ids')]],
                for (final r in c.skip(1)) [r[cc('photo')], r[cc('weight')], r[cc('none_p')], r[cc('counted')]],
              ]),
            ),
          )
          .toString();
      tableMd5[label] = '${md5.convert(paths.tracksCsv(stem).readAsBytesSync())}';
      _log(
        'SCORE $label: ${sw.elapsed.inSeconds} s, names ${(summary['name_list'] as Map)['names']}, tracks ${summary['tracks_total']}, '
        'by rank ${summary['by_identified_rank']}, no organism ${summary['no_organism']}, keys ${t.skip(1).where((r) => r[tc('gbif_species_key')].isNotEmpty).length}, '
        'last column ${t[1].last}, from the position ${(summary['name_list'] as Map)['country_from_session']}, '
        'tracks table md5 ${tableMd5[label]}, memory peak ${ProcessInfo.maxRss ~/ (1 << 20)} MB',
      );
    }
    if (!_pageOnly) {
      _log('FIXED ${fixed.values.toSet().length == 1 ? 'the same for every choice' : 'DIFFERS: $fixed'}');
      expect(fixed.values.toSet(), hasLength(1), reason: 'the none shares, weights, flags or joins depend on the country choice');
      expect(tableMd5['country of the position'], tableMd5['$_country+neighbours'], reason: 'the country found from the position gives the same table as the country chosen by hand');
    }

    // 3. The page: first a session with a position and nothing chosen by hand.
    final sp = await SharedPreferences.getInstance();
    await sp.setString('identify_model', _modelName);
    await sp.setString('identify_pack', _packName);
    await sp.remove('identify_name_list_scope');
    await sp.remove('identify_name_list_country');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: IdentificationScreen(sessionDir: here)));
    final found = find.text('Where the session was recorded (${countryName(_country)})');
    for (var i = 0; i < 300 && found.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(found, findsOneWidget);
    _log('PAGE with a position: ${tester.widget<Text>(find.textContaining('run chooses among')).data}');
    expect(tester.takeException(), isNull);
    _log('SHOT country_lists_position');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));

    // Then SESSION, with the country chosen by hand.
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(useMaterial3: true), home: IdentificationScreen(sessionDir: session)));
    final heading = find.text('Names of one country');
    for (var i = 0; i < 300 && heading.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(heading, findsOneWidget);
    final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
    // The sentence on the names a run will use (it starts with "A run" or ends with "a run").
    final used = find.textContaining('run chooses among');
    await tester.scrollUntilVisible(used, 80, scrollable: list);
    await tester.pump(const Duration(milliseconds: 500));
    _log('PAGE ${tester.widget<Text>(used).data}');
    _log('SHOT country_lists_default');
    await tester.pump(const Duration(seconds: 6));
    // Choose COUNTRY by hand in the long country list.
    final code = regions.countries.keys.contains(_country) ? _country : regions.countries.keys.first;
    // The box sits above the sentence: bring it back into view first.
    final countryBox = find.byKey(const ValueKey('name list country  false'));
    await tester.dragUntilVisible(countryBox, list, const Offset(0, 150));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(countryBox);
    await tester.pumpAndSettle();
    final item = find.textContaining(RegExp('^${RegExp.escape(countryName(code))} \\('));
    await tester.scrollUntilVisible(item, 300, scrollable: find.byType(Scrollable).last, maxScrolls: 200);
    await tester.tap(item.last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(used, 80, scrollable: list);
    await tester.pump(const Duration(milliseconds: 500));
    _log('PAGE after choosing $code: ${tester.widget<Text>(used).data}');
    for (final w in tester.widgetList<Text>(find.textContaining('⚠'))) {
      _log('PAGE ${w.data}');
    }
    expect((await IdentifyPrefs.load()).nameListCountry, code, reason: 'the choice is saved at once');
    expect(tester.takeException(), isNull);
    _log('SHOT country_lists_page');
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 90)));
}
