// FaunaPulse (round 208): image-embedding model wrapper for on-device identification.
//
// An "embedder" turns one image into a fixed-length vector (an "embedding", e.g. 768
// numbers for BioCLIP 2). Unlike the detectors, it returns no boxes and no classes: the
// Dart side compares the vector against a label pack of name embeddings. The model file
// is a TFLite export made by export_image_tower.py (fauna-pulse-models, bioclip_export/), which bakes the
// colour normalisation into the graph, so this class feeds plain RGB in 0..1 and only
// has to (a) lay the pixels out the way the model wants (HWC or CHW, see
// InferenceModel.inputUsesNchw) and (b) L2-normalise the output defensively.
// Round 266: a fixed-class classifier (e.g. insectDCT, fauna-pulse-models classifier_export/) is loaded with
// normalize = false: its output is one raw score per class, and scaling it to length 1 would
// change the probabilities the Dart side computes from it.
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
//
// Memory (round 243): setting a large model up on the GPU needs several times its file
// size in memory; on a 3.8 GB phone Android's low-memory killer closed the whole app while
// BioCLIP 2 was being set up there. The GPU is therefore tried only when the estimate
// ([GPU_MEMORY_FACTOR] × file size) stays under [GPU_MEMORY_SHARE] of the phone's memory;
// otherwise the model runs on the CPU with a note saying why.

package com.ultralytics.yolo

import android.app.ActivityManager
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
    private val normalize: Boolean = true,
) {
    companion object {
        private const val TAG = "Embedder"

        /** Lowest GPU/CPU agreement (cosine of the two embeddings of the test picture) that keeps
         *  the GPU. The GPU's 16-bit maths against the CPU's 32-bit gave 0.9995 on the test phone
         *  (round 242; real crops 0.994 to 0.997, same answers); a broken or too imprecise GPU path
         *  lands far below. (32-bit GPU maths needs ~1.2 GB of GPU memory for BioCLIP 2: Android
         *  killed the app on the 7.4 GB test phone.) */
        const val GPU_MIN_AGREEMENT = 0.995

        /** Memory a GPU setup needs, as a multiple of the model file's size: BioCLIP 2 (609 MB)
         *  took the app to 2.7 GB while it was set up on the 3.8 GB Samsung (round 243). */
        const val GPU_MEMORY_FACTOR = 4.5

        /** Largest share of the phone's memory that estimate may take (the rest is Android and
         *  other apps; the 7.4 GB Xiaomi runs BioCLIP 2 on the GPU, the 3.8 GB Samsung cannot).
         *  The note below names this share as what Android lets one app use: "needs 2.7 of 3.8 GB"
         *  alone read as if the model fitted. */
        const val GPU_MEMORY_SHARE = 0.6

        /** Why [modelPath] should not be set up on this phone's GPU, or null when it fits. */
        fun gpuMemoryNote(context: Context, modelPath: String): String? {
            val am = context.getSystemService(ActivityManager::class.java) ?: return null
            val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            val need = File(modelPath).length() * GPU_MEMORY_FACTOR
            if (info.totalMem <= 0 || need <= info.totalMem * GPU_MEMORY_SHARE) return null
            return ("this phone has %.1f GB of memory, of which Android lets one app use about %.1f GB; " +
                "setting this model up on the GPU takes about %.1f GB, so it runs on the CPU")
                .format(info.totalMem / 1e9, info.totalMem * GPU_MEMORY_SHARE / 1e9, need / 1e9)
        }

        /** Memory the CPU copy of a model takes, as a multiple of the file's size. With 16-bit CPU
         *  maths ([CPU_FP16], round 357) BioCLIP 2 (16-bit file, 0.61 GB) grew the native heap by
         *  0.74 to 0.78 GB on the two 4 GB test phones (1.2 to 1.3x: the weights stay 16-bit); 1.4
         *  keeps a margin. In 32-bit maths (round 319, part 2) it was 1.25 GB (2.05x, factor 2.15),
         *  and a 32-bit file (1.22 GB) took the same 1.25 GB; such a file is not re-measured, but
         *  1.4 x 1.22 GB = 1.7 GB still covers that (the check is stricter). */
        const val CPU_MEMORY_FACTOR = 1.4

        /** The CPU copy computes in 16-bit (XNNPACK's FORCE_FP16, see LiteRtModel). Measured on the
         *  two 4 GB test phones (ARMv8.2 cores, LiteRT 2.2.0, BioCLIP 2): the model's memory halved
         *  (about 0.75 instead of 1.25 GB) and a crop took 1.5 instead of 3.4 s (Redmi Note 9S,
         *  2 threads) and 3.3 instead of 8.9 s (Galaxy M12, 8 threads); the embedding of the test
         *  picture agreed with 32-bit to 0.9993 (the GPU check asks 0.995). A model or a phone
         *  that cannot run in 16-bit is set up in 32-bit by LiteRtModel (round 366). */
        const val CPU_FP16 = true

        /** Thread counts the self-test behind "0 = automatic" tries ([chooseCpuThreads]): 2, 4 and
         *  every core (fewer on a phone with fewer cores). */
        fun threadCandidates(): List<Int> {
            val cores = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
            return listOf(2, 4, cores).map { it.coerceAtMost(cores) }.distinct().sorted()
        }

        /** The self-test's verdicts, one line per model, phone build and app version: key, the
         *  chosen count, then "threads:seconds" per candidate. */
        private const val THREADS_STORE = "embedder_cpu_threads.txt"
        /** The self-test keeps the fewest threads within this share of the fastest time. */
        private const val THREADS_TIE_MARGIN = 0.05

        /** What a remembered verdict (GPU check, thread self-test) is tied to: the model file, the
         *  phone's Android build and the app's version. The app's version is part of it because an
         *  update can bring a new runtime (round 357, LiteRT 2.2.0 to 2.3.2), so the checks run
         *  once more after it (a few seconds, the self-test about a minute). */
        private fun checkKey(context: Context, modelPath: String): String {
            val file = File(modelPath)
            val appVersion = runCatching {
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
                else @Suppress("DEPRECATION") info.versionCode.toLong()
            }.getOrDefault(0L)
            return "${file.name}_${file.length()}|${Build.FINGERPRINT}|v$appVersion"
        }

        private fun rememberedThreads(context: Context, key: String): Int? = runCatching {
            val store = File(context.filesDir, THREADS_STORE)
            if (!store.exists()) null
            else store.readLines().mapNotNull { line ->
                val parts = line.split('\t')
                if (parts.size >= 2 && parts[0] == key) parts[1].toIntOrNull() else null
            }.lastOrNull()
        }.getOrNull()

        /**
         * Round 319, part 2: what loading [modelPath] would need and what Android has free now, for
         * the Dart side to decide whether an identification may load while the app is in the
         * background. The need is the GPU guard's estimate when the GPU would be tried, else the
         * CPU's. `availMem` and `threshold` are ActivityManager.MemoryInfo's; `memAvailable` is the
         * kernel's MemAvailable (bytes, -1 when unreadable), what the phone tests logged.
         */
        fun memoryCheck(context: Context, modelPath: String, useGpu: Boolean): Map<String, Any> {
            val am = context.getSystemService(ActivityManager::class.java)
            val info = ActivityManager.MemoryInfo().also { am?.getMemoryInfo(it) }
            val fileBytes = File(modelPath).length()
            val onGpu = useGpu && gpuMemoryNote(context, modelPath) == null
            val need = (fileBytes * if (onGpu) GPU_MEMORY_FACTOR else CPU_MEMORY_FACTOR).toLong()
            val memAvailable = runCatching {
                File("/proc/meminfo").useLines { lines ->
                    lines.first { it.startsWith("MemAvailable:") }.filter { it.isDigit() }.toLong() * 1024
                }
            }.getOrDefault(-1L)
            return mapOf(
                "fileBytes" to fileBytes,
                "needBytes" to need,
                "onGpu" to onGpu,
                "availMem" to info.availMem,
                "threshold" to info.threshold,
                "totalMem" to info.totalMem,
                "lowMemory" to info.lowMemory,
                "memAvailable" to memAvailable,
            )
        }
    }

    private val checkKey: String = checkKey(context, modelPath)

    /** "0 = automatic": the self-test's remembered choice for this model and phone, or null when
     *  [chooseCpuThreads] still has to run (null as well when the setting is not 0). */
    private val rememberedThreads: Int? = if (cpuThreads > 0) null else rememberedThreads(context, checkKey)

    /** The thread setting, else the remembered choice, else the self-test's first candidate. */
    private val cpuThreadCount: Int =
        if (cpuThreads > 0) cpuThreads else rememberedThreads ?: threadCandidates().first()

    /** Whether the self-test still has to choose the count ("0 = automatic", nothing remembered). */
    private val threadsToChoose: Boolean = cpuThreads <= 0 && rememberedThreads == null

    private val memoryNote: String? = if (useGpu) gpuMemoryNote(context, modelPath) else null

    private var rt: InferenceModel =
        InferenceModel.create(context, modelPath, useGpu && memoryNote == null, "Embedder", cpuThreadCount, CPU_FP16)

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
    val accelerationNote: String? get() = memoryNote ?: checkNote ?: rt.accelerationNote

    /** Threads the CPU engine runs on (the count behind "0 = automatic"); null on the GPU. */
    val cpuThreads: Int? get() = if (rt.accelerator == "CPU") (rt as? LiteRtModel)?.cpuThreads else null

    private val nchw: Boolean = rt.inputUsesNchw
    private val input: FloatArray

    init {
        // Round 319, part 2: a model that fails a check below was loaded already; close it, or
        // its memory (1.25 GB for BioCLIP 2 on the CPU) stays taken until the app ends (the
        // plugin keeps no reference to an Embedder that failed to build).
        try {
            val dims = rt.inputDims
            require(dims.size >= 4) { "Embedder model input shape could not be read (${dims.toList()})" }
            inputHeight = dims[1]
            inputWidth = dims[2]
            require(dims[3] == 3) { "Embedder expects an RGB model input, got ${dims.toList()}" }
            dim = rt.outputElementCounts.firstOrNull() ?: 0
            require(dim > 0) { "Embedder model produced no output" }
            input = FloatArray(inputWidth * inputHeight * 3)
            if (rt.accelerator == "GPU") checkGpu(context, modelPath, cpuThreadCount)
            if (rt.accelerator == "CPU" && threadsToChoose) chooseCpuThreads(context, modelPath)
        } catch (t: Throwable) {
            runCatching { rt.close() }
            throw t
        }
    }

    /** See the file comment. Runs on the loading thread; the first time per model and Android
     *  build it also loads the model on the CPU for one embedding (a few seconds). */
    private fun checkGpu(context: Context, modelPath: String, cpuThreads: Int) {
        val file = File(modelPath)
        val key = checkKey
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
            // result first, then the CPU copy (in the mode the app really uses, [CPU_FP16]), then
            // the GPU model again (its compiled program is cached, so the second GPU load is quicker).
            val picture = testPicture()
            val onGpu = embed(picture)
            rt.close()
            rt = InferenceModel.create(context, modelPath, false, "Embedder", cpuThreads, CPU_FP16)
            val onCpu = embed(picture)
            rt.close()
            rt = InferenceModel.create(context, modelPath, true, "Embedder", cpuThreads, CPU_FP16)
            // Cosine with explicit lengths: a classifier's raw scores are not unit vectors.
            var dot = 0.0
            var gg = 0.0
            var cc = 0.0
            for (i in onGpu.indices) {
                dot += (onGpu[i] * onCpu[i]).toDouble()
                gg += (onGpu[i] * onGpu[i]).toDouble()
                cc += (onCpu[i] * onCpu[i]).toDouble()
            }
            val cos = dot / sqrt(gg * cc)
            agreement = if (cos.isNaN()) 0.0 else cos
            runCatching { store.appendText("$key\t$agreement\n") }
            Log.i(TAG, "GPU check for ${file.name}: GPU and CPU embeddings agree to %.6f".format(agreement))
        }
        gpuAgreement = agreement
        if (rt.accelerator != "GPU") return // the GPU reload failed; the ladder's note says why
        if (agreement < GPU_MIN_AGREEMENT) {
            rt.close()
            rt = InferenceModel.create(context, modelPath, false, "Embedder", cpuThreads, CPU_FP16)
            checkNote = "the GPU's results differed from the CPU's on this phone (agreement %.3f, needs %.3f)"
                .format(agreement, GPU_MIN_AGREEMENT)
            Log.w(TAG, "GPU check failed for ${file.name}; running on the CPU")
        }
    }

    /**
     * "0 = automatic" on the CPU (round 357): times the test picture with each of
     * [threadCandidates], once per model, phone build and app version, keeps the fewest threads
     * within [THREADS_TIE_MARGIN] of the fastest (fewer busy cores, less heat on a long run) and
     * remembers it in [THREADS_STORE]. No fixed rule fitted the three test phones with 16-bit
     * maths: the Redmi Note 9S (2 fast + 6 slow cores) and the Galaxy M12 (8 equal cores) were
     * clearly fastest with all 8 threads; on the Xiaomi 11T Pro (1 + 3 fast + 4 slow cores) 4 and
     * 8 tied at 0.73 s per crop (0.99 s with 8 in one earlier run: XNNPACK splits the work evenly,
     * so threads on slow cores finish last). Costs about a minute once on a slow phone (one model
     * copy at a time). The detectors keep [LiteRtModel.automaticCpuThreads] (2): they run beside
     * the camera.
     */
    private fun chooseCpuThreads(context: Context, modelPath: String) {
        val picture = testPicture()
        val timings = LinkedHashMap<Int, Double>()
        var current = (rt as? LiteRtModel)?.cpuThreads ?: cpuThreadCount
        for (n in threadCandidates()) {
            if (n != current) {
                rt.close()
                rt = InferenceModel.create(context, modelPath, false, "Embedder", n, CPU_FP16)
                current = n
            }
            embed(picture) // warm-up: the first pass packs weights and grows buffers
            var best = Double.MAX_VALUE
            repeat(2) {
                val t0 = System.nanoTime()
                embed(picture)
                best = minOf(best, (System.nanoTime() - t0) / 1e9)
            }
            timings[n] = best
        }
        val fastest = timings.values.minOrNull() ?: Double.MAX_VALUE
        val chosen = timings.entries.firstOrNull { it.value <= fastest * (1 + THREADS_TIE_MARGIN) }?.key ?: current
        if (chosen != current) {
            rt.close()
            rt = InferenceModel.create(context, modelPath, false, "Embedder", chosen, CPU_FP16)
        }
        val timed = timings.entries.joinToString(" ") { "${it.key}:%.3f".format(it.value) }
        runCatching { File(context.filesDir, THREADS_STORE).appendText("$checkKey\t$chosen\t$timed\n") }
        Log.i(TAG, "CPU thread self-test for ${File(modelPath).name}: " +
            timings.entries.joinToString(", ") { "${it.key} threads %.2f s".format(it.value) } +
            "; keeping $chosen (fewest within ${(THREADS_TIE_MARGIN * 100).toInt()} % of the fastest)")
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
     * Returns a fresh float vector of [dim] elements: unit length, or the raw scores when
     * [normalize] is false.
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
        if (!normalize) return vec
        var sum = 0.0
        for (v in vec) sum += (v * v).toDouble()
        val norm = sqrt(sum).toFloat()
        if (norm > 0f) for (i in vec.indices) vec[i] /= norm
        return vec
    }

    fun close() = rt.close()
}
