// Tests for the whole-session gallery export (round 93): the album-name
// safety net and the chunked channel driver — chunk sizes, count
// accumulation, early stop on unsupported phones, surviving a failed chunk,
// and progress ticks. The native MediaStore side is exercised manually on the
// test phone (no Kotlin test harness exists in android/).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fauna_pulse/fauna_pulse/capture/crop_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('galleryAlbumName', () {
    test('already-clean session names pass through unchanged', () {
      expect(galleryAlbumName('Sunflower_2'), 'Sunflower_2');
      expect(galleryAlbumName('white clover-B'), 'white clover-B');
    });

    test('characters MediaStore may reject become underscores', () {
      expect(galleryAlbumName('rosa/canina?'), 'rosa_canina_');
    });

    test('a leading dot is stripped (it would hide the album)', () {
      expect(galleryAlbumName('.hidden'), 'hidden');
    });

    test('empty or all-illegal names fall back to "session"', () {
      expect(galleryAlbumName(''), 'session');
      expect(galleryAlbumName('   '), 'session');
    });
  });

  group('exportPhotosToGallery', () {
    // Channel identity is by name, so a fresh instance reaches the same
    // mock handler the production code's private channel does.
    const channel = MethodChannel('faunapulse/crop');

    List<File> fakePhotos(int n) =>
        List.generate(n, (i) => File('/fake/roi_frames/roi_1_$i.jpg'));

    void mockChannel(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      '60 photos arrive as chunks of 25/25/10 and counts accumulate',
      () async {
        final chunkSizes = <int>[];
        final progress = <int>[];
        mockChannel((call) async {
          expect(call.method, 'saveImagesToGallery');
          final args = call.arguments as Map;
          expect(args['album'], 'TestPlant');
          final paths = (args['paths'] as List).cast<String>();
          chunkSizes.add(paths.length);
          return {
            'supported': true,
            'exported': paths.length - 1,
            'skipped': 1,
            'failed': 0,
          };
        });
        final res = await exportPhotosToGallery(
          fakePhotos(60),
          'TestPlant',
          onProgress: (done, total) {
            expect(total, 60);
            progress.add(done);
          },
        );
        expect(chunkSizes, [25, 25, 10]);
        expect(progress, [25, 50, 60]);
        expect(res.supported, isTrue);
        expect(res.exported, 57); // (25-1) + (25-1) + (10-1)
        expect(res.skipped, 3);
        expect(res.failed, 0);
      },
    );

    test(
      'an unsupported (pre-Android-10) reply stops further chunks',
      () async {
        var calls = 0;
        mockChannel((call) async {
          calls++;
          return {'supported': false, 'exported': 0, 'skipped': 0, 'failed': 0};
        });
        final res = await exportPhotosToGallery(fakePhotos(60), 'TestPlant');
        expect(calls, 1);
        expect(res.supported, isFalse);
        expect(res.exported + res.skipped + res.failed, 0);
      },
    );

    test(
      'a chunk that throws is counted failed and the rest still runs',
      () async {
        var calls = 0;
        mockChannel((call) async {
          calls++;
          if (calls == 2) {
            throw PlatformException(code: 'boom');
          }
          final n = ((call.arguments as Map)['paths'] as List).length;
          return {'supported': true, 'exported': n, 'skipped': 0, 'failed': 0};
        });
        final res = await exportPhotosToGallery(fakePhotos(60), 'TestPlant');
        expect(calls, 3); // chunk 3 still went out after chunk 2 failed
        expect(res.supported, isTrue);
        expect(res.exported, 35); // 25 + 10
        expect(res.failed, 25); // the whole failed chunk
      },
    );

    test(
      'a null reply counts the chunk as failed instead of throwing',
      () async {
        mockChannel((call) async => null);
        final res = await exportPhotosToGallery(fakePhotos(10), 'TestPlant');
        expect(res.supported, isTrue);
        expect(res.failed, 10);
      },
    );
  });
}
