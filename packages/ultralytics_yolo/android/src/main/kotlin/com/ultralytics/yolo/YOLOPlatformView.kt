// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.content.Context
import android.util.Log
import android.view.View
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.atomic.AtomicBoolean

/**
 * YOLOPlatformView - Native view bridge from Flutter
 */
class YOLOPlatformView(
    private val context: Context,
    private val viewId: Int,
    creationParams: Map<String?, Any?>?,
    private val streamHandler: CustomStreamHandler,
    private val methodChannel: MethodChannel?,
    private val factory: YOLOPlatformViewFactory
) : PlatformView, MethodChannel.MethodCallHandler {

    private val yoloView: YOLOView = YOLOView(context)
    
    // Getter for external access to yoloView
    val yoloViewInstance: YOLOView
        get() = yoloView
    private val TAG = "YOLOPlatformView"
    
    // Track if we're actively streaming
    private val isStreaming = AtomicBoolean(false)
    
    // Store last event to resend after reconnection
    @Volatile
    private var lastStreamData: Map<String, Any>? = null
    
    // Initialization flag
    private var initialized = false
    
    // Unique ID to send to Flutter
    private val viewUniqueId: String
    
    // Retry handler for reconnection
    private val retryHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var retryRunnable: Runnable? = null

    // Latest-result slot for camera->Flutter delivery (perf review A2). The
    // camera thread drops each result here and returns immediately; a single
    // posted drain sends whatever is newest once the main thread is free. If
    // the UI is busy (photo save, settings rebuild) new results overwrite the
    // unsent one — dropping a stale detection frame is harmless, whereas the
    // old CountDownLatch.await(100 ms) stalled the camera thread and dropped
    // *camera* frames instead.
    private val pendingStreamData =
        java.util.concurrent.atomic.AtomicReference<Map<String, Any>?>(null)
    private val drainScheduled = AtomicBoolean(false)
    
    init {
        val dartViewIdParam = creationParams?.get("viewId")
        viewUniqueId = dartViewIdParam as? String ?: viewId.toString().also {
            Log.w(TAG, "YOLOPlatformView[$viewId init]: Using platform int viewId '$it' as fallback")
        }

        // Parse model path and task from creation params
        var modelPath = creationParams?.get("modelPath") as? String ?: "yolo26n"
        val taskString = creationParams?.get("task") as? String ?: "detect"
        val confidenceParam = creationParams?.get("confidenceThreshold") as? Double ?: 0.25
        val iouParam = creationParams?.get("iouThreshold") as? Double ?: 0.7

        // Parse lensFacing parameter
        val lensFacingParam = creationParams?.get("lensFacing") as? String ?: "back"
        val lensFacingValue = lensFacingParam.lowercase()
        val preferWideBackCamera = lensFacingValue == "backwide"
        val lensFacing = when (lensFacingValue) {
            "front" -> androidx.camera.core.CameraSelector.LENS_FACING_FRONT
            else -> androidx.camera.core.CameraSelector.LENS_FACING_BACK
        }

        // Set up the method channel handler
        methodChannel?.setMethodCallHandler(this)

        // Set initial thresholds
        yoloView.setConfidenceThreshold(confidenceParam)
        yoloView.setIouThreshold(iouParam)

        // Set lens facing before initializing camera
        yoloView.setLensFacing(lensFacing, preferWideBackCamera)

        // Configure YOLOView streaming functionality
        setupYOLOViewStreaming(creationParams)

        // Notify lifecycle FIRST before initializing camera
        // This ensures lifecycle owner is set before camera tries to start
        if (context is LifecycleOwner) {
            yoloView.onLifecycleOwnerAvailable(context)
            // initCamera will be called by onLifecycleOwnerAvailable if permissions are granted
            // But we also call it here as a fallback
            yoloView.initCamera()
        } else {
            Log.w(TAG, "Context is not a LifecycleOwner, camera may not start")
            // Still try to initialize camera - it will request permissions if needed
            yoloView.initCamera()
        }

        try {
            // Resolve model path
            modelPath = resolveModelPath(context, modelPath)
            val task = YOLOTask.valueOf(taskString.uppercase())

            // Set up model loading callback
            yoloView.setOnModelLoadCallback { success ->
                if (success) {
                    initialized = true
                    startStreaming()
                    val context = yoloView.context
                    val hasPermissions = android.Manifest.permission.CAMERA.let { permission ->
                        android.content.pm.PackageManager.PERMISSION_GRANTED == 
                        ContextCompat.checkSelfPermission(context, permission)
                    }
                    if (hasPermissions) {
                        yoloView.startCamera()
                    }
                } else {
                    initialized = true
                }
            }
            
            // Set up inference callback
            yoloView.setOnInferenceCallback { result ->
                // Callback for compatibility
            }
            
            // Load model
            val useGpu = creationParams?.get("useGpu") as? Boolean ?: true
            val cpuThreads = (creationParams?.get("cpuThreads") as? Number)?.toInt() ?: 0
            yoloView.setModel(modelPath, task, useGpu, cpuThreads)
            
        } catch (e: Exception) {
            Log.e(TAG, "Error initializing YOLOPlatformView", e)
        }
    }
    
    /**
     * Configure YOLOView streaming functionality with setState resilience
     */
    private fun setupYOLOViewStreaming(creationParams: Map<String?, Any?>?) {
        val streamingConfigParam = creationParams?.get("streamingConfig") as? Map<*, *>
        
        val streamConfig = if (streamingConfigParam != null) {
            YOLOStreamConfig(
                includeDetections = streamingConfigParam["includeDetections"] as? Boolean ?: true,
                includeClassifications = streamingConfigParam["includeClassifications"] as? Boolean ?: true,
                includeProcessingTimeMs = streamingConfigParam["includeProcessingTimeMs"] as? Boolean ?: true,
                includeFps = streamingConfigParam["includeFps"] as? Boolean ?: true,
                includeMasks = streamingConfigParam["includeMasks"] as? Boolean ?: false,
                includePoses = streamingConfigParam["includePoses"] as? Boolean ?: false,
                includeOBB = streamingConfigParam["includeOBB"] as? Boolean ?: false,
                includeOriginalImage = streamingConfigParam["includeOriginalImage"] as? Boolean ?: false,
                maxFPS = (streamingConfigParam["maxFPS"] as? Number)?.toInt(),
                throttleIntervalMs = (streamingConfigParam["throttleIntervalMs"] as? Number)?.toInt(),
                inferenceFrequency = (streamingConfigParam["inferenceFrequency"] as? Number)?.toInt(),
                skipFrames = (streamingConfigParam["skipFrames"] as? Number)?.toInt(),
                analysisWidth = (streamingConfigParam["analysisWidth"] as? Number)?.toInt(),
                analysisHeight = (streamingConfigParam["analysisHeight"] as? Number)?.toInt()
            )
        } else {
            // Create default config when no streaming config is provided
            // This ensures onResult callback receives detection data
            YOLOStreamConfig(
                includeDetections = true,
                includeClassifications = true,
                includeProcessingTimeMs = true,
                includeFps = true,
                includeMasks = false,
                includePoses = false,
                includeOBB = false,
                includeOriginalImage = false
            )
        }
        
        yoloView.setStreamConfig(streamConfig)

        // Set up streaming callback with resilience
        yoloView.setStreamCallback { streamData ->
            sendStreamDataWithRetry(streamData)
        }

        // Forward typed events (zoom/lens/focus) onto the same event sink so the Dart controller can route them via the
        // existing event channel.
        yoloView.setEventCallback { event ->
            sendEventOnMain(event)
        }
    }

    /**
     * Posts an event to the main thread and forwards it to the Flutter event sink.
     * Used for typed `{type:"zoom"|"lens"|"focus", ...}` events.
     */
    private fun sendEventOnMain(event: Map<String, Any>) {
        val send = Runnable {
            try {
                streamHandler.sink?.success(event)
            } catch (e: Exception) {
                Log.e(TAG, "Error sending typed event", e)
            }
        }
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            send.run()
        } else {
            retryHandler.post(send)
        }
    }
    
    /**
     * Send stream data with automatic retry on failure
     */
    private fun sendStreamDataWithRetry(streamData: Map<String, Any>) {
        try {
            // Store last data for potential resend
            lastStreamData = streamData
            
            // Cancel any pending retry
            retryRunnable?.let { retryHandler.removeCallbacks(it) }
            
            // Try to send data
            val sent = sendStreamData(streamData)
            
            if (!sent && isStreaming.get()) {
                // Schedule retry if sending failed
                scheduleRetry()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in sendStreamDataWithRetry", e)
            if (isStreaming.get()) {
                scheduleRetry()
            }
        }
    }
    
    /**
     * Attempt to send stream data
     */
    private fun sendStreamData(streamData: Map<String, Any>): Boolean {
        return try {
            val sink = streamHandler.sink
            
            if (sink != null) {
                // Send on main thread
                if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
                    sink.success(streamData)
                } else {
                    // Camera thread (perf review A2): fire-and-forget via the
                    // latest-result slot. The old code parked this thread on a
                    // CountDownLatch for up to 100 ms per frame whenever the UI
                    // was busy — and then ignored the latch result anyway.
                    pendingStreamData.set(streamData)
                    if (drainScheduled.compareAndSet(false, true)) {
                        retryHandler.post {
                            // Clear the flag BEFORE draining so a result that
                            // arrives mid-drain schedules a fresh drain instead
                            // of sitting in the slot until the next frame.
                            drainScheduled.set(false)
                            val data = pendingStreamData.getAndSet(null) ?: return@post
                            val liveSink = streamHandler.sink
                            if (liveSink == null) {
                                // Sink vanished between queueing and draining
                                // (channel teardown); the retry path resends
                                // lastStreamData once the channel is back.
                                Log.w(TAG, "Event sink is null at drain, will retry")
                                if (isStreaming.get()) scheduleRetry()
                                return@post
                            }
                            try {
                                liveSink.success(data)
                            } catch (e: Exception) {
                                Log.e(TAG, "Error sending stream data on main thread", e)
                            }
                        }
                    }
                }
                true
            } else {
                Log.w(TAG, "Event sink is null, will retry")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error sending stream data", e)
            false
        }
    }
    
    /**
     * Schedule a retry to resend data
     */
    private fun scheduleRetry() {
        retryRunnable?.let { retryHandler.removeCallbacks(it) }
        
        retryRunnable = Runnable {
            if (isStreaming.get()) {
                // Check if sink is available
                if (streamHandler.sink != null) {
                    // Resend last data if available
                    lastStreamData?.let { data ->
                        sendStreamData(data)
                    }
                } else {
                    // Request Flutter to recreate the event channel
                    methodChannel?.invokeMethod("recreateEventChannel", mapOf(
                        "viewId" to viewUniqueId,
                        "reason" to "sink_disconnected"
                    ))
                    
                    // Schedule another retry
                    scheduleRetry()
                }
            }
        }
        
        // Retry after 500ms
        retryHandler.postDelayed(retryRunnable!!, 500)
    }
    
    /**
     * Start streaming
     */
    private fun startStreaming() {
        if (isStreaming.compareAndSet(false, true)) {
            // Send initial test message to verify connection
            sendStreamData(mapOf(
                "test" to "Streaming started",
                "viewId" to viewUniqueId,
                "timestamp" to System.currentTimeMillis()
            ))
        }
    }

    /**
     * Stop streaming
     */
    private fun stopStreaming() {
        if (isStreaming.compareAndSet(true, false)) {
            retryRunnable?.let { retryHandler.removeCallbacks(it) }
            retryRunnable = null
            // Drop any result still parked in the latest-result slot so a
            // queued drain after stop sends nothing.
            pendingStreamData.set(null)
        }
    }
    
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setConfidenceThreshold" -> {
                    val threshold = call.argument<Double>("threshold")
                    if (threshold != null) {
                        yoloView.setConfidenceThreshold(threshold)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "threshold is required", null)
                    }
                }
                "setIoUThreshold", "setIouThreshold" -> {
                    val threshold = call.argument<Double>("threshold")
                    if (threshold != null) {
                        yoloView.setIouThreshold(threshold)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "threshold is required", null)
                    }
                }
                "setNumItemsThreshold" -> {
                    val numItems = call.argument<Int>("numItems")
                    if (numItems != null) {
                        yoloView.setNumItemsThreshold(numItems)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "numItems is required", null)
                    }
                }
                "setThresholds" -> {
                    val confidence = call.argument<Double>("confidenceThreshold")
                    val iou = call.argument<Double>("iouThreshold")
                    val numItems = call.argument<Int>("numItemsThreshold")
                    
                    confidence?.let { yoloView.setConfidenceThreshold(it) }
                    iou?.let { yoloView.setIouThreshold(it) }
                    numItems?.let { yoloView.setNumItemsThreshold(it) }
                    
                    result.success(null)
                }
                "setModel" -> {
                    var modelPath = call.argument<String>("modelPath")
                    val taskString = call.argument<String>("task")
                    val useGpu = call.argument<Boolean>("useGpu") ?: true
                    val cpuThreads = call.argument<Int>("cpuThreads") ?: 0

                    if (modelPath == null || taskString == null) {
                        result.error("invalid_args", "modelPath and task are required", null)
                        return
                    }

                    modelPath = resolveModelPath(context, modelPath)
                    val task = YOLOTask.valueOf(taskString.uppercase())

                    yoloView.setModel(modelPath, task, useGpu, cpuThreads) { success ->
                        if (success) {
                            result.success(null)
                        } else {
                            Log.e(TAG, "Failed to switch model")
                            result.error("MODEL_NOT_FOUND", "Failed to load model", null)
                        }
                    }
                }
                "switchCamera" -> {
                    yoloView.switchCamera()
                    result.success(null)
                }
                "setTorchMode" -> {
                    val enabled = call.argument<Boolean>("enabled")
                    if (enabled != null) {
                        // Return the actual resulting torch state so Dart caches the real hardware state.
                        result.success(yoloView.setTorchMode(enabled))
                    } else {
                        result.error("invalid_args", "enabled is required", null)
                    }
                }
                "setZoomLevel" -> {
                    val zoomLevel = call.argument<Double>("zoomLevel")
                    if (zoomLevel != null) {
                        yoloView.setZoomLevel(zoomLevel.toFloat())
                        result.success(null)
                    } else {
                        result.error("invalid_args", "zoomLevel is required", null)
                    }
                }
                "setStreamingConfig" -> {
                    // Parse streaming config from arguments
                    val configMap = call.arguments as? Map<*, *>
                    if (configMap != null) {
                        val streamConfig = YOLOStreamConfig(
                            includeDetections = configMap["includeDetections"] as? Boolean ?: true,
                            includeClassifications = configMap["includeClassifications"] as? Boolean ?: true,
                            includeProcessingTimeMs = configMap["includeProcessingTimeMs"] as? Boolean ?: true,
                            includeFps = configMap["includeFps"] as? Boolean ?: true,
                            includeMasks = configMap["includeMasks"] as? Boolean ?: false,
                            includePoses = configMap["includePoses"] as? Boolean ?: false,
                            includeOBB = configMap["includeOBB"] as? Boolean ?: false,
                            includeOriginalImage = configMap["includeOriginalImage"] as? Boolean ?: false,
                            maxFPS = (configMap["maxFPS"] as? Number)?.toInt(),
                            throttleIntervalMs = (configMap["throttleIntervalMs"] as? Number)?.toInt(),
                            inferenceFrequency = (configMap["inferenceFrequency"] as? Number)?.toInt(),
                            skipFrames = (configMap["skipFrames"] as? Number)?.toInt(),
                            analysisWidth = (configMap["analysisWidth"] as? Number)?.toInt(),
                            analysisHeight = (configMap["analysisHeight"] as? Number)?.toInt()
                        )
                        yoloView.setStreamConfig(streamConfig)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "Invalid streaming config", null)
                    }
                }
                "setShowOverlays" -> {
                    val visible = call.argument<Boolean>("visible")
                    if (visible != null) {
                        yoloView.setShowOverlays(visible)
                        result.success(null)
                    } else {
                        result.error("invalid_args", "visible is required", null)
                    }
                }
                "stop" -> {
                    yoloView.stop()
                    result.success(null)
                }
                "restartCamera" -> {
                    yoloView.startCamera()
                    result.success(null)
                }
                // pause/resume mirror the iOS paused-frame semantics. Android doesn't snapshot a share frame on pause
                // (capturePhoto takes an ImageCapture still, falling back to the preview snapshot). pause only unbinds
                // the camera use-cases; it must NOT
                // call stop(), which closes the predictor and would make resume()'s startCamera() a no-op (it early-
                // returns while predictor == null).
                "pause" -> {
                    yoloView.pauseCamera()
                    result.success(null)
                }
                "resume" -> {
                    yoloView.startCamera()
                    result.success(null)
                }
                "captureFrame" -> {
                    val imageData = yoloView.captureFrame()
                    if (imageData != null) {
                        result.success(imageData)
                    } else {
                        result.error("capture_failed", "Failed to capture frame", null)
                    }
                }
                "reconnectStream" -> {
                    // Handle reconnection request from Flutter
                    startStreaming()
                    result.success(null)
                }
                "getAvailableLenses" -> {
                    val lenses = yoloView.enumerateLenses()
                    val payload = lenses.map { lens ->
                        mapOf<String, Any>(
                            "zoomFactor" to lens.zoomFactor,
                            "label" to lens.label
                        )
                    }
                    result.success(payload)
                }
                "getCameraDiagnostics" -> {
                    // Pollinator Monitor: per-camera/lens info for the "which lenses can this
                    // app actually use?" diagnostic dialog (id, facing, focal length, physical
                    // vs logical, usable-for-inference verdict + reason, analysis sizes).
                    result.success(yoloView.cameraDiagnostics())
                }
                "setLens" -> {
                    val zoomFactor = call.argument<Double>("zoomFactor")
                    if (zoomFactor == null) {
                        result.error("invalid_args", "zoomFactor is required", null)
                    } else {
                        yoloView.setLens(zoomFactor)
                        result.success(null)
                    }
                }
                "tapToFocus" -> {
                    val x = call.argument<Double>("x")
                    val y = call.argument<Double>("y")
                    if (x == null || y == null) {
                        result.error("invalid_args", "x and y are required", null)
                    } else {
                        yoloView.tapToFocus(x, y)
                        result.success(null)
                    }
                }
                "setManualFocus" -> {
                    // Pollinator Monitor: lock focus at a 0..1 distance (0 = far/infinity, 1 = near).
                    val value = call.argument<Double>("value")
                    if (value == null) {
                        result.error("invalid_args", "value is required", null)
                    } else {
                        yoloView.setManualFocus(value)
                        result.success(null)
                    }
                }
                "setAutoFocus" -> {
                    yoloView.setAutoFocus()
                    result.success(null)
                }
                "getMinFocusDistance" -> {
                    // Largest focusing distance in dioptres; 0 means the lens is fixed-focus.
                    result.success(yoloView.minimumFocusDistanceDioptres().toDouble())
                }
                "capturePhoto" -> {
                    val withOverlays = call.argument<Boolean>("withOverlays") ?: true
                    yoloView.capturePhoto(withOverlays) { bytes ->
                        if (bytes != null) {
                            result.success(bytes)
                        } else {
                            result.error("capture_failed", "Failed to capture photo", null)
                        }
                    }
                }
                "capturePhotoRaw" -> {
                    // Pollinator Monitor (round 63): the still exactly as delivered —
                    // unrotated JPEG + rotation/mirror info — so the caller can crop
                    // first and rotate only the small square (the still-lag fix).
                    yoloView.capturePhotoRaw { map ->
                        if (map != null) {
                            result.success(map)
                        } else {
                            result.error("capture_failed", "Failed to capture raw photo", null)
                        }
                    }
                }
                "setInferenceRoi" -> {
                    // Pollinator Monitor: crop inference to a square ROI. Pass side <= 0 to clear.
                    val cx = call.argument<Double>("cx") ?: 0.5
                    val cy = call.argument<Double>("cy") ?: 0.5
                    val side = call.argument<Double>("side") ?: 0.0
                    yoloView.setInferenceRoi(cx, cy, side)
                    result.success(null)
                }
                "setMotionGate" -> {
                    // Pollinator Monitor: skip inference while nothing moves in the ROI
                    // (see MotionGate). Saves heat/battery during empty-flower periods.
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val pixelDelta = call.argument<Int>("pixelDelta") ?: 25
                    val areaFraction = call.argument<Double>("areaFraction") ?: 0.005
                    val wakeSeconds = call.argument<Double>("wakeSeconds") ?: 3.0
                    val gridSize = call.argument<Int>("gridSize") ?: MotionGate.DEFAULT_GRID
                    val idleFps = call.argument<Int>("idleFps") ?: 5
                    // Motion-only capture mode: photos on ROI motion, detector never
                    // runs. Optional — absent from older Dart callers.
                    val motionOnly = call.argument<Boolean>("motionOnly") ?: false
                    yoloView.setMotionGate(enabled, pixelDelta, areaFraction, wakeSeconds, gridSize, idleFps, motionOnly)
                    result.success(null)
                }
                "setTimeLapse" -> {
                    // Pollinator Monitor (round 97): time-lapse capture — no detector,
                    // no motion gate; Dart drives photos on a timer. sampleFps controls
                    // how many frames/s are converted (frame-cache freshness).
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val sampleFps = call.argument<Int>("sampleFps") ?: 1
                    yoloView.setTimeLapse(enabled, sampleFps)
                    result.success(null)
                }
                "setCameraFpsCap" -> {
                    // Pollinator Monitor (round 82): slow the camera hardware itself (sensor/ISP),
                    // not just inference. 0 = device default. See YOLOView.setCameraFpsCap.
                    yoloView.setCameraFpsCap(call.argument<Int>("maxFps") ?: 0)
                    result.success(null)
                }
                "setPreviewEnabled" -> {
                    // Pollinator Monitor (round 82): detach/reattach only the preview stream while
                    // detection + capture keep running (real power-save behind the black cover).
                    yoloView.setPreviewEnabled(call.argument<Boolean>("enabled") ?: true)
                    result.success(null)
                }
                "getStreamResolutions" -> {
                    result.success(yoloView.supportedStreamResolutions())
                }
                "getAnalysisStreamCeiling" -> {
                    // Pollinator Monitor: estimated max size CameraX ImageAnalysis can actually
                    // stream on this device (+ hardware level), so the UI stops over-promising.
                    result.success(yoloView.analysisStreamCeiling())
                }
                "captureRoiFromFrame" -> {
                    // Pollinator Monitor: crop the ROI from the live analysis frame (no
                    // full-res still capture, so the camera pipeline isn't stalled).
                    val cx = call.argument<Double>("cx") ?: 0.5
                    val cy = call.argument<Double>("cy") ?: 0.5
                    val side = call.argument<Double>("side") ?: 0.5
                    val quality = call.argument<Int>("quality") ?: 90
                    val maxPx = call.argument<Int>("maxPx") ?: 0
                    val bytes = yoloView.captureRoiFromFrame(cx, cy, side, quality, maxPx)
                    if (bytes != null) result.success(bytes)
                    else result.error("no_frame", "No analysis frame available yet", null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling method call: ${call.method}", e)
            result.error("method_call_error", e.message, null)
        }
    }
    
    override fun getView(): View {
        return yoloView
    }
    
    override fun dispose() {
        stopStreaming()

        try {
            yoloView.stop()
            // Detach from the lifecycle so the Activity doesn't retain this disposed view (and won't fire
            // onStart/onResume into it after disposal).
            yoloView.detachLifecycle()
            // Clear callbacks by setting them to empty implementations
            yoloView.setStreamCallback { }
            yoloView.setOnInferenceCallback { }
            yoloView.setOnModelLoadCallback { }
            yoloView.setEventCallback(null)
        } catch (e: Exception) {
            Log.e(TAG, "Error during disposal", e)
        }

        methodChannel?.setMethodCallHandler(null)
        factory.onPlatformViewDisposed(viewId)
    }
    
    private fun resolveModelPath(context: Context, modelPath: String): String {
        return when {
            modelPath.startsWith("/") -> modelPath
            modelPath.startsWith("internal://") -> {
                val filename = modelPath.removePrefix("internal://")
                context.filesDir.resolve(filename).absolutePath
            }
            else -> modelPath
        }
    }
}
