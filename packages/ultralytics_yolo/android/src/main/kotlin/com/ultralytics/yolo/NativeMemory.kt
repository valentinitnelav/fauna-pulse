// FaunaPulse (round 319, part 2): gives freed native memory back to Android.
//
// On the 3.6 GB test phone, closing the CPU copy of BioCLIP 2 freed its 1.25 GB, but the native
// allocator kept the freed pages in the process (dumpsys meminfo after the run: Native Heap PSS
// 1.25 GB, Heap Alloc 55 MB, Heap Free 1.37 GB). The app stayed that big, and Android ended it
// one second after the run, once it was in the background with no service. The allocator gives
// such pages back by itself about a second later; [giveBack] asks it to do so at once (mallopt,
// in native-lib.cpp) and logs what it did. Which mallopt option works differs between Android
// versions and phones (on the Android 12 test phone M_PURGE_ALL answered "done" and freed
// nothing), so each step is checked by the app's resident memory and the next one is tried
// when nothing came back.

package com.ultralytics.yolo

import android.os.Debug
import android.util.Log
import java.io.File

object NativeMemory {
    private const val TAG = "NativeMemory"

    /** The plugin's own native library (also used by ObjectDetector). */
    private val loaded: Boolean = runCatching { System.loadLibrary("ultralytics") }.isSuccess

    /** Native steps, in the order they are tried (see native-lib.cpp). */
    private val steps = listOf(1 to "purge all", 2 to "purge", 3 to "decay 0 + purge")

    /** Below this much free native heap there is little to give back: the first step that runs is enough. */
    private const val SMALL_FREE_MB = 64L

    /** A step counts as working when the app's resident memory fell by at least this much. */
    private const val DROP_MB = 32L

    /**
     * Step [step] of native-lib.cpp: mallopt's answer (1 = done, 0 = option unknown on this
     * Android), or -1 when mallopt is missing.
     */
    @JvmStatic
    private external fun purge(step: Int): Int

    /** The library file that provides mallopt, or null. */
    @JvmStatic
    private external fun malloptLibrary(): String?

    private var libraryLogged = false

    /** Gives freed native memory back to Android. Never throws; [why] goes into the log line. */
    fun giveBack(why: String) {
        if (!loaded) return
        try {
            if (!libraryLogged) {
                libraryLogged = true
                Log.i(TAG, "mallopt from ${malloptLibrary()}")
            }
            val freeBefore = Debug.getNativeHeapFreeSize() shr 20
            val t0 = System.nanoTime()
            val tried = tryInOrder(
                steps.map { (n, name) -> name to { purge(n) } },
                ::rssMb,
                enoughMb = if (freeBefore < SMALL_FREE_MB) 0L else DROP_MB,
            )
            Log.i(
                TAG,
                "$why: freed memory given back in %.0f ms (%s); native heap free %d -> %d MB, app RSS %d -> %d MB"
                    .format(
                        (System.nanoTime() - t0) / 1e6,
                        tried.joinToString { "${it.name} = ${it.answer}, RSS ${it.rssBefore} -> ${it.rssAfter} MB" },
                        freeBefore,
                        Debug.getNativeHeapFreeSize() shr 20,
                        tried.firstOrNull()?.rssBefore ?: -1L,
                        tried.lastOrNull()?.rssAfter ?: -1L,
                    ),
            )
        } catch (t: Throwable) {
            // UnsatisfiedLinkError on an old library, or anything else: the memory just stays.
            Log.w(TAG, "$why: giving memory back failed: $t")
        }
    }

    /** One step's name, mallopt's answer and the app's resident memory around it (MB, -1 = unknown). */
    internal data class Attempt(val name: String, val answer: Int, val rssBefore: Long, val rssAfter: Long)

    /**
     * Runs [steps] in order and stops after the first one that mallopt accepted (answer 1) and
     * that lowered [rssMb] by at least [enoughMb]. With [enoughMb] 0, or when the resident memory
     * cannot be read, an accepted step is enough. Steps the phone does not know (answer 0) or
     * that are missing (-1) are passed over.
     */
    internal fun tryInOrder(steps: List<Pair<String, () -> Int>>, rssMb: () -> Long, enoughMb: Long): List<Attempt> {
        val tried = mutableListOf<Attempt>()
        for ((name, run) in steps) {
            val before = rssMb()
            val answer = run()
            val after = rssMb()
            tried += Attempt(name, answer, before, after)
            if (answer != 1) continue
            if (enoughMb <= 0L || before < 0L || after < 0L || before - after >= enoughMb) break
        }
        return tried
    }

    /** This process's resident memory in MB (VmRSS), or -1. */
    private fun rssMb(): Long = runCatching {
        File("/proc/self/status").useLines { lines ->
            lines.first { it.startsWith("VmRSS:") }.filter { it.isDigit() }.toLong() shr 10
        }
    }.getOrDefault(-1L)
}
