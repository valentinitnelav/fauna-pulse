// Model assets intentionally shipped in FaunaPulse release builds.
//
// Model binaries themselves are git-ignored. The maintainer places these files
// in assets/models/custom/ before building. Keep this list in sync with
// releaseBundledModels in android/app/build.gradle, which removes every other
// local test weight while copying assets into a release APK.

const String kDefaultBundledModelPath =
    'assets/models/custom/MDV6-yolov10-c_int8_256.tflite';

const Set<String> kReleaseBundledModelPaths = {
  kDefaultBundledModelPath,
  'assets/models/custom/MDV6-yolov10-c_float16_256.tflite',
};

// Historical Ultralytics default. It remains usable in local debug builds but
// is deliberately absent from release APKs.
const String kLocalYolo26ModelId = 'yolo26n';
const String kLocalYolo26ModelPath = 'assets/models/yolo26n_int8.tflite';
