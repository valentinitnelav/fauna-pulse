// Tests for the model list (rounds 268, 276): the shipped
// assets/model_downloads.json parses completely and names every known model
// with its licence, source and citation, links are built from the base URL,
// a file finds its model by name (the naming rule), a bad entry is skipped
// without hiding the others, and the download dialog resumes with the file
// that failed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart' show modelIdOf;
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

void main() {
  test('the shipped list names every known model; the offered files have safe names, sizes and checksums', () {
    final c = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    expect(c.detectors.map((d) => d.id), ['arthronat-n', 'mdv6-yolov10c', 'flatbug-n', 'flatbug-s', 'insectdct-v8s']);
    expect(c.identification.map((d) => d.id), [
      'insectdct-cls-v7-eff2s',
      'insectdct-cls-v7-cnb',
      'insectdct-cls-v7-res',
      'bioclip-2',
      'bioclip-2.5',
    ]);
    expect(c.detectorOffers.map((d) => d.id), ['mdv6-yolov10c', 'flatbug-n', 'insectdct-v8s']);
    expect(c.identificationOffers.map((d) => d.id), ['insectdct-cls-v7-eff2s', 'bioclip-2', 'bioclip-2.5']);
    final all = [
      for (final d in [...c.detectorOffers, ...c.identificationOffers]) ...[d.file!, for (final l in d.nameLists) l.file],
    ];
    expect(all, hasLength(3 + 3 + 1 + 2 + 2));
    for (final f in all) {
      expect(f.url.isScheme('https'), isTrue, reason: f.name);
      expect(f.url.path, endsWith('/${f.name}'));
      expect(f.bytes, greaterThan(0), reason: f.name);
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.name);
    }
    // Every known model says where it comes from, under which licence, and how to cite it.
    for (final d in [...c.detectors, ...c.identification]) {
      expect(d.licence, isNotEmpty, reason: d.id);
      expect(d.source, startsWith('https://'), reason: d.id);
      expect(d.cite, isNotEmpty, reason: d.id);
    }
    expect(
      c.detectorOffers.first.file!.url.toString(),
      'https://github.com/valentinitnelav/fauna-pulse/releases/download/v0.8.0-alpha.1/MDV6-yolov10-c_int8_256.tflite',
    );
    expect(c.modelFor('/data/x/bioclip-2_image_fp16_4d.tflite')?.title, 'BioCLIP 2');
    final (model, list) = c.listFor('insectdct-cls-v7_eff2s_fp16.fpack')!;
    expect(model.id, 'insectdct-cls-v7-eff2s');
    expect(list.title, 'Its 104 classes');
    expect(list.classList, isTrue);
    expect(c.listFor('bioclip2_flower_visitors_32fam_v1.fpack')!.$2.classList, isFalse, reason: 'a label pack');
    expect(c.listFor('bioclip2_flower_visitors_32fam_v1.fpack')!.$2.licence, startsWith('CC0-1.0'));
  });

  test('a file finds its model by the offered name or by its first part (r276)', () {
    final c = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    String? title(String name) => c.modelFor(name)?.title;
    // Named by the rule: variants that are not offered.
    expect(title('flatbug-s_1024_fp16.tflite'), 'flat-bug s (larger)');
    expect(title('mdv6-yolov10c_640_fp16.tflite'), 'MegaDetector V6');
    expect(title('insectdct-cls-v7-res_224_fp16.tflite'), 'insectDCT classifier (ResNet50)');
    expect(title('bioclip-2.5_224_fp16.tflite'), 'BioCLIP 2.5');
    // Named before the rule: upper case, "-" and "." do not matter.
    expect(title('MDV6-yolov10-c_int8_320.tflite'), 'MegaDetector V6');
    expect(title('insectdct-v8-s_1024_fp16.tflite'), 'insectDCT detector');
    expect(title('bioclip-25_image_fp16.tflite'), 'BioCLIP 2.5');
    expect(title('insectdct-cls-v7_eff2s_fp16.tflite'), 'insectDCT classifier', reason: 'the offered file');
    expect(title('arthronat-n_640_int8.tflite'), 'ArthroNat n');
    // Not in the list.
    expect(title('my_bees_640.tflite'), isNull);
    expect(modelIdOf('/p/bioclip-2.5_224_fp16.tflite'), 'bioclip-2.5');
    expect(modelIdOf('nounderscore.tflite'), 'nounderscore');
  });

  test('an entry with an unsafe name, a non-HTTPS link, a repeated id or an unknown kind is skipped; a file may carry its own link', () {
    final c = ModelDownloads.parse('''
{"base_url": "https://example.org/r/",
 "models": [
   {"id": "bad", "kind": "detection_model", "title": "Bad", "purpose": "p", "file": {"name": "../x.tflite", "bytes": 1}},
   {"id": "http", "kind": "detection_model", "title": "Http", "purpose": "p", "file": {"name": "h.tflite", "bytes": 1, "url": "http://example.org/h.tflite"}},
   {"id": "ok", "kind": "detection_model", "title": "Ok", "purpose": "p", "file": {"name": "ok.tflite", "bytes": 5, "url": "https://huggingface.co/x/resolve/main/ok.tflite"}},
   {"id": "OK", "kind": "detection_model", "title": "Again", "purpose": "p"},
   {"id": "what", "kind": "detector", "title": "Unknown kind", "purpose": "p"},
   {"id": "known", "kind": "detection_model", "title": "Known", "purpose": "p", "cite": "Someone (2026)."},
   {"id": "cls", "kind": "identification_model", "title": "Cls", "purpose": "p", "file": {"name": "cls_224_fp16.tflite", "bytes": 3},
    "name_lists": [{"kind": "class_list", "title": "Its classes", "file": {"name": "cls_224_fp16.fpack", "bytes": 1}}]},
   {"id": "odd", "kind": "identification_model", "title": "Odd", "purpose": "p",
    "name_lists": [{"kind": "names", "title": "?", "file": {"name": "odd_x_v1.fpack", "bytes": 1}}]}
 ]}''');
    expect(c.detectors.map((d) => d.id), ['ok', 'known']);
    expect(c.identification.map((d) => d.id), ['cls']);
    expect(c.identification.single.nameLists.single.classList, isTrue);
    expect(c.detectors.first.file!.url.host, 'huggingface.co');
    expect(c.detectors.first.file!.sha256, isNull);
    expect(c.detectors.last.offered, isFalse);
    expect(c.detectors.last.cite, 'Someone (2026).');
    expect(c.detectorOffers.map((d) => d.id), ['ok']);
  });

  testWidgets('the download dialog shows the total, and Try again continues with the failed file', (tester) async {
    final a = DownloadFile(name: 'a.tflite', url: _url, bytes: 3 * 1024 * 1024);
    final b = DownloadFile(name: 'a.fpack', url: _url, bytes: 1024 * 1024);
    final calls = <String>[];
    var failOnce = true;
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<bool>(
              context: context,
              builder: (_) => DownloadFilesDialog(
                title: 'insectDCT classifier',
                description: 'The model and its class list.',
                files: [a, b],
                download: (f, onProgress, isCancelled) async {
                  calls.add(f.name);
                  onProgress(f.bytes, f.bytes);
                  if (f == b && failOnce) {
                    failOnce = false;
                    throw Exception('Download failed (HTTP 404).');
                  }
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Download insectDCT classifier'), findsOneWidget);
    expect(find.text('The model and its class list. In total 4.0 MB.'), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('⚠ Download failed (HTTP 404).'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(calls, ['a.tflite', 'a.fpack', 'a.fpack']);
    expect(result, isTrue);
  });
}

final _url = Uri.parse('https://example.org/f');
