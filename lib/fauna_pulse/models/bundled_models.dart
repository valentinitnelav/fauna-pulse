// Model assets intentionally shipped in FaunaPulse release builds.
//
// Model binaries themselves are git-ignored. The maintainer chooses which local
// files a release APK ships by editing [kBundledModelsManifestPath]. Android's
// Gradle build reads the same file when copying assets.

const String kBundledModelsManifestPath = 'assets/models/bundled_models.txt';

const String kDefaultBundledModelPath =
    'assets/models/custom/MDV6-yolov10-c_int8_256.tflite';

/// Converts the text manifest into Flutter asset paths.
///
/// Blank lines and lines beginning with `#` are ignored. Both normal
/// project-relative paths (`assets/models/...`) and the repository-style paths
/// used by the maintainer (`/fauna-pulse/assets/models/...`) are accepted.
Set<String> parseBundledModelsManifest(String contents) {
  final paths = <String>{};
  for (final line in contents.split(RegExp(r'\r?\n'))) {
    var path = line.trim().replaceAll('\\', '/');
    if (path.isEmpty || path.startsWith('#')) continue;
    while (path.startsWith('./')) {
      path = path.substring(2);
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    const projectPrefix = 'fauna-pulse/';
    if (path.startsWith(projectPrefix)) {
      path = path.substring(projectPrefix.length);
    }
    paths.add(path);
  }
  return paths;
}

// Historical Ultralytics default. It remains a special named entry in local
// debug builds. A release can include it by listing its asset path in the
// bundled-model manifest, in which case it appears as a normal bundled model.
const String kLocalYolo26ModelId = 'yolo26n';
const String kLocalYolo26ModelPath = 'assets/models/yolo26n_int8.tflite';
