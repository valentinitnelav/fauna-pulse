// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.util.Log
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.TensorBuffer
import com.google.ai.edge.litert.TensorType

/**
 * Wraps a LiteRT 2.x [CompiledModel] behind a simple float-in / float-out API so the predictors don't deal with
 * [TensorBuffer]s or the accelerator framework directly.
 *
 * Accelerator ladder: GPU first (the CL/GL accelerator bundled with `litert`; profiled at ~4.7ms/inf for a non-end2end
 * fp16 YOLO26 on a Galaxy S26 GPU vs ~29ms CPU), falling back to CPU when the GPU can't compile the model. Whether it
 * can is a per-graph property (some end2end/custom exports fail), NOT a dtype rule - int8 models can compile and run
 * on GPU (verified: arthropod_yolov11_int8, session_120). Unlike the old `Interpreter`+`GpuDelegate`, `CompiledModel` compiles the whole graph for one
 * accelerator, so a model either runs fully on GPU or fully on CPU - no per-op fragmentation.
 *
 * Tensor names follow the Ultralytics tflite export conventions (round 155): legacy onnx2tf exports use input
 * `images` and outputs `Identity`, `Identity_1`, ...; litert-torch (`format=litert`) exports use input `args_0`
 * and outputs `output_0`, `output_1`, .... The input layout is detected from the input tensor shape: legacy
 * exports are NHWC `[1,H,W,3]`, litert-torch exports are NCHW `[1,3,H,W]`. [inputDims] is always reported in
 * the NHWC convention so predictors stay layout-agnostic; [inputUsesNchw] tells them when to write CHW planes.
 */
class LiteRtModel(
    private val context: android.content.Context,
    modelPath: String,
    useGpu: Boolean,
    private val tag: String,
    // CPU inference threads. 0 = leave it to the runtime's default. LiteRT's CPU backend is
    // XNNPACK (a library of hand-optimized CPU kernels that TFLite/LiteRT uses automatically);
    // this only tunes how many threads those kernels may spread across. More threads can be
    // faster but also draws more power/heat - benchmark before changing (see benchmarkAccelerators).
    private val cpuThreads: Int = 0,
) : InferenceModel {
    private data class PreparedModel(
        val model: CompiledModel,
        val inputBuffers: List<TensorBuffer>,
        val outputBuffers: List<TensorBuffer>,
        val inputDims: IntArray,
        val nchw: Boolean,
        val outputElementCounts: IntArray,
        val outputDims: List<IntArray>,
        val outputTypes: List<TensorType.ElementType?>,
    )

    private val model: CompiledModel
    private val inputBuffers: List<TensorBuffer>
    private val outputBuffers: List<TensorBuffer>
    private val outputTypes: List<TensorType.ElementType?>

    /** Accelerator actually in use after the ladder resolves: "GPU" or "CPU". */
    override val accelerator: String

    /** Input tensor dimensions in NHWC convention, e.g. [1, 640, 640, 3], regardless of the model's native
     *  layout (NCHW litert-torch shapes are reported transposed). Empty if the shape can't be read by any
     *  known input name or from the TFLite graph. */
    override val inputDims: IntArray

    /** True when the model input is NCHW `[1,3,H,W]` (litert-torch / `format=litert`) rather than NHWC
     *  `[1,H,W,3]` (legacy onnx2tf). Preprocessing writes CHW planes when set (round 155). */
    override val inputUsesNchw: Boolean

    /** Float element count of each output buffer, in order. */
    override val outputElementCounts: IntArray

    /** Output tensor dimensions, in order (e.g. [[1, 84, 8400]] for detect). Empty entries if a name doesn't resolve. */
    override val outputDims: List<IntArray>

    init {
        var prepared: PreparedModel? = null
        var acc = "CPU"
        // Crash-guard for GPU model compilation. Compiling a model for the GPU writes a serialized
        // "program cache" to disk so later launches start fast (see prepareModel). Two things can
        // make the NEXT launch crash HARD inside the native GPU library - a crash Kotlin's try/catch
        // below cannot catch, because it kills the whole process:
        //   (1) the app is killed *during* that first compile, leaving a half-written cache;
        //   (2) the model's graph itself makes the GPU backend crash on compile (some custom/odd
        //       exports do this on some GPUs).
        // To recover automatically we drop a tiny marker file - holding THIS model's key - just
        // before compiling, and delete it right after success. If we find that marker still present
        // at startup, the previous GPU compile didn't finish, so we wipe the (possibly corrupt)
        // cache and count a "failure" for that model's key. Only after the SECOND failure of the
        // same model do we add it to an on-disk "GPU blocklist" (CPU from then on). The 2-strike
        // rule matters because the marker can also be left behind by a benign kill - the OS
        // reclaiming memory, or the user force-stopping the app mid-compile - which is NOT a real
        // crash; demoting a good model to CPU forever after one such kill would be a silent, hard-
        // to-diagnose slowdown. A genuinely GPU-incompatible model (e.g. an odd custom export) will
        // fail twice and then stick to CPU, while every healthy model keeps the GPU. A successful
        // GPU compile resets that model's failure count.
        val gpuCacheDir = java.io.File(context.codeCacheDir, "litert_gpu")
        val gpuCompileMarker = java.io.File(context.codeCacheDir, "litert_gpu_compiling.lock")
        val blocklistFile = java.io.File(context.filesDir, "litert_gpu_blocklist.txt")
        val failCountFile = java.io.File(context.filesDir, "litert_gpu_failcounts.txt")
        val modelKey = "${java.io.File(modelPath).name}_${java.io.File(modelPath).length()}"
        val blocked = readBlocklist(blocklistFile)
        val failCounts = readFailCounts(failCountFile)

        if (gpuCompileMarker.exists()) {
            val crashedKey = runCatching { gpuCompileMarker.readText().trim() }.getOrNull().orEmpty()
            Log.w(tag, "Previous GPU compile did not finish for key='$crashedKey'; clearing GPU cache.")
            runCatching { gpuCacheDir.deleteRecursively() }
            runCatching { gpuCompileMarker.delete() }
            if (crashedKey.isNotEmpty()) {
                val count = (failCounts[crashedKey] ?: 0) + 1
                failCounts[crashedKey] = count
                if (count >= 2 && blocked.add(crashedKey)) {
                    runCatching { blocklistFile.appendText("$crashedKey\n") }
                    Log.w(tag, "Key '$crashedKey' failed GPU compile $count times; blocklisting (CPU from now on).")
                }
                writeFailCounts(failCountFile, failCounts)
            }
        }

        val allowGpu = useGpu && modelKey !in blocked
        if (useGpu && !allowGpu) {
            Log.i(tag, "Model '$modelKey' is on the GPU blocklist; loading on CPU.")
        }
        if (allowGpu) {
            try {
                runCatching { gpuCacheDir.mkdirs() }
                runCatching { gpuCompileMarker.writeText(modelKey) }
                prepared = prepareModel(modelPath, Accelerator.GPU, gpuCacheDir)
                acc = "GPU"
                runCatching { gpuCompileMarker.delete() }
                // Success: forget any earlier failures for this model.
                if (failCounts.remove(modelKey) != null) {
                    writeFailCounts(failCountFile, failCounts)
                }
            } catch (e: Throwable) {
                runCatching { gpuCompileMarker.delete() }
                Log.w(tag, "GPU accelerator could not run model, falling back to CPU: ${e.message}")
            }
        }
        if (prepared == null) {
            prepared = prepareModel(modelPath, Accelerator.CPU, gpuCacheDir)
            acc = "CPU"
        }
        model = prepared.model
        accelerator = acc

        inputBuffers = prepared.inputBuffers
        outputBuffers = prepared.outputBuffers
        inputDims = prepared.inputDims
        inputUsesNchw = prepared.nchw
        outputElementCounts = prepared.outputElementCounts
        outputDims = prepared.outputDims
        outputTypes = prepared.outputTypes

        Log.i(
            tag,
            "LiteRT compiled on $acc; inputDims=${inputDims.toList()} " +
                "layout=${if (inputUsesNchw) "NCHW" else "NHWC"} " +
                "outputDims=${outputDims.map { it.toList() }} outputCounts=${outputElementCounts.toList()}",
        )
    }

    /** Read the set of model keys known to crash the GPU backend (one per line); empty if absent. */
    private fun readBlocklist(file: java.io.File): MutableSet<String> =
        runCatching {
            if (file.exists()) file.readLines().map { it.trim() }.filter { it.isNotEmpty() }.toMutableSet()
            else mutableSetOf()
        }.getOrDefault(mutableSetOf())

    /** Read per-model GPU-compile failure counts, stored one "key\tcount" per line. */
    private fun readFailCounts(file: java.io.File): MutableMap<String, Int> =
        runCatching {
            val map = mutableMapOf<String, Int>()
            if (file.exists()) {
                for (line in file.readLines()) {
                    val tab = line.lastIndexOf('\t')
                    if (tab <= 0) continue
                    val key = line.substring(0, tab)
                    val count = line.substring(tab + 1).trim().toIntOrNull() ?: continue
                    map[key] = count
                }
            }
            map
        }.getOrDefault(mutableMapOf())

    private fun writeFailCounts(file: java.io.File, counts: Map<String, Int>) {
        runCatching {
            file.writeText(counts.entries.joinToString("\n") { "${it.key}\t${it.value}" })
        }
    }

    private fun prepareModel(modelPath: String, accelerator: Accelerator, gpuCacheDir: java.io.File): PreparedModel {
        val options = CompiledModel.Options(accelerator)
        if (accelerator == Accelerator.CPU && cpuThreads > 0) {
            // litert 2.1.5 exposes numThreads / xnnPackFlags / xnnPackWeightCachePath. Only
            // numThreads is set here: flags are exotic, and the weight cache is deliberately
            // skipped - a cache file corrupted by a mid-write kill would be read back by
            // native code on the next launch, and unlike the GPU program cache above there
            // is no crash-guard around it yet.
            options.cpuOptions = CompiledModel.CpuOptions(numThreads = cpuThreads)
        }
        if (accelerator == Accelerator.GPU) {
            // Serialize compiled GPU programs so subsequent model opens skip CL compilation entirely.
            // Kept in a dedicated sub-directory so the crash-guard above can wipe just this cache.
            options.gpuOptions = CompiledModel.GpuOptions(
                serializationDir = gpuCacheDir.absolutePath,
                modelCacheKey = "${java.io.File(modelPath).name}_${java.io.File(modelPath).length()}",
                serializeProgramCache = true,
            )
        }
        val compiled = CompiledModel.create(modelPath, options)
        val inputs: List<TensorBuffer>
        val outputs: List<TensorBuffer>
        try {
            inputs = compiled.createInputBuffers()
            outputs = compiled.createOutputBuffers()
        } catch (e: Throwable) {
            runCatching { compiled.close() }
            throw e
        }

        try {
            // Round 155: read the input shape by name. Legacy onnx2tf exports name the input `images`;
            // litert-torch (format=litert) exports name it `args_0`. Custom (non-Ultralytics) TFLite models
            // may use other signature input names, so a few common ones are probed too — litert 2.1.5
            // exposes the input shape only by name (no by-index lookup).
            var nativeDims = sequenceOf("images", "args_0", "input", "input_1", "serving_default_input")
                .firstNotNullOfOrNull { name ->
                    try {
                        compiled.getInputTensorType(inputName = name).layout?.dimensions?.toIntArray()
                            ?.takeIf { it.isNotEmpty() }
                    } catch (_: Throwable) {
                        null
                    }
                } ?: IntArray(0)
            // Fallback for models whose input tensor matches none of the names above: read the shape from
            // the TFLite graph by index (kept over upstream's buffer-size square guess — the graph shape is
            // exact). Without this, dims stays empty and the predictor falls back to a 640 input — which
            // overflows a model whose real input is a different size, throwing on every frame (0 FPS,
            // endless "Calibrating").
            if (nativeDims.size < 4) {
                YOLOFileUtils.inputTensorShapeFromPath(modelPath)?.let { graphDims ->
                    if (graphDims.size == 4) {
                        Log.i(tag, "Input dims via TFLite graph (input name not recognized): ${graphDims.toList()}")
                        nativeDims = graphDims
                    }
                }
            }
            // litert-torch exports are NCHW [1,3,H,W]; legacy onnx2tf exports are NHWC [1,H,W,3]. Detect
            // from the shape — the graph fallback above must pass through this test too, it returns the
            // native layout — and report NHWC-convention dims so predictors stay layout-agnostic.
            val nchw = nativeDims.size >= 4 && nativeDims[1] == 3 && nativeDims.last() != 3
            val dims = if (nchw) intArrayOf(nativeDims[0], nativeDims[2], nativeDims[3], 3) else nativeDims

            // Warm up once with a zeroed input to (a) prime the accelerator and (b) learn each output's element count,
            // which the predictors use to reshape the flat float outputs. Keep this inside the accelerator fallback
            // path: some GPU drivers compile successfully but fail on first run.
            val inputFloats = if (dims.isNotEmpty()) dims.fold(1) { a, b -> a * b } else 0
            if (inputFloats > 0) {
                inputs[0].writeFloat(FloatArray(inputFloats))
                compiled.run(inputs, outputs)
            }
            val outputTensorTypes = List(outputs.size) { i ->
                // litert-torch (format=litert) names signature outputs output_0, output_1, …; legacy onnx2tf
                // exports name them Identity, Identity_1, …. Try both so the output shape resolves for either
                // export; a miss leaves that outputDims entry empty (detect falls back to the element count).
                val legacyName = if (i == 0) "Identity" else "Identity_$i"
                sequenceOf("output_$i", legacyName).firstNotNullOfOrNull { name ->
                    try {
                        compiled.getOutputTensorType(outputName = name)
                    } catch (_: Throwable) {
                        null // also thrown for element types the Kotlin API can't read (e.g. uint8)
                    }
                }
            }
            val outputShapes = outputTensorTypes.map { it?.layout?.dimensions?.toIntArray() ?: IntArray(0) }
            val types = outputTensorTypes.map { it?.elementType }
            val elementCounts = IntArray(outputs.size) { readAsFloats(outputs[it], types[it]).size }
            return PreparedModel(compiled, inputs, outputs, dims, nchw, elementCounts, outputShapes, types)
        } catch (e: Throwable) {
            closeBuffers(inputs, outputs)
            runCatching { compiled.close() }
            throw e
        }
    }

    /**
     * Run inference: write [input] floats into the first input buffer, run, and return each output as a flat
     * float array. Integer outputs are returned in reused per-output arrays that are only valid until the next
     * run() — the same contract as [OrtQnnModel].
     */
    override fun run(input: FloatArray): List<FloatArray> {
        inputBuffers[0].writeFloat(input)
        model.run(inputBuffers, outputBuffers)
        return List(outputBuffers.size) { readAsFloats(outputBuffers[it], outputTypes[it], reuseIndex = it) }
    }

    // Reused widening targets, one per output (perf review A3): without these, an integer
    // output would allocate a fresh FloatArray every inference. Float outputs (all official
    // assets) CANNOT reuse a buffer — LiteRT 2.x TensorBuffer only exposes readFloat():
    // FloatArray, which allocates a new array inside the runtime on every call (verified
    // against litert 2.1.5; no read-into-existing-array variant like ONNX Runtime's).
    // Revisit if the API grows one.
    private var widenTargets = arrayOfNulls<FloatArray>(0)

    private fun widenTarget(index: Int, size: Int): FloatArray {
        if (index < 0) return FloatArray(size) // model-load probe: reuse not needed
        if (widenTargets.size <= index) widenTargets = widenTargets.copyOf(index + 1)
        widenTargets[index]?.takeIf { it.size == size }?.let { return it }
        return FloatArray(size).also { widenTargets[index] = it }
    }

    /**
     * Read a tensor buffer as floats; integer outputs (e.g. semantic class maps) are widened, into a reused
     * per-output target when [reuseIndex] >= 0. Dispatch on the declared element type - the native read
     * functions don't type-check, so a mistyped read corrupts memory.
     */
    private fun readAsFloats(buffer: TensorBuffer, type: TensorType.ElementType?, reuseIndex: Int = -1): FloatArray = when (type) {
        TensorType.ElementType.INT -> buffer.readInt().let { v ->
            widenTarget(reuseIndex, v.size).also { t -> for (i in v.indices) t[i] = v[i].toFloat() }
        }
        TensorType.ElementType.INT8 -> buffer.readInt8().let { v -> widenToFloats(v, widenTarget(reuseIndex, v.size)) }
        TensorType.ElementType.INT64 -> buffer.readLong().let { v ->
            widenTarget(reuseIndex, v.size).also { t -> for (i in v.indices) t[i] = v[i].toFloat() }
        }
        else -> buffer.readFloat() // FLOAT, or null when the type can't be read (all official assets are float)
    }

    override fun close() {
        closeBuffers(inputBuffers, outputBuffers)
        try {
            model.close()
        } catch (_: Throwable) {
            // best-effort
        }
    }

    private fun closeBuffers(inputs: List<TensorBuffer>, outputs: List<TensorBuffer>) {
        for (buffer in inputs) {
            try {
                buffer.close()
            } catch (_: Throwable) {
                // best-effort
            }
        }
        for (buffer in outputs) {
            try {
                buffer.close()
            } catch (_: Throwable) {
                // best-effort
            }
        }
    }
}
