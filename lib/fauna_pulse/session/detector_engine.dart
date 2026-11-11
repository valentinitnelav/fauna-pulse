// The engine a detector really ran on, as session records store it (round 367).
//
// `accelerator` is "GPU", "CPU" or "NPU". On the CPU only, `cpu_16bit` says whether it computed
// in 16-bit maths (faster; boxes move about as much as between CPU and GPU) or in 32-bit (files
// with 8-bit weights, or a phone without 16-bit maths). LiteRtModel.kt in the plugin decides.
// docs/DATA_GUIDE.md describes both fields; keep the three in step.

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../logging/app_error_hooks.dart';

/// [engineRecordFields] of a loaded detector; empty when the plugin cannot say (the run then
/// reports a model that fails to build, as before).
Future<Map<String, Object?>> engineRecordFieldsOf(YOLO yolo) async {
  try {
    final info = await yolo.engineInfo();
    return engineRecordFields(info['accelerator'] as String?, info['cpuFp16'] as bool?);
  } catch (e) {
    logSwallowed('detector_engine_info', e);
    return const {};
  }
}

/// Record fields for an engine reported by the plugin (`engineInfo`, or the live camera's frames).
Map<String, Object?> engineRecordFields(String? accelerator, bool? cpuFp16) => {
  'accelerator': ?accelerator,
  if (accelerator == 'CPU' && cpuFp16 != null) 'cpu_16bit': cpuFp16,
};

/// "CPU (16-bit maths)", "GPU" and so on, for the session summary; null when [rec] has no engine.
String? engineLabel(Map<String, dynamic>? rec) {
  final accelerator = rec?['accelerator'];
  if (accelerator is! String || accelerator.isEmpty) return null;
  return switch (rec?['cpu_16bit']) {
    true => '$accelerator (16-bit maths)',
    false => '$accelerator (32-bit maths)',
    _ => accelerator,
  };
}
