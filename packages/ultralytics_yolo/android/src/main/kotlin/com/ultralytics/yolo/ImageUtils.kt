// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.*
import androidx.camera.core.ImageProxy
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

object ImageUtils {
    // Shared read-only paint for frame preprocessing.
    private val filterPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG)

    data class LetterboxTransform(
        val gain: Float,
        val padX: Float,
        val padY: Float,
        val padRight: Float,
        val padBottom: Float,
        val resizedWidth: Int,
        val resizedHeight: Int
    )

    @JvmStatic
    fun letterboxTransform(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        centerCrop: Boolean = false
    ): LetterboxTransform? {
        if (sourceWidth <= 0 || sourceHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) return null

        val scaleX = targetWidth.toFloat() / sourceWidth
        val scaleY = targetHeight.toFloat() / sourceHeight
        val gain = if (centerCrop) max(scaleX, scaleY) else min(scaleX, scaleY)
        if (gain <= 0f) return null
        val resizedWidth = (sourceWidth * gain).roundToInt()
        val resizedHeight = (sourceHeight * gain).roundToInt()
        val padWidth = targetWidth - resizedWidth
        val padHeight = targetHeight - resizedHeight
        // Match Ultralytics LetterBox leading/trailing pad rounding.
        val padX = (padWidth / 2f - 0.1f).roundToInt().toFloat()
        val padY = (padHeight / 2f - 0.1f).roundToInt().toFloat()
        val padRight = (padWidth / 2f + 0.1f).roundToInt().toFloat()
        val padBottom = (padHeight / 2f + 0.1f).roundToInt().toFloat()
        return LetterboxTransform(gain, padX, padY, padRight, padBottom, resizedWidth, resizedHeight)
    }

    /**
     * Sample to convert ImageProxy to NV21 (BYTE array), then [YuvImage] -> [Bitmap]
     */
    @JvmStatic
    fun toBitmap(imageProxy: ImageProxy): Bitmap? {
        // Fast path: CameraX is configured for OUTPUT_IMAGE_FORMAT_RGBA_8888, so the frame is a single RGBA plane we
        // can copy straight into a Bitmap (~2-5ms). This replaces a YUV->NV21->JPEG-encode@100->JPEG-decode round-trip
        // that cost ~100ms/frame (~5 FPS).
        if (imageProxy.format == PixelFormat.RGBA_8888 && imageProxy.planes.size == 1) {
            val plane = imageProxy.planes[0]
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowPadding = rowStride - pixelStride * imageProxy.width
            // When rowStride has padding the buffer is wider than the image; copy at full stride width then crop back.
            val paddedWidth = imageProxy.width + rowPadding / pixelStride
            val bitmap = Bitmap.createBitmap(paddedWidth, imageProxy.height, Bitmap.Config.ARGB_8888)
            plane.buffer.rewind()
            bitmap.copyPixelsFromBuffer(plane.buffer)
            return if (rowPadding == 0) {
                bitmap
            } else {
                Bitmap.createBitmap(bitmap, 0, 0, imageProxy.width, imageProxy.height)
            }
        }

        // Fallback for YUV_420_888 frames (older config / devices that don't honor the RGBA request).
        val nv21 = yuv420888ToNv21(imageProxy)
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, imageProxy.width, imageProxy.height, null)
        return yuvImageToBitmap(yuvImage)
    }

    /**
     * Converts analysis frames to a Bitmap while REUSING the same backing bitmap across
     * frames (perf review A3), instead of allocating a fresh one per frame like [toBitmap].
     * "Allocation" refresher: creating a new multi-megabyte Bitmap 10-30x per second forces
     * the garbage collector to run often, which shows up as periodic stutter over a
     * multi-hour session.
     *
     * Threading contract:
     * - [convert] must only ever be called from ONE thread (CameraX's analyzer thread).
     * - The returned bitmap is overwritten by the NEXT [convert] call. Readers on the same
     *   thread (motion gate, model preprocessing) need no locking, because the next
     *   overwrite cannot start until they return. Readers on OTHER threads (the fast ROI
     *   photo path, [cropRoiFromFrame]) must `synchronized` on the bitmap instance itself —
     *   the writes here hold that same monitor, so a photo crop can never observe a
     *   half-written (torn) frame.
     */
    class BitmapFrameBuffer {
        private var output: Bitmap? = null // published to callers; monitor-guarded
        private var padded: Bitmap? = null // private staging when camera rows are padded
        private val blitRect = Rect()

        fun convert(imageProxy: ImageProxy): Bitmap? {
            if (imageProxy.format == PixelFormat.RGBA_8888 && imageProxy.planes.size == 1) {
                val plane = imageProxy.planes[0]
                val pixelStride = plane.pixelStride
                val rowPadding = plane.rowStride - pixelStride * imageProxy.width
                val out = obtainOutput(imageProxy.width, imageProxy.height)
                plane.buffer.rewind()
                if (rowPadding == 0) {
                    synchronized(out) { out.copyPixelsFromBuffer(plane.buffer) }
                } else {
                    // Row padding: the camera buffer is wider than the image. Copy at full
                    // stride width into the private staging bitmap, then blit just the image
                    // region into the published bitmap — the same single copy the old
                    // Bitmap.createBitmap() crop did, but into reused memory.
                    val paddedWidth = imageProxy.width + rowPadding / pixelStride
                    val stage = obtainPadded(paddedWidth, imageProxy.height)
                    stage.copyPixelsFromBuffer(plane.buffer)
                    blitRect.set(0, 0, imageProxy.width, imageProxy.height)
                    synchronized(out) { Canvas(out).drawBitmap(stage, blitRect, blitRect, null) }
                }
                return out
            }
            // YUV_420_888 fallback allocates inherently (JPEG round-trip); rare legacy path.
            return toBitmap(imageProxy)
        }

        private fun obtainOutput(width: Int, height: Int): Bitmap {
            val cur = output
            if (cur != null && cur.width == width && cur.height == height) return cur
            // First frame or stream size changed: allocate once at the new size. The old
            // bitmap is NOT recycled — an in-flight photo crop may still be reading it.
            return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { output = it }
        }

        private fun obtainPadded(width: Int, height: Int): Bitmap {
            val cur = padded
            if (cur != null && cur.width == width && cur.height == height) return cur
            return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { padded = it }
        }
    }

    private fun yuvImageToBitmap(yuvImage: YuvImage): Bitmap? {
        val out = ByteArrayOutputStream()
        val success = yuvImage.compressToJpeg(
            Rect(0, 0, yuvImage.width, yuvImage.height),
            100,
            out
        )
        if (!success) return null
        val imageBytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
    }


    private fun yuv420888ToNv21(imageProxy: ImageProxy): ByteArray {
        val cropRect = imageProxy.cropRect
        val pixelCount = cropRect.width() * cropRect.height()
        val pixelSizeBits = ImageFormat.getBitsPerPixel(ImageFormat.YUV_420_888)
        val outputBuffer = ByteArray(pixelCount * pixelSizeBits / 8)
        imageToByteBuffer(imageProxy, outputBuffer, pixelCount)
        return outputBuffer
    }


    private fun imageToByteBuffer(
        imageProxy: ImageProxy,
        outputBuffer: ByteArray,
        pixelCount: Int
    ) {
        require(imageProxy.format == ImageFormat.YUV_420_888) {
            "Input ImageProxy must be in YUV_420_888 format."
        }

        val imageCrop = imageProxy.cropRect
        val imagePlanes = imageProxy.planes

        for (planeIndex in imagePlanes.indices) {
            val (outputStride, startOffset) = when (planeIndex) {
                0 -> Pair(1, 0)               // Y
                1 -> Pair(2, pixelCount + 1)  // U
                2 -> Pair(2, pixelCount)      // V
                else -> return
            }

            val plane = imagePlanes[planeIndex]
            val planeBuffer: ByteBuffer = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride

            val planeCrop = if (planeIndex == 0) {
                imageCrop
            } else {
                Rect(
                    imageCrop.left / 2,
                    imageCrop.top / 2,
                    imageCrop.right / 2,
                    imageCrop.bottom / 2
                )
            }

            val planeWidth = planeCrop.width()
            val planeHeight = planeCrop.height()

            val rowBuffer = ByteArray(rowStride)
            var outputOffset = startOffset

            val rowLength = if (pixelStride == 1 && outputStride == 1) {
                planeWidth
            } else {
                (planeWidth - 1) * pixelStride + 1
            }

            for (row in 0 until planeHeight) {
                planeBuffer.position(
                    (row + planeCrop.top) * rowStride +
                            planeCrop.left * pixelStride
                )

                if (pixelStride == 1 && outputStride == 1) {
                    planeBuffer.get(outputBuffer, outputOffset, rowLength)
                    outputOffset += rowLength
                } else {
                    planeBuffer.get(rowBuffer, 0, rowLength)
                    for (col in 0 until planeWidth) {
                        outputBuffer[outputOffset] = rowBuffer[col * pixelStride]
                        outputOffset += outputStride
                    }
                }
            }
        }
    }

    @JvmStatic
    fun prepareBitmapForModel(
        bitmap: Bitmap,
        targetBitmap: Bitmap,
        rotateForCamera: Boolean,
        isLandscape: Boolean,
        isFrontCamera: Boolean,
        rotationDegrees: Int? = null,
        centerCrop: Boolean = false
    ): Bitmap {
        val degrees = cameraRotationDegrees(rotateForCamera, isLandscape, isFrontCamera, rotationDegrees)
        val isRotated = degrees % 180 != 0
        val orientedWidth = if (isRotated) bitmap.height else bitmap.width
        val orientedHeight = if (isRotated) bitmap.width else bitmap.height
        val targetWidth = targetBitmap.width
        val targetHeight = targetBitmap.height
        val transform = letterboxTransform(orientedWidth, orientedHeight, targetWidth, targetHeight, centerCrop)
            ?: return targetBitmap

        Canvas(targetBitmap).apply {
            drawColor(Color.BLACK)
            save()
            translate(transform.padX + transform.resizedWidth / 2f, transform.padY + transform.resizedHeight / 2f)
            rotate(degrees.toFloat())
            scale(transform.gain, transform.gain)
            drawBitmap(bitmap, -bitmap.width / 2f, -bitmap.height / 2f, filterPaint)
            restore()
        }
        return targetBitmap
    }

    /**
     * Like [prepareBitmapForModel] but feeds only a square region of interest to
     * the model. The ROI ([roiCx],[roiCy],[roiSide], normalized in the upright
     * frame, side as a fraction of width) is rotated into display orientation,
     * then drawn so it fills [targetBitmap]. Because the ROI is square and the
     * model input is (normally) square, the same letterbox math used elsewhere
     * gives gain = target / roiPixels and zero padding — i.e. a clean zoom into
     * the ROI with no wasted border. Returns the ROI's pixel side (oriented),
     * which the caller uses as the "original" size when mapping detections back.
     */
    @JvmStatic
    fun prepareBitmapForModelRoi(
        bitmap: Bitmap,
        targetBitmap: Bitmap,
        rotateForCamera: Boolean,
        isLandscape: Boolean,
        isFrontCamera: Boolean,
        rotationDegrees: Int?,
        roiCx: Float,
        roiCy: Float,
        roiSide: Float
    ): Int {
        val degrees = cameraRotationDegrees(rotateForCamera, isLandscape, isFrontCamera, rotationDegrees)
        val isRotated = degrees % 180 != 0
        val orientedWidth = if (isRotated) bitmap.height else bitmap.width
        val orientedHeight = if (isRotated) bitmap.width else bitmap.height
        val targetWidth = targetBitmap.width
        val targetHeight = targetBitmap.height

        // Square ROI in oriented pixels (side is a fraction of the frame width).
        val roiPx = (roiSide * orientedWidth).roundToInt().coerceIn(1, min(orientedWidth, orientedHeight))
        val roiCxPx = roiCx * orientedWidth
        val roiCyPx = roiCy * orientedHeight

        val transform = letterboxTransform(roiPx, roiPx, targetWidth, targetHeight)
            ?: return roiPx
        // Shift so the ROI centre (not the whole-frame centre) lands at the
        // centre of the resized area; otherwise identical to the full-frame blit.
        val tx = transform.padX + transform.resizedWidth / 2f + transform.gain * (orientedWidth / 2f - roiCxPx)
        val ty = transform.padY + transform.resizedHeight / 2f + transform.gain * (orientedHeight / 2f - roiCyPx)

        Canvas(targetBitmap).apply {
            drawColor(Color.BLACK)
            save()
            translate(tx, ty)
            rotate(degrees.toFloat())
            scale(transform.gain, transform.gain)
            drawBitmap(bitmap, -bitmap.width / 2f, -bitmap.height / 2f, filterPaint)
            restore()
        }
        return roiPx
    }

    /**
     * Crops a SQUARE region of interest out of an in-hand camera frame [bitmap]
     * (the live analysis frame) and returns it as a JPEG — no full-resolution
     * still capture, so the camera pipeline is never stalled. The ROI is rotated
     * into display orientation and drawn 1:1 (no downscale) into a
     * roiPx × roiPx output, where roiPx = roiSide * orientedWidth snapped to a
     * multiple of 32. [maxPx] > 0 caps the SAVED side: a larger crop is
     * downscaled (never enlarged) to the largest multiple of 32 that fits, so
     * saved photos come out at one uniform size. Returns null if the
     * bitmap/ROI is unusable.
     */
    @JvmStatic
    fun cropRoiFromFrame(
        bitmap: Bitmap,
        rotateForCamera: Boolean,
        isLandscape: Boolean,
        isFrontCamera: Boolean,
        rotationDegrees: Int?,
        roiCx: Float,
        roiCy: Float,
        roiSide: Float,
        quality: Int,
        maxPx: Int = 0
    ): ByteArray? {
        val degrees = cameraRotationDegrees(rotateForCamera, isLandscape, isFrontCamera, rotationDegrees)
        val isRotated = degrees % 180 != 0
        val orientedWidth = if (isRotated) bitmap.height else bitmap.width
        val orientedHeight = if (isRotated) bitmap.width else bitmap.height

        // Round to the nearest multiple of 32 (matches the Dart snapToMultipleOf32
        // used for the on-screen readout), then cap to the largest 32-multiple that
        // fits the frame's short side — so the saved size is always a clean
        // multiple of 32 AND exactly equals the displayed value.
        val cap = (min(orientedWidth, orientedHeight) / 32) * 32
        var roiPx = ((roiSide * orientedWidth) / 32f).roundToInt() * 32
        roiPx = roiPx.coerceIn(32, max(32, cap))
        if (roiPx <= 0) return null

        val roiCxPx = roiCx * orientedWidth
        val roiCyPx = roiCy * orientedHeight

        var output = Bitmap.createBitmap(roiPx, roiPx, Bitmap.Config.ARGB_8888)
        // gain = 1 (no scaling): draw the oriented frame so the ROI centre lands
        // at the centre of the output square.
        val tx = roiPx / 2f + (orientedWidth / 2f - roiCxPx)
        val ty = roiPx / 2f + (orientedHeight / 2f - roiCyPx)
        // The source may be a reused [BitmapFrameBuffer] bitmap that the camera thread
        // overwrites each frame; holding its monitor during the read (just the draw —
        // scaling and JPEG encoding below work on our private copy) guarantees a whole
        // frame, never a torn one. For fresh bitmaps the lock is uncontended and free.
        synchronized(bitmap) {
            Canvas(output).apply {
                drawColor(Color.BLACK)
                save()
                translate(tx, ty)
                rotate(degrees.toFloat())
                drawBitmap(bitmap, -bitmap.width / 2f, -bitmap.height / 2f, filterPaint)
                restore()
            }
        }
        // Apply the saved-side cap (mirrors the Dart capSavedSidePx math).
        val savedCap = if (maxPx > 0) max(32, (maxPx / 32) * 32) else 0
        if (savedCap in 1 until roiPx) {
            val scaled = Bitmap.createScaledBitmap(output, savedCap, savedCap, true)
            if (scaled !== output) output.recycle()
            output = scaled
        }
        val out = ByteArrayOutputStream()
        output.compress(Bitmap.CompressFormat.JPEG, quality, out)
        output.recycle()
        return out.toByteArray()
    }

    private fun cameraRotationDegrees(
        rotateForCamera: Boolean,
        isLandscape: Boolean,
        isFrontCamera: Boolean,
        rotationDegrees: Int?
    ): Int {
        if (!rotateForCamera) return 0

        val fallbackDegrees = if (isLandscape) 0 else if (isFrontCamera) 90 else 270
        return (rotationDegrees ?: fallbackDegrees).floorMod(360)
    }

    private fun Int.floorMod(other: Int): Int = ((this % other) + other) % other

    // A channel value is one of only 256 possible bytes, so the normalized float for each value can be
    // precomputed once into a small table ("lookup table"/LUT) instead of doing subtract+divide three times
    // per pixel on the camera thread. Rebuilt only if a caller passes different mean/std constants; every
    // current caller uses the default 0/255 pair, so in practice it is built once. Only the camera analyzer
    // thread runs these copies, so plain fields are safe here.
    private var normLut = FloatArray(0)
    private var normLutMean = 0f
    private var normLutStd = 0f

    private fun normalizationLut(inputMean: Float, inputStd: Float): FloatArray {
        var lut = normLut
        if (lut.isEmpty() || inputMean != normLutMean || inputStd != normLutStd) {
            lut = FloatArray(256) { (it - inputMean) / inputStd }
            normLut = lut
            normLutMean = inputMean
            normLutStd = inputStd
        }
        return lut
    }

    @JvmStatic
    fun copyRgbBitmapToFloatBuffer(
        bitmap: Bitmap,
        byteBuffer: ByteBuffer,
        pixels: IntArray,
        inputMean: Float = 0f,
        inputStd: Float = 255f
    ) {
        val lut = normalizationLut(inputMean, inputStd)
        byteBuffer.clear()
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)

        for (pixel in pixels) {
            byteBuffer.putFloat(lut[(pixel shr 16) and 0xFF])
            byteBuffer.putFloat(lut[(pixel shr 8) and 0xFF])
            byteBuffer.putFloat(lut[pixel and 0xFF])
        }
        byteBuffer.rewind()
    }

    // FloatArray variant for the LiteRT 2.x CompiledModel path (TensorBuffer.writeFloat takes a float[], not a
    // ByteBuffer). Writes planar-free interleaved RGB, normalized to [0,1] by default. `out` must be width*height*3.
    @JvmStatic
    fun copyRgbBitmapToFloatArray(
        bitmap: Bitmap,
        out: FloatArray,
        pixels: IntArray,
        inputMean: Float = 0f,
        inputStd: Float = 255f
    ) {
        val lut = normalizationLut(inputMean, inputStd)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        var j = 0
        for (pixel in pixels) {
            out[j++] = lut[(pixel shr 16) and 0xFF]
            out[j++] = lut[(pixel shr 8) and 0xFF]
            out[j++] = lut[pixel and 0xFF]
        }
    }

    /**
     * Process grayscale image for 1-channel classification models
     * Optimized for handwriting recognition (EMNIST-like models)
     * 
     * @param bitmap Input bitmap to process
     * @param targetWidth Target width for the model
     * @param targetHeight Target height for the model  
     * @param outputBuffer Reusable buffer for 1-channel float32 data
     * @param pixels Reusable pixel scratch array
     * @param enableColorInversion Whether to invert colors (white-on-black → black-on-white)
     * @param enableMaxNormalization Whether to use 0-1 normalization instead of mean/std
     * @param inputMean Mean value for normalization
     * @param inputStd Standard deviation for normalization
     * @return ByteBuffer ready for TensorFlow Lite inference
     */
    @JvmStatic
    fun processGrayscaleImage(
        bitmap: Bitmap,
        targetWidth: Int,
        targetHeight: Int,
        outputBuffer: ByteBuffer,
        pixels: IntArray,
        enableColorInversion: Boolean = false,
        enableMaxNormalization: Boolean = false,
        inputMean: Float = 0f,
        inputStd: Float = 255f
    ): ByteBuffer {
        val scaledBitmap = if (bitmap.width == targetWidth && bitmap.height == targetHeight) {
            bitmap
        } else {
            val targetBitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            prepareBitmapForModel(
                bitmap = bitmap,
                targetBitmap = targetBitmap,
                rotateForCamera = false,
                isLandscape = false,
                isFrontCamera = false,
                centerCrop = true
            )
        }
        
        outputBuffer.clear()
        
        // Process each pixel
        scaledBitmap.getPixels(pixels, 0, targetWidth, 0, 0, targetWidth, targetHeight)
        
        for (i in 0 until targetWidth * targetHeight) {
            val pixel = pixels[i]
            // Extract RGB components
            val r = (pixel shr 16) and 0xFF
            val g = (pixel shr 8) and 0xFF  
            val b = pixel and 0xFF
            
            // Convert to grayscale using luminance formula
            var gray = (0.299f * r + 0.587f * g + 0.114f * b) / 255.0f
            
            // Apply color inversion if enabled (for white-on-black handwriting)
            if (enableColorInversion) {
                gray = 1.0f - gray
            }
            
            // Apply normalization based on options
            val normalizedValue = if (enableMaxNormalization) {
                // Simple 0-1 normalization (already done above)
                gray
            } else {
                // Standard normalization using mean/std
                (gray - inputMean) / inputStd
            }
            
            outputBuffer.putFloat(normalizedValue)
        }
        
        // Clean up scaled bitmap if it's different from input
        if (scaledBitmap !== bitmap) {
            scaledBitmap.recycle()
        }
        
        outputBuffer.rewind()
        return outputBuffer
    }


}
