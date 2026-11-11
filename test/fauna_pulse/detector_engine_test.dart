import 'package:fauna_pulse/fauna_pulse/session/detector_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cpu_16bit is recorded only for the CPU', () {
    expect(engineRecordFields('CPU', true), {'accelerator': 'CPU', 'cpu_16bit': true});
    expect(engineRecordFields('CPU', false), {'accelerator': 'CPU', 'cpu_16bit': false});
    expect(engineRecordFields('GPU', false), {'accelerator': 'GPU'});
    // The live camera before its first frame: the key stays, as before round 367.
    expect(engineRecordFields('', null), {'accelerator': ''});
    expect(engineRecordFields(null, null), isEmpty);
  });

  test('summary label names the maths when the record has it', () {
    expect(engineLabel({'accelerator': 'CPU', 'cpu_16bit': true}), 'CPU (16-bit maths)');
    expect(engineLabel({'accelerator': 'CPU', 'cpu_16bit': false}), 'CPU (32-bit maths)');
    expect(engineLabel({'accelerator': 'CPU'}), 'CPU');
    expect(engineLabel({'accelerator': 'GPU'}), 'GPU');
    expect(engineLabel({'accelerator': ''}), isNull);
    expect(engineLabel(null), isNull);
  });
}
