// Tests for the model list (rounds 268, 276): the shipped
// assets/model_downloads.json parses completely and names every known model
// with its licence and source, links are built from the base URL,
// a file finds its model by name (the naming rule), a bad entry is skipped
// without hiding the others, and the download dialog resumes with the file
// that failed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fauna_pulse/fauna_pulse/identification/identification_store.dart' show modelIdOf;
import 'package:fauna_pulse/fauna_pulse/models/model_downloads.dart';
import 'package:fauna_pulse/fauna_pulse/models/model_file_security.dart' show kMaxModelFileBytes;
import 'package:fauna_pulse/fauna_pulse/widgets/download_files_dialog.dart';

void main() {
  test('the shipped list names every known model; the offered files have safe names, sizes and checksums', () {
    final c = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    // One entry per file (round 390: MegaDetector V6 offers several, and keeps its old file).
    expect(c.detectors.map((d) => d.file?.name ?? d.id), [
      'arthronat-n',
      'mdv6-yolov10c_320_fp16.tflite',
      'mdv6-yolov10c_640_fp16.tflite',
      'mdv6-yolov10c_256_w8a32.tflite',
      'mdv6-yolov10e_320_fp16.tflite',
      'mdv6-yolov10e_640_fp16.tflite',
      'flatbug-n_640_fp16.tflite',
      'flatbug-s_640_fp16.tflite',
      'insectdct-v8s_640_fp16.tflite',
    ]);
    expect(c.identification.map((d) => d.id), [
      'insectdct-cls-v7-eff2s',
      'insectdct-cls-v7-cnb',
      'insectdct-cls-v7-res',
      'bioclip-2',
      'bioclip-2.5',
    ]);
    expect(c.detectorOffers.map((d) => d.id), [
      'mdv6-yolov10c',
      'mdv6-yolov10c',
      'mdv6-yolov10e',
      'mdv6-yolov10e',
      'flatbug-n',
      'flatbug-s',
      'insectdct-v8s',
    ]);
    // Round 390: the old MegaDetector file is no longer offered, but keeps its link (for
    // update_catalogue.py --urls) and a note for the phones that have it.
    final formerFiles = c.detectors.where((d) => d.former).toList();
    expect(formerFiles.map((d) => d.file!.name), ['mdv6-yolov10c_256_w8a32.tflite']);
    expect(formerFiles.single.noteOfFile, startsWith('An older file of this model'));
    // Each MegaDetector file says what it is for; the files of one model differ only there.
    for (final d in c.detectorOffers.where((d) => d.id.startsWith('mdv6'))) {
      expect(d.fileNote, isNotNull, reason: d.file!.name);
    }
    // Families (round 390): Download & import models shows a family's purpose once, under its
    // heading (round 392), so the models of one family must share it.
    expect({for (final d in c.detectorOffers) d.id: d.family}, {
      'mdv6-yolov10c': 'MegaDetector V6',
      'mdv6-yolov10e': 'MegaDetector V6',
      'flatbug-n': 'flat-bug',
      'flatbug-s': 'flat-bug',
      'insectdct-v8s': null,
    });
    for (final d in c.detectors.where((d) => d.family != null)) {
      expect(d.purpose, c.detectors.firstWhere((o) => o.family == d.family).purpose, reason: d.id);
    }
    expect(c.uses.firstWhere((u) => u.id == 'mammals_birds').find.map((d) => d.file!.name), [
      'mdv6-yolov10c_320_fp16.tflite',
      'mdv6-yolov10c_640_fp16.tflite',
      'mdv6-yolov10e_320_fp16.tflite',
      'mdv6-yolov10e_640_fp16.tflite',
    ], reason: 'the fastest file first; a model brings its files in their order');
    expect(c.identificationOffers.map((d) => d.id), ['insectdct-cls-v7-eff2s', 'bioclip-2', 'bioclip-2.5']);
    final all = [
      for (final d in [...c.detectorOffers, ...c.identificationOffers]) ...[d.file!, for (final l in d.nameLists) l.file],
    ];
    expect(all, hasLength(7 + 3 + 1 + 7 + 6),
        reason: 'round 390: four MegaDetector files; round 322: the v2 label packs, no 32-family demo; round 379: the six continent lists of BioCLIP 2 and its world '
            'mammals and birds; round 381: the six continent lists of BioCLIP 2.5');
    // Round 322: the lists no longer offered keep their pinned links and
    // checksums (update_catalogue.py --urls matches them by checksum).
    final former = [for (final d in c.identificationOffers) ...d.formerNameLists];
    expect(former.map((l) => l.file.name), [
      'bioclip-2_pollinator-orders-europe_v1.fpack',
      'bioclip-2_pollinator-orders-europe_v2.fpack',
      'bioclip-2_pollinator-orders-europe_v3.fpack',
      'bioclip-2_flower-visitors-32fam_v1.fpack',
      'bioclip-2_mammals-birds-world_v1.fpack',
      'bioclip-2_mammals-birds-world_v2.fpack', // round 388: replaced by v4 (country lists)
      'bioclip-2.5_pollinator-orders-europe_v1.fpack',
      'bioclip-2.5_pollinator-orders-europe_v2.fpack',
      'bioclip-2.5_flower-visitors-32fam_v1.fpack',
    ]);
    for (final l in former) {
      expect(l.note ?? l.warning, isNotNull, reason: l.file.name);
      expect(l.warning != null, l.file.name.contains('32fam'), reason: 'only the demo lists warn: ${l.file.name}');
    }
    for (final f in [...all, for (final l in former) l.file, for (final d in formerFiles) d.file!]) {
      expect(f.url.isScheme('https'), isTrue, reason: f.name);
      expect(f.url.path, endsWith('/${f.name}'));
      // Round 314: a Hugging Face link is pinned to one upload (a commit), never a branch.
      if (f.url.host == 'huggingface.co') {
        expect(f.url.path, matches(RegExp(r'/resolve/[0-9a-f]{40}/[^/]+$')), reason: f.name);
      }
      expect(f.bytes, greaterThan(0), reason: f.name);
      // Round 314: one size limit for every kind of file; every listed file fits it.
      expect(f.bytes, lessThanOrEqualTo(kMaxModelFileBytes), reason: f.name);
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: f.name);
    }
    // Every known model says where it comes from (where its authors say how to
    // cite it) and under which licence.
    for (final d in [...c.detectors, ...c.identification]) {
      expect(d.licence, isNotEmpty, reason: d.id);
      expect(d.source, startsWith('https://'), reason: d.id);
    }
    expect(
      c.detectorOffers.first.file!.url.toString(),
      'https://huggingface.co/Valen-Peregrine/mdv6-tflite/resolve/8e06c919a320806147c008933ef51be32052614e/mdv6-yolov10c_320_fp16.tflite',
    );
    expect(
      c.identificationOffers.last.file!.url.toString(),
      'https://huggingface.co/Valen-Peregrine/bioclip-2.5-tflite/resolve/dd1f5b7259ce3ee2d3aef89c200dde96745f3e85/bioclip-2.5_224_fp16.tflite',
    );
    expect(c.modelFor('/data/x/bioclip-2_224_fp16.tflite')?.title, 'BioCLIP 2');
    final (model, list) = c.listFor('insectdct-cls-v7-eff2s_224_fp16.fpack')!;
    expect(model.id, 'insectdct-cls-v7-eff2s');
    expect(list.title, 'Its 104 classes');
    expect(list.classList, isTrue);
    expect(c.listFor('bioclip-2_pollinator-orders-europe_v2.fpack')!.$2.classList, isFalse, reason: 'a label pack');
    expect(c.listFor('bioclip-2_pollinator-orders-europe_v2.fpack')!.$2.licence, startsWith('CC0-1.0'));
    // Round 379: Europe v4 (newer GBIF data) is offered and suggested, v3 is kept as a former list;
    // the other five continents are offered too.
    expect(c.listFor('bioclip-2_pollinator-orders-europe_v4.fpack')!.$2.licence, startsWith('CC0-1.0'));
    expect(c.listFor('bioclip-2_pollinator-orders-europe_v3.fpack')!.$2.note, startsWith('Replaced by version 4'));
    expect(c.identificationOffers.firstWhere((d) => d.id == 'bioclip-2').nameLists.map((l) => l.file.name), containsAll([
      for (final r in ['north-america', 'south-america', 'africa', 'asia', 'oceania']) 'bioclip-2_pollinator-orders-${r}_v1.fpack',
    ]));
    // Round 381: the same for BioCLIP 2.5, Europe v3 replacing v2.
    expect(c.identificationOffers.firstWhere((d) => d.id == 'bioclip-2.5').nameLists.map((l) => l.file.name), [
      for (final r in ['europe_v3', 'north-america_v1', 'south-america_v1', 'africa_v1', 'asia_v1', 'oceania_v1'])
        'bioclip-2.5_pollinator-orders-$r.fpack',
    ]);
    expect(c.listFor('bioclip-2.5_pollinator-orders-europe_v2.fpack')!.$2.note, startsWith('Replaced by version 3'));
    expect(c.uses.where((u) => u.id == 'pollinators' || u.id == 'flat_surface').map((u) => u.name.first.$2.file.name),
        everyElement('bioclip-2_pollinator-orders-europe_v4.fpack'));
    // A list no longer offered is still found, with its licence and its note.
    final (_, demo) = c.listFor('bioclip-2_flower-visitors-32fam_v1.fpack')!;
    expect(demo.licence, startsWith('CC0-1.0'));
    expect(demo.warning, startsWith('A demo list, no longer updated'));
  });

  test('a file finds its model by the offered name or by its first part (r276)', () {
    final c = ModelDownloads.parse(File('assets/model_downloads.json').readAsStringSync());
    String? title(String name) => c.modelFor(name)?.title;
    // Named by the rule: variants that are not offered.
    expect(title('flatbug-s_1024_fp16.tflite'), 'flat-bug s (larger)');
    expect(title('mdv6-yolov10c_1280_fp16.tflite'), 'MegaDetector V6 c (compact)');
    expect(title('mdv6-yolov10e_1280_fp16.tflite'), 'MegaDetector V6 e (larger)');
    expect(title('insectdct-cls-v7-res_224_fp16.tflite'), 'insectDCT classifier (ResNet50)');
    expect(title('bioclip-2.5_224_fp16.tflite'), 'BioCLIP 2.5');
    // Named before the rule: upper case, "-" and "." do not matter.
    expect(title('MDV6-yolov10-c_int8_320.tflite'), 'MegaDetector V6 c (compact)');
    expect(title('insectdct-v8-s_1024_fp16.tflite'), 'insectDCT detector');
    expect(title('bioclip-25_image_fp16.tflite'), 'BioCLIP 2.5');
    expect(title('arthronat-n_640_int8.tflite'), 'ArthroNat n');
    // Not in the list.
    expect(title('my_bees_640.tflite'), isNull);
    expect(modelIdOf('/p/bioclip-2.5_224_fp16.tflite'), 'bioclip-2.5');
    expect(modelIdOf('nounderscore.tflite'), 'nounderscore');
    // The offered file finds its model by its exact name, even when its first
    // part names another model.
    final x = ModelDownloads.parse('{"base_url": "https://example.org/r/", "models": ['
        '{"id": "det", "kind": "detection_model", "title": "Det", "purpose": "p", "file": {"name": "other_640_fp16.tflite", "bytes": 5}},'
        '{"id": "other", "kind": "detection_model", "title": "Other", "purpose": "p"}]}');
    expect(x.modelFor('/p/other_640_fp16.tflite')?.id, 'det', reason: 'the offered file: its exact name wins over its first part');
    expect(x.modelFor('other_320_fp16.tflite')?.id, 'other');
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
   {"id": "known", "kind": "detection_model", "title": "Known", "purpose": "p"},
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
    expect(c.detectorOffers.map((d) => d.id), ['ok']);
  });

  test('uses (r278): a suggestion of a model that is not offered, or of a list it lacks, is left out', () {
    final c = ModelDownloads.parse('''
{"base_url": "https://example.org/r/",
 "models": [
   {"id": "det", "kind": "detection_model", "title": "Det", "purpose": "p", "file": {"name": "det_640_fp16.tflite", "bytes": 5}},
   {"id": "known", "kind": "detection_model", "title": "Known", "purpose": "p"},
   {"id": "cls", "kind": "identification_model", "title": "Cls", "purpose": "p", "file": {"name": "cls_224_fp16.tflite", "bytes": 3},
    "name_lists": [{"kind": "class_list", "title": "Its classes", "file": {"name": "cls_224_fp16.fpack", "bytes": 1}}]},
   {"id": "clip", "kind": "identification_model", "title": "Clip", "purpose": "p", "file": {"name": "clip_224_fp16.tflite", "bytes": 9},
    "name_lists": [{"kind": "label_pack", "title": "A", "file": {"name": "clip_a_v1.fpack", "bytes": 1}},
                   {"kind": "label_pack", "title": "B", "file": {"name": "clip_b_v1.fpack", "bytes": 1}}]}
 ],
 "uses": [
   {"id": "bees", "icon": "pollinators", "title": "Bees", "setup": "s",
    "find": ["known", "nothing", "det"],
    "name": [{"model": "cls"}, {"model": "clip"}, {"model": "clip", "list": "clip_b_v1.fpack"}, {"model": "clip", "list": "clip_z_v1.fpack"}]},
   {"id": "empty", "title": "No detector offered", "find": ["known"]},
   {"title": "No id"}
 ]}''');
    final u = c.uses.single;
    expect(u.id, 'bees');
    expect(u.find.map((d) => d.id), ['det'], reason: 'known but not offered, and unknown, are left out');
    expect([for (final (m, l) in u.name) '${m.id}/${l.file.name}'], ['cls/cls_224_fp16.fpack', 'clip/clip_b_v1.fpack'],
        reason: 'a model with several lists needs the list named');
  });

  test('several files per detection model and former files (r390)', () {
    final c = ModelDownloads.parse('''
{"models": [
   {"id": "det", "kind": "detection_model", "title": "Det", "purpose": "p", "note": "model note",
    "files": [{"name": "det_320_fp16.tflite", "bytes": 5, "url": "https://example.org/det_320_fp16.tflite", "note": "fast"},
              {"name": "det_640_fp16.tflite", "bytes": 6, "url": "https://example.org/det_640_fp16.tflite"}],
    "former_files": [{"name": "det_256_int8.tflite", "bytes": 4, "url": "https://example.org/det_256_int8.tflite", "note": "old"}]},
   {"id": "gone", "kind": "detection_model", "title": "Gone", "purpose": "p",
    "former_files": [{"name": "gone_640_fp16.tflite", "bytes": 4, "url": "https://example.org/gone_640_fp16.tflite"}]},
   {"id": "two", "kind": "identification_model", "title": "Two files", "purpose": "p",
    "files": [{"name": "two_224_fp16.tflite", "bytes": 1, "url": "https://example.org/a.tflite"},
              {"name": "two_336_fp16.tflite", "bytes": 1, "url": "https://example.org/b.tflite"}]},
   {"id": "old", "kind": "identification_model", "title": "Former file", "purpose": "p",
    "former_files": [{"name": "old_224_fp16.tflite", "bytes": 1, "url": "https://example.org/old.tflite"}]}
 ],
 "uses": [{"id": "u", "title": "U", "find": ["gone", "det"]}]}''');
    expect(c.detectors.map((d) => d.file!.name), ['det_320_fp16.tflite', 'det_640_fp16.tflite', 'det_256_int8.tflite', 'gone_640_fp16.tflite']);
    expect(c.detectorOffers.map((d) => d.file!.name), ['det_320_fp16.tflite', 'det_640_fp16.tflite']);
    expect(c.detectors.map((d) => d.noteOfFile), ['fast', 'model note', 'old', null], reason: "a file's own note, else the model's");
    expect(c.identification, isEmpty, reason: 'an identification model would repeat its name lists with every file');
    expect(c.uses.single.find.map((d) => d.file!.name), ['det_320_fp16.tflite', 'det_640_fp16.tflite'],
        reason: 'a model brings its offered files in their order, never a former one');
    // A former file finds its own entry (and note); another file of the model gets the model's.
    expect(c.modelFor('/p/det_256_int8.tflite')!.former, isTrue);
    expect(c.modelFor('/p/det_256_int8.tflite')!.noteOfFile, 'old');
    expect(c.modelFor('det_1024_fp16.tflite')!.note, 'model note');
    expect(c.modelFor('det_1024_fp16.tflite')!.offered, isTrue);
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
