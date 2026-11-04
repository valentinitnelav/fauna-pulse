// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.Bitmap
import android.graphics.RectF

data class YOLOResult(
    val origShape: Size,
    val boxes: List<Box> = emptyList(),
    val annotatedImage: Bitmap? = null,
    val speed: Double,
    val fps: Double? = null,
    val preMs: Double = 0.0,
    val inferenceMs: Double = 0.0,
    val postMs: Double = 0.0,
    val originalImage: Bitmap? = null,
    val names: List<String>
)

data class Box(
    var index: Int,
    var cls: String,
    var conf: Float,
    val xywh: RectF,    // Real image coordinates
    val xywhn: RectF    // Normalized coordinates (0~1)
)

data class Size(val width: Int, val height: Int)
