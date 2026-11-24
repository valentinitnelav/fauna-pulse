// The never-throwing reads of saved settings (models/saved_prefs.dart). A typed get
// (getDouble, getInt, getString, getBool, getStringList) throws when the key holds another type,
// and a loader that throws keeps its screen from opening, so the last test fails when one is
// added anywhere in lib/.

import 'dart:io';

import 'package:fauna_pulse/fauna_pulse/models/model_choice_keys.dart';
import 'package:fauna_pulse/fauna_pulse/models/models_on_phone.dart';
import 'package:fauna_pulse/fauna_pulse/models/saved_prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SharedPreferences> prefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('numbers: another type or not finite gives the fallback, out of range is clamped', () async {
    final p = await prefs({'text': 'x', 'whole': 3, 'big': 1e15, 'low': -2.0, 'inf': double.infinity, 'half': 2.5});
    expect(p.doubleIn('text', 0.6, 0.5, 0.99), 0.6);
    expect(p.doubleIn('missing', 0.6, 0.5, 0.99), 0.6);
    expect(p.doubleIn('inf', 0.6, 0.5, 0.99), 0.6);
    expect(p.doubleIn('whole', 0, 0, 10), 3.0, reason: 'a saved int is a number too');
    expect(p.doubleIn('big', 0, 0, 10), 10);
    expect(p.doubleIn('low', 1, 0, 10), 0);
    expect(p.intIn('half', 0, 0, 8), 3, reason: 'a saved decimal is rounded');
    expect(p.intIn('big', 0, 0, 8), 8);
    expect(p.intIn('text', 4, 0, 8), 4);
    expect(p.doubleOrNull('text'), isNull);
    expect(p.intOrNull('inf'), isNull);
    expect(p.intOrNull('whole'), 3);
  });

  test('text, switches and lists: another type gives the fallback', () async {
    final p = await prefs({
      'n': 5,
      's': 'a',
      'b': true,
      'bs': 'true',
      'list': ['a', 'b'],
    });
    expect(p.stringOrNull('n'), isNull);
    expect(p.stringOrNull('s'), 'a');
    expect(p.boolOr('b', false), isTrue);
    expect(p.boolOr('bs', false), isFalse, reason: 'the text "true" is not a switch');
    expect(p.boolOr('n', true), isTrue);
    expect(p.stringListOrNull('list'), ['a', 'b']);
    expect(p.stringListOrNull('s'), isNull);
  });

  test('a damaged list of the models chosen for an answer is left out, not read shifted', () async {
    // getStringList cast every entry and threw on the number; dropping only the number would
    // have read the name list as the identification model.
    await prefs({
      '${kWatchChoicePrefPrefix}bees': ['det.tflite', 'bioclip.tflite', 'list.fpack'],
      '${kWatchChoicePrefPrefix}moths': ['det.tflite', 7, 'list.fpack'],
      '${kWatchChoicePrefPrefix}birds': 'det.tflite',
    });
    final got = await watchChoices(['bees', 'moths', 'birds']);
    expect(got.keys, ['bees']);
    expect(got['bees']!.idModel, 'bioclip.tflite');
  });

  test('no typed get of a saved setting in lib/ (use saved_prefs.dart)', () {
    final typedGet = RegExp(r'\.get(Double|Int|Bool|String|StringList)\(');
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (typedGet.hasMatch(lines[i])) found.add('${f.path}:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'a typed get throws when the key holds another type');
  });
}
