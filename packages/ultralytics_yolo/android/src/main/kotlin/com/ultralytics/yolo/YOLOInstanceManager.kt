// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Manages multiple YOLO instances with unique IDs
 */
object YOLOInstanceManager {
    private const val TAG = "YOLOInstanceManager"

    // Singleton access
    val shared: YOLOInstanceManager = this

    // Store YOLO instances by their ID. Concurrent maps (round 161, perf review E2): dispose()
    // closes instances on an IO dispatcher while predict/load run on the platform thread.
    private val instances = ConcurrentHashMap<String, YOLO>()

    // Store loading states to prevent multiple concurrent loads
    private val loadingStates = ConcurrentHashMap<String, Boolean>()

    // Store classifier options per instance
    private val instanceOptions = ConcurrentHashMap<String, Map<String, Any>>()

    init {
        // Initialize default instance for backward compatibility
        createInstance("default")
    }

    /**
     * Creates a new instance placeholder
     */
    fun createInstance(instanceId: String) {
        // Just register the ID, actual YOLO instance created on load
        loadingStates[instanceId] = false
    }

    /**
     * Gets a YOLO instance by ID
     */
    fun getInstance(instanceId: String): YOLO? {
        return instances[instanceId]
    }

    /**
     * Loads a model for a specific instance (overload without useGpu for backward compatibility)
     */
    fun loadModel(
        instanceId: String,
        context: Context,
        modelPath: String,
        task: YOLOTask,
        callback: (Result<Unit>) -> Unit
    ) {
        // Call the main implementation with default useGpu = true
        loadModel(
            instanceId = instanceId,
            context = context,
            modelPath = modelPath,
            task = task,
            useGpu = true,
            classifierOptions = null,
            callback = callback
        )
    }

    /**
     * Loads a model for a specific instance with GPU control and classifier options
     */
    fun loadModel(
        instanceId: String,
        context: Context,
        modelPath: String,
        task: YOLOTask,
        useGpu: Boolean = true,
        numItemsThreshold: Int = 30,
        classifierOptions: Map<String, Any>?,
        callback: (Result<Unit>) -> Unit
    ) {
        // Check if already loaded
        if (instances[instanceId] != null) {
            callback(Result.success(Unit))
            return
        }

        // Check if loading
        if (loadingStates[instanceId] == true) {
            Log.w(TAG, "Model is already loading for instance: $instanceId")
            callback(Result.failure(Exception("Model is already loading")))
            return
        }

        // Start loading
        loadingStates[instanceId] = true

        try {
            // Store classifier options if provided
            classifierOptions?.let { options ->
                instanceOptions[instanceId] = options
            }

            // Create YOLO instance with the specified parameters
            val yolo = YOLO(context, modelPath, task, emptyList(), useGpu, numItemsThreshold, classifierOptions)
            instances[instanceId] = yolo
            loadingStates[instanceId] = false
            callback(Result.success(Unit))
        } catch (e: Exception) {
            loadingStates[instanceId] = false
            instanceOptions.remove(instanceId) // Clean up options on failure
            Log.e(TAG, "Failed to load model for instance $instanceId: ${e.message}")
            callback(Result.failure(e))
        }
    }

    /**
     * Runs inference on a specific instance
     */
    fun predict(
        instanceId: String,
        bitmap: Bitmap,
        confidenceThreshold: Float? = null,
        iouThreshold: Float? = null,
        // FaunaPulse (round 156, perf review D3): false skips the annotated-image render.
        generateAnnotatedImage: Boolean = true
    ): YOLOResult? {
        val yolo = instances[instanceId] ?: run {
            Log.e(TAG, "No model loaded for instance: $instanceId")
            return null
        }

        // Round 161 (perf review E2): synchronized(yolo) makes the temporary-threshold window and the
        // predict atomic against a concurrent close() (same monitor as YOLO's @Synchronized methods),
        // and the finally block restores thresholds on EVERY exit path, including non-Exception
        // Throwables that the old try/catch pair missed. A predict on an already-closed instance
        // throws IllegalStateException from the predictor guard and lands in the catch -> null.
        return synchronized(yolo) {
            val originalConfThreshold = yolo.getConfidenceThreshold()
            val originalIouThreshold = yolo.getIouThreshold()
            confidenceThreshold?.let { yolo.setConfidenceThreshold(it) }
            iouThreshold?.let { yolo.setIouThreshold(it) }
            try {
                yolo.predict(bitmap, generateAnnotatedImage = generateAnnotatedImage)
            } catch (e: Exception) {
                Log.e(TAG, "Prediction failed for instance $instanceId: ${e.message}")
                null
            } finally {
                yolo.setConfidenceThreshold(originalConfThreshold)
                yolo.setIouThreshold(originalIouThreshold)
            }
        }
    }

    fun predictorInstance(instanceId: String){
        instances[instanceId]?.let { yolo ->
            yolo.predictorInstance();
        }
    }

    /**
     * Disposes a specific instance. Round 161 (perf review E2, ported from upstream 0.6.11): the
     * instance is removed from the maps FIRST (no new caller can reach it), then its native model is
     * released on the IO dispatcher — YOLO.close() may briefly block on an in-flight predict, and
     * that wait must not happen on the platform thread. Pre-r161 this method silently leaked the
     * native interpreter (an empty try block noting "YOLO class doesn't have a close() method").
     */
    suspend fun dispose(instanceId: String) {
        loadingStates.remove(instanceId)
        instanceOptions.remove(instanceId)
        val yolo = instances.remove(instanceId) ?: return
        withContext(Dispatchers.IO) { yolo.close() }
    }

    /**
     * Disposes all instances (engine detach). Non-suspend on purpose: the caller is the plugin's
     * onDetachedFromEngine, which has no scope left after cancel() — the closes are handed straight
     * to the IO dispatcher.
     */
    fun disposeAll() {
        loadingStates.clear()
        instanceOptions.clear()
        val all = instances.values.toList()
        instances.clear()
        if (all.isNotEmpty()) {
            Dispatchers.IO.dispatch(EmptyCoroutineContext) {
                all.forEach { yolo ->
                    try {
                        yolo.close()
                    } catch (e: Exception) {
                        Log.e(TAG, "Error closing instance during disposeAll: ${e.message}")
                    }
                }
            }
        }
    }

    /**
     * Checks if an instance exists
     */
    fun hasInstance(instanceId: String): Boolean {
        return instances.containsKey(instanceId)
    }

    /**
     * Gets all active instance IDs
     */
    fun getActiveInstanceIds(): List<String> {
        return instances.keys.toList()
    }

    /**
     * Gets classifier options for a specific instance
     */
    fun getClassifierOptions(instanceId: String): Map<String, Any>? {
        return instanceOptions[instanceId]
    }

    /**
     * Clears all instances
     */
    fun clearAll() {
        disposeAll()
    }
}