// Round 242: BioCLIP on the GPU. The native GPU check's result reaches Dart
// (ImageEmbedderInfo.gpuAgreement), and the Identify screen explains a GPU
// that could not compile the model (gpuNoteText).

import 'package:fauna_pulse/fauna_pulse/identification/identification_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = ChannelConfig.createSingleImageChannel();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  void reply(Map<String, Object?> r) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'embedderLoad');
        return r;
      });

  test('the GPU check agreement arrives with the load reply', () async {
    reply({'accelerator': 'GPU', 'gpuAgreement': 0.999505, 'inputWidth': 224, 'inputHeight': 224, 'dim': 768, 'loadMs': 9400.0});
    final info = await ImageEmbedder.load('/m.tflite');
    expect(info.accelerator, 'GPU');
    expect(info.gpuAgreement, closeTo(0.999505, 1e-9));
    expect(info.accelerationNote, isNull);
  });

  test('a CPU load without a GPU check has no agreement', () async {
    reply({'accelerator': 'CPU', 'accelerationNote': 'Failed to compile model', 'cpuThreads': 2, 'inputWidth': 224, 'inputHeight': 224, 'dim': 768});
    final info = await ImageEmbedder.load('/m.tflite');
    expect(info.gpuAgreement, isNull);
    expect(info.cpuThreads, 2);
  });

  test('normalize reaches the native side: true by default, false for a classifier (round 266)', () async {
    final seen = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      seen.add((call.arguments as Map)['normalize']);
      return {'accelerator': 'CPU', 'inputWidth': 224, 'inputHeight': 224, 'dim': 164};
    });
    await ImageEmbedder.load('/m.tflite');
    await ImageEmbedder.load('/c.tflite', normalize: false);
    expect(seen, [true, false]);
  });

  test('GPU notes are shown in plain words; the memory note keeps the native text', () {
    // Any set-up failure (not only "Failed to compile"): CPU used + the re-export advice.
    for (final n in ['Failed to compile model', 'GPU delegate could not be created']) {
      expect(gpuNoteText(n), contains('so the main processor (CPU) is used'));
      expect(gpuNoteText(n), contains('convert it again'));
      expect(gpuNoteText(n), isNot(contains(n)));
    }
    const mismatch = "the GPU's results differed from the CPU's on this phone (agreement 0.900, needs 0.995)";
    expect(gpuNoteText(mismatch), startsWith('On this phone the GPU gave different answers from the CPU'));
    expect(gpuNoteText(mismatch), isNot(contains('agreement')));
    final blocked = gpuNoteText('on the GPU blocklist after repeated failed GPU compiles');
    expect(blocked, startsWith('The GPU failed with this model several times before'));
    expect(blocked, isNot(contains('convert it again')));
    const memory = 'this phone has 3.5 GB of memory; setting this model up on the GPU needs about 4.0 GB, so it runs on the CPU';
    expect(gpuNoteText(memory), 'T${memory.substring(1)}.');
  });
}
