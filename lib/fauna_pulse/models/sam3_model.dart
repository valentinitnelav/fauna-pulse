// FaunaPulse (round 257, sam3 branch): where the SAM 3 files live.
//
// SAM 3 (Meta, SAM License) is not a YOLO model file but a folder of six
// files (see Sam3Detector.kt), about 1.7 GB, kept in the app's private
// storage at `files/sam3/`. Nothing is bundled or downloaded by the app: for
// now the files are copied there with adb (docs/SAM3.md). When all files are
// present, "Run AI on videos" offers SAM 3 as a detection model.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// [ModelEntry.id] and `video_run_start` model of SAM 3 runs.
const kSam3ModelId = 'sam3';

/// Readable model name, stored with each run.
String sam3ModelName(String prompt) => 'SAM 3, prompt "$prompt"';

/// Files besides the picture model, which is `sam3_vision.tflite` or its
/// parts `sam3_vision_part1.tflite`, ... (tool/sam3/split_tflite.py).
const kSam3Files = [
  'sam3_head.tflite',
  'sam3_text.tflite',
  'sam3_token_embed.bin',
  'vocab.json',
  'merges.txt',
];

/// The SAM 3 folder when every file is there, else null.
Future<Directory?> sam3Dir() async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/sam3');
  bool has(String f) => File('${dir.path}/$f').existsSync();
  return kSam3Files.every(has) && (has('sam3_vision.tflite') || has('sam3_vision_part1.tflite')) ? dir : null;
}
