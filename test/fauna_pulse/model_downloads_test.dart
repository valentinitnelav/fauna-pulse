// Tests for the download catalogue (round 268): the shipped
// assets/model_downloads.json parses completely, links are built from the
// base URL, a bad entry is skipped without hiding the others, and the
// download dialog resumes with the file that failed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

void main() {
  test('the shipped catalogue lists every model with safe names, sizes and checksums', () {
    final c = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    expect(c.detectors.map((d) => d.id), ['megadetector-v6', 'flatbug-n', 'insectdct-v8-s']);
    expect(c.identification.map((d) => d.id), ['insectdct-cls-v7', 'bioclip-2', 'bioclip-2.5']);
    final all = [
      for (final d in [...c.detectors, ...c.identification]) ...[d.file, for (final l in d.lists) l.file],
    ];
    expect(all, hasLength(3 + 3 + 1 + 2 + 2));
    for (final f in all) {
      expect(f.url.isScheme('https'), isTrue, reason: f.name);
      expect(f.url.path, endsWith('/${f.name}'));
      expect(f.bytes, greaterThan(0), reason: f.name);
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.name);
    }
    expect(
      c.detectors.first.file.url.toString(),
      'https://github.com/valentinitnelav/fauna-pulse/releases/download/v0.8.0-alpha.1/MDV6-yolov10-c_int8_256.tflite',
    );
    expect(c.modelFor('/data/x/bioclip-2_image_fp16_4d.tflite')?.title, 'BioCLIP 2');
    final (model, list) = c.listFor('insectdct-cls-v7_eff2s_fp16.fpack')!;
    expect(model.id, 'insectdct-cls-v7');
    expect(list.title, 'Its 104 classes');
    expect(c.identification.first.icon, ModelPurposeIcon.flowers);
  });

  test('an entry with an unsafe name or a non-HTTPS link is skipped; a file may carry its own link', () {
    final c = ModelDownloads.parse('''
{"base_url": "https://example.org/r/",
 "detectors": [
   {"id": "bad", "icon": "animals", "title": "Bad", "purpose": "p", "file": {"name": "../x.tflite", "bytes": 1}},
   {"id": "http", "icon": "animals", "title": "Http", "purpose": "p", "file": {"name": "h.tflite", "bytes": 1, "url": "http://example.org/h.tflite"}},
   {"id": "ok", "icon": "insects", "title": "Ok", "purpose": "p", "file": {"name": "ok.tflite", "bytes": 5, "url": "https://huggingface.co/x/resolve/main/ok.tflite"}}
 ]}''');
    expect(c.detectors.map((d) => d.id), ['ok']);
    expect(c.detectors.single.file.url.host, 'huggingface.co');
    expect(c.detectors.single.file.sha256, isNull);
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
