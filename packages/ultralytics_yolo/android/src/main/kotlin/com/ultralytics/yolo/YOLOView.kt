// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.*
import android.util.AttributeSet
import android.util.Log
import android.view.*
import android.widget.FrameLayout
import android.widget.Toast
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.CaptureRequestOptions
import android.os.Build
import android.os.SystemClock
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.core.*
import androidx.camera.core.Camera
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import android.util.SizeF
import kotlin.math.abs
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import android.widget.TextView
import android.view.Gravity
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import android.content.res.Configuration

/**
 * Describes a back-camera lens with its equivalent zoom factor relative to the main wide-angle lens (1.0x). Used by
 * `getAvailableLenses` to populate the Dart lens picker.
 */
data class LensInfo(
    val zoomFactor: Double,
    val label: String,
    val cameraInfo: CameraInfo? = null
)

class YOLOView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : FrameLayout(context, attrs), DefaultLifecycleObserver {

    // Lifecycle owner for camera
    private var lifecycleOwner: LifecycleOwner? = null

    companion object {
        private const val REQUEST_CODE_PERMISSIONS = 10
        private val REQUIRED_PERMISSIONS = arrayOf(Manifest.permission.CAMERA)
        private var previewUseCase: Preview? = null

        private const val TAG = "YOLOView"

        // Line thickness and corner radius
        private const val BOX_LINE_WIDTH = 8f
        private const val BOX_CORNER_RADIUS = 12f
        private const val KEYPOINT_LINE_WIDTH = 6f

        // Colors derived from Ultralytics
        private val ultralyticsColors = arrayOf(
            Color.argb(153, 4,   42,  255),
            Color.argb(153, 11,  219, 235),
            Color.argb(153, 243, 243, 243),
            Color.argb(153, 0,   223, 183),
            Color.argb(153, 17,  31,  104),
            Color.argb(153, 255, 111, 221),
            Color.argb(153, 255, 68,  79),
            Color.argb(153, 204, 237, 0),
            Color.argb(153, 0,   243, 68),
            Color.argb(153, 189, 0,   255),
            Color.argb(153, 0,   180, 255),
            Color.argb(153, 221, 0,   186),
            Color.argb(153, 0,   255, 255),
            Color.argb(153, 38,  192, 0),
            Color.argb(153, 1,   255, 179),
            Color.argb(153, 125, 36,  255),
            Color.argb(153, 123, 0,   104),
            Color.argb(153, 255, 27,  108),
            Color.argb(153, 252, 109, 47),
            Color.argb(153, 162, 255, 11)
        )

        // Pose
        private val posePalette = arrayOf(
            floatArrayOf(255f, 128f,  0f),
            floatArrayOf(255f, 153f,  51f),
            floatArrayOf(255f, 178f, 102f),
            floatArrayOf(230f, 230f,   0f),
            floatArrayOf(255f, 153f, 255f),
            floatArrayOf(153f, 204f, 255f),
            floatArrayOf(255f, 102f, 255f),
            floatArrayOf(255f,  51f, 255f),
            floatArrayOf(102f, 178f, 255f),
            floatArrayOf( 51f, 153f, 255f),
            floatArrayOf(255f, 153f, 153f),
            floatArrayOf(255f, 102f, 102f),
            floatArrayOf(255f,  51f,  51f),
            floatArrayOf(153f, 255f, 153f),
            floatArrayOf(102f, 255f, 102f),
            floatArrayOf( 51f, 255f,  51f),
            floatArrayOf(  0f, 255f,   0f),
            floatArrayOf(  0f,   0f, 255f),
            floatArrayOf(255f,   0f,   0f),
            floatArrayOf(255f, 255f, 255f),
        )

        private val kptColorIndices = intArrayOf(
            16,16,16,16,16,
            9, 9, 9, 9, 9, 9,
            0, 0, 0, 0, 0, 0
        )

        private val limbColorIndices = intArrayOf(
            0, 0, 0, 0,
            7, 7, 7,
            9, 9, 9, 9, 9,
            16,16,16,16,16,16,16
        )

        private val skeleton = arrayOf(
            intArrayOf(16, 14),
            intArrayOf(14, 12),
            intArrayOf(17, 15),
            intArrayOf(15, 13),
            intArrayOf(12, 13),
            intArrayOf(6, 12),
            intArrayOf(7, 13),
            intArrayOf(6, 7),
            intArrayOf(6, 8),
            intArrayOf(7, 9),
            intArrayOf(8, 10),
            intArrayOf(9, 11),
            intArrayOf(2, 3),
            intArrayOf(1, 2),
            intArrayOf(1, 3),
            intArrayOf(2, 4),
            intArrayOf(3, 5),
            intArrayOf(4, 6),
            intArrayOf(5, 7)
        )
    }

    // Callback to notify inference results externally
    private var inferenceCallback: ((YOLOResult) -> Unit)? = null
    
    // Streaming functionality
    private var streamConfig: YOLOStreamConfig? = null
    private var streamCallback: ((Map<String, Any>) -> Unit)? = null
    
    // Frame counter for streaming
    private var frameNumberCounter: Long = 0
    
    // Throttling variables for performance control
    private var lastInferenceTime: Long = 0
    // Deadline (nanoTime) before which the inference-rate cap rejects frames.
    // A deadline SCHEDULER, not an elapsed-time check: each allowed start
    // advances it by exactly one interval (see shouldRunInference), so the
    // average rate honours the configured cap even when camera frame arrivals
    // don't line up with it. 0 = run immediately (reset on config change).
    private var nextAllowedInferenceNs: Long = 0
    private var targetFrameInterval: Long? = null // in nanoseconds
    private var throttleInterval: Long? = null // in nanoseconds
    
    // Inference frequency control variables
    private var inferenceFrameInterval: Long? = null // Target inference interval in nanoseconds
    private var frameSkipCount: Int = 0 // Current frame skip counter
    private var targetSkipFrames: Int = 0 // Number of frames to skip between inferences

    /** Set the callback */
    fun setOnInferenceCallback(callback: (YOLOResult) -> Unit) {
        this.inferenceCallback = callback
    }
    
    /** Set streaming configuration */
    fun setStreamConfig(config: YOLOStreamConfig?) {
        val resolutionChanged = config?.analysisWidth != streamConfig?.analysisWidth ||
            config?.analysisHeight != streamConfig?.analysisHeight
        this.streamConfig = config
        setupThrottlingFromConfig()
        if (resolutionChanged && camera != null) {
            startCamera() // rebind so the new analysis resolution takes effect
        }
    }

    /** Set streaming callback */
    fun setStreamCallback(callback: ((Map<String, Any>) -> Unit)?) {
        this.streamCallback = callback
    }

    // Generic event callback used to forward {type:"zoom"|"lens"|"focus", ...} maps to the Flutter event sink without
    // coupling YOLOView to a Flutter type.
    private var eventCallback: ((Map<String, Any>) -> Unit)? = null

    /** Set a callback that receives typed events (zoom/lens/focus) for the Flutter event sink. */
    fun setEventCallback(callback: ((Map<String, Any>) -> Unit)?) {
        this.eventCallback = callback
    }

    // Throttle inference-error events: an incompatible model fails on every frame,
    // so surface the error to Flutter once every few seconds rather than flooding it.
    private var lastInferenceErrorMs = 0L

    /** Emit a typed inference-error event (throttled) so the Flutter UI can warn the user. */
    private fun maybeEmitInferenceError(e: Throwable) {
        val now = System.currentTimeMillis()
        if (now - lastInferenceErrorMs < 3000) return
        lastInferenceErrorMs = now
        emitEvent(
            mapOf(
                "type" to "error",
                "scope" to "inference",
                "message" to (e.message ?: e.javaClass.simpleName),
            )
        )
    }

    private fun emitEvent(event: Map<String, Any>) {
        try {
            eventCallback?.invoke(event)
        } catch (e: Exception) {
            Log.e(TAG, "Error emitting event", e)
        }
    }

    // Callback to notify model load completion
    private var modelLoadCallback: ((Boolean) -> Unit)? = null

    /** Set model load completion callback (true: success) */
    fun setOnModelLoadCallback(callback: (Boolean) -> Unit) {
        this.modelLoadCallback = callback
    }

    /** True while a predictor is loaded and inference can run. False after an initial-load failure. */
    fun isModelLoaded(): Boolean = predictor != null

    /**
     * Why the most recent [setModel] failed (exception class + message), or null after a success.
     * Written on the loader thread, read on the platform (main) thread when building the channel
     * error, hence @Volatile. Lets callers surface the real reason (e.g. an ONNX Runtime QNN
     * context-binary arch mismatch) instead of a generic "failed to load".
     */
    @Volatile
    var lastModelLoadError: String? = null
        private set

    // Use a PreviewView, forcing a TextureView under the hood
    private val previewView: PreviewView = PreviewView(context).apply {
        // Force TextureView usage so the overlay can be on top
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        // FIT_CENTER ("contain"): show the WHOLE camera frame, adding thin letterbox bars rather
        // than cropping. The FaunaPulse needs the entire sensor frame visible so the square
        // region of interest can be dragged anywhere and grown to the full sensor resolution while
        // staying inside what the user sees. (FILL_CENTER would crop the frame to fill the screen,
        // which hid part of the sensor and capped the ROI below the true sensor width.)
        scaleType = PreviewView.ScaleType.FIT_CENTER
    }

    // The overlay for bounding boxes
    private val overlayView: OverlayView = OverlayView(context)

    private var inferenceResult: YOLOResult? = null
    private var predictor: Predictor? = null
    private var task: YOLOTask = YOLOTask.DETECT
    private var modelName: String = "Model"

    // Camera config
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var preferWideBackCamera = false
    private lateinit var cameraProviderFuture: ListenableFuture<ProcessCameraProvider>
    private var camera: Camera? = null

    // New fields for proper teardown:
    private var cameraExecutor: ExecutorService? = null
    private var imageAnalysisUseCase: ImageAnalysis? = null
    private var targetRotation = Surface.ROTATION_0

    // Bumped on every camera (re)bind. A rebind path (lens snap / camera flip / resume) shuts down the old executor
    // without awaiting it, so an in-flight analyzer frame on the old thread can still be running when the new analyzer
    // goes live; stale frames check this and bail so two predict() calls never overlap on the non-thread-safe predictor.
    private val cameraGeneration = AtomicInteger(0)
    
    // Flag to track if the view is stopped/disposed to prevent race conditions
    @Volatile
    private var isStopped = false

    // Distinguishes an intentional Dart-driven pause (pauseCamera) from a lifecycle stop. Both set isStopped, but a
    // lifecycle onStart/onResume must NOT auto-restart the camera while the app explicitly paused it.
    @Volatile
    private var intentionallyPaused = false

    // Zoom related
    private var currentZoomRatio = 1.0f
    private var minZoomRatio = 1.0f
    private var maxZoomRatio = 10.0f
    var onZoomChanged: ((Float) -> Unit)? = null

    // Multi-lens enumeration / selection
    private var cachedLenses: List<LensInfo> = emptyList()
    private var selectedLensZoomFactor: Double? = null
    private var selectedLensCameraInfo: CameraInfo? = null
    private var selectedLensLabel: String? = null
    // Effective zoom (relative to the wide-camera 1.0x reference) to emit after the next `startCamera()` rebind.
    // `startCamera()` resets physical zoom to 1.0x, but on a non-wide lens the user-facing effective zoom equals the
    // lens reference factor (e.g. 0.5x on ultra-wide, 2.0x on telephoto). Without this the ZoomIndicator/LensPicker
    // would snap back to 1.0x after every lens change.
    private var pendingEffectiveZoomToEmit: Double? = null
    private var pendingZoomRatioToApply: Float? = null

    // Optional ImageCapture use-case (bound alongside Preview+Analysis when supported)
    private var imageCaptureUseCase: ImageCapture? = null

    // Round 82 (FaunaPulse): the camera provider + selector actually bound, kept so
    // setPreviewEnabled() can detach/reattach ONLY the preview use case without a full rebind.
    private var boundCameraProvider: ProcessCameraProvider? = null
    private var boundCameraSelector: CameraSelector? = null
    // Whether the live preview should be attached. Power-save ("screen off") turns this off:
    // the preview output is one of the streams the camera hardware pipeline produces every
    // frame, so detaching it saves real sensor/ISP/compositing work while nobody is looking.
    @Volatile private var previewEnabled = true

    // Round 82: Camera2 interop state. setCaptureRequestOptions() REPLACES the whole option
    // set, so manual focus and the AE frame-rate cap must be applied together through the ONE
    // funnel below (applyInteropOptions) — never call setCaptureRequestOptions anywhere else,
    // or one setting will silently erase the other (e.g. re-enabling autofocus mid-session).
    private var interopAfMode: Int? = null          // null = leave device default
    private var interopFocusDioptres: Float? = null // only when interopAfMode == AF_MODE_OFF
    private var requestedCameraFpsCap = 0           // user wish; 0 = device default (~30)
    private var appliedFpsRange: android.util.Range<Int>? = null // what the HAL accepted

    // Round 63: still photos are processed OFF the main thread. CameraX runs the
    // takePicture callback on whatever executor it is given; handing it the main
    // executor meant ~1.5 s of JPEG work per photo (12 MP copy/decode/rotate/
    // re-encode) froze the UI, the preview AND the detector (measured as
    // PerfMonitor "longMsg wall=1570ms" on the Xiaomi test phone). A dedicated
    // single thread keeps captures serialized without touching the camera
    // executor. Intentionally view-lifetime (one idle thread is negligible and
    // must survive camera rebinds).
    private val stillExecutor = Executors.newSingleThreadExecutor()

    // Round 161 (perf review E2): model loads run on ONE owned executor instead of a throwaway
    // Executors.newSingleThreadExecutor() per setModel() call — each of those parked a non-daemon
    // thread forever (one leaked thread per model switch). The generation counter identifies loads
    // that a newer setModel() superseded while they were still building; the released flag marks
    // permanent platform-view disposal. Both stillExecutor and modelLoadExecutor are view-lifetime
    // on purpose: stop() is NOT terminal (a later setModel() restarts the camera), so they are only
    // shut down by release(), called from YOLOPlatformView.dispose().
    private val modelLoadExecutor = Executors.newSingleThreadExecutor()
    private val modelLoadGeneration = AtomicInteger(0)
    @Volatile
    private var executorsReleased = false

    // Main-looper handler for model-load completions. Deliberately NOT View.post: on a detached
    // (disposed) view, View.post parks the runnable until a re-attach that never comes, which would
    // strand the freshly built predictor unclosed. A looper handler always runs.
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // The executor handed to CameraX takePicture. A capture-error callback can arrive from the
    // camera thread just AFTER release() shut stillExecutor down (dispose() unbinds first, but that
    // delivery is asynchronous); dropping the late callback beats crashing CameraX internals with
    // RejectedExecutionException. All direct stillExecutor.execute call sites run on the main
    // thread and are therefore serialized against release() — only this CameraX hand-off races.
    private val stillCallbackExecutor = java.util.concurrent.Executor { r ->
        try {
            stillExecutor.execute(r)
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            Log.w(TAG, "Still-capture callback after release(); dropped")
        }
    }

    // FaunaPulse: optional region of interest. When non-null, inference runs only on this
    // square crop of the frame (see BasePredictor.inferenceRoi). Volatile because it is written from
    // the Flutter platform-channel thread and read on the camera analyzer thread.
    @Volatile
    private var inferenceRoi: InferenceRoi? = null

    /** Sets (or clears, when [side] <= 0) the square ROI inference crop. Coordinates are normalized
     *  in the upright frame; [side] is a fraction of frame width. */
    fun setInferenceRoi(cx: Double, cy: Double, side: Double) {
        inferenceRoi = if (side <= 0.0) {
            null
        } else {
            InferenceRoi(cx.toFloat(), cy.toFloat(), side.toFloat())
        }
        // The gate's learned background belongs to the OLD ROI position; forget it
        // and keep the detector awake briefly so a mid-session ROI drag never
        // causes a false idle (or a false motion burst) while the background relearns.
        if (motionGateEnabled) {
            motionGate.reset()
            gateAwakeUntilNs = System.nanoTime() + motionGateWakeNs
        }
    }

    // FaunaPulse: optional motion gate. When enabled, frames where nothing
    // moved inside the ROI (and no detection happened recently) skip inference
    // entirely — the detector "sleeps" while the flower is empty, saving heat and
    // battery in the field. See MotionGate for the algorithm. All fields volatile:
    // written from the platform-channel (main) thread, read on the analyzer thread.
    @Volatile private var motionGateEnabled = false
    @Volatile private var motionGateWakeNs = 3_000_000_000L
    // Deadline (nanoTime) until which the detector stays awake. Extended by
    // motion, by every non-empty detection result, and by ROI changes.
    @Volatile private var gateAwakeUntilNs = 0L
    private val motionGate = MotionGate()
    private var lastGateHeartbeatNs = 0L // analyzer thread only
    // Round 63 (cooler idle): while the gate keeps the detector asleep, only
    // one frame per this interval is converted + motion-checked; the rest are
    // dropped untouched. Converting EVERY frame to a bitmap just to look for
    // motion (7–16 ms each, ~30 fps) was the main idle heat source.
    private var lastGateSampleNs = 0L // analyzer thread only
    @Volatile private var gateIdleSampleNs = 200_000_000L // set via setMotionGate(idleFps)
    // Motion-only capture mode: photos are taken on ROI motion alone and the
    // detector NEVER runs — predict() is skipped entirely (the model stays
    // loaded but cold, so the GPU never spins up). Frames divert into their own
    // branch in onFrame, BEFORE the predictor block. Requires the motion gate.
    @Volatile private var motionOnlyMode = false
    private var lastMotionOnlyEmitNs = 0L // analyzer thread only

    // Time-lapse capture mode (round 97): photos on a pure Dart-side clock —
    // no detector, no motion gate. The native side only (1) keeps the cached
    // frame fresh enough for fast ROI crops by converting at sampleFps
    // (Dart raises it during a burst, lowers it between bursts — conversion
    // is the idle heat source, same lesson as the gate's idle sampler) and
    // (2) heartbeats ~1 Hz so the Dart watchdog/bootstrap stay fed.
    @Volatile private var timeLapseMode = false
    @Volatile private var timeLapseSampleNs = 1_000_000_000L // via setTimeLapse
    private var lastTimeLapseSampleNs = 0L // analyzer thread only
    private var lastTimeLapseEmitNs = 0L // analyzer thread only

    /** Enables/disables time-lapse mode. [sampleFps] is how many camera
     *  frames per second are converted (frame-cache freshness for fast ROI
     *  crops); the rest are dropped before the costly bitmap conversion. */
    fun setTimeLapse(enabled: Boolean, sampleFps: Int) {
        timeLapseSampleNs = 1_000_000_000L / sampleFps.coerceIn(1, 30)
        timeLapseMode = enabled
        Log.i(TAG, "TimeLapse ${if (enabled) "ON" else "OFF"} sampleFps=$sampleFps")
    }

    /**
     * Enables/disables the motion gate and applies its tuning. [pixelDelta] is the
     * per-pixel brightness change (0..255) that counts as "changed"; [areaFraction]
     * the fraction of ROI pixels that must change to wake the detector;
     * [wakeSeconds] how long the detector keeps running after the last motion or
     * detection; [gridSize] the side of the comparison thumbnail (finer grids let
     * smaller insects register — each cell covers ROI-side/gridSize of the scene).
     * The gate always starts AWAKE so the user can see the detector working before
     * it first goes to sleep.
     */
    fun setMotionGate(
        enabled: Boolean,
        pixelDelta: Int,
        areaFraction: Double,
        wakeSeconds: Double,
        gridSize: Int = MotionGate.DEFAULT_GRID,
        idleFps: Int = 5,
        motionOnly: Boolean = false,
    ) {
        motionGate.pixelDelta = pixelDelta.coerceIn(1, 255)
        motionGate.areaFraction = areaFraction.coerceIn(0.0001, 1.0)
        motionGate.gridSize = gridSize
        motionGateWakeNs = (wakeSeconds.coerceIn(0.5, 60.0) * 1e9).toLong()
        // Round 64: user-tunable idle sampling rate (was hardcoded ~5 fps).
        gateIdleSampleNs = 1_000_000_000L / idleFps.coerceIn(1, 30)
        motionGate.reset()
        gateAwakeUntilNs = System.nanoTime() + motionGateWakeNs
        motionOnlyMode = motionOnly
        // Motion-only capture cannot work without the gate (it IS the trigger),
        // so it forces the gate on regardless of the caller's enabled flag.
        motionGateEnabled = enabled || motionOnly
        Log.i(TAG, "MotionGate ${if (motionGateEnabled) "ON" else "OFF"} pixelDelta=$pixelDelta areaFraction=$areaFraction wakeSeconds=$wakeSeconds gridSize=$gridSize motionOnly=$motionOnly")
    }

    /** Runs the motion gate directly on the camera frame (the gate draws its own
     *  tiny ROI thumbnail). Only used on frames without a model-input raster —
     *  gate idle, or awake but FPS-capped; frames that run inference reuse the
     *  detector's model-input bitmap instead (perf review A5, see onFrame). */
    private fun gateMotionFromFrame(bitmap: Bitmap, rotationDegrees: Int, isLandscape: Boolean): Boolean {
        val roi = inferenceRoi
        return motionGate.motionDetected(
            bitmap = bitmap,
            rotateForCamera = true,
            isLandscape = isLandscape,
            isFrontCamera = lensFacing == CameraSelector.LENS_FACING_FRONT,
            rotationDegrees = rotationDegrees,
            // No ROI set -> watch the centered full-height square (side is
            // clamped to the frame's short side inside the crop helper).
            roiCx = roi?.cx ?: 0.5f,
            roiCy = roi?.cy ?: 0.5f,
            roiSide = roi?.side ?: 1f,
        )
    }

    /** Tells Flutter once a second that we are alive but gated, so the UI can
     *  show "motion gate: idle" instead of tripping the 0-FPS "detector not
     *  producing results" watchdog. Single emitter shared by the detector-gate
     *  and motion-only idle paths so the two heartbeat shapes cannot drift. */
    private fun maybeEmitGateIdleHeartbeat(nowNs: Long) {
        if (nowNs - lastGateHeartbeatNs < 1_000_000_000L) return
        lastGateHeartbeatNs = nowNs
        streamCallback?.invoke(
            mapOf(
                "gateIdle" to true,
                "motionOnly" to motionOnlyMode,
                "motionScore" to motionGate.lastScore,
                "cameraFps" to lastDeliveredFps,
                "timestamp" to System.currentTimeMillis(),
            )
        )
    }

    // detection thresholds (can be changed externally via setters)
    private var confidenceThreshold = 0.25  // initial value
    private var iouThreshold = 0.7
    private var numItemsThreshold = 30
    private var showOverlays = true
    private lateinit var zoomLabel: TextView
    private lateinit var cameraButton: TextView
    private lateinit var confidenceLabel: TextView
    private var showUIControls = false

    init {
        // Clear any existing children
        removeAllViews()

        // 1) A container for the camera preview
        val previewContainer = FrameLayout(context).apply {
            layoutParams = LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.MATCH_PARENT
            )
        }

        // 2) Add the previewView to that container
        previewContainer.addView(previewView, LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT
        ))

        // 3) Add that container
        addView(previewContainer)

        // 4) Add the overlay on top
        addView(overlayView, LayoutParams(
            LayoutParams.MATCH_PARENT,
            LayoutParams.MATCH_PARENT
        ))

        // Ensure overlay is visually above the preview container
        overlayView.elevation = 100f
        overlayView.translationZ = 100f
        previewContainer.elevation = 1f
        
        // Add zoom label
        zoomLabel = TextView(context).apply {
            layoutParams = LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.CENTER
            }
            text = "ZOOM: 1.0x"
            textSize = 28f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(200, 255, 0, 0))
            setPadding(20, 15, 20, 15)
            visibility = View.GONE
        }
        addView(zoomLabel)
        zoomLabel.elevation = 1000f
        
        // Add camera switch button
        cameraButton = TextView(context).apply {
            layoutParams = LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.TOP or Gravity.END
                topMargin = 100
                rightMargin = 50
            }
            text = "📷 CAMERA"
            textSize = 24f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(200, 0, 100, 200))
            setPadding(20, 15, 20, 15)
            visibility = View.GONE
            
            setOnClickListener {
                switchCamera()
            }
        }
        addView(cameraButton)
        cameraButton.elevation = 1000f
        
        // Add confidence threshold label
        confidenceLabel = TextView(context).apply {
            layoutParams = LayoutParams(
                LayoutParams.WRAP_CONTENT,
                LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.START
                bottomMargin = 100
                leftMargin = 50
            }
            text = "Confidence: 0.25"
            textSize = 20f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(200, 200, 100, 0))
            setPadding(15, 10, 15, 10)
            visibility = View.GONE
        }
        addView(confidenceLabel)
        confidenceLabel.elevation = 1000f
        // Dart owns gestures (pinch + tap) via Flutter GestureDetector in YOLOShowcase; native is setter-only. Do not
        // attach ScaleGestureDetector here.
    }

    // region threshold setters

    fun setConfidenceThreshold(conf: Double) {
        confidenceThreshold = conf
        predictor?.setConfidenceThreshold(conf)
        // Update the confidence label if UI controls are shown
        if (showUIControls) {
            post {
                confidenceLabel.text = "Confidence: ${String.format("%.2f", conf)}"
            }
        }
    }

    fun setIouThreshold(iou: Double) {
        iouThreshold = iou
        predictor?.setIouThreshold(iou)
    }

    fun setNumItemsThreshold(n: Int) {
        numItemsThreshold = n
        predictor?.setNumItemsThreshold(n)
    }
    
    fun setShowOverlays(show: Boolean) {
        showOverlays = show
        if (!show) {
            inferenceResult = null
        }
        post {
            overlayView.invalidate()
        }
    }
    
    fun setShowUIControls(show: Boolean) {
        showUIControls = show
        // Show/hide all UI controls
        val visibility = if (show) View.VISIBLE else View.GONE
        zoomLabel.visibility = visibility
        cameraButton.visibility = visibility
        confidenceLabel.visibility = visibility
    }
    
    /**
     * Apply an *effective* zoom (relative to the wide-camera 1.0x reference). The physical setZoomRatio applied to the
     * underlying camera is `effective / selectedLensZoomFactor`, so on telephoto the same effective 2.0x produces
     * physical 1.0x (the tele's native FOV). Auto lens snap happens here before the digital zoom is applied.
     */
    fun setZoomLevel(zoomLevel: Float) {
        // First check whether the effective zoom should switch us to a different physical lens. `maybeSnapLensForZoom`
        // will rebind and emit the post-rebind zoom event itself; bail out so we don't apply digital zoom to the old
        // lens that's about to die.
        if (maybeSnapLensForZoom(zoomLevel.toDouble())) return

        camera?.let { cam: Camera ->
            val lensFactor = (selectedLensZoomFactor ?: 1.0).toFloat()
            val physical = (zoomLevel / lensFactor).coerceIn(
                minZoomRatio,
                cam.cameraInfo.zoomState.value?.maxZoomRatio ?: maxZoomRatio
            )
            cam.cameraControl.setZoomRatio(physical)
            currentZoomRatio = physical

            val effective = (physical * lensFactor).toDouble()

            // Notify zoom change (legacy callback uses physical ratio).
            onZoomChanged?.invoke(physical)

            // Dart-side ZoomIndicator consumes effective zoom so the value is consistent across lens switches.
            emitEvent(mapOf("type" to "zoom", "value" to effective))
        }
    }

    /**
     * If the requested effective zoom maps onto a different physical back-camera lens than the currently selected one,
     * switch CameraSelector and emit a `lens` event. Returns `true` when a snap was triggered (callers should not also
     * apply digital zoom on the about-to-rebind lens). Same thresholds as iOS upstream `updateSelectedLens` (largest
     * lens whose zoomFactor is <= requested wins; ties broken by the smallest lens).
     */
    private fun maybeSnapLensForZoom(zoomFactor: Double): Boolean {
        if (lensFacing != CameraSelector.LENS_FACING_BACK) return false
        val lenses = cachedLenses.filter { it.cameraInfo != null }
        if (lenses.size < 2) return false

        val sorted = lenses.sortedBy { it.zoomFactor }
        val target = sorted.lastOrNull { zoomFactor >= it.zoomFactor - 0.01 } ?: sorted.first()

        // Skip rebind if we're already on the target lens. When `selectedLensCameraInfo` is null (first frame after the
        // back camera bound), fall back to identifying the lens by matching cameraInfo against the currently-bound
        // camera so a first pinch on the wide lens doesn't trigger an unnecessary rebind.
        val currentInfo = selectedLensCameraInfo ?: camera?.cameraInfo
        if (currentInfo == target.cameraInfo) return false

        try {
            // Preserve the user-requested effective zoom across the rebind: the new lens starts at physical 1.0x =
            // effective `target.zoomFactor`, which is the same FOV the user was pinching toward.
            pendingEffectiveZoomToEmit = target.zoomFactor
            switchToLens(target)
            emitEvent(mapOf("type" to "lens", "label" to target.label))
            return true
        } catch (e: Exception) {
            Log.w(TAG, "Lens snap to ${target.label} failed", e)
            pendingEffectiveZoomToEmit = null
            return false
        }
    }

    // Turns the torch on/off and returns the actual resulting state (false when there is no flash unit), so callers
    // can keep their cached state in sync with the hardware.
    fun setTorchMode(enabled: Boolean): Boolean {
        camera?.let { cam ->
            if (cam.cameraInfo.hasFlashUnit()) {
                cam.cameraControl.enableTorch(enabled)
                return enabled
            }
        }
        return false
    }

    // endregion

    // region Model / Task

    // Recently-loaded predictors kept in memory so switching back to a model is instant instead of re-building the
    // TFLite interpreter every time. Bounded by predictorCacheLimit to cap memory. Accessed on the main thread
    // (setModel is called from the platform channel; cache writes happen inside post {}).
    private val predictorCache = HashMap<String, Predictor>()
    private val predictorCacheOrder = ArrayList<String>()  // LRU: oldest first, newest last
    private val predictorCacheLimit = 3

    private fun cachePredictor(key: String, predictor: Predictor) {
        val previous = predictorCache.put(key, predictor)
        if (previous != null && previous !== predictor) {
            closePredictor(previous)
        }
        predictorCacheOrder.remove(key)
        predictorCacheOrder.add(key)
        while (predictorCacheOrder.size > predictorCacheLimit) {
            // The current predictor is always newest (just touched), so it is never the eviction target.
            val evictedKey = predictorCacheOrder.removeAt(0)
            val evictedPredictor = predictorCache.remove(evictedKey)
            if (evictedPredictor != null && evictedPredictor !== predictor) {
                closePredictor(evictedPredictor)
            }
        }
    }

    private fun closePredictor(predictor: Predictor) {
        // Cache eviction/replacement runs on the main thread, but onFrame() calls predict() on this predictor on the
        // camera executor thread. Defer the close onto that same single thread so the native interpreter is never freed
        // while a frame is still mid-predict() (use-after-free). When no executor is live (e.g. during stop()) close
        // directly — stop() drains the executor before closing, so no inference can be in flight there.
        val exec = cameraExecutor
        if (exec != null && !exec.isShutdown) {
            exec.execute {
                try {
                    (predictor as? BasePredictor)?.close()
                } catch (e: Exception) {
                    Log.e(TAG, "Error closing cached predictor", e)
                }
            }
        } else {
            try {
                (predictor as? BasePredictor)?.close()
            } catch (e: Exception) {
                Log.e(TAG, "Error closing cached predictor", e)
            }
        }
    }

    fun setModel(modelPath: String, task: YOLOTask, useGpu: Boolean = true, cpuThreads: Int = 0, callback: ((Boolean) -> Unit)? = null) {
        val cacheKey = "$modelPath|$task|$useGpu|$cpuThreads"
        // Round 161 (perf review E2): this call owns the newest generation; any still-building older
        // load sees the mismatch on completion and steps aside instead of installing over us.
        val generation = modelLoadGeneration.incrementAndGet()
        inferenceResult = null
        post {
            overlayView.invalidate()
        }

        // Fast path: reuse an already-loaded predictor (re-applying the current thresholds) for an instant switch.
        predictorCache[cacheKey]?.let { cached ->
            cached.setConfidenceThreshold(confidenceThreshold)
            cached.setIouThreshold(iouThreshold)
            cached.setNumItemsThreshold(numItemsThreshold)
            post {
                this.task = task
                this.predictor = cached
                this.modelName = modelPath.substringAfterLast("/")
                lastModelLoadError = null
                cachePredictor(cacheKey, cached)
                modelLoadCallback?.invoke(true)
                callback?.invoke(true)
                if (allPermissionsGranted() && lifecycleOwner != null && (camera == null || isStopped)) {
                    startCamera()
                }
            }
            return
        }

        val accepted = submitModelLoad(modelPath) {
            try {
                val newPredictor = when (task) {
                    YOLOTask.DETECT -> ObjectDetector(context = context, modelPath = modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                    YOLOTask.SEGMENT -> Segmenter(context, modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                    YOLOTask.SEMANTIC -> SemanticSegmenter(context, modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                    YOLOTask.CLASSIFY -> Classifier(context, modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                    YOLOTask.POSE -> PoseEstimator(context, modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                    YOLOTask.OBB -> ObbDetector(context, modelPath, labels = emptyList(), useGpu = useGpu, cpuThreads = cpuThreads)
                }

                // Apply thresholds to all predictor types
                newPredictor.apply {
                    setConfidenceThreshold(confidenceThreshold)
                    setIouThreshold(iouThreshold)
                    setNumItemsThreshold(numItemsThreshold)
                }

                mainHandler.post {
                    if (executorsReleased) {
                        // The platform view was disposed while this model was building: stop() has
                        // already closed the active + cached predictors, so close the orphan too.
                        try {
                            (newPredictor as? BasePredictor)?.close()
                        } catch (e: Exception) {
                            Log.e(TAG, "Error closing orphaned model load", e)
                        }
                        callback?.invoke(false)
                        return@post
                    }
                    if (generation != modelLoadGeneration.get()) {
                        // A newer setModel() superseded this load while it was building. Keep the
                        // finished predictor warm in the bounded LRU cache (instant switch back)
                        // but do NOT install it over the newer model.
                        cachePredictor(cacheKey, newPredictor)
                        callback?.invoke(true)
                        return@post
                    }
                    this.task = task
                    this.predictor = newPredictor
                    this.modelName = modelPath.substringAfterLast("/")
                    lastModelLoadError = null
                    cachePredictor(cacheKey, newPredictor)
                    modelLoadCallback?.invoke(true)
                    callback?.invoke(true)
                    // Ensure camera starts after model loads if it's not already running
                    if (allPermissionsGranted() && lifecycleOwner != null && (camera == null || isStopped)) {
                        startCamera()
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to load model: $modelPath. Keeping the previously loaded model if one is present.", e)
                lastModelLoadError = "${e.javaClass.simpleName}: ${e.message}"
                mainHandler.post {
                    if (executorsReleased || generation != modelLoadGeneration.get()) {
                        // Disposed or superseded by a newer load: that newer call owns the UI/error
                        // state now (nothing to close — the failed load built no predictor).
                        callback?.invoke(false)
                        return@post
                    }
                    // The new predictor was built into a local and never assigned, so the previously loaded model is
                    // untouched. Only drop inference when there is nothing to fall back to (an initial-load failure);
                    // for an in-place switch failure keep the previous predictor running so the camera doesn't
                    // silently stop detecting while the UI reverts to the still-loaded model.
                    if (this.predictor == null) {
                        this.modelName = "No Model"
                    }
                    modelLoadCallback?.invoke(false)
                    callback?.invoke(false)
                }
            }
        }
        if (!accepted) {
            // release() already shut the load executor down (platform view disposed mid-call).
            callback?.invoke(false)
        }
    }

    /** Round 161 (perf review E2): submit a model load to the owned executor; false when the
     *  executor was already shut down by release() (permanent view disposal). */
    private fun submitModelLoad(modelPath: String, block: () -> Unit): Boolean =
        try {
            modelLoadExecutor.execute { block() }
            true
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            Log.w(TAG, "Model load rejected after release(): $modelPath")
            false
        }

    /**
     * Round 161 (perf review E2): terminal counterpart to stop() for PERMANENT platform-view
     * disposal (YOLOPlatformView.dispose()). stop() must stay restartable — a later setModel()
     * rebinds the camera — so the view-lifetime executors are only shut down here. Call AFTER
     * stop(). shutdown() (not shutdownNow()) lets an in-flight model build finish; its completion
     * sees executorsReleased and closes the orphaned predictor instead of installing it.
     */
    fun release() {
        executorsReleased = true
        modelLoadGeneration.incrementAndGet() // strand any in-flight load's generation
        modelLoadExecutor.shutdown()
        stillExecutor.shutdown()
    }

    // endregion

    private fun syncTargetRotation() {
        val rotation = previewView.display?.rotation ?: return
        if (rotation == targetRotation) return
        targetRotation = rotation
        previewUseCase?.targetRotation = rotation
        imageAnalysisUseCase?.targetRotation = rotation
        imageCaptureUseCase?.targetRotation = rotation
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        syncTargetRotation()
    }

    /**
     * Called when a LifecycleOwner is available for camera operations
     */
    fun onLifecycleOwnerAvailable(owner: LifecycleOwner) {
        // Detach from any previous owner before re-registering so a re-attach (or owner change) can't leave a stale
        // observer wired to this view, and so disposal can fully release it.
        this.lifecycleOwner?.lifecycle?.removeObserver(this)
        this.lifecycleOwner = owner
        owner.lifecycle.addObserver(this)

        if (allPermissionsGranted() && (camera == null || isStopped)) {
            startCamera()
        }
    }

    /**
     * Detach from the lifecycle owner. Called on platform-view disposal so the Activity's lifecycle no longer holds a
     * strong reference to this (now-dead) view — otherwise a later onStart/onResume would invoke startCamera() on it.
     */
    fun detachLifecycle() {
        lifecycleOwner?.lifecycle?.removeObserver(this)
        lifecycleOwner = null
    }

    /**
     * Pause the camera pipeline without tearing down the predictor.
     *
     * The "pause" method channel call routes here (not [stop]) so that "resume" -> [startCamera] can rebind: [stop]
     * closes and nulls the predictor, and [startCamera] early-returns while `predictor == null`, which would otherwise
     * leave the preview dead after a single pause/resume cycle. This only unbinds the camera use-cases and clears the
     * analyzer; the predictor, callbacks and cache stay intact for an instant resume.
     */
    fun pauseCamera() {
        isStopped = true
        intentionallyPaused = true
        try {
            imageAnalysisUseCase?.clearAnalyzer()
            if (::cameraProviderFuture.isInitialized) {
                try {
                    cameraProviderFuture.get(1, TimeUnit.SECONDS).unbindAll()
                } catch (e: Exception) {
                    Log.e(TAG, "Error unbinding camera on pause", e)
                }
            }
            previewUseCase?.setSurfaceProvider(null)
            camera = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during camera pause", e)
        }
    }
    
    // region camera init

    fun initCamera() {
        if (allPermissionsGranted()) {
            if (lifecycleOwner != null && (camera == null || isStopped)) {
                startCamera()
            }
        } else {
            val activity = context as? Activity ?: return
            ActivityCompat.requestPermissions(
                activity,
                REQUIRED_PERMISSIONS,
                REQUEST_CODE_PERMISSIONS
            )
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == REQUEST_CODE_PERMISSIONS) {
            if (allPermissionsGranted()) {
                startCamera()
            } else {
                Toast.makeText(context, "Camera permission not granted.", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun allPermissionsGranted() = REQUIRED_PERMISSIONS.all {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

    fun startCamera() {
        // Defer binding the camera until a model is loaded. Otherwise the preview starts on view-attach and the heavy
        // first GPU model compile runs while the preview is live, disrupting it. With this guard the camera binds
        // exactly once, from setModel's callback after the predictor is ready. setModel re-invokes startCamera once it
        // sets predictor.
        if (predictor == null) {
            return
        }
        isStopped = false
        // An explicit start/resume clears the intentional-pause flag so lifecycle events resume the camera again.
        intentionallyPaused = false

        try {
            cameraProviderFuture = ProcessCameraProvider.getInstance(context)
            cameraProviderFuture.addListener({
                try {
                    val cameraProvider = cameraProviderFuture.get()

                    // Stale-listener guard: if pauseCamera()/stop() ran after this listener was posted but before it
                    // fired (e.g. rapid pause during model load), bail so we don't rebind a camera that was just stopped.
                    if (isStopped) {
                        return@addListener
                    }

                    // Tear down the previous analyzer + executor before rebinding. Rebind paths (setLens/auto-snap,
                    // switchCamera, setLensFacing, onStart/onResume) reach startCamera() without going through stop(),
                    // and each call builds a fresh ImageAnalysis + executor below. Without this, the old executor's
                    // non-daemon analyzer thread and the old ImageAnalysis analyzer would be orphaned on every rebind.
                    imageAnalysisUseCase?.clearAnalyzer()
                    // Drain the old executor (not just shutdown) so any frame already inside onFrame()/predict() on the
                    // previous analyzer thread finishes before the new analyzer binds — the generation guard below only
                    // stops not-yet-started frames, and the predictor is not thread-safe. We're on the camera-provider
                    // listener thread here, not the analyzer thread, so awaiting does not self-deadlock.
                    cameraExecutor?.let { exec ->
                        exec.shutdown()
                        try {
                            if (!exec.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                                exec.shutdownNow()
                            }
                        } catch (e: InterruptedException) {
                            exec.shutdownNow()
                            Thread.currentThread().interrupt()
                        }
                    }
                    cameraExecutor = null

                    targetRotation = previewView.display?.rotation ?: Surface.ROTATION_0

                    previewUseCase = Preview.Builder()
                        .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                        .setTargetRotation(targetRotation)
                        .build()

                    val analysisBuilder = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setTargetRotation(targetRotation)
                        // Ask CameraX for RGBA frames so toBitmap() is a direct buffer copy. The default YUV_420_888
                        // forced a per-frame JPEG encode@100 + decode round-trip (~100ms/frame, ~5 FPS).
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    val analysisWidth = streamConfig?.analysisWidth
                    val analysisHeight = streamConfig?.analysisHeight
                    if (analysisWidth != null && analysisHeight != null && analysisWidth > 0 && analysisHeight > 0) {
                        // Opt-in higher analysis resolution: by default CameraX delivers ~640x480 frames, which caps
                        // the detail reaching models with larger inputs. CameraX picks the nearest supported size.
                        val selectorBuilder = ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    android.util.Size(analysisWidth, analysisHeight),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                )
                            )
                        // Only trade frame rate for resolution when the caller actually asks for a
                        // large stream (> ~720p). For the default ~640x480 we keep CameraX's
                        // frame-rate-first behaviour, so a low stream stays fast (no forced upsize).
                        if (analysisWidth.toLong() * analysisHeight > 921_600L) {
                            selectorBuilder.setAllowedResolutionMode(
                                ResolutionSelector.PREFER_HIGHER_RESOLUTION_OVER_CAPTURE_RATE
                            )
                        }
                        analysisBuilder.setResolutionSelector(selectorBuilder.build())
                    } else {
                        if (analysisWidth != null || analysisHeight != null) {
                            Log.w(TAG, "Ignoring invalid analysisResolution ${analysisWidth}x${analysisHeight}")
                        }
                        analysisBuilder.setTargetAspectRatio(AspectRatio.RATIO_4_3)
                    }
                    imageAnalysisUseCase = analysisBuilder.build()

                    cameraExecutor = Executors.newSingleThreadExecutor()
                    val myGeneration = cameraGeneration.incrementAndGet()
                    imageAnalysisUseCase!!.setAnalyzer(cameraExecutor!!) { imageProxy ->
                        // Drop frames from a superseded binding: the old executor may still deliver one in-flight frame
                        // after a rebind, and overlapping predict() calls on the shared predictor are not thread-safe.
                        if (myGeneration != cameraGeneration.get()) {
                            imageProxy.close()
                            return@setAnalyzer
                        }
                        onFrame(imageProxy)
                    }

                    val cameraSelector = buildCameraSelector(cameraProvider)

                    cameraProvider.unbindAll()

                    try {
                        val owner = lifecycleOwner
                        if (owner == null) {
                            Log.e(TAG, "No LifecycleOwner available. Call onLifecycleOwnerAvailable() first.")
                            return@addListener
                        }

                        // Refresh lens enumeration once we have a camera provider.
                        cachedLenses = computeLensInfos(cameraProvider)

                        // Preferred path: bind Preview + ImageAnalysis + ImageCapture so capturePhoto() can grab a
                        // full-resolution still. Some low-tier devices cannot bind three use-cases simultaneously; in
                        // that case fall back to Preview + ImageAnalysis only and rely on captureFrame() for snapshots.
                        // Zero-Shutter-Lag keeps a ring buffer of full-resolution frames, so a
                        // still can be grabbed near-instantly without reconfiguring the camera —
                        // this is the Android equivalent of the OAK's continuous encoder and
                        // greatly reduces the per-capture FPS stall when saving ROI photos. Only
                        // some devices/use-case combos support it, so we check first and fall back.
                        val zslSupported = try {
                            cameraProvider.getCameraInfo(cameraSelector).isZslSupported
                        } catch (e: Exception) {
                            false
                        }
                        fun buildImageCapture(zsl: Boolean) = ImageCapture.Builder()
                            .setCaptureMode(
                                if (zsl) ImageCapture.CAPTURE_MODE_ZERO_SHUTTER_LAG
                                else ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY
                            )
                            .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                            .setTargetRotation(targetRotation)
                            .build()
                        imageCaptureUseCase = buildImageCapture(zslSupported)
                        Log.i(TAG, "ImageCapture mode: ${if (zslSupported) "ZERO_SHUTTER_LAG" else "MINIMIZE_LATENCY"}")

                        camera = try {
                            cameraProvider.bindToLifecycle(
                                owner,
                                cameraSelector,
                                previewUseCase,
                                imageAnalysisUseCase,
                                imageCaptureUseCase
                            )
                        } catch (e: IllegalArgumentException) {
                            // ZSL alongside ImageAnalysis may be rejected on some devices; retry
                            // with a plain (MINIMIZE_LATENCY) still capture before giving up on it.
                            Log.w(TAG, "Three-use-case binding failed; retrying without ZSL", e)
                            try {
                                imageCaptureUseCase = buildImageCapture(false)
                                cameraProvider.bindToLifecycle(
                                    owner,
                                    cameraSelector,
                                    previewUseCase,
                                    imageAnalysisUseCase,
                                    imageCaptureUseCase
                                )
                            } catch (e2: IllegalArgumentException) {
                                Log.w(TAG, "Three-use-case binding failed, falling back without ImageCapture", e2)
                                imageCaptureUseCase = null
                                cameraProvider.bindToLifecycle(
                                    owner,
                                    cameraSelector,
                                    previewUseCase,
                                    imageAnalysisUseCase
                                )
                            }
                        }

                        // Reset zoom to 1.0x when camera starts
                        currentZoomRatio = 1.0f
                        onZoomChanged?.invoke(currentZoomRatio)

                        previewUseCase?.setSurfaceProvider(previewView.surfaceProvider)

                        // Round 82: remember what was bound (setPreviewEnabled needs it), honor
                        // an active power-save preview-off across rebinds (lens switch/resume),
                        // and re-assert the Camera2 interop options — a rebind builds a fresh
                        // capture session, which would otherwise drop the focus lock / fps cap.
                        boundCameraProvider = cameraProvider
                        boundCameraSelector = cameraSelector
                        if (!previewEnabled) {
                            previewUseCase?.let { p ->
                                try {
                                    if (cameraProvider.isBound(p)) cameraProvider.unbind(p)
                                } catch (e: Exception) {
                                    Log.w(TAG, "Could not keep preview detached across rebind", e)
                                }
                            }
                        }
                        applyInteropOptions()

                        // Initialize zoom
                        camera?.let { cam: Camera ->
                            val cameraInfo = cam.cameraInfo
                            minZoomRatio = cameraInfo.zoomState.value?.minZoomRatio ?: 1.0f
                            maxZoomRatio = cameraInfo.zoomState.value?.maxZoomRatio ?: 1.0f
                            currentZoomRatio = cameraInfo.zoomState.value?.zoomRatio ?: 1.0f

                            // Sync the lens tracking state with whatever lens we actually bound to so the first pinch
                            // on the wide lens doesn't think it needs to rebind. Default the selectedLensZoomFactor to
                            // 1.0 (the wide reference) when we can't identify the bound camera in `cachedLenses` (e.g.
                            // front-camera path).
                            val bound = cachedLenses.firstOrNull { it.cameraInfo == cameraInfo }
                            if (bound != null) {
                                selectedLensCameraInfo = bound.cameraInfo
                                selectedLensZoomFactor = bound.zoomFactor
                                selectedLensLabel = bound.label
                            } else if (selectedLensZoomFactor == null) {
                                selectedLensZoomFactor = 1.0
                            }

                            pendingZoomRatioToApply?.let { zoom ->
                                pendingZoomRatioToApply = null
                                val physical = zoom.coerceIn(
                                    minZoomRatio,
                                    cameraInfo.zoomState.value?.maxZoomRatio ?: maxZoomRatio
                                )
                                cam.cameraControl.setZoomRatio(physical)
                                currentZoomRatio = physical
                                onZoomChanged?.invoke(physical)
                            }

                            // setLens() / auto-snap stashes the effective zoom that should appear in Dart after the
                            // rebind; emit it now so the ZoomIndicator/LensPicker stay consistent across the change.
                            pendingEffectiveZoomToEmit?.let { effective ->
                                pendingEffectiveZoomToEmit = null
                                emitEvent(mapOf("type" to "zoom", "value" to effective))
                                onZoomChanged?.invoke(currentZoomRatio)
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Use case binding failed", e)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error getting camera provider", e)
                }
            }, ContextCompat.getMainExecutor(context))
        } catch (e: Exception) {
            Log.e(TAG, "Error starting camera", e)
        }
    }

    private fun buildCameraSelector(cameraProvider: ProcessCameraProvider): CameraSelector {
        // If the caller explicitly picked a lens via setLens(), honor it (back-camera only).
        if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            selectedLensCameraInfo?.let { target ->
                if (cameraProvider.availableCameraInfos.contains(target)) {
                    return CameraSelector.Builder()
                        .addCameraFilter { infos -> infos.filter { it == target } }
                        .build()
                }
            }
        }

        if (lensFacing != CameraSelector.LENS_FACING_BACK || !preferWideBackCamera) {
            return CameraSelector.Builder()
                .requireLensFacing(lensFacing)
                .build()
        }

        return selectWidestBackCamera(cameraProvider)?.let { wideCamera ->
            CameraSelector.Builder()
                .addCameraFilter { cameraInfos ->
                    cameraInfos.filter { it == wideCamera }
                }
                .build()
        } ?: CameraSelector.DEFAULT_BACK_CAMERA
    }

    private fun selectWidestBackCamera(cameraProvider: ProcessCameraProvider): CameraInfo? {
        return cameraProvider.availableCameraInfos
            .mapNotNull { cameraInfo ->
                try {
                    val camera2Info = Camera2CameraInfo.from(cameraInfo)
                    val facing = camera2Info.getCameraCharacteristic(CameraCharacteristics.LENS_FACING)
                    if (facing != CameraCharacteristics.LENS_FACING_BACK) return@mapNotNull null

                    val focalLength = camera2Info
                        .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.minOrNull() ?: return@mapNotNull null
                    cameraInfo to focalLength
                } catch (e: Exception) {
                    Log.w(TAG, "Skipping camera with unreadable metadata", e)
                    null
                }
            }
            .minByOrNull { it.second }
            ?.first
    }

    fun setLensFacing(facing: Int, preferWideBackCamera: Boolean = false) {
        lensFacing = facing
        this.preferWideBackCamera = preferWideBackCamera && facing == CameraSelector.LENS_FACING_BACK
        clearLensSelection()
        // Restart camera if already started
        if (::cameraProviderFuture.isInitialized) {
            startCamera()
        }
    }

    fun switchCamera() {
        preferWideBackCamera = false
        // Clear any sticky lens selection when the user explicitly flips cameras.
        clearLensSelection()
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        startCamera()
    }

    private fun clearLensSelection() {
        cachedLenses = emptyList()
        selectedLensCameraInfo = null
        selectedLensZoomFactor = null
        selectedLensLabel = null
        pendingEffectiveZoomToEmit = null
        pendingZoomRatioToApply = null
    }

    // endregion

    // region multi-lens / focus / capture (Dart-driven setters)

    /**
     * Enumerate physical lenses for the active camera side. Back cameras include public CameraX cameras plus Camera2
     * physical IDs from logical multi-camera devices; front cameras return their single active lens.
     *
     * On-device findings (FaunaPulse, round 49) — the result is intentionally *device-limited*, not a bug:
     *  - **Xiaomi Mi 11 Lite 5G (MIUI):** the HAL has 8 camera devices (several back logical multi-cameras with
     *    hidden physical IDs), but MIUI exposes only ONE logical back camera + one front to third-party apps via
     *    CameraX/Camera2. The ultra-wide/macro are hidden physical sub-cameras CameraX cannot bind ImageAnalysis to,
     *    so only the main wide lens is selectable (the lens-switch button is correctly disabled).
     *  - **Samsung Galaxy M12:** CameraX exposes the two bindable rear lenses (wide 1x + ultra-wide 0.5x); the macro
     *    (fixed-focus, low-res) and depth (not an imaging sensor) cameras are correctly excluded as they can't run
     *    the detector usefully.
     * We deliberately do NOT attempt privileged/unsupported access (e.g. concurrent/physical-camera binding) to reach
     * lenses the platform hides from normal apps. See cameraDiagnostics() for the per-camera report surfaced in the UI.
     *
     * Note: `CameraManager.getCameraIdList()` returns a manufacturer-curated *subset* of cameras, NOT a 1:1 map of the
     * physical glass lenses on the phone. On the Xiaomi test device the framework even logs "ignore the torch status
     * update of camera: 2..6" — those lenses exist but are not handed to third-party apps. So a phone with 3-4 visible
     * rear lenses may legitimately expose only one to this app.
     */
    fun enumerateLenses(): List<LensInfo> {
        if (cachedLenses.isNotEmpty()) return cachedLenses
        return try {
            val provider = ProcessCameraProvider.getInstance(context).get(1, TimeUnit.SECONDS)
            computeLensInfos(provider).also { cachedLenses = it }
        } catch (e: Exception) {
            Log.w(TAG, "enumerateLenses: cameraProvider unavailable", e)
            emptyList()
        }
    }

    private fun computeLensInfos(cameraProvider: ProcessCameraProvider): List<LensInfo> {
        data class Raw(val info: CameraInfo?, val focalLength: Float, val sensorWidth: Float)

        val publicInfos = cameraProvider.availableCameraInfos.mapNotNull { info ->
            try {
                val c2 = Camera2CameraInfo.from(info)
                val facing = c2.getCameraCharacteristic(CameraCharacteristics.LENS_FACING)
                val focal = c2.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.minOrNull() ?: return@mapNotNull null
                val sensor: SizeF? = c2.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                Triple(facing, c2.cameraId, Raw(info, focal, sensor?.width ?: 0f))
            } catch (e: Exception) {
                Log.w(TAG, "computeLensInfos: skipping camera with unreadable metadata", e)
                null
            }
        }

        if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            val front = publicInfos.firstOrNull { it.first == CameraCharacteristics.LENS_FACING_FRONT }
            return listOf(LensInfo(zoomFactor = 1.0, label = "Front camera", cameraInfo = front?.third?.info))
        }

        // Read physical IDs from Camera2 in addition to CameraX's public CameraInfo list. Samsung and other flagship
        // devices often expose telephoto lenses only as hidden physical cameras under a logical back camera; CameraX's
        // availableCameraInfos may therefore report ultra-wide + wide but omit telephoto.
        val publicInfoById = publicInfos.associate { it.second to it.third.info }
        val rawsById = linkedMapOf<String, Raw>()
        publicInfos
            .filter { it.first == CameraCharacteristics.LENS_FACING_BACK }
            .forEach { rawsById[it.second] = it.third }

        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        if (cameraManager != null) {
            for (id in cameraManager.cameraIdList) {
                try {
                    val chars = cameraManager.getCameraCharacteristics(id)
                    val facing = chars.get(CameraCharacteristics.LENS_FACING)
                    if (facing != CameraCharacteristics.LENS_FACING_BACK) continue
                    val physicalIds: Set<String> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        chars.physicalCameraIds
                    } else {
                        emptySet<String>()
                    }
                    val ids = physicalIds.ifEmpty { setOf(id) }
                    for (physicalId in ids) {
                        val physicalChars = if (physicalId == id) {
                            chars
                        } else {
                            cameraManager.getCameraCharacteristics(physicalId)
                        }
                        val physicalFacing = physicalChars.get(CameraCharacteristics.LENS_FACING)
                        if (physicalFacing != CameraCharacteristics.LENS_FACING_BACK) continue
                        val focal = physicalChars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                            ?.minOrNull() ?: continue
                        val sensor = physicalChars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                        rawsById[physicalId] = Raw(
                            info = publicInfoById[physicalId],
                            focalLength = focal,
                            sensorWidth = sensor?.width ?: 0f
                        )
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "computeLensInfos: skipping Camera2 id $id", e)
                }
            }
        }

        val raws = rawsById.values.toList()
        if (raws.isEmpty()) return emptyList()
        if (raws.size == 1) {
            return listOf(LensInfo(zoomFactor = 1.0, label = "Wide camera", cameraInfo = raws[0].info))
        }

        // Convert each lens's focal length to a 35mm-equivalent by scaling against the full-frame sensor width (36mm).
        // When sensor width is unavailable we fall back to a synthetic equivalent based on raw focal length × a
        // typical smartphone crop factor (~7.0). Phone lens equivalents land roughly:
        //   ultra-wide: 13-20mm   wide: 22-32mm   telephoto: 50mm+
        fun equiv(raw: Raw): Float {
            val sensorWidth = raw.sensorWidth
            return if (sensorWidth > 0f) raw.focalLength * 36f / sensorWidth
            else raw.focalLength * 7f
        }

        val withEquiv = raws.map { it to equiv(it) }
        // Identify the main (wide) lens: closest to the 26mm ideal among lenses that aren't obviously ultra-wide. If
        // every lens is ultra-wide-ish, pick the longest focal as main.
        val mainRaw = withEquiv
            .filter { (_, e) -> e >= 21f }
            .minByOrNull { (_, e) -> abs(e - 26f) }
            ?.first
            ?: withEquiv.maxByOrNull { it.second }!!.first
        val mainEquiv = equiv(mainRaw)

        val deduped = withEquiv
            .sortedBy { it.second }
            .fold(mutableListOf<Pair<Raw, Float>>()) { acc, item ->
                val previous = acc.lastOrNull()
                val sameFocal = previous != null && abs(previous.second - item.second) < 1f
                if (sameFocal) {
                    // Prefer the public CameraX camera when a logical and physical ID describe the same lens.
                    if (previous!!.first.info == null && item.first.info != null) {
                        acc[acc.lastIndex] = item
                    }
                } else {
                    acc.add(item)
                }
                acc
            }

        val logicalWideInfo = deduped
            .firstOrNull { (raw, equivMm) -> raw.info != null && abs(equivMm - mainEquiv) < 1f }
            ?.first
            ?.info
        val logicalZoomState = logicalWideInfo?.zoomState?.value
        val logicalMinZoom = logicalZoomState?.minZoomRatio ?: 1f
        val logicalMaxZoom = logicalZoomState?.maxZoomRatio ?: 1f

        return deduped.mapNotNull { (raw, equivMm) ->
            val lensInfo = when {
                abs(equivMm - mainEquiv) < 1f -> LensInfo(zoomFactor = 1.0, label = "Wide camera", cameraInfo = raw.info)
                equivMm < mainEquiv - 4f -> {
                    // Ultra-wide. iOS exposes these as 0.5x relative to the main lens.
                    val zoom = (equivMm.toDouble() / mainEquiv.toDouble()).coerceAtLeast(0.1)
                    val rounded = if (abs(zoom - 0.5) < 0.15) 0.5 else zoom
                    LensInfo(zoomFactor = rounded, label = "Ultra wide camera", cameraInfo = raw.info)
                }
                else -> {
                    val zoom = equivMm.toDouble() / mainEquiv.toDouble()
                    LensInfo(zoomFactor = zoom, label = "Telephoto camera", cameraInfo = raw.info)
                }
            }
            if (raw.info == null) {
                val zoom = lensInfo.zoomFactor.toFloat()
                if (logicalWideInfo == null || zoom < logicalMinZoom - 0.01f || zoom > logicalMaxZoom + 0.01f) {
                    return@mapNotNull null
                }
            }
            lensInfo
        }
    }

    /**
     * Switch the active back-camera lens to the one whose computed zoom factor is closest
     * to [zoomFactor]. Emits a `{type:"lens",label}` event on the existing event sink.
     */
    fun setLens(zoomFactor: Double) {
        if (lensFacing != CameraSelector.LENS_FACING_BACK) return
        val lenses = if (cachedLenses.isEmpty()) enumerateLenses() else cachedLenses
        if (lenses.isEmpty()) return
        val target = lenses.minByOrNull { abs(it.zoomFactor - zoomFactor) } ?: return
        if (target.cameraInfo == null) {
            selectLogicalBackLens(target)
            return
        }
        // After the rebind the new lens starts at physical 1.0x; that maps to effective `target.zoomFactor`
        // (e.g. 0.5x on ultra-wide, 2.0x on tele) which is exactly what the user asked for.
        pendingEffectiveZoomToEmit = target.zoomFactor
        switchToLens(target)
        emitEvent(mapOf("type" to "lens", "label" to target.label))
    }

    private fun switchToLens(target: LensInfo) {
        selectedLensCameraInfo = target.cameraInfo
        selectedLensZoomFactor = target.zoomFactor
        selectedLensLabel = target.label
        // Switching lenses always means we're staying on the back side.
        lensFacing = CameraSelector.LENS_FACING_BACK
        preferWideBackCamera = false
        // Rebind so the new CameraSelector is honored.
        startCamera()
    }

    private fun selectLogicalBackLens(target: LensInfo) {
        lensFacing = CameraSelector.LENS_FACING_BACK
        preferWideBackCamera = false
        val logicalWide = cachedLenses
            .filter { it.cameraInfo != null }
            .minByOrNull { abs(it.zoomFactor - 1.0) }
            ?: return
        val logicalWideCameraInfo = logicalWide.cameraInfo ?: return

        val targetPhysicalZoom = target.zoomFactor.toFloat()
        val logicalZoomState = logicalWideCameraInfo.zoomState.value
        val logicalMinZoom = logicalZoomState?.minZoomRatio ?: 1f
        val logicalMaxZoom = logicalZoomState?.maxZoomRatio ?: maxZoomRatio
        if (targetPhysicalZoom < logicalMinZoom - 0.01f || targetPhysicalZoom > logicalMaxZoom + 0.01f) {
            Log.w(TAG, "Hidden lens ${target.label} is not reachable through logical camera zoom")
            return
        }

        selectedLensCameraInfo = logicalWideCameraInfo
        selectedLensZoomFactor = 1.0
        selectedLensLabel = target.label

        if (camera?.cameraInfo != logicalWideCameraInfo) {
            pendingZoomRatioToApply = targetPhysicalZoom
            pendingEffectiveZoomToEmit = target.zoomFactor
            switchToLens(logicalWide)
            selectedLensLabel = target.label
            emitEvent(mapOf("type" to "lens", "label" to target.label))
            return
        }

        val physical = targetPhysicalZoom.coerceIn(
            minZoomRatio,
            camera?.cameraInfo?.zoomState?.value?.maxZoomRatio ?: maxZoomRatio
        )
        camera?.cameraControl?.setZoomRatio(physical)
        currentZoomRatio = physical
        onZoomChanged?.invoke(physical)
        emitEvent(mapOf("type" to "zoom", "value" to physical.toDouble()))
        emitEvent(mapOf("type" to "lens", "label" to target.label))
    }

    /**
     * Tap-to-focus. [x] and [y] are normalized view-relative coordinates in 0..1. Builds a FocusMeteringAction via the
     * PreviewView's MeteringPointFactory and triggers AF/AE. Emits `{type:"focus",x,y}` when the future completes
     * successfully so the Dart `FocusReticle` can animate.
     */
    fun tapToFocus(x: Double, y: Double) {
        val cam = camera ?: return
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val nx = x.toFloat().coerceIn(0f, 1f)
        val ny = y.toFloat().coerceIn(0f, 1f)
        try {
            val factory = previewView.meteringPointFactory
            val point = factory.createPoint(nx * w, ny * h)
            val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
                .setAutoCancelDuration(3, TimeUnit.SECONDS)
                .build()
            val future = cam.cameraControl.startFocusAndMetering(action)
            future.addListener({
                try {
                    val result = future.get()
                    if (result.isFocusSuccessful) {
                        post {
                            emitEvent(mapOf("type" to "focus", "x" to nx.toDouble(), "y" to ny.toDouble()))
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "tapToFocus: focus future failed", e)
                }
            }, ContextCompat.getMainExecutor(context))
        } catch (e: Exception) {
            Log.e(TAG, "tapToFocus failed", e)
        }
    }

    /**
     * The 4:3 analysis-stream sizes the active camera actually supports, as "WxH"
     * strings (largest first), read from the camera HAL. The settings dropdown
     * uses these so only realistic resolutions are offered. Empty if unavailable.
     */
    fun supportedStreamResolutions(): List<String> {
        val cam = camera ?: return emptyList()
        return try {
            val map = Camera2CameraInfo.from(cam.cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: return emptyList()
            val sizes = map.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
                ?: return emptyList()
            sizes
                .filter { it.width > 0 && it.height > 0 }
                // Keep ~4:3 to match the app's square-ROI cropping math.
                .filter { kotlin.math.abs(it.width.toDouble() / it.height - 4.0 / 3.0) < 0.05 }
                // getOutputSizes(YUV) also lists big *still* sizes (e.g. 4000x3000)
                // the HAL won't stream for real-time analysis (CameraX caps
                // ImageAnalysis around 1080p/2MP). Keep only realistically
                // streamable sizes so the menu isn't misleading.
                .filter { it.width.toLong() * it.height <= 2_100_000L }
                .distinctBy { "${it.width}x${it.height}" }
                .sortedByDescending { it.width.toLong() * it.height }
                .map { "${it.width}x${it.height}" }
        } catch (e: Exception) {
            Log.w(TAG, "supportedStreamResolutions failed", e)
            emptyList()
        }
    }

    /**
     * The realistic ceiling for the **live analysis stream** on the currently bound camera (FaunaPulse).
     *
     * Why this exists: `supportedStreamResolutions()` lists sizes from `getOutputSizes(YUV)`, but those are the sizes
     * the camera's *still/preview* path can produce — NOT necessarily what CameraX `ImageAnalysis` can actually stream.
     * When Preview + ImageAnalysis + ImageCapture are bound together (as this app does), CameraX bounds the analysis
     * stream to roughly the device's "PREVIEW" size: the smaller of 1080p and the screen resolution. So a phone whose
     * screen is ~720 px wide typically caps the analysis stream near 960x720 even though `getOutputSizes` advertises
     * 1440x1080 — which is exactly why a 1080x1440 request can come back as 720x960 on a budget device.
     *
     * This returns an *estimate* of that ceiling plus the camera's hardware level, so the UI can stop offering sizes
     * the pipeline will silently shrink. It is an estimate: the *authoritative* delivered size is whatever the live
     * "Stream: WxH" readout shows once the camera is bound — the two together are the honest picture.
     *
     * Keys: `hardwareLevel` (legacy/limited/full/level3/external/unknown), `recommendedMax` ("WxH" or ""),
     * `previewBoundW`/`previewBoundH` (the chosen size, 0 if unknown), `displayW`/`displayH`. Android only.
     */
    fun analysisStreamCeiling(): Map<String, Any?> {
        fun unknown(): Map<String, Any?> = mapOf(
            "hardwareLevel" to "unknown", "recommendedMax" to "",
            "previewBoundW" to 0, "previewBoundH" to 0, "displayW" to 0, "displayH" to 0
        )
        val cam = camera ?: return unknown()
        return try {
            val info = Camera2CameraInfo.from(cam.cameraInfo)
            val hwLevel = when (info.getCameraCharacteristic(
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
                CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level3"
                4 -> "external" // INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL (constant is API 28+)
                else -> "unknown"
            }
            // CameraX bounds ImageAnalysis to ~the PREVIEW size = min(1080p area, display area).
            val dm = context.resources.displayMetrics
            val displayArea = dm.widthPixels.toLong() * dm.heightPixels
            val previewBoundArea =
                min(1920L * 1080L, if (displayArea > 0) displayArea else 1920L * 1080L)
            val best = info.getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
                ?.filter { it.width > 0 && it.height > 0 }
                ?.filter { abs(it.width.toDouble() / it.height - 4.0 / 3.0) < 0.05 }
                ?.filter { it.width.toLong() * it.height <= 2_100_000L }
                ?.filter { it.width.toLong() * it.height <= previewBoundArea }
                ?.maxByOrNull { it.width.toLong() * it.height }
            mapOf(
                "hardwareLevel" to hwLevel,
                "recommendedMax" to (best?.let { "${it.width}x${it.height}" } ?: ""),
                "previewBoundW" to (best?.width ?: 0),
                "previewBoundH" to (best?.height ?: 0),
                "displayW" to dm.widthPixels,
                "displayH" to dm.heightPixels
            )
        } catch (e: Exception) {
            Log.w(TAG, "analysisStreamCeiling failed", e)
            unknown()
        }
    }

    /**
     * Full per-camera diagnostics for the "which lenses can this app actually use?" dialog (FaunaPulse).
     *
     * Walks every camera the OS reports (`CameraManager.cameraIdList`) and, for logical multi-camera devices, every
     * hidden physical sub-camera under each one (`physicalCameraIds`). For each it reports the lens facing, focal
     * length(s), an estimated 35mm-equivalent focal length, a coarse lens type, whether it is a logical or a
     * physical-only camera, and — the key field for this app — whether it is **usable for inference**.
     *
     * "Usable for inference" means the camera has a public CameraX `CameraInfo` (it appears in
     * `availableCameraInfos`), so an `ImageAnalysis` use case can be bound to it and our detector can read its frames.
     * A telephoto exposed only as a hidden *physical* sub-camera of a logical camera CANNOT be bound directly by
     * CameraX 1.x; it is reachable only as digital zoom through the wide camera, which the `reason` field explains.
     *
     * Returns one map per camera/lens. Empty on devices/SDKs where enumeration fails. Android only.
     */
    fun cameraDiagnostics(): List<Map<String, Any>> {
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return emptyList()

        // Camera IDs CameraX can independently bind (and therefore run inference on).
        val bindableIds: Set<String> = try {
            ProcessCameraProvider.getInstance(context).get(1, TimeUnit.SECONDS)
                .availableCameraInfos
                .mapNotNull {
                    try {
                        Camera2CameraInfo.from(it).cameraId
                    } catch (e: Exception) {
                        null
                    }
                }
                .toSet()
        } catch (e: Exception) {
            Log.w(TAG, "cameraDiagnostics: cameraProvider unavailable", e)
            emptySet()
        }

        fun facingLabel(facing: Int?): String = when (facing) {
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }

        // 35mm-equivalent focal length: scale the lens focal length against the sensor's physical width (full frame is
        // 36mm wide). Falls back to a typical smartphone crop factor (~7x) when the sensor size isn't reported.
        fun equiv35(focalMm: Float, sensorWidthMm: Float): Double =
            if (sensorWidthMm > 0f) (focalMm * 36f / sensorWidthMm).toDouble()
            else (focalMm * 7f).toDouble()

        fun lensTypeFor(equivMm: Double): String = when {
            equivMm <= 0.0 -> "unknown"
            equivMm < 21.0 -> "Ultra wide"
            equivMm <= 45.0 -> "Wide"
            else -> "Telephoto"
        }

        // 4:3, realistically-streamable (≤ ~2MP) analysis sizes for one camera's characteristics, "WxH", largest first.
        fun analysisSizesFor(chars: CameraCharacteristics): List<String> = try {
            chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888)
                ?.asList()
                ?.filter { it.width > 0 && it.height > 0 }
                ?.filter { abs(it.width.toDouble() / it.height - 4.0 / 3.0) < 0.05 }
                ?.filter { it.width.toLong() * it.height <= 2_100_000L }
                ?.distinctBy { "${it.width}x${it.height}" }
                ?.sortedByDescending { it.width.toLong() * it.height }
                ?.map { "${it.width}x${it.height}" }
                ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }

        fun describe(
            id: String,
            chars: CameraCharacteristics,
            physicalOnly: Boolean,
            parentId: String?
        ): Map<String, Any>? {
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            val focals = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?.map { it.toDouble() } ?: emptyList()
            val sensorWidth = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)?.width ?: 0f
            val minFocal = focals.minOrNull()?.toFloat() ?: 0f
            val equiv = if (minFocal > 0f) equiv35(minFocal, sensorWidth) else 0.0
            // A camera is usable for our detector only if CameraX exposes it as a bindable CameraInfo.
            val usable = !physicalOnly && bindableIds.contains(id)
            val reason = when {
                usable -> "Bindable as a CameraX camera, so ImageAnalysis frames can be fed to the detector."
                physicalOnly -> "Hidden physical sub-camera of logical camera ${parentId ?: "?"}. CameraX cannot " +
                    "bind ImageAnalysis to it directly — it is reachable only as digital zoom through the wide camera."
                else -> "Reported by the OS but not exposed by CameraX as a bindable camera on this device."
            }
            return mapOf(
                "cameraId" to id,
                "lensFacing" to facingLabel(facing),
                "focalLengthsMm" to focals,
                "equiv35mm" to equiv,
                "lensType" to lensTypeFor(equiv),
                "isLogical" to (!physicalOnly),
                "isPhysicalOnly" to physicalOnly,
                "parentCameraId" to (parentId ?: ""),
                "usableForInference" to usable,
                "reason" to reason,
                "analysisSizes" to analysisSizesFor(chars)
            )
        }

        val out = mutableListOf<Map<String, Any>>()
        val topLevelIds = try {
            cameraManager.cameraIdList.toList()
        } catch (e: Exception) {
            Log.w(TAG, "cameraDiagnostics: cameraIdList failed", e)
            return emptyList()
        }
        for (id in topLevelIds) {
            try {
                val chars = cameraManager.getCameraCharacteristics(id)
                describe(id, chars, physicalOnly = false, parentId = null)?.let { out.add(it) }

                // List hidden physical sub-cameras that aren't themselves top-level ids (so we don't double-report).
                val physicalIds: Set<String> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    chars.physicalCameraIds
                } else {
                    emptySet()
                }
                for (physId in physicalIds) {
                    if (physId == id || topLevelIds.contains(physId)) continue
                    try {
                        val physChars = cameraManager.getCameraCharacteristics(physId)
                        describe(physId, physChars, physicalOnly = true, parentId = id)?.let { out.add(it) }
                    } catch (e: Exception) {
                        Log.w(TAG, "cameraDiagnostics: skipping physical id $physId", e)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "cameraDiagnostics: skipping camera id $id", e)
            }
        }
        return out
    }

    /**
     * Largest focus distance the lens accepts, in dioptres (1/metres). This is the value that means "focus as close as
     * the lens physically can"; 0.0 always means "focus at infinity". Returned so the Dart side can map a 0..1 slider
     * onto the real range. 0 if the device doesn't report it (then manual focus isn't meaningful).
     */
    fun minimumFocusDistanceDioptres(): Float {
        val cam = camera ?: return 0f
        return try {
            Camera2CameraInfo.from(cam.cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        } catch (e: Exception) {
            Log.w(TAG, "minimumFocusDistanceDioptres failed", e)
            0f
        }
    }

    /**
     * Manual focus. [normalized] is 0..1 where 0 = focus at infinity (far) and 1 = closest the lens can focus (near).
     * Turns autofocus OFF and pins the lens at the requested distance, so the user can lock focus on the flower inside
     * the ROI rather than letting the camera hunt. Mapped onto the device's real dioptre range via
     * [minimumFocusDistanceDioptres]. Has no effect on a fixed-focus camera (minimum distance 0).
     */
    fun setManualFocus(normalized: Double) {
        val cam = camera ?: return
        val maxDioptres = minimumFocusDistanceDioptres()
        if (maxDioptres <= 0f) {
            Log.w(TAG, "setManualFocus: device reports no manual-focus range (fixed-focus lens?)")
            return
        }
        val n = normalized.toFloat().coerceIn(0f, 1f)
        interopAfMode = CaptureRequest.CONTROL_AF_MODE_OFF
        interopFocusDioptres = n * maxDioptres
        applyInteropOptions()
    }

    /**
     * Hand focus back to continuous autofocus (undoes [setManualFocus]). Clears the manual capture-request overrides so
     * the camera resumes its normal auto behaviour.
     */
    fun setAutoFocus() {
        interopAfMode = CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
        interopFocusDioptres = null
        applyInteropOptions()
    }

    /**
     * Caps the CAMERA's own frame rate (FaunaPulse, round 82). This is different from
     * the inference FPS cap: that one only decides which of the delivered frames the detector
     * looks at, while the sensor + image processor still capture and process ~30 frames every
     * second regardless — a large standing heat cost the motion gate cannot remove. This asks
     * the camera hardware itself to run slower (Camera2 AE target FPS range), so every stage
     * downstream (ISP, preview, ZSL still ring buffer, analysis delivery) does proportionally
     * less work. [maxFps] <= 0 restores the device default. The HAL only accepts ranges it
     * advertises; [chooseAeFpsRange] picks the closest legal one and the choice is logged.
     * Survives lens-switch rebinds (re-applied after every successful bind).
     */
    fun setCameraFpsCap(maxFps: Int) {
        requestedCameraFpsCap = maxFps
        applyInteropOptions()
    }

    /**
     * Picks the AE target FPS range closest to the requested cap among the ranges this camera
     * actually supports. Prefers the highest upper bound that stays <= [cap] (the strongest
     * legal cap not exceeding the wish); when none exists, the smallest upper bound available.
     * Ties prefer a narrower range (fixed rate = steadier, and AE can't speed back up).
     */
    private fun chooseAeFpsRange(cap: Int): android.util.Range<Int>? {
        val cam = camera ?: return null
        if (cap <= 0) return null
        val available: Array<android.util.Range<Int>> = try {
            Camera2CameraInfo.from(cam.cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?: return null
        } catch (e: Exception) {
            Log.w(TAG, "chooseAeFpsRange: cannot read supported ranges", e)
            return null
        }
        if (available.isEmpty()) return null
        val within = available.filter { it.upper <= cap }
        val pool = if (within.isNotEmpty()) within else available.toList()
        val bestUpper = if (within.isNotEmpty()) pool.maxOf { it.upper } else pool.minOf { it.upper }
        return pool.filter { it.upper == bestUpper }.maxByOrNull { it.lower }
    }

    /**
     * The ONE place Camera2 interop options are written (see the field comments): rebuilds the
     * full option set (focus + AE fps range) and applies it atomically. Safe to call before the
     * camera is bound (it just returns; the bind path calls it again once `camera` is set).
     */
    private fun applyInteropOptions() {
        val cam = camera ?: return
        val builder = CaptureRequestOptions.Builder()
        interopAfMode?.let { mode ->
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, mode)
            if (mode == CaptureRequest.CONTROL_AF_MODE_OFF) {
                interopFocusDioptres?.let {
                    builder.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, it)
                }
            }
        }
        val range = chooseAeFpsRange(requestedCameraFpsCap)
        if (range != null) {
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, range)
        }
        if (range != appliedFpsRange) {
            Log.i(TAG, "Camera fps cap: requested=$requestedCameraFpsCap applied=${range ?: "device default"}")
            appliedFpsRange = range
        }
        try {
            Camera2CameraControl.from(cam.cameraControl).setCaptureRequestOptions(builder.build())
        } catch (e: Exception) {
            Log.e(TAG, "applyInteropOptions failed", e)
        }
    }

    /**
     * Attaches/detaches ONLY the live preview use case (FaunaPulse, round 82). The
     * analysis stream (detector, motion gate) and the still-capture use case stay bound, so a
     * recording continues untouched. Used by the app's power-save mode: a black cover alone
     * does NOT stop the preview pipeline — the camera keeps producing and compositing preview
     * frames nobody can see. Detaching the use case does. Reattaching triggers a short (~0.2 s)
     * camera reconfiguration, then re-asserts the interop options (focus lock, fps cap).
     */
    fun setPreviewEnabled(enabled: Boolean) {
        previewEnabled = enabled
        val provider = boundCameraProvider ?: return
        val preview = previewUseCase ?: return
        val owner = lifecycleOwner ?: return
        val selector = boundCameraSelector ?: return
        try {
            if (!enabled) {
                if (provider.isBound(preview)) provider.unbind(preview)
                Log.i(TAG, "Preview use case detached (power save)")
            } else if (!provider.isBound(preview)) {
                camera = provider.bindToLifecycle(owner, selector, preview)
                preview.setSurfaceProvider(previewView.surfaceProvider)
                // The repeating request was rebuilt for the new session config; re-assert the
                // manual focus / fps cap so waking the screen can never unlock the focus.
                applyInteropOptions()
                Log.i(TAG, "Preview use case reattached")
            }
        } catch (e: Exception) {
            Log.e(TAG, "setPreviewEnabled($enabled) failed", e)
        }
    }

    /**
     * Capture a still photo. Preferred path uses the bound ImageCapture use-case so we get a full-resolution JPEG; if
     * [withOverlays] is true the current overlay bitmap is composited on top of the still before re-encoding. If
     * ImageCapture binding isn't available (e.g. three-use-case bind failed), falls back to [captureFrame] which
     * snapshots the preview + overlay composite. The heavy JPEG processing runs on [stillExecutor] (round 63); the
     * callback is always invoked on the main thread.
     */
    fun capturePhoto(withOverlays: Boolean = true, callback: (ByteArray?) -> Unit) {
        val mainExec = ContextCompat.getMainExecutor(context)
        takeRawStill(
            onJpeg = { jpegBytes, rotationDegrees, isFront, _, _, _ ->
                // Runs on stillExecutor: the full-frame decode/rotate/re-encode
                // stays off the main thread (round-63 lag fix). Rotation +
                // front-camera mirroring are baked into the pixels so consumers
                // (crop, gallery) see an upright image regardless of EXIF
                // support — without this every portrait share ends up sideways.
                val processed = try {
                    if (!withOverlays) {
                        normalizeJpegOrientation(jpegBytes, rotationDegrees, isFront) ?: jpegBytes
                    } else {
                        // Composite the current overlay bitmap on top of the still.
                        compositeOverlayOnJpeg(jpegBytes, rotationDegrees, isFront) ?: jpegBytes
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "capturePhoto: error processing capture", e)
                    null
                }
                if (processed != null) {
                    mainExec.execute { callback(processed) }
                } else {
                    // captureFrame touches views — main thread only.
                    mainExec.execute { callback(captureFrame(withOverlays)) }
                }
            },
            onFail = { callback(captureFrame(withOverlays)) },
        )
    }

    /**
     * Round 63 (FaunaPulse): the still exactly as the camera delivered it — NOT rotated upright — plus the
     * info needed to interpret it ("bytes", "rotationDegrees" = clockwise rotation that would make it upright,
     * "isFront"). Skips normalizeJpegOrientation's full-frame decode/rotate/re-encode (~1.5 s per 12 MP photo);
     * the app's ROI crop maps its rectangle into raw coordinates and rotates only the small square. The callback is
     * always invoked on the main thread; null on failure (no captureFrame fallback — the caller decides).
     */
    fun capturePhotoRaw(callback: (Map<String, Any?>?) -> Unit) {
        val mainExec = ContextCompat.getMainExecutor(context)
        takeRawStill(
            onJpeg = { bytes, rotationDegrees, isFront, contentLagMs, callbackLagMs, contentAtEpochMs ->
                mainExec.execute {
                    callback(
                        mapOf(
                            "bytes" to bytes,
                            "rotationDegrees" to rotationDegrees,
                            "isFront" to isFront,
                            // Round 108: how old the frame CONTENT is vs the
                            // request (negative = ZSL served a past frame) and
                            // the plain shutter-to-bytes wait. Logged per photo.
                            "contentLagMs" to contentLagMs,
                            "callbackLagMs" to callbackLagMs,
                            // Round 114: the content's sensor-exposure moment
                            // as EPOCH ms — lets logged detection boxes be
                            // time-matched to this photo. Null on odd HALs.
                            "contentAtEpochMs" to contentAtEpochMs,
                        )
                    )
                }
            },
            onFail = { callback(null) },
        )
    }

    /**
     * Round 114 (FaunaPulse): maps a CameraX sensor timestamp (elapsedRealtime
     * nanos on compliant HALs) to epoch milliseconds via the current clock
     * pair. Both clocks are read HERE (callback/emit time), so a wall-clock
     * jump earlier in the session cannot skew the mapping — only a jump within
     * the sub-second capture window could, which is negligible. Returns null
     * when the result is implausible (> 10 s from now): that guards HALs whose
     * SENSOR_INFO_TIMESTAMP_SOURCE is UNKNOWN (arbitrary base), where the
     * mapping would be meaningless.
     */
    private fun sensorNanosToEpochMs(sensorNanos: Long): Double? {
        val mapped = System.currentTimeMillis() -
            (SystemClock.elapsedRealtimeNanos() - sensorNanos) / 1e6
        return if (kotlin.math.abs(System.currentTimeMillis() - mapped) < 10_000) mapped else null
    }

    /**
     * Shared still-capture plumbing: grabs a JPEG from the bound ImageCapture use-case and hands it to [onJpeg] ON
     * [stillExecutor], together with the clockwise rotation that would make it upright and the front-camera flag.
     * [onFail] runs on the MAIN thread when ImageCapture is unbound (three-use-case bind failed at startup) or the
     * capture/extraction fails — so callers can fall back to view-touching snapshots directly.
     */
    private fun takeRawStill(
        onJpeg: (bytes: ByteArray, rotationDegrees: Int, isFront: Boolean, contentLagMs: Double?, callbackLagMs: Double?, contentAtEpochMs: Double?) -> Unit,
        onFail: () -> Unit,
    ) {
        val ic = imageCaptureUseCase
        val mainExec = ContextCompat.getMainExecutor(context)
        if (ic == null) {
            mainExec.execute(onFail)
            return
        }
        // Round 108 (FaunaPulse): measure how OLD the delivered frame's content
        // is relative to the takePicture() call. ImageInfo.timestamp is the
        // sensor timestamp on the elapsedRealtime clock (on compliant HALs), so
        // contentLagMs NEGATIVE = the frame predates the request = zero-shutter
        // -lag is actually serving from its ring buffer; a large positive value
        // = the "still lands after the detection" lag is real frame-content lag
        // (fast insects will have left the box). callbackLagMs is the plain
        // shutter-to-bytes wait.
        val t0Nanos = SystemClock.elapsedRealtimeNanos()
        try {
            ic.takePicture(
                stillCallbackExecutor,
                object : ImageCapture.OnImageCapturedCallback() {
                    override fun onCaptureSuccess(image: ImageProxy) {
                        try {
                            val rotationDegrees = image.imageInfo.rotationDegrees
                            val isFront = lensFacing == CameraSelector.LENS_FACING_FRONT
                            val contentLagMs = try {
                                (image.imageInfo.timestamp - t0Nanos) / 1e6
                            } catch (e: Exception) {
                                null
                            }
                            val callbackLagMs =
                                (SystemClock.elapsedRealtimeNanos() - t0Nanos) / 1e6
                            // Round 114: the content's sensor-exposure moment on
                            // the EPOCH clock, directly comparable to the frame
                            // timestamps the app logs. Null on odd HALs.
                            val contentAtEpochMs = try {
                                sensorNanosToEpochMs(image.imageInfo.timestamp)
                            } catch (e: Exception) {
                                null
                            }
                            val jpegBytes = imageProxyToJpegBytes(image)
                            if (jpegBytes == null) {
                                mainExec.execute(onFail)
                            } else {
                                onJpeg(jpegBytes, rotationDegrees, isFront, contentLagMs, callbackLagMs, contentAtEpochMs)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "takeRawStill: error extracting still", e)
                            mainExec.execute(onFail)
                        } finally {
                            image.close()
                        }
                    }

                    override fun onError(exception: ImageCaptureException) {
                        Log.w(TAG, "takeRawStill: ImageCapture failed", exception)
                        mainExec.execute(onFail)
                    }
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "takeRawStill: takePicture threw", e)
            mainExec.execute(onFail)
        }
    }

    private fun imageProxyToJpegBytes(image: ImageProxy): ByteArray? {
        return try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            // ImageCapture (JPEG format) hands us a JPEG buffer directly.
            if (image.format == ImageFormat.JPEG || image.format == 256 /* JPEG */) {
                bytes
            } else {
                // Fallback: convert via Bitmap (rare path).
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
                try {
                    val out = java.io.ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, out)
                    out.toByteArray()
                } finally {
                    bmp.recycle()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "imageProxyToJpegBytes failed", e)
            null
        }
    }

    private fun compositeOverlayOnJpeg(jpegBytes: ByteArray, rotationDegrees: Int, isFront: Boolean): ByteArray? {
        return try {
            val decoded = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size) ?: return null
            // Apply the capture orientation (and mirror for the front camera) BEFORE compositing — the overlay is
            // drawn in display coordinates, so the still bitmap has to be in the same upright orientation or boxes land
            // at the wrong positions and the shared JPEG ends up sideways.
            val still = applyOrientation(decoded, rotationDegrees, isFront)
            if (still !== decoded) decoded.recycle()
            // Render overlay onto a bitmap sized to match the upright still.
            val composite = Bitmap.createBitmap(still.width, still.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(composite)
            canvas.drawBitmap(still, 0f, 0f, null)
            // Capture the overlay at its current view size and scale it to the still.
            val overlayBitmap = Bitmap.createBitmap(
                overlayView.width.coerceAtLeast(1),
                overlayView.height.coerceAtLeast(1),
                Bitmap.Config.ARGB_8888,
            )
            overlayView.draw(Canvas(overlayBitmap))
            val matrix = Matrix().apply {
                setScale(still.width.toFloat() / overlayBitmap.width, still.height.toFloat() / overlayBitmap.height)
            }
            canvas.drawBitmap(overlayBitmap, matrix, null)
            val out = java.io.ByteArrayOutputStream()
            composite.compress(Bitmap.CompressFormat.JPEG, 90, out)
            still.recycle()
            overlayBitmap.recycle()
            composite.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.e(TAG, "compositeOverlayOnJpeg failed", e)
            null
        }
    }

    /** Decode + rotate/mirror a JPEG to the display-correct orientation, then re-encode. */
    private fun normalizeJpegOrientation(jpegBytes: ByteArray, rotationDegrees: Int, isFront: Boolean): ByteArray? {
        if (rotationDegrees == 0 && !isFront) return jpegBytes
        return try {
            val decoded = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size) ?: return null
            val oriented = applyOrientation(decoded, rotationDegrees, isFront)
            if (oriented === decoded) {
                jpegBytes
            } else {
                val out = java.io.ByteArrayOutputStream()
                oriented.compress(Bitmap.CompressFormat.JPEG, 90, out)
                decoded.recycle()
                oriented.recycle()
                out.toByteArray()
            }
        } catch (e: Exception) {
            Log.e(TAG, "normalizeJpegOrientation failed", e)
            null
        }
    }

    /** Rotate `bitmap` clockwise by `rotationDegrees`, mirroring horizontally when `isFront` is true. */
    private fun applyOrientation(bitmap: Bitmap, rotationDegrees: Int, isFront: Boolean): Bitmap {
        if (rotationDegrees == 0 && !isFront) return bitmap
        val matrix = Matrix().apply {
            if (rotationDegrees != 0) postRotate(rotationDegrees.toFloat())
            if (isFront) postScale(-1f, 1f)
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    // endregion
    
    // Lifecycle methods from DefaultLifecycleObserver
    override fun onStart(owner: LifecycleOwner) {
        if (allPermissionsGranted()) {
            // Restart the camera on start if it was stopped by a lifecycle event (e.g. navigating back), but NOT if the
            // Dart layer intentionally paused it — that pause must hold until an explicit resume.
            if (!intentionallyPaused && (isStopped || camera == null)) {
                startCamera()
            }
        }
    }

    override fun onResume(owner: LifecycleOwner) {
        if (allPermissionsGranted()) {
            // Double-check camera is running on resume, unless the Dart layer intentionally paused it.
            if (!intentionallyPaused && (isStopped || camera == null)) {
                startCamera()
            }
        }
    }

    override fun onStop(owner: LifecycleOwner) {
        // Camera will be automatically stopped by CameraX when lifecycle stops
    }

    // region onFrame (per frame inference)

    // Frame-pipeline timing counters (diagnostic): how many analysis frames the
    // camera delivers per second, how many we actually run inference on, and how
    // long the YUV->RGB bitmap conversion takes. Logged once a second.
    private var perfWindowStartNs = 0L
    private var perfFramesIn = 0
    private var perfInferred = 0
    private var perfToBitmapNs = 0L
    // Frames that actually paid the RGBA->Bitmap conversion this window. Since
    // the FPS-cap drop moved BEFORE the conversion (perf review A1) this is a
    // subset of perfFramesIn, and the toBitmapMs average must divide by it.
    private var perfConverted = 0
    // Latest camera analysis delivery rate (frames/sec the sensor feeds us),
    // surfaced to Flutter so the UI can show it next to the detector rate.
    private var lastDeliveredFps = 0.0

    // Latest analysis frame + its orientation, for cropping ROI photos straight
    // from the live stream (no full-res still capture → no camera stall).
    // Reused per-frame conversion buffer (perf review A3): one Bitmap gets overwritten
    // each frame instead of allocating a fresh multi-MB one 10-30x per second. Only
    // ever touched from the camera analyzer thread.
    private val frameBitmapBuffer = ImageUtils.BitmapFrameBuffer()

    @Volatile private var lastFrameBitmap: Bitmap? = null
    @Volatile private var lastFrameRotationDegrees: Int = 0
    @Volatile private var lastFrameIsFront: Boolean = false
    @Volatile private var lastFrameIsLandscape: Boolean = false

    /** Crops the given ROI from the most recent analysis frame and returns it as
     *  a JPEG. Fast (no `takePicture`), at the analysis-frame resolution. A
     *  [maxPx] > 0 downscales (never enlarges) larger crops to that side before
     *  encoding. Returns null if no frame is available yet. */
    fun captureRoiFromFrame(
        cx: Double,
        cy: Double,
        side: Double,
        quality: Int,
        maxPx: Int = 0,
    ): ByteArray? {
        val bmp = lastFrameBitmap ?: return null
        return ImageUtils.cropRoiFromFrame(
            bitmap = bmp,
            rotateForCamera = true,
            isLandscape = lastFrameIsLandscape,
            isFrontCamera = lastFrameIsFront,
            rotationDegrees = lastFrameRotationDegrees,
            roiCx = cx.toFloat(),
            roiCy = cy.toFloat(),
            roiSide = side.toFloat(),
            quality = quality,
            maxPx = maxPx,
        )
    }

    /** Round 154 (perf review D1): as [captureRoiFromFrame], but off the main
     *  thread. The crop + JPEG encode cost ~10-50 ms (stream-size dependent),
     *  and the platform thread that used to run them also delivers detection
     *  results to Flutter, so every photo stalled box delivery by that much.
     *  The work runs on [stillExecutor] (round-63 rationale; single-threaded,
     *  so crops stay serialized behind any in-flight still job) and [callback]
     *  is always invoked on the main thread; null on failure. Safe off-thread:
     *  [captureRoiFromFrame] reads only volatile frame state, and
     *  ImageUtils.cropRoiFromFrame synchronizes its source draw on the shared
     *  frame bitmap. */
    fun captureRoiFromFrameAsync(
        cx: Double,
        cy: Double,
        side: Double,
        quality: Int,
        maxPx: Int = 0,
        callback: (ByteArray?) -> Unit,
    ) {
        val mainExec = ContextCompat.getMainExecutor(context)
        stillExecutor.execute {
            val bytes = try {
                captureRoiFromFrame(cx, cy, side, quality, maxPx)
            } catch (e: Throwable) {
                Log.w(TAG, "ROI frame crop failed off-thread: ${e.message}")
                null
            }
            mainExec.execute { callback(bytes) }
        }
    }

    private fun onFrame(imageProxy: ImageProxy) {
        // Early return if view is stopped to prevent accessing closed resources
        if (isStopped) {
            imageProxy.close()
            return
        }

        // Round 63 (cooler idle): while the motion gate keeps the detector
        // asleep, sample only ~5 frames/s for the motion check and drop the
        // rest BEFORE the (expensive) bitmap conversion. An arriving insect is
        // still noticed within ~0.2 s; once motion wakes the gate, every frame
        // flows again. Note: the delivered-FPS readout intentionally reflects
        // this (~5 while idle) — it reports frames the pipeline actually uses.
        if (motionGateEnabled && System.nanoTime() > gateAwakeUntilNs) {
            val nowIdle = System.nanoTime()
            if (nowIdle - lastGateSampleNs < gateIdleSampleNs) {
                imageProxy.close()
                return
            }
            lastGateSampleNs = nowIdle
        }

        // Time-lapse mode: same pre-conversion drop, but rate-controlled by
        // Dart (raised during a burst so fast crops stay fresh, ~1 fps
        // between bursts). No gate, no inference — see the branch below.
        if (timeLapseMode) {
            val nowTl = System.nanoTime()
            if (nowTl - lastTimeLapseSampleNs < timeLapseSampleNs) {
                imageProxy.close()
                return
            }
            lastTimeLapseSampleNs = nowTl
        }

        perfFramesIn++

        val w = imageProxy.width
        val h = imageProxy.height

        // Emit a per-second summary of the camera->inference pipeline. Runs
        // BEFORE any frame drop below so deliveredFps keeps meaning "frames
        // CameraX handed the analyzer" (the Dart watchdog and the session FPS
        // graphs rely on that meaning) even now that capped frames are dropped
        // before conversion.
        val nowNs = System.nanoTime()
        if (perfWindowStartNs == 0L) perfWindowStartNs = nowNs
        val elapsed = nowNs - perfWindowStartNs
        if (elapsed >= 1_000_000_000L) {
            val secs = elapsed / 1e9
            val avgToBitmap = if (perfConverted > 0) perfToBitmapNs / perfConverted / 1e6 else 0.0
            lastDeliveredFps = perfFramesIn / secs
            Log.i(
                TAG,
                "FRAMEPERF deliveredFps=${"%.1f".format(lastDeliveredFps)} " +
                    "convertedFps=${"%.1f".format(perfConverted / secs)} " +
                    "inferredFps=${"%.1f".format(perfInferred / secs)} " +
                    "toBitmapMs=${"%.1f".format(avgToBitmap)} format=${imageProxy.format} ${w}x$h"
            )
            perfWindowStartNs = nowNs
            perfFramesIn = 0
            perfConverted = 0
            perfInferred = 0
            perfToBitmapNs = 0L
        }

        // Perf review A1: when the motion gate is OFF, a frame the inference
        // FPS cap will drop can do no useful work at all — so drop it BEFORE
        // paying the RGBA->Bitmap conversion (a full image copy; with a 10/s
        // cap on a 30 fps camera two thirds of conversions were pure heat).
        // When the gate is ON every frame must still be converted, because the
        // gate's background model has to keep seeing frames even while the cap
        // skips inference; the cap then applies at its original spot below.
        // shouldRunInference() is stateful (advances the cap clock), so
        // remember its verdict instead of asking twice per frame.
        var inferenceApproved = false
        if (!motionGateEnabled) {
            if (!shouldRunInference()) {
                imageProxy.close()
                return
            }
            inferenceApproved = true
        }

        val tb0 = System.nanoTime()
        val bitmap = frameBitmapBuffer.convert(imageProxy) ?: run {
            Log.e(TAG, "Failed to convert ImageProxy to Bitmap")
            imageProxy.close()
            return
        }
        perfToBitmapNs += System.nanoTime() - tb0
        perfConverted++

        // Cache the latest frame so ROI photos can be cropped from it WITHOUT a
        // separate full-res still capture (which stalls the camera). Since A3 the
        // bitmap is a REUSED buffer that this thread overwrites on a later frame;
        // cropRoiFromFrame synchronizes on the bitmap instance (as does the writer),
        // so a photo crop on another thread sees a whole frame, never a torn one.
        // (Since A1 this refreshes at the capped inference rate, not the camera
        // rate — the photo crop is at most one cap interval older than before.)
        // Perf review A6: read the device orientation ONCE per frame and share the
        // answer with every consumer below (frame cache, motion gate, inference).
        // Resources.getConfiguration() is not free, and this used to be asked up
        // to three times per frame.
        val frameIsLandscape =
            context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE

        lastFrameBitmap = bitmap
        lastFrameRotationDegrees = imageProxy.imageInfo.rotationDegrees
        lastFrameIsFront = lensFacing == CameraSelector.LENS_FACING_FRONT
        lastFrameIsLandscape = frameIsLandscape

        // Check again after bitmap conversion (in case stop() was called during conversion)
        if (isStopped) {
            imageProxy.close()
            return
        }

        // FaunaPulse time-lapse capture mode: no detector, no motion
        // gate — photos are triggered by a Dart-side timer via the capture
        // channel methods. This branch only refreshes the frame cache (done
        // above) and heartbeats ~1 Hz with the oriented dims so the Dart
        // watchdog and its ROI/still-probe bootstrap stay fed. BEFORE the
        // predictor block: the detector path stays untouched when off.
        if (timeLapseMode) {
            val nowTl = System.nanoTime()
            if (nowTl - lastTimeLapseEmitNs >= 1_000_000_000L) {
                lastTimeLapseEmitNs = nowTl
                val rotationDegrees = imageProxy.imageInfo.rotationDegrees
                val isRotated = rotationDegrees % 180 != 0
                streamCallback?.invoke(
                    mapOf(
                        "timeLapse" to true,
                        "cameraFps" to lastDeliveredFps,
                        "imageWidth" to (if (isRotated) h else w),
                        "imageHeight" to (if (isRotated) w else h),
                        "roiActive" to (inferenceRoi != null),
                        "timestamp" to System.currentTimeMillis(),
                    )
                )
            }
            imageProxy.close()
            return
        }

        // FaunaPulse motion-only capture mode: the detector never runs.
        // Every converted frame feeds the motion gate (the background model must
        // keep learning), motion extends the wake window, and Flutter is told at
        // a bounded rate so it can drive time-lapse photo captures. Placed BEFORE
        // the predictor block on purpose: it needs nothing from the model, and
        // the detector path below stays byte-identical while the flag is off.
        // The idle 5-fps sampler at the top of onFrame throttles idle frames
        // exactly as in detector-gate mode, so idle heat is identical.
        if (motionOnlyMode && motionGateEnabled) {
            val nowGate = System.nanoTime()
            val wasAwake = nowGate <= gateAwakeUntilNs
            val rotationDegrees = imageProxy.imageInfo.rotationDegrees
            // Always the direct thumbnail draw: no model raster ever exists here
            // (motionDetectedFromModelInput needs the predictor to have run).
            val motion = gateMotionFromFrame(bitmap, rotationDegrees, frameIsLandscape)
            if (motion) gateAwakeUntilNs = nowGate + motionGateWakeNs
            if (motion || wasAwake) {
                // Awake: emit at most every 100 ms — plenty for a >= 1 s photo
                // step — except a wake TRANSITION, which emits immediately so the
                // first photo and the chip flip land without delay. Deliberately
                // NOT shouldRunInference(): that cap is tied to the auto-throttle,
                // which never updates without inference timings.
                if (!wasAwake || nowGate - lastMotionOnlyEmitNs >= 100_000_000L) {
                    lastMotionOnlyEmitNs = nowGate
                    val isRotated = rotationDegrees % 180 != 0
                    streamCallback?.invoke(
                        mapOf(
                            "gateIdle" to false,
                            "motionOnly" to true,
                            "motionScore" to motionGate.lastScore,
                            "cameraFps" to lastDeliveredFps,
                            // Oriented full-frame dims: the Dart side bootstraps
                            // its ROI push + still-size probe from the first map
                            // that carries them (heartbeats don't).
                            "imageWidth" to (if (isRotated) h else w),
                            "imageHeight" to (if (isRotated) w else h),
                            "roiActive" to (inferenceRoi != null),
                            "timestamp" to System.currentTimeMillis(),
                        )
                    )
                }
            } else {
                maybeEmitGateIdleHeartbeat(nowGate)
            }
            imageProxy.close()
            return
        }

        predictor?.let { p ->
            // Double-check stopped flag before inference (predictor might be closed)
            if (isStopped) {
                imageProxy.close()
                return
            }

            // FaunaPulse motion gate: on every frame (cheap, <1 ms) decide
            // whether anything moved inside the ROI. While there is neither motion
            // nor a recent detection, skip inference entirely — the detector
            // sleeps, the phone stays cool. The gate sees every converted frame,
            // but where the pixels come from depends on the frame (perf review
            // A5 — rasterize the ROI once per frame, not twice): frames that run
            // inference reuse the ROI the detector rasterizes into its model
            // input anyway (checked AFTER predict, below), while idle and
            // FPS-capped frames — where that raster never happens — draw the
            // gate's own tiny thumbnail so the background model keeps learning.
            var gateFromModelInput = false
            if (motionGateEnabled) {
                val nowGate = System.nanoTime()
                if (nowGate <= gateAwakeUntilNs) {
                    // Awake: consult the FPS cap once (it is stateful — asking
                    // twice per frame would advance its clock and veto itself).
                    inferenceApproved = shouldRunInference()
                    if (inferenceApproved) {
                        // This frame runs inference: derive the gate thumbnail
                        // from the model-input bitmap after predict() instead of
                        // rasterizing the ROI a second time here.
                        gateFromModelInput = true
                    } else {
                        // Awake but FPS-capped: no model raster this frame, so
                        // the gate draws its own thumbnail; motion must keep
                        // extending the wake window between inferred frames.
                        if (gateMotionFromFrame(bitmap, imageProxy.imageInfo.rotationDegrees, frameIsLandscape)) {
                            gateAwakeUntilNs = nowGate + motionGateWakeNs
                        }
                        imageProxy.close()
                        return
                    }
                } else if (gateMotionFromFrame(bitmap, imageProxy.imageInfo.rotationDegrees, frameIsLandscape)) {
                    // Was idle, motion just woke the gate; the FPS-cap check
                    // below decides whether this frame also runs inference.
                    gateAwakeUntilNs = nowGate + motionGateWakeNs
                } else {
                    // Still idle: heartbeat instead of results (see helper doc).
                    maybeEmitGateIdleHeartbeat(nowGate)
                    imageProxy.close()
                    return
                }
            }

            // Check if we should run inference on this frame. Skipped when an
            // earlier check already approved it (pre-conversion when the gate is
            // off — A1; inside the awake gate branch above when it is on) —
            // asking twice would advance the cap clock and veto its own approval.
            if (!inferenceApproved && !shouldRunInference()) {
                imageProxy.close()
                return
            }
            perfInferred++

            try {
                syncTargetRotation()
                // Device orientation, read once per frame above (perf review A6)
                val isLandscape = frameIsLandscape

                // Check if using front camera
                val isFrontCamera = lensFacing == CameraSelector.LENS_FACING_FRONT
                val rotationDegrees = imageProxy.imageInfo.rotationDegrees
                val isRotated = rotationDegrees % 180 != 0
                val orientedWidth = if (isRotated) h else w
                val orientedHeight = if (isRotated) w else h
                
                // Set camera facing information in predictor
                (p as? BasePredictor)?.let { basePredictor ->
                    basePredictor.isFrontCamera = isFrontCamera
                    basePredictor.cameraRotationDegrees = rotationDegrees
                    basePredictor.includeRawMaskData = streamConfig?.includeMasks == true
                    // FaunaPulse: crop inference to the ROI when one is set.
                    basePredictor.inferenceRoi = inferenceRoi
                }
                
                val result = p.predict(
                    bitmap,
                    orientedWidth,
                    orientedHeight,
                    rotateForCamera = true,
                    isLandscape = isLandscape
                )

                // Motion gate, deferred from before inference (perf review A5):
                // predict() just rasterized the ROI into its model-input bitmap,
                // so derive the gate thumbnail from those pixels instead of
                // drawing the ROI from the camera frame a second time. Same
                // analyzer thread, so the reused buffer is still this frame's.
                // Falls back to the direct draw when no ROI raster exists (no
                // ROI set, or a predictor that doesn't expose its input).
                if (gateFromModelInput) {
                    val roiInput = (p as? BasePredictor)?.lastRoiModelInput()
                    val motion = if (roiInput != null) {
                        motionGate.motionDetectedFromModelInput(roiInput)
                    } else {
                        gateMotionFromFrame(bitmap, rotationDegrees, frameIsLandscape)
                    }
                    if (motion) gateAwakeUntilNs = System.nanoTime() + motionGateWakeNs
                }

                // Apply originalImage if streaming config requires it
                val resultWithOriginalImage = if (streamConfig?.includeOriginalImage == true) {
                    result.copy(originalImage = bitmap)  // Reuse bitmap from ImageProxy conversion
                } else {
                    result
                }
                
                // Motion gate: every frame with at least one detection keeps the
            // detector awake, so an insect that lands and sits perfectly still is
            // never dropped just because it stopped producing motion.
            if (motionGateEnabled && result.boxes.isNotEmpty()) {
                gateAwakeUntilNs = System.nanoTime() + motionGateWakeNs
            }

            inferenceResult = resultWithOriginalImage

                // Log
                
                // Callback
                inferenceCallback?.invoke(resultWithOriginalImage)
                
                // Streaming callback (with output throttling)
                streamCallback?.let { callback ->
                    if (shouldProcessFrame()) {
                        updateLastInferenceTime()
                        
                        // Convert to stream data and send. The converter returns a
                        // fresh mutable map, so enrich it in place instead of copying
                        // every entry into a second map (perf review A6).
                        val enhancedStreamData = convertResultToStreamData(resultWithOriginalImage)
                        // Add timestamp and frame info
                        enhancedStreamData["timestamp"] = System.currentTimeMillis()
                        // Round 114: the frame's sensor-exposure moment on the
                        // epoch clock, so logged boxes can be time-matched to a
                        // high-res photo's contentAtEpochMs without the
                        // ~50–150 ms pre+inference bias that "timestamp"
                        // (frozen semantics: emit time) carries. Absent on odd
                        // HALs (sensorNanosToEpochMs plausibility clamp).
                        try {
                            sensorNanosToEpochMs(imageProxy.imageInfo.timestamp)?.let {
                                enhancedStreamData["frameSensorMs"] = Math.round(it)
                            }
                        } catch (_: Exception) {
                            // Field simply absent; matching falls back.
                        }
                        enhancedStreamData["frameNumber"] = frameNumberCounter++
                        // Dimensions of the upright FULL frame, so the Flutter overlay maps onto the whole preview.
                        // (With a ROI crop, result.origShape is the ROI's size and detections are normalized to the
                        // ROI; the Dart side knows the ROI it set and maps those boxes back onto the frame. #506)
                        enhancedStreamData["imageWidth"] = orientedWidth
                        enhancedStreamData["imageHeight"] = orientedHeight
                        enhancedStreamData["roiActive"] = (inferenceRoi != null)
                    // Motion gate state for the UI: on frames that ran inference the
                    // gate is by definition awake; include the live motion score so
                    // the user can tune the trigger threshold against reality.
                    if (motionGateEnabled) {
                        enhancedStreamData["gateIdle"] = false
                        enhancedStreamData["motionScore"] = motionGate.lastScore
                    }
                        // Which processor is actually running inference ("GPU"/"CPU"/"NPU"). CPU
                        // fallback is decided per model by whether the GPU backend can compile its
                        // graph, NOT by dtype - int8 models can and do compile on GPU (verified:
                        // arthropod_yolov11_int8 runs on GPU, session_120). See LiteRtModel.
                        enhancedStreamData["accelerator"] = (p as? BasePredictor)?.accelerator ?: "unknown"
                        // Camera analysis delivery rate (frames/sec the sensor feeds the analyzer).
                        enhancedStreamData["cameraFps"] = lastDeliveredFps

                        callback.invoke(enhancedStreamData)
                    }
                }

                // Update overlay
                post {
                    overlayView.invalidate()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error during prediction", e)
                maybeEmitInferenceError(e)
            }
        }
        imageProxy.close()
    }

    // endregion

    // region OverlayView

    private inner class OverlayView(context: Context) : View(context) {
        private val paint = Paint().apply { isAntiAlias = true }

        private fun labelText(name: String, confidence: Float) =
            "$name ${"%.1f".format(confidence * 100)}"

        private fun colorFor(index: Int, confidence: Float): Int {
            val alpha = (confidence * 255).toInt().coerceIn((0.6f * 255).toInt(), 255)
            val baseColor = ultralyticsColors[index % ultralyticsColors.size]
            return Color.argb(
                alpha,
                Color.red(baseColor),
                Color.green(baseColor),
                Color.blue(baseColor)
            )
        }

        private fun drawLabel(
            canvas: Canvas,
            text: String,
            color: Int,
            anchorLeft: Float,
            anchorTop: Float,
            anchorRight: Float,
            viewWidth: Float,
            viewHeight: Float,
            centered: Boolean = false
        ) {
            paint.textSize = 40f
            val fm = paint.fontMetrics
            val textWidth = paint.measureText(text)
            val textHeight = fm.bottom - fm.top
            val pad = 8f
            val labelWidth = textWidth + 2 * pad
            val labelHeight = textHeight + 2 * pad
            var labelLeft = if (centered) (viewWidth - labelWidth) / 2 else anchorLeft
            var labelTop = if (centered) (viewHeight - labelHeight) / 2 else anchorTop - labelHeight
            var labelRight = labelLeft + labelWidth
            var labelBottom = labelTop + labelHeight

            if (labelTop < 0) {
                labelTop = anchorTop
                labelBottom = labelTop + labelHeight
            }
            if (labelLeft < 0) {
                labelLeft = 0f
                labelRight = labelWidth
            }
            if (labelRight > viewWidth) {
                labelRight = viewWidth
                labelLeft = maxOf(0f, anchorRight - labelWidth)
            }
            if (labelBottom > viewHeight) {
                labelBottom = viewHeight
                labelTop = labelBottom - labelHeight
            }

            val bgRect = RectF(labelLeft, labelTop, labelRight, labelBottom)
            paint.style = Paint.Style.FILL
            paint.color = color
            canvas.drawRoundRect(bgRect, BOX_CORNER_RADIUS, BOX_CORNER_RADIUS, paint)

            paint.color = Color.WHITE
            val centerY = (bgRect.top + bgRect.bottom) / 2
            val baseline = centerY - (fm.descent + fm.ascent) / 2
            canvas.drawText(text, bgRect.left + pad, baseline, paint)
        }

        init {
            // Make background transparent
            setBackgroundColor(Color.TRANSPARENT)
            // Use hardware layer for better z-order 
            setLayerType(LAYER_TYPE_HARDWARE, null)

            // Raise overlay
            elevation = 1000f
            translationZ = 1000f

            setWillNotDraw(false)

            // Make overlay not intercept touch events
            isClickable = false
            isFocusable = false
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val result = inferenceResult ?: return
            
            // Only draw overlays if showOverlays is true
            if (!showOverlays) {
                return
            }

            val iw = result.origShape.width.toFloat()
            val ih = result.origShape.height.toFloat()

            val vw = width.toFloat()
            val vh = height.toFloat()
            
            // Scale factor from camera image to view
            val scaleX = vw / iw
            val scaleY = vh / ih
            val scale = max(scaleX, scaleY)
            

            // Check if using front camera
            val isFrontCamera = lensFacing == CameraSelector.LENS_FACING_FRONT

            val imageRect = RectF(
                (vw - iw * scale) / 2f,
                (vh - ih * scale) / 2f,
                (vw + iw * scale) / 2f,
                (vh + ih * scale) / 2f
            )

            fun mapPoint(x: Float, y: Float): PointF {
                val px = imageRect.left + x * scale
                val py = imageRect.top + y * scale
                return PointF(if (isFrontCamera) vw - px else px, py)
            }

            fun mapRect(rect: RectF): RectF {
                val topLeft = mapPoint(rect.left, rect.top)
                val bottomRight = mapPoint(rect.right, rect.bottom)
                return RectF(
                    minOf(topLeft.x, bottomRight.x),
                    minOf(topLeft.y, bottomRight.y),
                    maxOf(topLeft.x, bottomRight.x),
                    maxOf(topLeft.y, bottomRight.y)
                )
            }

            when (task) {
                // ----------------------------------------
                // DETECT
                // ----------------------------------------
                YOLOTask.DETECT -> {
                    for (box in result.boxes) {
                        val newColor = colorFor(box.index, box.conf)

                        val rect = mapRect(box.xywh)
                        // Draw at the box's true position and let the canvas clip whatever falls outside the view. Do
                        // NOT pin an edge to the bound while keeping the width — that shifts a partially off-screen box
                        // inward (a left edge clamped to 0 pushes the right edge too far right, and vice versa).

                        paint.color = newColor
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = BOX_LINE_WIDTH
                        canvas.drawRoundRect(
                            rect.left, rect.top, rect.right, rect.bottom,
                            BOX_CORNER_RADIUS, BOX_CORNER_RADIUS,
                            paint
                        )

                        drawLabel(canvas, labelText(box.cls, box.conf), newColor, rect.left, rect.top, rect.right, vw, vh)
                    }
                }
                // ----------------------------------------
                // SEGMENT
                // ----------------------------------------
                YOLOTask.SEGMENT -> {
                    // Bounding boxes & labels
                    for (box in result.boxes) {
                        val newColor = colorFor(box.index, box.conf)

                        val rect = mapRect(box.xywh)

                        paint.color = newColor
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = BOX_LINE_WIDTH
                        canvas.drawRoundRect(
                            rect.left, rect.top, rect.right, rect.bottom,
                            BOX_CORNER_RADIUS, BOX_CORNER_RADIUS,
                            paint
                        )

                        drawLabel(canvas, labelText(box.cls, box.conf), newColor, rect.left, rect.top, rect.right, vw, vh)
                    }

                    // Segmentation mask
                    result.masks?.combinedMask?.let { maskBitmap ->
                        val src = Rect(0, 0, maskBitmap.width, maskBitmap.height)
                        val maskPaint = Paint().apply {
                            alpha = 128
                            isFilterBitmap = true
                        }
                        
                        if (isFrontCamera) {
                            // For front camera, flip the mask horizontally
                            canvas.save()
                            // Translate to center, flip horizontally, translate back
                            canvas.translate(vw / 2f, 0f)
                            canvas.scale(-1f, 1f)
                            canvas.translate(-vw / 2f, 0f)
                            canvas.drawBitmap(maskBitmap, src, imageRect, maskPaint)
                            canvas.restore()
                        } else {
                            canvas.drawBitmap(maskBitmap, src, imageRect, maskPaint)
                        }
                    }
                }
                // ----------------------------------------
                // SEMANTIC
                // ----------------------------------------
                YOLOTask.SEMANTIC -> {
                    result.semanticMask?.maskImage?.let { maskBitmap ->
                        val src = Rect(0, 0, maskBitmap.width, maskBitmap.height)
                        val maskPaint = Paint().apply {
                            alpha = 128
                            isFilterBitmap = true
                        }

                        if (isFrontCamera) {
                            canvas.save()
                            canvas.translate(vw / 2f, 0f)
                            canvas.scale(-1f, 1f)
                            canvas.translate(-vw / 2f, 0f)
                            canvas.drawBitmap(maskBitmap, src, imageRect, maskPaint)
                            canvas.restore()
                        } else {
                            canvas.drawBitmap(maskBitmap, src, imageRect, maskPaint)
                        }
                    }
                }
                // ----------------------------------------
                // CLASSIFY
                // ----------------------------------------
                YOLOTask.CLASSIFY -> {
                    result.probs?.let { probs ->
                        val newColor = colorFor(probs.top1Index, probs.top1Conf)

                        drawLabel(
                            canvas,
                            labelText(probs.top1Label, probs.top1Conf),
                            newColor,
                            16f,
                            16f,
                            16f,
                            vw,
                            vh,
                            centered = true
                        )
                    }
                }
                // ----------------------------------------
                // POSE
                // ----------------------------------------
                YOLOTask.POSE -> {
                    // Bounding boxes
                    for (box in result.boxes) {
                        val newColor = colorFor(box.index, box.conf)

                        val rect = mapRect(box.xywh)

                        paint.color = newColor
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = BOX_LINE_WIDTH
                        canvas.drawRoundRect(
                            rect.left, rect.top, rect.right, rect.bottom,
                            BOX_CORNER_RADIUS, BOX_CORNER_RADIUS,
                            paint
                        )
                        
                        drawLabel(canvas, labelText(box.cls, box.conf), newColor, rect.left, rect.top, rect.right, vw, vh)
                    }

                    // Keypoints & skeleton
                    for (person in result.keypointsList) {
                        val points = arrayOfNulls<PointF>(person.xyn.size)
                        for (i in person.xyn.indices) {
                            val kp = person.xyn[i]
                            val conf = person.conf[i]
                            if (conf > 0.25f) {
                                val point = mapPoint(kp.first * iw, kp.second * ih)

                                val colorIdx = if (i < kptColorIndices.size) kptColorIndices[i] else 0
                                val rgbArray = posePalette[colorIdx % posePalette.size]
                                paint.color = Color.argb(
                                    255,
                                    rgbArray[0].toInt().coerceIn(0,255),
                                    rgbArray[1].toInt().coerceIn(0,255),
                                    rgbArray[2].toInt().coerceIn(0,255)
                                )
                                paint.style = Paint.Style.FILL
                                canvas.drawCircle(point.x, point.y, 8f, paint)

                                points[i] = point
                            }
                        }

                        // Skeleton connection
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = KEYPOINT_LINE_WIDTH
                        for ((idx, bone) in skeleton.withIndex()) {
                            val i1 = bone[0] - 1  // 1-indexed to 0-indexed
                            val i2 = bone[1] - 1
                            val p1 = points.getOrNull(i1)
                            val p2 = points.getOrNull(i2)
                            if (p1 != null && p2 != null) {
                                val limbColorIdx = if (idx < limbColorIndices.size) limbColorIndices[idx] else 0
                                val rgbArray = posePalette[limbColorIdx % posePalette.size]
                                paint.color = Color.argb(
                                    255,
                                    rgbArray[0].toInt().coerceIn(0,255),
                                    rgbArray[1].toInt().coerceIn(0,255),
                                    rgbArray[2].toInt().coerceIn(0,255)
                                )
                                canvas.drawLine(p1.x, p1.y, p2.x, p2.y, paint)
                            }
                        }
                    }
                }
                // ----------------------------------------
                // OBB
                // ----------------------------------------
                YOLOTask.OBB -> {
                    for (obbRes in result.obb) {
                        val newColor = colorFor(obbRes.index, obbRes.confidence)

                        paint.color = newColor
                        paint.style = Paint.Style.STROKE
                        paint.strokeWidth = BOX_LINE_WIDTH

                        // Draw rotated rectangle (polygon) using path
                        val polygon = obbRes.box.toPolygon(iw, ih).map { pt -> mapPoint(pt.x * iw, pt.y * ih) }
                        if (polygon.size >= 4) {
                            val path = Path().apply {
                                moveTo(polygon[0].x, polygon[0].y)
                                for (p in polygon.drop(1)) {
                                    lineTo(p.x, p.y)
                                }
                                close()
                            }
                            canvas.drawPath(path, paint)

                            // Find bounding box of the OBB polygon
                            val minX = polygon.map { it.x }.minOrNull() ?: 0f
                            val maxX = polygon.map { it.x }.maxOrNull() ?: 0f
                            val minY = polygon.map { it.y }.minOrNull() ?: 0f
                            drawLabel(
                                canvas,
                                labelText(obbRes.cls, obbRes.confidence),
                                newColor,
                                minX,
                                minY,
                                maxX,
                                vw,
                                vh
                            )
                        }
                    }
                }
            }
        }
        
        override fun onTouchEvent(event: MotionEvent?): Boolean {
            // Pass through all touch events
            return false
        }
    }
    
    // region Streaming functionality
    
    /**
     * Setup throttling parameters from streaming configuration
     */
    private fun setupThrottlingFromConfig() {
        streamConfig?.let { config ->
            // Setup maxFPS throttling (for result output)
            config.maxFPS?.let { maxFPS ->
                if (maxFPS > 0) {
                    targetFrameInterval = (1_000_000_000L / maxFPS) // Convert to nanoseconds
                }
            } ?: run {
                targetFrameInterval = null
            }

            // Setup throttleInterval (for result output)
            config.throttleIntervalMs?.let { throttleMs ->
                if (throttleMs > 0) {
                    throttleInterval = throttleMs * 1_000_000L // Convert ms to nanoseconds
                }
            } ?: run {
                throttleInterval = null
            }

            // Setup inference frequency control
            config.inferenceFrequency?.let { inferenceFreq ->
                if (inferenceFreq > 0) {
                    inferenceFrameInterval = (1_000_000_000L / inferenceFreq) // Convert to nanoseconds
                }
            } ?: run {
                inferenceFrameInterval = null
            }

            // Setup frame skipping
            config.skipFrames?.let { skipFrames ->
                if (skipFrames > 0) {
                    targetSkipFrames = skipFrames
                    frameSkipCount = 0 // Reset counter
                }
            } ?: run {
                targetSkipFrames = 0
                frameSkipCount = 0
            }

            // Initialize timing
            lastInferenceTime = System.nanoTime()
            // New cap takes effect on the very next frame (0 = no deadline yet).
            nextAllowedInferenceNs = 0L
        }
    }
    
    /**
     * Check if we should run inference on this frame based on inference frequency control
     */
    private fun shouldRunInference(): Boolean {
        val now = System.nanoTime()
        
        // Check frame skipping control first (simpler, more deterministic)
        if (targetSkipFrames > 0) {
            frameSkipCount++
            if (frameSkipCount <= targetSkipFrames) {
                // Still skipping frames
                return false
            } else {
                // Reset counter and allow inference
                frameSkipCount = 0
                return true
            }
        }
        
        // Inference frequency control (time-based). This is a DEADLINE
        // scheduler: each allowed start advances the deadline by exactly one
        // interval, so the average rate equals the configured cap even when
        // camera frames don't line up with it. The previous elapsed-time rule
        // ("skip unless >= interval since the last allowed start") beat against
        // the camera cadence — a 10/s cap on a 15 fps camera could only fire
        // every SECOND frame, a locked 7.5/s (perf review C1, round 129).
        // After a stall longer than one interval (gate sleep, settings pause,
        // slow inference) the schedule re-anchors at now + interval instead of
        // bursting to catch up.
        inferenceFrameInterval?.let { interval ->
            if (now < nextAllowedInferenceNs) {
                return false
            }
            nextAllowedInferenceNs =
                if (now - nextAllowedInferenceNs >= interval) now + interval
                else nextAllowedInferenceNs + interval
        }

        return true
    }
    
    /**
     * Check if we should send results to Flutter based on output throttling settings
     */
    private fun shouldProcessFrame(): Boolean {
        val now = System.nanoTime()
        
        // Check maxFPS throttling
        targetFrameInterval?.let { interval ->
            if (now - lastInferenceTime < interval) {
                return false
            }
        }
        
        // Check throttleInterval
        throttleInterval?.let { interval ->
            if (now - lastInferenceTime < interval) {
                return false
            }
        }
        
        return true
    }
    
    /**
     * Update the last inference time (call this when actually processing)
     */
    private fun updateLastInferenceTime() {
        lastInferenceTime = System.nanoTime()
    }
    
    /**
     * Flattens keypoints data into a single array format: [x1, y1, conf1, x2, y2, conf2, ...]
     */
    private fun flattenKeypoints(keypoints: Keypoints): List<Double> {
        val flattened = mutableListOf<Double>()
        for (i in keypoints.xy.indices) {
            flattened.add(keypoints.xy[i].first.toDouble())
            flattened.add(keypoints.xy[i].second.toDouble())
            val confidence = if (i < keypoints.conf.size) {
                keypoints.conf[i].toDouble()
            } else {
                0.0
            }
            flattened.add(confidence)
        }
        return flattened
    }

    /**
     * Convert YOLOResult to a Map for streaming (ported from archived YOLOPlatformView)
     * Uses detection index correctly to avoid class index confusion
     */
    private fun convertResultToStreamData(result: YOLOResult): HashMap<String, Any> {
        // Sized for the handful of top-level keys plus the extras onFrame adds
        // in place after this returns (timestamp, dimensions, gate state, ...).
        val map = HashMap<String, Any>(32)
        val config = streamConfig ?: return map

        // Convert detection results (if enabled)
        if (config.includeDetections) {
            val detections = ArrayList<Map<String, Any>>(result.boxes.size)

            if (config.includePoses && result.keypointsList.isNotEmpty() && result.boxes.isEmpty()) {
                for ((poseIndex, keypoints) in result.keypointsList.withIndex()) {
                    val detection = HashMap<String, Any>()
                    detection["classIndex"] = 0
                    detection["className"] = result.names.getOrNull(0)?.takeIf { it.isNotBlank() } ?: "class 0"
                    detection["confidence"] = 1.0
                    var minX = Float.MAX_VALUE
                    var minY = Float.MAX_VALUE
                    var maxX = Float.MIN_VALUE
                    var maxY = Float.MIN_VALUE
                    
                    for (kp in keypoints.xy) {
                        if (kp.first > 0 && kp.second > 0) {
                            minX = minOf(minX, kp.first)
                            minY = minOf(minY, kp.second)
                            maxX = maxOf(maxX, kp.first)
                            maxY = maxOf(maxY, kp.second)
                        }
                    }
                    val boundingBox = HashMap<String, Any>()
                    boundingBox["left"] = minX.toDouble()
                    boundingBox["top"] = minY.toDouble()
                    boundingBox["right"] = maxX.toDouble()
                    boundingBox["bottom"] = maxY.toDouble()
                    detection["boundingBox"] = boundingBox
                    
                    // Normalized bounding box
                    val normalizedBox = HashMap<String, Any>()
                    normalizedBox["left"] = (minX / result.origShape.width).toDouble()
                    normalizedBox["top"] = (minY / result.origShape.height).toDouble()
                    normalizedBox["right"] = (maxX / result.origShape.width).toDouble()
                    normalizedBox["bottom"] = (maxY / result.origShape.height).toDouble()
                    detection["normalizedBox"] = normalizedBox
                    
                    val keypointsFlat = flattenKeypoints(keypoints)
                    detection["keypoints"] = keypointsFlat

                    detections.add(detection)
                }
            }
            
            // Convert detection boxes - CRITICAL: use detectionIndex, not class index
            // These maps are built per detection on the camera thread, so they are
            // pre-sized to their known entry counts to avoid rehashing (perf review A6).
            for ((detectionIndex, box) in result.boxes.withIndex()) {
                val detection = HashMap<String, Any>(12)
                detection["classIndex"] = box.index
                detection["className"] = box.cls
                detection["confidence"] = box.conf.toDouble()

                // Bounding box in original coordinates
                val boundingBox = HashMap<String, Any>(8)
                boundingBox["left"] = box.xywh.left.toDouble()
                boundingBox["top"] = box.xywh.top.toDouble()
                boundingBox["right"] = box.xywh.right.toDouble()
                boundingBox["bottom"] = box.xywh.bottom.toDouble()
                detection["boundingBox"] = boundingBox

                // Normalized bounding box (0-1)
                val normalizedBox = HashMap<String, Any>(8)
                normalizedBox["left"] = box.xywhn.left.toDouble()
                normalizedBox["top"] = box.xywhn.top.toDouble()
                normalizedBox["right"] = box.xywhn.right.toDouble()
                normalizedBox["bottom"] = box.xywhn.bottom.toDouble()
                detection["normalizedBox"] = normalizedBox
                
                // Add mask data for segmentation (if available and enabled)
                if (config.includeMasks && result.masks != null && detectionIndex < result.masks!!.masks.size) {
                    val maskData = result.masks!!.masks[detectionIndex] // Get mask for this detection
                    // Convert List<List<Float>> to List<List<Double>> for Flutter compatibility
                    val maskDataDouble = maskData.map { row ->
                        row.map { it.toDouble() }
                    }
                    detection["mask"] = maskDataDouble
                }
                
                // Add pose keypoints (if available and enabled)
                if (config.includePoses && result.keypointsList.isNotEmpty()) {
                    if (detectionIndex < result.keypointsList.size) {
                        val keypoints = result.keypointsList[detectionIndex]
                        val keypointsFlat = flattenKeypoints(keypoints)
                        detection["keypoints"] = keypointsFlat
                    }
                }
                
                detections.add(detection)
            }
            
            // Handle OBB results directly (same pattern as overlay: for obbRes in result.obb)
            for (obbRes in result.obb) {
                val detection = HashMap<String, Any>()
                detection["classIndex"] = obbRes.index
                detection["className"] = obbRes.cls
                detection["confidence"] = obbRes.confidence.toDouble()
                
                // Get OBB polygon points (4 corners of rotated rectangle)
                val imgWidth = result.origShape.width.toFloat()
                val imgHeight = result.origShape.height.toFloat()
                val polygon = obbRes.box.toPolygon(imgWidth, imgHeight)
                
                // Convert polygon points to pixel coordinates  
                val polygonPixels = polygon.map { point ->
                    mapOf(
                        "x" to (point.x * imgWidth).toDouble(),
                        "y" to (point.y * imgHeight).toDouble()
                    )
                }
                
                // Store polygon points directly for precise OBB cropping
                detection["polygon"] = polygonPixels

                // Normalized (0-1) corners and rotation angle, always present so custom overlays
                // can transform OBB detections without enabling includeOBB (#506)
                val pointsNormalized = polygon.map { point ->
                    mapOf(
                        "x" to point.x.toDouble(),
                        "y" to point.y.toDouble()
                    )
                }
                detection["polygonNormalized"] = pointsNormalized
                detection["angle"] = obbRes.box.angle.toDouble()

                // Also calculate AABB as fallback for compatibility (but Flutter should use polygon)
                var minX = Float.MAX_VALUE
                var maxX = Float.MIN_VALUE  
                var minY = Float.MAX_VALUE
                var maxY = Float.MIN_VALUE
                
                for (point in polygon) {
                    if (point.x < minX) minX = point.x
                    if (point.x > maxX) maxX = point.x
                    if (point.y < minY) minY = point.y
                    if (point.y > maxY) maxY = point.y
                }
                
                // Fallback bounding box (enlarged) - only use if polygon cropping fails
                val boundingBox = HashMap<String, Any>()
                boundingBox["left"] = (minX * imgWidth).toDouble()
                boundingBox["top"] = (minY * imgHeight).toDouble()
                boundingBox["right"] = (maxX * imgWidth).toDouble()
                boundingBox["bottom"] = (maxY * imgHeight).toDouble()
                detection["boundingBox"] = boundingBox
                
                // Normalized bounding box (0-1) - fallback
                val normalizedBox = HashMap<String, Any>()
                normalizedBox["left"] = minX.toDouble()
                normalizedBox["top"] = minY.toDouble()
                normalizedBox["right"] = maxX.toDouble()
                normalizedBox["bottom"] = maxY.toDouble()
                detection["normalizedBox"] = normalizedBox
                
                // Add OBB-specific data
                if (config.includeOBB) {
                    val obbDataMap = mapOf(
                        "centerX" to obbRes.box.cx.toDouble(),
                        "centerY" to obbRes.box.cy.toDouble(),
                        "width" to obbRes.box.w.toDouble(),
                        "height" to obbRes.box.h.toDouble(),
                        "angle" to obbRes.box.angle.toDouble(),
                        "angleDegrees" to (obbRes.box.angle * 180.0 / Math.PI),
                        "area" to obbRes.box.area.toDouble(),
                        "points" to pointsNormalized,
                        "confidence" to obbRes.confidence.toDouble(),
                        "className" to obbRes.cls,
                        "classIndex" to obbRes.index
                    )
                    
                    detection["obb"] = obbDataMap
                }
                
                detections.add(detection)
            }
            
            map["detections"] = detections
        }

        if (config.includeMasks) {
            result.semanticMask?.let { semanticMask ->
                map["semanticMask"] = mapOf(
                    "classMap" to semanticMask.classMap,
                    "width" to semanticMask.width,
                    "height" to semanticMask.height
                )
            }
        }

        // Add classification results (if available and enabled for CLASSIFY task)
        if (config.includeClassifications && result.probs != null && result.boxes.isEmpty()) {
            val probs = result.probs!!

            val top5Count = minOf(
                probs.top5Indices.size,
                probs.top5Labels.size,
                probs.top5Confs.size
            )
            val top5List = (0 until top5Count).map { index ->
                val classIdx = probs.top5Indices[index]
                val name = probs.top5Labels[index]
                val conf = probs.top5Confs[index]
                mapOf(
                    "class" to classIdx,
                    "name" to name,
                    "confidence" to conf.toDouble()
                )
            }

            // Add classification result to detections array (for compatibility with YOLOResult.fromMap)
            val detections = (map["detections"] as? List<Map<String, Any>>)?.toMutableList() ?: ArrayList()

            val classificationDetection = HashMap<String, Any>()
            classificationDetection["class"] = probs.top1Index
            classificationDetection["name"] = probs.top1Label
            classificationDetection["confidence"] = probs.top1Conf.toDouble()
            classificationDetection["top5"] = top5List

            // Full image bounding box for classification
            val boundingBox = HashMap<String, Any>()
            boundingBox["left"] = 0.0
            boundingBox["top"] = 0.0
            boundingBox["right"] = result.origShape.width.toDouble()
            boundingBox["bottom"] = result.origShape.height.toDouble()
            classificationDetection["boundingBox"] = boundingBox

            // Normalized bounding box (full image)
            val normalizedBox = HashMap<String, Any>()
            normalizedBox["left"] = 0.0
            normalizedBox["top"] = 0.0
            normalizedBox["right"] = 1.0
            normalizedBox["bottom"] = 1.0
            classificationDetection["normalizedBox"] = normalizedBox

            detections.add(classificationDetection)
            map["detections"] = detections
        }
        
        // Add performance metrics (if enabled)
        if (config.includeProcessingTimeMs) {
            val processingTimeMs = result.speed.toDouble()
            map["processingTimeMs"] = processingTimeMs
            map["preMs"] = result.preMs
            map["inferenceMs"] = result.inferenceMs
            map["postMs"] = result.postMs
        }
        
        if (config.includeFps) {
            map["fps"] = result.fps?.toDouble() ?: 0.0
        }
        
        // Add original image (if available and enabled)
        // ⚠️ FOOTGUN: this JPEG-encodes the FULL camera frame at quality 90 on every
        // streamed frame, on the camera analyzer thread. The FaunaPulse app
        // never enables includeOriginalImage — keep it that way (perf review A6);
        // ROI photos use captureRoiFromFrame/capturePhoto instead.
        if (config.includeOriginalImage) {
            result.originalImage?.let { bitmap ->
                val outputStream = java.io.ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
                val imageData = outputStream.toByteArray()
                map["originalImage"] = imageData
            }
        }
        
        return map
    }
    
    // endregion
    
    /**
     * Capture current camera frame. When [withOverlays] is true the overlay bitmap (bounding boxes / mask / pose) is
     * composited on top of the preview snapshot before encoding. Used as the fallback path when [capturePhoto]'s
     * preferred ImageCapture binding is unavailable. Returns the captured image as a ByteArray (JPEG format).
     */
    fun captureFrame(withOverlays: Boolean = true): ByteArray? {
        try {
            // Create bitmap to hold the captured frame
            val width = width
            val height = height
            if (width <= 0 || height <= 0) {
                Log.e(TAG, "Invalid view dimensions for capture: ${width}x${height}")
                return null
            }
            
            // Create bitmap and canvas
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            
            // Method 1: Try to get bitmap from PreviewView directly
            var cameraFrameCaptured = false
            previewView.bitmap?.let { cameraBitmap ->
                // Draw the camera bitmap scaled to fit
                val matrix = Matrix()
                val scaleX = width.toFloat() / cameraBitmap.width
                val scaleY = height.toFloat() / cameraBitmap.height
                matrix.setScale(scaleX, scaleY)
                canvas.drawBitmap(cameraBitmap, matrix, null)
                cameraFrameCaptured = true
            }
            
            if (!cameraFrameCaptured) {
                // Method 2: Use hardware acceleration to capture the view
                Log.w(TAG, "PreviewView.bitmap is null, trying hardware capture")
                
                // Enable drawing cache temporarily
                isDrawingCacheEnabled = true
                buildDrawingCache()
                drawingCache?.let { cache ->
                    canvas.drawBitmap(cache, 0f, 0f, null)
                    cameraFrameCaptured = true
                }
                isDrawingCacheEnabled = false
                
                if (!cameraFrameCaptured) {
                    // Method 3: Last resort - draw the entire view hierarchy
                    Log.w(TAG, "Drawing cache failed, using draw method")
                    // Draw PreviewView first
                    previewView.draw(canvas)
                }
            }
            
            // Conditionally draw the overlay on top — callers asking for a raw photo (e.g.
            // capturePhoto(withOverlays=false) hitting the fallback path) get the unannotated preview snapshot.
            if (withOverlays) {
                overlayView.draw(canvas)
            }
            
            // Convert bitmap to JPEG byte array
            val outputStream = java.io.ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
            val imageData = outputStream.toByteArray()
            
            // Clean up
            outputStream.close()
            bitmap.recycle()

            return imageData
        } catch (e: Exception) {
            Log.e(TAG, "Error capturing frame", e)
            return null
        }
    }

    /**
     * Stop camera and inference (can be restarted later)
     */
    fun stop() {
        // Set stopped flag first to prevent new frames from being processed
        isStopped = true
        // A full teardown is not an intentional pause; a later lifecycle restart should rebind normally.
        intentionallyPaused = false

        try {
            imageAnalysisUseCase?.clearAnalyzer()
            if (::cameraProviderFuture.isInitialized) {
                try {
                    val cameraProvider = cameraProviderFuture.get(1, TimeUnit.SECONDS)
                    cameraProvider.unbindAll()
                } catch (e: Exception) {
                    Log.e(TAG, "Error getting camera provider for unbind", e)
                }
            }

            imageAnalysisUseCase = null
            imageCaptureUseCase = null

            previewUseCase?.setSurfaceProvider(null)
            previewUseCase = null

            cameraExecutor?.let { exec ->
                exec.shutdown()
                try {
                    if (!exec.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                        Log.w(TAG, "Executor didn't shut down in time; forcing shutdown")
                        exec.shutdownNow()
                        if (!exec.awaitTermination(500, TimeUnit.MILLISECONDS)) {
                            Log.e(TAG, "Executor failed to terminate after forced shutdown")
                        }
                    }
                } catch (e: InterruptedException) {
                    Log.e(TAG, "Interrupted while waiting for executor shutdown", e)
                    exec.shutdownNow()
                    Thread.currentThread().interrupt()
                }
            }
            cameraExecutor = null

            camera = null
            
            // Close the active predictor AND release every other cached predictor (prior setModel() instances), so a
            // disposed view doesn't leak their native LiteRT interpreters / tensor buffers. Closing also makes a later
            // same-key setModel() fast path unable to serve a now-closed instance (use-after-close).
            val closing = predictor
            try {
                (closing as? BasePredictor)?.close()
            } catch (e: Exception) {
                Log.e(TAG, "Error closing predictor", e)
            }
            for (cached in predictorCache.values) {
                if (cached !== closing) {
                    try {
                        (cached as? BasePredictor)?.close()
                    } catch (e: Exception) {
                        Log.e(TAG, "Error closing cached predictor", e)
                    }
                }
            }
            predictorCache.clear()
            predictorCacheOrder.clear()
            predictor = null
            inferenceCallback = null
            streamCallback = null
            inferenceResult = null
        } catch (e: Exception) {
            Log.e(TAG, "Error during YOLOView stop", e)
        }
    }

}
