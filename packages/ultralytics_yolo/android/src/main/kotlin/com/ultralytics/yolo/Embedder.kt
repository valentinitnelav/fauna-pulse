// FaunaPulse (round 208): image-embedding model wrapper for on-device identification.
//
// An "embedder" turns one image into a fixed-length vector (an "embedding", e.g. 768
// numbers for BioCLIP 2). Unlike the detectors, it returns no boxes and no classes: the
// Dart side compares the vector against a label pack of name embeddings. The model file
// is a TFLite export made by tool/bioclip_export/export_image_tower.py, which bakes the
// colour normalisation into the graph, so this class feeds plain RGB in 0..1 and only
// has to (a) lay the pixels out the way the model wants (HWC or CHW, see
// InferenceModel.inputUsesNchw) and (b) L2-normalise the output defensively.
//
// Reuses InferenceModel.create, so the GPU-first / CPU-fallback ladder, the GPU crash
// blocklist and the CPU thread option of LiteRtModel apply unchanged.
//
// GPU check (round 242): GPUs differ between phones and Android versions, and a GPU can
// compile a model yet compute it with too little precision. The first time a model runs
// on this phone's GPU, one fixed test picture is embedded on the GPU and on the CPU; the
// GPU is kept only when the two embeddings agree (cosine >= [GPU_MIN_AGREEMENT]). The
// verdict is remembered per model file and Android build (a system update, which usually
// brings new GPU drivers, checks again), so later loads cost nothing.

package com.ultralytics.yolo

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import kotlin.math.sin
import kotlin.math.sqrt

class Embedder(
    context: Context,
    modelPath: String,
    useGpu: Boolean,
    cpuThreads: Int = 0,
) {
    companion object {
        private const val TAG = "Embedder"

        /** Lowest GPU/CPU agreement (cosine of the two embeddings of the test picture) that keeps
         *  the GPU. The GPU's 16-bit maths against the CPU's 32-bit gave 0.9995 on the test phone
         *  (round 242; real crops 0.994 to 0.997, same answers); a broken or too imprecise GPU path
         *  lands far below. (32-bit GPU maths needs ~1.2 GB of GPU memory for BioCLIP 2: Android
         *  killed the app on the 7.4 GB test phone.) */
        const val GPU_MIN_AGREEMENT = 0.995
    }

    private var rt: InferenceModel = InferenceModel.create(context, modelPath, useGpu, "Embedder", cpuThreads)

    /** Cosine of the GPU and CPU embeddings of the test picture, when the GPU check ran or
     *  was remembered; null when the model runs on the CPU without a GPU verdict. */
    var gpuAgreement: Double? = null
        private set
    private var checkNote: String? = null

    /** Model input size (square models only are expected; both sides reported). */
    val inputWidth: Int
    val inputHeight: Int

    /** Embedding length (elements of the first output). */
    val dim: Int

    val accelerator: String get() = rt.accelerator
    val accelerationNote: String? get() = checkNote ?: rt.accelerationNote

    /** Threads the CPU engine runs on (the count behind "0 = automatic"); null on the GPU. */
    val cpuThreads: Int? get() = if (rt.accelerator == "CPU") (rt as? LiteRtModel)?.cpuThreads else null

    private val nchw: Boolean = rt.inputUsesNchw
    private val input: FloatArray

    init {
        val dims = rt.inputDims
        require(dims.size >= 4) { "Embedder model input shape could not be read (${dims.toList()})" }
        inputHeight = dims[1]
        inputWidth = dims[2]
        require(dims[3] == 3) { "Embedder expects an RGB model input, got ${dims.toList()}" }
        dim = rt.outputElementCounts.firstOrNull() ?: 0
        require(dim > 0) { "Embedder model produced no output" }
        input = FloatArray(inputWidth * inputHeight * 3)
        if (rt.accelerator == "GPU") checkGpu(context, modelPath, cpuThreads)
    }

    /** See the file comment. Runs on the loading thread; the first time per model and Android
     *  build it also loads the model on the CPU for one embedding (a few seconds). */
    private fun checkGpu(context: Context, modelPath: String, cpuThreads: Int) {
        val file = File(modelPath)
        val key = "${file.name}_${file.length()}|${Build.FINGERPRINT}"
        val store = File(context.filesDir, "embedder_gpu_checks.txt")
        val known = runCatching {
            if (store.exists()) store.readLines().mapNotNull { line ->
                val parts = line.split('\t')
                if (parts.size == 2) parts[0] to parts[1].toDoubleOrNull() else null
            }.toMap() else emptyMap()
        }.getOrDefault(emptyMap())
        var agreement = known[key]
        if (agreement == null) {
            // One model at a time (a large model twice in memory can get the app killed): the GPU
            // result first, then the CPU copy, then the GPU model again (its compiled program is
            // cached, so the second GPU load is quicker).
            val picture = testPicture()
            val onGpu = embed(picture)
            rt.close()
            rt = InferenceModel.create(context, modelPath, false, "Embedder", cpuThreads)
            val onCpu = embed(picture)
            rt.close()
            rt = InferenceModel.create(context, modelPath, true, "Embedder", cpuThreads)
            var dot = 0.0
            for (i in onGpu.indices) dot += (onGpu[i] * onCpu[i]).toDouble()
            agreement = if (dot.isNaN()) 0.0 else dot
            runCatching { store.appendText("$key\t$agreement\n") }
            Log.i(TAG, "GPU check for ${file.name}: GPU and CPU embeddings agree to %.6f".format(agreement))
        }
        gpuAgreement = agreement
        if (rt.accelerator != "GPU") return // the GPU reload failed; the ladder's note says why
        if (agreement < GPU_MIN_AGREEMENT) {
            rt.close()
            rt = InferenceModel.create(context, modelPath, false, "Embedder", cpuThreads)
            checkNote = "the GPU's results differed from the CPU's on this phone (agreement %.3f, needs %.3f)"
                .format(agreement, GPU_MIN_AGREEMENT)
            Log.w(TAG, "GPU check failed for ${file.name}; running on the CPU")
        }
    }

    /** The fixed test picture: smooth colour waves, the same on every phone. */
    private fun testPicture(): ByteArray {
        val out = ByteArray(inputWidth * inputHeight * 3)
        var j = 0
        for (y in 0 until inputHeight) {
            for (x in 0 until inputWidth) {
                for (c in 0 until 3) {
                    val v = 128 + 100 * sin(x * (0.05 + 0.02 * c) + y * (0.03 + 0.015 * c) + c)
                    out[j++] = v.toInt().coerceIn(0, 255).toByte()
                }
            }
        }
        return out
    }

    /**
     * Embed one image given as interleaved RGB bytes (row-major, exactly inputWidth x inputHeight x 3).
     * Returns a fresh unit-length float vector of [dim] elements.
     */
    fun embed(rgb: ByteArray): FloatArray {
        val pixels = inputWidth * inputHeight
        require(rgb.size == pixels * 3) {
            "Embedder needs ${pixels * 3} RGB bytes (${inputWidth}x${inputHeight}x3), got ${rgb.size}"
        }
        if (nchw) {
            var r = 0
            var g = pixels
            var b = pixels * 2
            var j = 0
            for (i in 0 until pixels) {
                input[r++] = (rgb[j++].toInt() and 0xFF) * (1f / 255f)
                input[g++] = (rgb[j++].toInt() and 0xFF) * (1f / 255f)
                input[b++] = (rgb[j++].toInt() and 0xFF) * (1f / 255f)
            }
        } else {
            for (i in 0 until pixels * 3) input[i] = (rgb[i].toInt() and 0xFF) * (1f / 255f)
        }
        val out = rt.run(input)[0]
        val vec = out.copyOf(dim)
        var sum = 0.0
        for (v in vec) sum += (v * v).toDouble()
        val norm = sqrt(sum).toFloat()
        if (norm > 0f) for (i in vec.indices) vec[i] /= norm
        return vec
    }

    fun close() = rt.close()
}
