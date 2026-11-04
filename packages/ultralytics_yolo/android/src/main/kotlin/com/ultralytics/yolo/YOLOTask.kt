// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

// FaunaPulse runs object detection models only, so DETECT is the only task (FAUNAPULSE_FORK.md).
enum class YOLOTask {
    DETECT;

    companion object {
        /** Error code sent to Dart when a call names any other task. */
        const val UNSUPPORTED_TASK_CODE = "unsupported_task"

        fun unsupportedTaskMessage(task: String) =
            "This app runs detection models only; task \"$task\" is not supported."

        /** The task named [name] (any letter case), or null when this app does not support it. */
        fun fromName(name: String): YOLOTask? = entries.firstOrNull { it.name.equals(name, ignoreCase = true) }
    }
}
