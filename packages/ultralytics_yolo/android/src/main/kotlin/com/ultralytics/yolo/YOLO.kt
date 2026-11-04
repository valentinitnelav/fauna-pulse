// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.content.Context
import android.graphics.*
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.camera.core.ImageProxy
import java.io.IOException
import kotlin.math.max

/**
 * YOLO model wrapper for single images (bitmaps, camera frames, image Uris). FaunaPulse runs object detection models only.
 */
class YOLO(
    private val context: Context,
    private val modelPath: String,
    val task: YOLOTask,
    private val labels: List<String> = emptyList(),
    private val useGpu: Boolean = true,
    private var numItemsThreshold: Int = 30
) {
    private val TAG = "YOLO"

    // The underlying predictor that will be initialized based on the task. LiteRT 2.x CompiledModel handles thread/
    // accelerator configuration internally (see LiteRtModel), so there are no per-interpreter options to pass.
    // FaunaPulse (round 161, perf review E2): the explicit lazy delegate + closed flag make disposal
    // deterministic. close() releases the native model, and any predictor access after close() fails fast
    // (IllegalStateException) instead of silently rebuilding a fresh interpreter on a disposed instance.
    // LazyThreadSafetyMode.NONE is safe because every initializing access point is @Synchronized.
    private var closed = false
    private val predictorDelegate = lazy(LazyThreadSafetyMode.NONE) {
        when (task) {
            YOLOTask.DETECT -> ObjectDetector(context, modelPath, labels, useGpu, numItemsThreshold = numItemsThreshold)
        }
    }
    private val predictor: Predictor
        get() {
            check(!closed) { "YOLO instance is closed" }
            return predictorDelegate.value
        }

    /**
     * This method is used to directly instantiate the predictor to avoid lazy invocation.
     */
    @Synchronized
    fun predictorInstance(): Predictor {
        return predictor
    }

    /**
     * Operator function that enables calling the YOLO instance like a function (bitmap input)
     * Example: val result = model(bitmap)
     * @param bitmap The bitmap to process
     * @param rotateForCamera Set to true if this is a camera feed bitmap that needs rotation
     */
    operator fun invoke(bitmap: Bitmap, rotateForCamera: Boolean = false): YOLOResult {
        return predict(bitmap, rotateForCamera)
    }

    /**
     * Predict using a bitmap input
     * @param bitmap The bitmap to process
     * @param rotateForCamera Whether to rotate the image for camera processing, defaults to false for standard bitmap inference
     * @param generateAnnotatedImage FaunaPulse (round 156, perf review D3): when false, skip rendering the
     * detections onto a full-size copy of the image — for DETECT that copy + draw costs several ms per call,
     * and the batch/SAHI analysis path throws the result away (it draws its own boxes from coordinates).
     */
    @Synchronized
    fun predict(bitmap: Bitmap, rotateForCamera: Boolean = false, generateAnnotatedImage: Boolean = true): YOLOResult {
        val result = predictor.predict(bitmap, bitmap.width, bitmap.height, rotateForCamera, isLandscape = false)

        // Don't create the annotated image when the caller opted out (memory/time).
        val annotatedImage = if (!generateAnnotatedImage) {
            null
        } else {
            drawAnnotations(bitmap, result, rotateForCamera)
        }
        
        return result.copy(
            originalImage = bitmap,
            annotatedImage = annotatedImage
        )
    }

    /**
     * Predict using an ImageProxy (from CameraX)
     * Always applies rotation for camera feed
     */
    fun predict(imageProxy: ImageProxy): YOLOResult? {
        val bitmap = ImageUtils.toBitmap(imageProxy) ?: return null
        val rotationDegrees = imageProxy.imageInfo.rotationDegrees
        val isRotated = rotationDegrees % 180 != 0
        val orientedWidth = if (isRotated) imageProxy.height else imageProxy.width
        val orientedHeight = if (isRotated) imageProxy.width else imageProxy.height
        (predictor as? BasePredictor)?.let { basePredictor ->
            basePredictor.cameraRotationDegrees = rotationDegrees
        }
        val result = predictor.predict(
            bitmap,
            orientedWidth,
            orientedHeight,
            rotateForCamera = true,
            isLandscape = false
        )
        return result.copy(
            originalImage = bitmap,
            annotatedImage = drawAnnotations(bitmap, result, rotateForCamera = true, rotationDegrees)
        )
    }

    /**
     * Predict using a local image Uri
     * No rotation is applied (single image processing)
     */
    fun predict(imageUri: Uri): YOLOResult? {
        try {
            val bitmap = MediaStore.Images.Media.getBitmap(context.contentResolver, imageUri)
            val result = predictor.predict(bitmap, bitmap.width, bitmap.height, rotateForCamera = false, isLandscape = false)
            return result.copy(
                originalImage = bitmap,
                annotatedImage = drawAnnotations(bitmap, result, rotateForCamera = false)
            )
        } catch (e: IOException) {
            Log.e(TAG, "Failed to load image from Uri: ${e.message}")
            return null
        }
    }

    // FaunaPulse (round 329): upstream's predict(imageUrl) is removed. It had no caller and
    // opened any address (also http and file) with no size limit; photos reach the plugin as
    // files or bytes that the app has checked.

    /**
     * Calculate smart label position that ensures the label stays within screen bounds
     * @param boxRect The bounding box rectangle
     * @param labelWidth The width of the label
     * @param labelHeight The height of the label
     * @param viewWidth The width of the view/canvas
     * @param viewHeight The height of the view/canvas
     * @return The adjusted rectangle for the label
     */
    private fun calculateSmartLabelRect(
        boxRect: RectF,
        labelWidth: Float,
        labelHeight: Float,
        viewWidth: Float,
        viewHeight: Float
    ): RectF {
        // Initial position: above the box
        var labelLeft = boxRect.left
        var labelTop = boxRect.top - labelHeight
        var labelRight = labelLeft + labelWidth
        var labelBottom = boxRect.top
        
        // Check top boundary
        if (labelTop < 0) {
            // Place inside top of box
            labelTop = boxRect.top
            labelBottom = labelTop + labelHeight
        }
        
        // Check left boundary
        if (labelLeft < 0) {
            labelLeft = 0f
            labelRight = labelWidth
        }
        
        // Check right boundary
        if (labelRight > viewWidth) {
            labelRight = viewWidth
            labelLeft = labelRight - labelWidth
            // If still too wide, align with box's right edge
            if (labelLeft < 0) {
                labelLeft = maxOf(0f, boxRect.right - labelWidth)
            }
        }
        
        // Check bottom boundary
        if (labelBottom > viewHeight) {
            labelBottom = viewHeight
            labelTop = labelBottom - labelHeight
        }
        
        return RectF(labelLeft, labelTop, labelRight, labelBottom)
    }

    /**
     * Draw annotations on the input image based on the result type
     * @param bitmap Input bitmap to annotate
     * @param result YOLOResult containing detection results
     * @param rotateForCamera If true, rotate the image 90 degrees (for camera feed), otherwise don't rotate
     */
    private fun drawAnnotations(
        bitmap: Bitmap,
        result: YOLOResult,
        rotateForCamera: Boolean = true,
        rotationDegrees: Int? = null
    ): Bitmap {
        val output: Bitmap
        val canvas: Canvas

        if (rotateForCamera) {
            val degrees = rotationDegrees ?: 90
            val isRotated = degrees % 180 != 0
            output = Bitmap.createBitmap(
                if (isRotated) bitmap.height else bitmap.width,
                if (isRotated) bitmap.width else bitmap.height,
                Bitmap.Config.ARGB_8888
            )
            canvas = Canvas(output)
            // Draw the camera frame in the same orientation used for inference.
            canvas.save()
            canvas.translate(output.width / 2f, output.height / 2f)
            canvas.rotate(degrees.toFloat())
            canvas.drawBitmap(bitmap, -bitmap.width / 2f, -bitmap.height / 2f, null)
            canvas.restore()
        } else {
            // Single image: no rotation needed
            output = bitmap.copy(Bitmap.Config.ARGB_8888, true)
            canvas = Canvas(output)
        }

        // Calculate appropriate line thickness and text size based on image dimensions
        val maxDimension = max(output.width, output.height)
        val lineThickness = maxDimension / 200f  // Adaptive line thickness
        val calculatedTextSize = maxDimension / 40f  // Adaptive text size

        val paint = Paint().apply {
            style = Paint.Style.STROKE
            strokeWidth = lineThickness.coerceAtLeast(3f) // Minimum 3f
            textSize = calculatedTextSize.coerceAtLeast(40f) // Minimum 40f
        }

        val resultWidth = result.origShape.width.toFloat().takeIf { it > 0f } ?: output.width.toFloat()
        val resultHeight = result.origShape.height.toFloat().takeIf { it > 0f } ?: output.height.toFloat()
        val scaleX = output.width / resultWidth
        val scaleY = output.height / resultHeight

        // Result coordinates are already mapped into the image orientation used for inference.
        fun transformRect(rect: RectF): RectF {
            return RectF(
                rect.left * scaleX,
                rect.top * scaleY,
                rect.right * scaleX,
                rect.bottom * scaleY
            )
        }

        when (task) {
            YOLOTask.DETECT -> {
                // Draw bounding boxes
                for (box in result.boxes) {
                    paint.color = ultralyticsColors[box.index % ultralyticsColors.size]

                    // Transform coordinates
                    val transformedRect = transformRect(box.xywh)
                    // Draw rounded rectangle with corner radius
                    val cornerRadius = 12f
                    canvas.drawRoundRect(transformedRect, cornerRadius, cornerRadius, paint)

                    // Draw label with background
                    val labelText = "${box.cls} ${(box.conf * 100).toInt()}%"
                    val labelPadding = 8f
                    
                    // Measure text
                    val textBounds = Rect()
                    paint.getTextBounds(labelText, 0, labelText.length, textBounds)
                    
                    // Calculate label size
                    val labelWidth = textBounds.width() + labelPadding * 2
                    val labelHeight = textBounds.height() + labelPadding * 2
                    
                    // Calculate smart label position
                    val labelRect = calculateSmartLabelRect(
                        transformedRect,
                        labelWidth,
                        labelHeight,
                        output.width.toFloat(),
                        output.height.toFloat()
                    )
                    
                    // Draw label background
                    paint.style = Paint.Style.FILL
                    canvas.drawRoundRect(labelRect, cornerRadius, cornerRadius, paint)
                    
                    // Draw label text in white
                    paint.color = Color.WHITE
                    canvas.drawText(
                        labelText,
                        labelRect.left + labelPadding,
                        labelRect.bottom - labelPadding,
                        paint
                    )
                    
                    // Reset paint for next box
                    paint.style = Paint.Style.STROKE
                }
            }
        }

        return output
    }

    /**
     * Set confidence threshold for detection
     */
    fun setConfidenceThreshold(threshold: Double) {
        predictor.setConfidenceThreshold(threshold)
    }
    
    /**
     * Set confidence threshold for detection (Float overload)
     */
    fun setConfidenceThreshold(threshold: Float) {
        predictor.setConfidenceThreshold(threshold.toDouble())
    }
    
    /**
     * Get current confidence threshold
     */
    fun getConfidenceThreshold(): Float {
        return predictor.getConfidenceThreshold().toFloat()
    }

    /**
     * Set IoU threshold for non-maximum suppression
     */
    fun setIouThreshold(threshold: Double) {
        predictor.setIouThreshold(threshold)
    }
    
    /**
     * Set IoU threshold for non-maximum suppression (Float overload)
     */
    fun setIouThreshold(threshold: Float) {
        predictor.setIouThreshold(threshold.toDouble())
    }
    
    /**
     * Get current IoU threshold
     */
    fun getIouThreshold(): Float {
        return predictor.getIouThreshold().toFloat()
    }

    /**
     * Set maximum number of detections
     */
    fun setNumItemsThreshold(max: Int) {
        predictor.setNumItemsThreshold(max)
    }

    /**
     * FaunaPulse (round 161, perf review E2): idempotent release of the native predictor (LiteRT
     * interpreter / ORT session and their buffers). @Synchronized so a close waits for an in-flight
     * synchronized predict on this instance instead of freeing native memory under it. After close(),
     * every predictor access throws IllegalStateException, which YOLOInstanceManager.predict turns
     * into a null result for the platform channel.
     */
    @Synchronized
    fun close() {
        closed = true
        if (predictorDelegate.isInitialized()) {
            (predictorDelegate.value as? BasePredictor)?.close()
        }
    }
}
