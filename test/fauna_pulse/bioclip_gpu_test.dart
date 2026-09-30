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

  test('a failed GPU compile points to the newer export; other reasons stay as they are', () {
    expect(gpuNoteText('Failed to compile model'), contains('export the model again'));
    const other = "the GPU's results differed from the CPU's on this phone (agreement 0.900, needs 0.995)";
    expect(gpuNoteText(other), other);
    expect(gpuNoteText('on the GPU blocklist after repeated failed GPU compiles'), isNot(contains('export the model again')));
  });
}
