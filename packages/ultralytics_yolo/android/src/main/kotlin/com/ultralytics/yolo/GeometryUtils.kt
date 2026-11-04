// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.RectF
import kotlin.math.max
import kotlin.math.min

fun nonMaxSuppression(boxes: List<RectF>, scores: List<Float>, iouThreshold: Float): List<Int> {
    val sortedIndices = scores.indices.sortedByDescending { scores[it] }
    val selected = mutableListOf<Int>()
    val active = BooleanArray(boxes.size) { true }
    for (i in sortedIndices.indices) {
        val idx = sortedIndices[i]
        if (!active[idx]) continue
        selected.add(idx)
        for (j in i + 1 until sortedIndices.size) {
            val idxB = sortedIndices[j]
            if (active[idxB]) {
                val iou = computeIoU(boxes[idx], boxes[idxB])
                if (iou > iouThreshold) {
                    active[idxB] = false
                }
            }
        }
    }
    return selected
}

fun computeIoU(a: RectF, b: RectF): Float {
    val interLeft = max(a.left, b.left)
    val interTop = max(a.top, b.top)
    val interRight = min(a.right, b.right)
    val interBottom = min(a.bottom, b.bottom)
    val interArea = max(0f, interRight - interLeft) * max(0f, interBottom - interTop)
    val unionArea = (a.right - a.left) * (a.bottom - a.top) + (b.right - b.left) * (b.bottom - b.top) - interArea
    return if (unionArea > 0) interArea / unionArea else 0f
}
