import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultralytics_yolo/core/yolo_inference.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';

// Round 156 (perf review D3): the batch/SAHI analysis path opts out of the
// native annotated-image render + JPEG encode via `includeAnnotatedImage:
// false`. These tests pin the wire contract: the key crosses the method
// channel ONLY when false (absent = native default true), so the plugin demo
// screen and any older caller keep their annotated image.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test_yolo_predict');
  MethodCall? lastCall;

  setUp(() {
    lastCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          lastCall = call;
          return <String, dynamic>{'boxes': <dynamic>[]};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  YOLOInference inference() => YOLOInference(
    channel: channel,
    instanceId: 'default',
    task: YOLOTask.detect,
  );

  final bytes = Uint8List.fromList([1, 2, 3]);

  test('default predict does not send the includeAnnotatedImage key', () async {
    await inference().predict(bytes);
    expect(lastCall!.method, 'predictSingleImage');
    final args = lastCall!.arguments as Map;
    expect(args.containsKey('includeAnnotatedImage'), isFalse);
  });

  test('includeAnnotatedImage: false is sent on the wire', () async {
    await inference().predict(bytes, includeAnnotatedImage: false);
    final args = lastCall!.arguments as Map;
    expect(args['includeAnnotatedImage'], isFalse);
  });

  test('explicit true stays off the wire (matches the native default)', () async {
    await inference().predict(bytes, includeAnnotatedImage: true);
    final args = lastCall!.arguments as Map;
    expect(args.containsKey('includeAnnotatedImage'), isFalse);
  });
}
