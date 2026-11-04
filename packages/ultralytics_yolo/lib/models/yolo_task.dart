// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

// lib/yolo_task.dart

/// Represents the different types of tasks that can be performed by YOLO models.
///
/// YOLO models can be trained for various computer vision tasks, and this enum
/// allows specifying which task a particular model is designed to perform.
enum YOLOTask {
  // FaunaPulse fork: detection only (the other tasks' native code is gone,
  // see FAUNAPULSE_FORK.md); `tryParse` gives null for their names.
  detect,
}

extension YOLOTaskParsing on YOLOTask {
  static YOLOTask? tryParse(String? value) {
    if (value == null) return null;
    for (final task in YOLOTask.values) {
      if (task.name == value.toLowerCase()) {
        return task;
      }
    }
    return null;
  }
}
