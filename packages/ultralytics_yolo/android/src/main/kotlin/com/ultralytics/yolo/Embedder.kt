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

package com.ultralytics.yolo

import android.content.Context
import kotlin.math.sqrt

class Embedder(
    context: Context,
    modelPath: String,
    useGpu: Boolean,
    cpuThreads: Int = 0,
) {
    private val rt: InferenceModel = InferenceModel.create(context, modelPath, useGpu, "Embedder", cpuThreads)

    /** Model input size (square models only are expected; both sides reported). */
    val inputWidth: Int
    val inputHeight: Int

    /** Embedding length (elements of the first output). */
    val dim: Int

    val accelerator: String get() = rt.accelerator
    val accelerationNote: String? get() = rt.accelerationNote

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
