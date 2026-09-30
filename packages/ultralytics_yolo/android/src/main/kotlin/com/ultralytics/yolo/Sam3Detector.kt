// FaunaPulse (round 257, sam3 branch): SAM 3 as a slow, text-prompted detector for "AI later".
//
// SAM 3 ("Segment Anything with Concepts", Meta, SAM License) finds every object that matches
// a short text prompt ("insect", "bee") without being trained on it. The files are the LiteRT
// conversion by mlboydaisuke (Hugging Face `mlboydaisuke/SAM3-LiteRT`), kept in one folder:
//
//   sam3_text.tflite       prompt token vectors [1,32,1024] -> text memory [8192]      CPU
//   sam3_token_embed.bin   fp16 table [49408 x 1024]: one vector per token number        -
//   vocab.json, merges.txt the CLIP tokenizer (ClipTokenizer.kt)                         -
//   sam3_vision.tflite     picture [1,3,1008,1008] -> image features [27,869,184]        GPU
//     or sam3_vision_part1.tflite ... _partN.tflite: the same model cut into consecutive parts
//     (tool/sam3/split_tflite.py), run one after the other with identical results
//   sam3_head.tflite       features + text memory + padding flags -> 200 candidates     CPU
//   prompts/               the text memory of prompts encoded before (<token numbers>.f32)
//
// The prompt is encoded once when the detector loads (then the 600 MB text model is released),
// and remembered in prompts/, so the text model only runs for a new prompt. Every picture then
// costs one vision run (the slow part, seconds) and one head run. The head
// returns, per candidate ("query"), a score and a box, plus one "presence" score saying how sure
// the model is that the prompt is in the picture at all; a candidate's probability is
// sigmoid(score) x sigmoid(presence), as in the model card. The head also returns 200 masks
// (288 x 288), which are not used here.
//
// Why the text encoder and head run on the CPU: the model card says fp16 GPU maths corrupts
// some prompt embeddings, and that LiteRT before 2.2.0 (the app has 2.1.5) mis-runs the head
// graph on Android GPUs. [headOnGpu] exists to test the head on a phone's GPU.
//
// Round 257 on the Xiaomi (Adreno 642L): the picture model runs on the GPU (9.6 s per picture)
// but returns only NaN ("not a number") from its first part on, with LiteRT 2.1.5 and 2.2.0,
// and also with 32-bit adding up or overflow clamping. The model card verified a Pixel 8a
// (Mali GPU) and an iPhone. A picture that gives NaN therefore stops the run with a message
// instead of passing meaningless boxes on to the tracker.
//
// Memory: setting the whole 930 MB picture model up on the GPU took the 7.4 GB Xiaomi's app to
// about 5 GB, and Android closed it (round 257); the text model on the CPU peaks at about 2 GB
// and leaves about 0.8 GB behind after closing. Hence the parts and the prompt memory above.
// Each picture also moves the 111 MB of features from the vision model to the head through
// Java arrays (LiteRT's Kotlin API only reads and writes whole arrays), so the app needs
// android:largeHeap (512 MB instead of 256 MB on the test phones).

package com.ultralytics.yolo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

class Sam3Detector(
    context: Context,
    dir: File,
    val prompt: String,
    useGpu: Boolean,
    headOnGpu: Boolean = false,
) {
    companion object {
        private const val TAG = "Sam3Detector"
        const val SIDE = 1008
        private const val QUERIES = 200
        private const val FEATURES = 256 * (288 * 288 + 144 * 144 + 72 * 72)
        private const val TOKENS = 32
        private const val WIDTH = 1024
        private const val TEXT = TOKENS * 256

        /** Files the folder must hold, besides the picture model (whole or in parts). */
        val FILES = listOf("sam3_head.tflite", "sam3_text.tflite", "sam3_token_embed.bin", "vocab.json", "merges.txt")

        /** The picture model's parts in order, or the whole model. */
        fun visionFiles(dir: File): List<File> {
            val parts = generateSequence(1) { it + 1 }.map { File(dir, "sam3_vision_part$it.tflite") }
                .takeWhile { it.isFile }.toList()
            return parts.ifEmpty { listOf(File(dir, "sam3_vision.tflite")) }
        }

        /** CPU threads for the text encoder and the head (more than the detectors' 2: they
         *  run seconds, not milliseconds, per call). */
        private const val CPU_THREADS = 4

        private fun sigmoid(v: Float) = 1f / (1f + exp(-v))
    }

    val tokenIds: IntArray
    val visionAccelerator: String
    val headAccelerator: String

    /** Why the vision model is not on the GPU although asked (memory, compile error), or null. */
    val visionNote: String?
    val loadMs: Double

    /** Timings and presence of the last picture. */
    var lastVisionMs = 0.0
        private set
    var lastHeadMs = 0.0
        private set
    var lastPresence = 0f
        private set

    private val vision = ArrayList<InferenceModel>()
    private val head: InferenceModel
    // Head input: features | text memory | pad flags. Allocated after the models are set up, whose
    // setup is the app's memory peak.
    private val headInput: FloatArray
    private val scaled = Bitmap.createBitmap(SIDE, SIDE, Bitmap.Config.ARGB_8888)
    private val pixels = IntArray(SIDE * SIDE)
    private val chw = FloatArray(3 * SIDE * SIDE)

    init {
        val t0 = System.nanoTime()
        for (f in FILES) require(File(dir, f).isFile) { "SAM 3 file missing: ${File(dir, f)}" }
        val visionFiles = visionFiles(dir)
        require(visionFiles.first().isFile) { "SAM 3 file missing: ${visionFiles.first()}" }

        // 1. Prompt -> text memory, from prompts/ or from the text model.
        tokenIds = ClipTokenizer(File(dir, "vocab.json"), File(dir, "merges.txt")).encode(prompt, TOKENS)
        val memory = rememberedPrompt(dir) ?: encodePrompt(context, dir)

        // 2. Vision (GPU when it fits, see Embedder.gpuMemoryNote) and head.
        var memoryNote: String? = null
        head = try {
            for (f in visionFiles) {
                val note = if (useGpu) Embedder.gpuMemoryNote(context, f.path) else null
                memoryNote = memoryNote ?: note
                vision.add(LiteRtModel(context, f.path, useGpu && note == null, TAG))
            }
            LiteRtModel(context, File(dir, "sam3_head.tflite").path, useGpu && headOnGpu, TAG, CPU_THREADS)
        } catch (e: Throwable) {
            vision.forEach { runCatching { it.close() } }
            throw e
        }
        visionAccelerator = vision.map { it.accelerator }.distinct().joinToString("+")
        visionNote = memoryNote ?: vision.firstNotNullOfOrNull { it.accelerationNote }
        headAccelerator = head.accelerator
        require(vision.last().outputElementCounts.firstOrNull() == FEATURES) { "Unexpected SAM 3 vision output ${vision.last().outputElementCounts.toList()}" }
        require(head.outputElementCounts.firstOrNull()?.let { it > 1000 + QUERIES } == true) { "Unexpected SAM 3 head output" }
        headInput = FloatArray(FEATURES + TEXT + TOKENS)
        System.arraycopy(memory, 0, headInput, FEATURES, TEXT)
        for (i in 0 until TOKENS) headInput[FEATURES + TEXT + i] = if (tokenIds[i] == 0) 1f else 0f
        loadMs = (System.nanoTime() - t0) / 1e6
        Log.i(TAG, "Loaded in ${loadMs.toInt()} ms: prompt '$prompt' ids=${tokenIds.takeWhile { it != 0 }} " +
            "vision=$visionAccelerator (${vision.size} part(s))${visionNote?.let { " ($it)" } ?: ""} head=$headAccelerator")
    }

    /** prompts/<token numbers>.f32: the text memory depends on the token numbers only. */
    private fun promptFile(dir: File) = File(dir, "prompts/${tokenIds.takeWhile { it != 0 }.joinToString("_")}.f32")

    private fun rememberedPrompt(dir: File): FloatArray? {
        val f = promptFile(dir)
        if (f.length() != TEXT * 4L) return null
        val out = FloatArray(TEXT)
        ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(out)
        Log.i(TAG, "Prompt '$prompt' read from ${f.name}")
        return out
    }

    private fun encodePrompt(context: Context, dir: File): FloatArray {
        val text = LiteRtModel(context, File(dir, "sam3_text.tflite").path, false, TAG, CPU_THREADS)
        val memory = try {
            text.run(tokenVectors(File(dir, "sam3_token_embed.bin"), tokenIds))[0].copyOf()
        } finally {
            text.close()
        }
        require(memory.size == TEXT) { "Unexpected text memory size ${memory.size}" }
        runCatching {
            val f = promptFile(dir)
            f.parentFile?.mkdirs()
            val bytes = ByteBuffer.allocate(TEXT * 4).order(ByteOrder.LITTLE_ENDIAN)
            bytes.asFloatBuffer().put(memory)
            val tmp = File(f.path + ".tmp")
            tmp.writeBytes(bytes.array())
            tmp.renameTo(f)
        }
        return memory
    }

    /** The prompt's token vectors [32 x 1024] from the fp16 table (only the rows needed are read). */
    private fun tokenVectors(table: File, ids: IntArray): FloatArray {
        val out = FloatArray(TOKENS * WIDTH)
        val row = ByteArray(WIDTH * 2)
        RandomAccessFile(table, "r").use { f ->
            for ((t, id) in ids.withIndex()) {
                f.seek(id.toLong() * WIDTH * 2)
                f.readFully(row)
                val halves = ByteBuffer.wrap(row).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                for (c in 0 until WIDTH) out[t * WIDTH + c] = halfToFloat(halves.get(c).toInt())
            }
        }
        return out
    }

    /** One 16-bit float (sign, 5 exponent bits, 10 fraction bits) as a 32-bit float
     *  (android.util.Half needs Android 8; the app starts at Android 7). */
    private fun halfToFloat(h: Int): Float {
        val sign = if (h and 0x8000 != 0) -1f else 1f
        val e = (h shr 10) and 0x1F
        val m = h and 0x3FF
        return when (e) {
            0 -> sign * m * 5.9604645e-8f // tiny numbers: m x 2^-24
            31 -> if (m == 0) sign * Float.POSITIVE_INFINITY else Float.NaN
            else -> java.lang.Float.intBitsToFloat((h and 0x8000 shl 16) or ((e + 112) shl 23) or (m shl 13))
        }
    }

    /**
     * Boxes in [bitmap]'s pixels as (left, top, right, bottom, probability, 0), probability at least
     * [confidence], overlaps above [iou] removed (the stronger box stays). The picture is stretched
     * to 1008 x 1008 like SAM 3's own preprocessing does, so boxes map back by plain scaling.
     */
    fun detect(bitmap: Bitmap, confidence: Float, iou: Float): List<FloatArray> {
        Canvas(scaled).drawBitmap(bitmap, null, Rect(0, 0, SIDE, SIDE), Paint(Paint.FILTER_BITMAP_FLAG))
        scaled.getPixels(pixels, 0, SIDE, 0, 0, SIDE, SIDE)
        val plane = SIDE * SIDE
        for (i in 0 until plane) {
            val p = pixels[i]
            chw[i] = ((p shr 16) and 0xFF) / 127.5f - 1f
            chw[plane + i] = ((p shr 8) and 0xFF) / 127.5f - 1f
            chw[2 * plane + i] = (p and 0xFF) / 127.5f - 1f
        }
        var t = System.nanoTime()
        var features = chw
        for ((k, part) in vision.withIndex()) {
            features = part.run(features)[0]
            if (!checked) Log.i(TAG, "picture model part ${k + 1}/${vision.size} (${part.accelerator}): ${stats(features)}")
        }
        checked = true
        System.arraycopy(features, 0, headInput, 0, FEATURES)
        lastVisionMs = (System.nanoTime() - t) / 1e6
        t = System.nanoTime()
        val y = head.run(headInput)[0]
        lastHeadMs = (System.nanoTime() - t) / 1e6

        val presence = sigmoid(y[1000])
        lastPresence = presence
        check(!presence.isNaN()) {
            "SAM 3 gave no usable numbers on this phone: its GPU computes the picture model wrongly (NaN). " +
                "SAM 3 cannot run on this phone yet; it runs on a PC (docs/SAM3.md)."
        }
        val w = bitmap.width.toFloat()
        val h = bitmap.height.toFloat()
        val found = ArrayList<FloatArray>()
        for (q in 0 until QUERIES) {
            val p = sigmoid(y[q]) * presence
            if (p < confidence) continue
            val cx = y[200 + 4 * q]
            val cy = y[201 + 4 * q]
            val bw = y[202 + 4 * q]
            val bh = y[203 + 4 * q]
            found.add(floatArrayOf(
                ((cx - bw / 2) * w).coerceIn(0f, w), ((cy - bh / 2) * h).coerceIn(0f, h),
                ((cx + bw / 2) * w).coerceIn(0f, w), ((cy + bh / 2) * h).coerceIn(0f, h), p, 0f,
            ))
        }
        found.sortByDescending { it[4] }
        val kept = ArrayList<FloatArray>()
        for (b in found) if (kept.none { overlap(it, b) > iou }) kept.add(b)
        return kept
    }

    /** The first picture's numbers after each part are logged (largest size, NaN count), to see
     *  where a GPU's 16-bit maths overflows; the PC's are in docs/SAM3.md. */
    private var checked = false

    private fun stats(a: FloatArray): String {
        var nan = 0
        var inf = 0
        var maxAbs = 0f
        var sum = 0.0
        for (v in a) {
            when {
                v.isNaN() -> nan++
                v.isInfinite() -> inf++
                else -> { val m = kotlin.math.abs(v); sum += m; if (m > maxAbs) maxAbs = m }
            }
        }
        return "max %.1f, mean %.3f, NaN %d, infinite %d".format(maxAbs, sum / max(1, a.size - nan - inf), nan, inf)
    }

    private fun overlap(a: FloatArray, b: FloatArray): Float {
        val iw = max(0f, min(a[2], b[2]) - max(a[0], b[0]))
        val ih = max(0f, min(a[3], b[3]) - max(a[1], b[1]))
        val inter = iw * ih
        val union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return if (union > 0f) inter / union else 0f
    }

    fun close() {
        vision.forEach { runCatching { it.close() } }
        runCatching { head.close() }
        scaled.recycle()
    }
}
