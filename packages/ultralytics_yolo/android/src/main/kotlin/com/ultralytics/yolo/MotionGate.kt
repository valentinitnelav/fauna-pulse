// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.Bitmap
import kotlin.math.abs

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
        // Apply a grid-size change here, on the analyzer thread that owns the
        // buffers: reallocate and relearn the background from scratch.
        val grid = gridSize
        val ss = grid * 2
        if (grid != currentGrid) {
            currentGrid = grid
            ssBitmap = Bitmap.createBitmap(ss, ss, Bitmap.Config.ARGB_8888)
            ssPixels = IntArray(ss * ss)
            background = FloatArray(grid * grid)
            hasBackground = false
        }

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
