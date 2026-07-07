// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import kotlin.math.abs
import kotlin.math.min

/**
 * Motion gate (Pollinator Monitor).
 *
 * Decides — very cheaply — whether anything is moving inside the region of
 * interest (ROI), so the expensive object detector can sleep while the flower
 * is empty. This saves heat and battery on long field sessions: the detector
 * only wakes when something (hopefully an insect) enters the ROI.
 *
 * How it works, in plain language:
 *  1. Every camera frame, the ROI is shrunk down to a tiny [gridSize]²
 *     grayscale thumbnail (a few thousand pixels — well under 1 ms of work).
 *     On frames that also run the detector, the thumbnail is derived from the
 *     model-input bitmap the detector already rasterized, so the ROI is only
 *     copied out of the camera frame once (see [motionDetectedFromModelInput]).
 *  2. The gate keeps a "background" image: a slowly-updated running average of
 *     those thumbnails (an *exponential moving average*, i.e. each new frame
 *     nudges the remembered background a little). Slow drift — sun moving,
 *     clouds, auto-exposure — soaks into the background instead of triggering.
 *  3. A pixel "changed" when its brightness differs from the background by
 *     more than [pixelDelta] (on the 0..255 brightness scale). If the fraction
 *     of changed pixels exceeds [areaFraction], that frame counts as motion.
 *
 * The gate itself only reports motion; the caller (YOLOView) decides how long
 * the detector stays awake afterwards (the "wake window") and also keeps it
 * awake while detections are still coming in, so a resting insect is never
 * lost just because it stopped moving.
 *
 * Thread-safety: [motionDetected] must only be called from the camera analyzer
 * thread. The tunable parameters are @Volatile so the platform channel (main
 * thread) can update them live.
 */
class MotionGate {
    companion object {
        /** Default side of the square thumbnail the ROI is shrunk to. */
        const val DEFAULT_GRID = 48
    }

    /** Brightness change (0..255) a single pixel needs to count as "changed". */
    @Volatile var pixelDelta: Int = 25

    /** Fraction (0..1) of ROI pixels that must change to count as motion.
     *  Kept small on purpose: an insect covers little of the ROI. */
    @Volatile var areaFraction: Double = 0.005

    /** Requested side of the comparison thumbnail. Each thumbnail cell covers
     *  ROI-side/gridSize of the scene, so a tiny insect needs a fine enough
     *  grid to span at least one cell. Applied (buffers reallocated) on the
     *  analyzer thread at the start of the next frame, so there is never a
     *  cross-thread buffer swap mid-comparison. */
    @Volatile var gridSize: Int = DEFAULT_GRID
        set(value) {
            field = value.coerceIn(16, 160)
        }

    /** Last computed changed-pixel fraction (0..1), for UI display and logs. */
    @Volatile var lastScore: Double = 0.0
        private set

    // Comparison buffers. Owned by the analyzer thread: (re)allocated there
    // when gridSize changed since the previous frame.
    //
    // The ROI is drawn SUPERSAMPLED at twice the grid resolution and each grid
    // cell then averages its 2×2 block. Why: Android's bilinear filter only
    // blends the nearest 2×2 source pixels, so at heavy shrink factors every
    // thumbnail pixel degenerates to a near-point sample carrying full sensor
    // noise — which made COARSER grids trigger MORE (field observation,
    // session_89: grid 48 never slept indoors, 128 did). Averaging 4 samples
    // per cell cuts that noise variance 4× and makes grid sizes behave
    // consistently (coarser = calmer, as intended).
    private var currentGrid = 0
    private lateinit var ssBitmap: Bitmap // supersampled, side = 2 × grid
    private lateinit var ssPixels: IntArray // (2 × grid)² ARGB samples
    private lateinit var background: FloatArray // grid² cell luma EMA
    private var hasBackground = false

    // Background learning rate: each frame moves the background 5% toward the
    // current frame (~20-frame memory). Fast enough to absorb lighting drift,
    // slow enough that a walking insect stays "different" for many frames.
    private val bgAlpha = 0.05f

    // Scratch objects for [motionDetectedFromModelInput] (allocation-free frames).
    private val filterPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val srcRect = Rect()
    private val dstRect = Rect()

    /** Forget the learned background (call when the ROI moves or the camera
     *  restarts — the old background no longer matches what the ROI sees). */
    fun reset() {
        hasBackground = false
        lastScore = 0.0
    }

    /**
     * Shrinks the ROI of [bitmap] into the grid, compares it to the learned
     * background, updates the background, and returns true when the changed
     * fraction is at least [areaFraction]. The ROI arguments use the same
     * convention as [InferenceRoi]: normalized (0..1) in the upright frame,
     * [roiSide] as a fraction of frame width. The first frame after [reset]
     * only primes the background and never reports motion.
     */
    fun motionDetected(
        bitmap: Bitmap,
        rotateForCamera: Boolean,
        isLandscape: Boolean,
        isFrontCamera: Boolean,
        rotationDegrees: Int?,
        roiCx: Float,
        roiCy: Float,
        roiSide: Float,
    ): Boolean {
        val grid = ensureBuffers()

        // Reuse the exact ROI-crop geometry the detector uses, just with a tiny
        // target bitmap — so the gate watches precisely what the model would see.
        ImageUtils.prepareBitmapForModelRoi(
            bitmap = bitmap,
            targetBitmap = ssBitmap,
            rotateForCamera = rotateForCamera,
            isLandscape = isLandscape,
            isFrontCamera = isFrontCamera,
            rotationDegrees = rotationDegrees,
            roiCx = roiCx,
            roiCy = roiCy,
            roiSide = roiSide,
        )
        return scoreThumbnail(grid)
    }

    /**
     * Same decision as [motionDetected], but fed from the model-input bitmap the
     * detector just rasterized for this frame — so the ROI is copied out of the
     * camera frame once per frame instead of twice (perf review A5). Because the
     * square ROI letterboxes into the (normally square) model input with zero
     * padding, the ROI is exactly the centered square of [modelInput] (the whole
     * bitmap when it is square). Only call this on frames where the detector
     * actually ran with an ROI set; otherwise use [motionDetected]. Same
     * analyzer-thread rule as [motionDetected].
     *
     * Noise note (see the r60 buffer comment below): the 2× supersampled fold is
     * identical on this path, and for typical ROIs (smaller than the model input
     * side) [modelInput] is an *upscaled* — hence smoother — copy of the ROI, so
     * this path is if anything calmer than the direct one.
     */
    fun motionDetectedFromModelInput(modelInput: Bitmap): Boolean {
        val grid = ensureBuffers()
        val ss = grid * 2
        val side = min(modelInput.width, modelInput.height)
        val left = (modelInput.width - side) / 2
        val top = (modelInput.height - side) / 2
        srcRect.set(left, top, left + side, top + side)
        dstRect.set(0, 0, ss, ss)
        Canvas(ssBitmap).drawBitmap(modelInput, srcRect, dstRect, filterPaint)
        return scoreThumbnail(grid)
    }

    /** Applies a pending grid-size change here, on the analyzer thread that owns
     *  the buffers: reallocate and relearn the background from scratch. Returns
     *  the grid side to use for this frame. */
    private fun ensureBuffers(): Int {
        val grid = gridSize
        if (grid != currentGrid) {
            currentGrid = grid
            val ss = grid * 2
            ssBitmap = Bitmap.createBitmap(ss, ss, Bitmap.Config.ARGB_8888)
            ssPixels = IntArray(ss * ss)
            background = FloatArray(grid * grid)
            hasBackground = false
        }
        return grid
    }

    /** Folds the freshly drawn [ssBitmap] into grid cells, compares against and
     *  updates the learned background, records [lastScore], and returns the
     *  motion verdict. Shared tail of both public entry points. */
    private fun scoreThumbnail(grid: Int): Boolean {
        val ss = grid * 2
        ssBitmap.getPixels(ssPixels, 0, ss, 0, 0, ss, ss)

        // Fold the supersampled image down: each grid cell = mean luma of its
        // 2×2 block (see the buffer comment above for why this matters).
        val priming = !hasBackground
        var changed = 0
        val threshold = pixelDelta.toFloat()
        var cell = 0
        for (cy in 0 until grid) {
            val row0 = (cy * 2) * ss
            val row1 = row0 + ss
            for (cx in 0 until grid) {
                val x0 = cx * 2
                val l = 0.25f * (
                    luma(ssPixels[row0 + x0]) + luma(ssPixels[row0 + x0 + 1]) +
                    luma(ssPixels[row1 + x0]) + luma(ssPixels[row1 + x0 + 1])
                )
                if (priming) {
                    background[cell] = l
                } else {
                    if (abs(l - background[cell]) > threshold) changed++
                    background[cell] += bgAlpha * (l - background[cell])
                }
                cell++
            }
        }
        if (priming) {
            hasBackground = true
            lastScore = 0.0
            return false
        }
        val score = changed.toDouble() / (grid * grid)
        lastScore = score
        return score >= areaFraction
    }

    /** Perceived brightness (0..255) of an ARGB pixel (standard luma weights). */
    private fun luma(p: Int): Float {
        val r = (p shr 16) and 0xFF
        val g = (p shr 8) and 0xFF
        val b = p and 0xFF
        return 0.299f * r + 0.587f * g + 0.114f * b
    }
}
