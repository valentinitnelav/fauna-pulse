// FaunaPulse (round 238): records the square ROI of the live camera frames as an MP4 clip, for
// time-lapse "video bursts" (Settings → Setup → Save bursts as: Video).
//
// Plain-language terms used below:
//  - "encoder" (MediaCodec): the phone's video chip that compresses pictures into H.264 ("AVC"),
//    the format every phone, computer and Python/R video library can play.
//  - "input surface": a drawing target the encoder owns; whatever is drawn on it becomes the next
//    video frame. This writer draws on it with its own small OpenGL (GPU) context, so the CPU never
//    converts colours for the encoder. (Android's simpler lockHardwareCanvas crashed the app on the
//    Xiaomi test phone, round 238: its renderer asks the codec for frame timings over a link that
//    cannot answer them.)
//  - "muxer" (MediaMuxer): writes the compressed frames into the .mp4 file.
//  - "key frame": a frame that can be decoded on its own. One per second, so the player and the
//    offline analysis can jump anywhere in the clip quickly.
//  - "PTS" (presentation time stamp): when a frame is shown, in microseconds.
//
// Threads: the camera analyzer thread calls [wants] and [offer] for each frame. [offer] copies the
// ROI square, as the sensor saw it (not yet turned upright), into one of two small bitmaps (the only
// CPU work, a plain row copy) and hands it to this writer's own thread, which uploads it to the GPU,
// turns it upright and scales it to the clip's side while drawing it onto the encoder's surface. When that thread
// is still busy with the previous frame, the new frame is skipped and counted: the analyzer thread
// never waits for the encoder, which would starve the camera and trip the app's camera watchdog.
//
// Each frame carries the camera's own capture time as its PTS, so the times inside the clip are
// the true gaps between the camera's frames. The clip's first frame is tied to the clock
// ([firstEpochMs]); a frame's clock time is firstEpochMs + its time in the file (which starts at 0).

package com.ultralytics.yolo

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

class RoiVideoWriter private constructor(
    private val file: File,
    val sidePx: Int,
    val fps: Int,
    val bitrate: Int,
    val encoderName: String,
    private val thread: HandlerThread,
) {
    companion object {
        private const val TAG = "RoiVideoWriter"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        // EGL_RECORDABLE_ANDROID: the EGL config can feed a video encoder.
        private const val EGL_RECORDABLE_ANDROID = 0x3142

        private const val VERTEX_SHADER = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            varying vec2 vTex;
            void main() { gl_Position = aPos; vTex = aTex; }
        """
        private const val FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vTex;
            uniform sampler2D uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }
        """

        /**
         * The encoder and the largest square side ≤ [requested] (stepping down by 32 px) that this
         * phone's H.264 encoders accept at [fps]; hardware encoders are tried first. Null when none.
         */
        fun supportedSide(requested: Int, fps: Int): Pair<String, Int>? {
            val encoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(MIME, ignoreCase = true) } }
                .sortedBy { if (isSoftware(it)) 1 else 0 }
            var side = (requested / 32) * 32
            while (side >= 64) {
                for (info in encoders) {
                    val caps = info.getCapabilitiesForType(MIME).videoCapabilities ?: continue
                    if (caps.areSizeAndRateSupported(side, side, fps.toDouble())) return info.name to side
                }
                side -= 32
            }
            return null
        }

        private fun isSoftware(info: MediaCodecInfo): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) info.isSoftwareOnly
            else info.name.startsWith("OMX.google.") || info.name.startsWith("c2.android.")

        /**
         * Opens a clip at [path]: [requestedSide] px square (made smaller when the encoder needs
         * it), [fps] frames per second, a bit rate of [bitsPerPixel] per pixel per frame. Throws
         * when no encoder fits or the file cannot be created (nothing is left behind then).
         */
        fun start(path: String, requestedSide: Int, fps: Int, bitsPerPixel: Double): RoiVideoWriter {
            val (name, side) = supportedSide(requestedSide, fps)
                ?: throw IllegalStateException("No video encoder on this phone takes ${requestedSide}px at $fps fps")
            val bitrate = (bitsPerPixel * side * side * fps).roundToInt().coerceAtLeast(100_000)
            val format = MediaFormat.createVideoFormat(MIME, side, side).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                // Standard HD colours, as phone cameras record, so players show the colours right.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                    setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                    setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                }
            }
            val thread = HandlerThread("RoiVideoWriter").apply { start() }
            var codec: MediaCodec? = null
            try {
                codec = MediaCodec.createByCodecName(name)
                val writer = RoiVideoWriter(File(path), side, fps, bitrate, name, thread)
                writer.codec = codec
                codec.setCallback(writer.callback, writer.handler)
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                writer.surface = codec.createInputSurface()
                writer.muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                codec.start()
                // The GL context lives on the writer thread; set it up there and wait for it.
                var glError: Throwable? = null
                val ready = CountDownLatch(1)
                writer.handler.post {
                    try { writer.initGl() } catch (e: Throwable) { glError = e }
                    ready.countDown()
                }
                if (!ready.await(3, TimeUnit.SECONDS)) glError = IllegalStateException("GL setup timed out")
                glError?.let { e ->
                    val done = CountDownLatch(1)
                    writer.handler.post { writer.tearDown(); done.countDown() }
                    done.await(3, TimeUnit.SECONDS)
                    thread.quitSafely()
                    throw IllegalStateException("Video drawing could not start: ${e.message}")
                }
                Log.i(TAG, "clip started ${side}px $fps fps ${bitrate / 1000} kbit/s ($name): $path")
                return writer
            } catch (e: Exception) {
                try { codec?.release() } catch (_: Exception) {}
                thread.quitSafely()
                File(path).delete()
                throw e
            }
        }
    }

    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var codec: MediaCodec
    private lateinit var surface: Surface
    private lateinit var muxer: MediaMuxer

    // Analyzer thread only.
    private val intervalNs = 1_000_000_000L / fps
    private var dueNs = 0L
    private var hasDue = false
    private val buffers = arrayOfNulls<Bitmap>(2)
    private var nextBuffer = 0
    private var cropNs = 0L
    private var cropCount = 0

    // Writer thread only.
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texture = 0
    private var textureSide = 0
    private var quadDegrees = -1
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
    private var track = -1
    private var muxing = false
    private var eosSignalled = false
    private var drawn = 0
    private var drawNs = 0L
    private var encoded = 0
    private var bytesWritten = 0L
    private var firstPtsUs = -1L
    private var lastPtsUs = -1L

    @Volatile private var accepting = true
    @Volatile private var firstEpochMs: Double? = null
    @Volatile private var error: String? = null
    private val drawing = AtomicBoolean(false)
    private val skipped = AtomicInteger(0)
    private val finishing = AtomicBoolean(false)
    private val eos = CountDownLatch(1)
    private var endReason = ""

    // Guarded by [waiting].
    private val waiting = mutableListOf<(Map<String, Any?>) -> Unit>()
    private var result: Map<String, Any?>? = null

    /**
     * Whether the camera frame taken at [sensorNs] is due. Each frame is due one frame interval
     * after the last one taken, with a quarter-interval tolerance, so a camera running at exactly
     * the video rate keeps every frame despite jitter and a faster camera is thinned evenly.
     * Called before the frame is converted, so frames not needed cost nothing.
     */
    fun wants(sensorNs: Long): Boolean = accepting && (!hasDue || sensorNs >= dueNs - intervalNs / 4)

    /**
     * Takes one due frame: [copyRoi] copies the ROI square as the sensor saw it into the
     * [sourceSide] square bitmap it is given; [degrees] (clockwise) turns it upright. Skipped
     * (and counted) while the writer thread is still drawing the previous frame.
     */
    fun offer(sensorNs: Long, epochMs: Double?, sourceSide: Int, degrees: Int, copyRoi: (Bitmap) -> Unit) {
        if (!accepting) return
        // After a long wait (the first frame, a slow camera) start the clock again from here.
        dueNs = if (!hasDue || sensorNs - dueNs > intervalNs) sensorNs + intervalNs else dueNs + intervalNs
        hasDue = true
        if (!drawing.compareAndSet(false, true)) {
            skipped.incrementAndGet()
            return
        }
        // Two bitmaps in turn: the GPU may still read the previous one while this one is filled.
        val i = nextBuffer
        nextBuffer = 1 - i
        // A resized ROI changes the square; the clip keeps its side (the GPU scales).
        val buf = buffers[i]?.takeIf { it.width == sourceSide }
            ?: Bitmap.createBitmap(sourceSide, sourceSide, Bitmap.Config.ARGB_8888).also { buffers[i] = it }
        val t0 = System.nanoTime()
        try {
            copyRoi(buf)
        } catch (e: Exception) {
            drawing.set(false)
            Log.w(TAG, "ROI draw failed: ${e.message}")
            return
        }
        cropNs += System.nanoTime() - t0
        cropCount++
        if (!handler.post { drawFrame(buf, degrees, sensorNs, epochMs) }) drawing.set(false)
    }

    /** Writer thread: the EGL context on the encoder's surface, the shader and the texture. */
    private fun initGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "no recordable EGL config"
        }
        eglContext = EGL14.eglCreateContext(
            eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }
        check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) { "eglMakeCurrent failed" }
        program = buildProgram()
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        texture = ids[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private fun buildProgram(): Int {
        fun shader(type: Int, source: String): Int {
            val id = GLES20.glCreateShader(type)
            GLES20.glShaderSource(id, source)
            GLES20.glCompileShader(id)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: ${GLES20.glGetShaderInfoLog(id)}" }
            return id
        }
        val id = GLES20.glCreateProgram()
        GLES20.glAttachShader(id, shader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER))
        GLES20.glAttachShader(id, shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER))
        GLES20.glLinkProgram(id)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(id, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "program: ${GLES20.glGetProgramInfoLog(id)}" }
        return id
    }

    /** The quad's corners (x, y) and which texture point (s, t) lands there. The texture is the
     *  square as the sensor saw it (t = 0 is its top row); the frame's top is y = 1. For an
     *  upright point (a, b) (0..1, from the top left) the texture point is, turned clockwise by
     *  0°: (a, b); 90°: (b, 1−a); 180°: (1−a, 1−b); 270°: (1−b, a). */
    private fun setQuad(degrees: Int) {
        if (degrees == quadDegrees) return
        quadDegrees = degrees
        fun st(a: Float, b: Float): List<Float> = when (degrees) {
            90 -> listOf(b, 1 - a)
            180 -> listOf(1 - a, 1 - b)
            270 -> listOf(1 - b, a)
            else -> listOf(a, b)
        }
        // Strip order: bottom left, bottom right, top left, top right.
        val v = listOf(-1f, -1f) + st(0f, 1f) + listOf(1f, -1f) + st(1f, 1f) +
            listOf(-1f, 1f) + st(0f, 0f) + listOf(1f, 1f) + st(1f, 0f)
        quad.position(0)
        quad.put(v.toFloatArray())
        quad.position(0)
    }

    private fun drawFrame(buf: Bitmap, degrees: Int, sensorNs: Long, epochMs: Double?) {
        try {
            if (eosSignalled || eglSurface == EGL14.EGL_NO_SURFACE) return
            val t0 = System.nanoTime()
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            if (textureSide == buf.width) {
                GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, buf)
            } else {
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, buf, 0)
                textureSide = buf.width
            }
            setQuad(degrees)
            GLES20.glViewport(0, 0, sidePx, sidePx)
            GLES20.glUseProgram(program)
            val pos = GLES20.glGetAttribLocation(program, "aPos")
            val tex = GLES20.glGetAttribLocation(program, "aTex")
            quad.position(0)
            GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(pos)
            quad.position(2)
            GLES20.glVertexAttribPointer(tex, 2, GLES20.GL_FLOAT, false, 16, quad)
            GLES20.glEnableVertexAttribArray(tex)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            // The camera's capture time becomes the frame's PTS (nanoseconds).
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, sensorNs)
            check(EGL14.eglSwapBuffers(eglDisplay, eglSurface)) { "eglSwapBuffers failed: ${EGL14.eglGetError()}" }
            drawNs += System.nanoTime() - t0
            if (drawn == 0) firstEpochMs = epochMs ?: System.currentTimeMillis().toDouble()
            drawn++
        } catch (e: Exception) {
            if (error == null) error = "draw: ${e.message}"
            Log.w(TAG, "frame draw failed: ${e.message}")
        } finally {
            drawing.set(false)
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            // Frames come in through the input surface, never through input buffers.
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            if (muxing) return
            try {
                track = muxer.addTrack(format)
                muxer.start()
                muxing = true
            } catch (e: Exception) {
                if (error == null) error = "muxer: ${e.message}"
                Log.w(TAG, "muxer start failed: ${e.message}")
            }
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                // Codec-config data (SPS/PPS) already reached the muxer through the format above.
                val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                if (!config && info.size > 0 && muxing) {
                    val out = codec.getOutputBuffer(index)
                    if (out != null) {
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        muxer.writeSampleData(track, out, info)
                        encoded++
                        bytesWritten += info.size
                        if (firstPtsUs < 0) firstPtsUs = info.presentationTimeUs
                        lastPtsUs = info.presentationTimeUs
                    }
                }
                codec.releaseOutputBuffer(index, false)
            } catch (e: Exception) {
                if (error == null) error = "write: ${e.message}"
                Log.w(TAG, "sample write failed: ${e.message}")
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) eos.countDown()
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            if (error == null) error = "encoder: ${e.diagnosticInfo}"
            Log.w(TAG, "encoder error: ${e.diagnosticInfo}")
            eos.countDown()
        }
    }

    /**
     * Ends the clip: no new frames, the encoder hands over what it still holds (waiting at most
     * 2 s), and the .mp4 is closed. [done] gets the clip's facts on the main thread. A clip without
     * a single frame is deleted. Safe to call again: every caller gets the same answer.
     */
    fun finish(reason: String, done: ((Map<String, Any?>) -> Unit)?) {
        synchronized(waiting) {
            val r = result
            if (r != null) {
                if (done != null) main.post { done(r) }
                return
            }
            if (done != null) waiting.add(done)
        }
        if (!finishing.compareAndSet(false, true)) return
        accepting = false
        endReason = reason
        handler.post {
            eosSignalled = true
            try {
                codec.signalEndOfInputStream()
            } catch (e: Exception) {
                eos.countDown()
            }
        }
        Thread({
            val flushed = eos.await(2, TimeUnit.SECONDS)
            val closed = CountDownLatch(1)
            if (handler.post { tearDown(); closed.countDown() }) closed.await(3, TimeUnit.SECONDS)
            thread.quitSafely()
            val r = facts(flushed)
            Log.i(TAG, "clip ended ($reason): $r")
            val callbacks = synchronized(waiting) {
                result = r
                waiting.toList().also { waiting.clear() }
            }
            main.post { callbacks.forEach { it(r) } }
        }, "RoiVideoWriterStop").start()
    }

    private fun tearDown() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            // Not eglTerminate: the display is shared with Flutter's own renderer in this process.
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglReleaseThread()
            eglSurface = EGL14.EGL_NO_SURFACE
            eglContext = EGL14.EGL_NO_CONTEXT
            eglDisplay = EGL14.EGL_NO_DISPLAY
        }
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
        if (muxing) {
            try {
                // Throws when no frame was written; such a file is deleted below anyway.
                if (encoded > 0) muxer.stop()
            } catch (e: Exception) {
                if (error == null) error = "close: ${e.message}"
            }
        }
        try { muxer.release() } catch (_: Exception) {}
        try { surface.release() } catch (_: Exception) {}
        if (encoded == 0) file.delete()
    }

    private fun facts(flushed: Boolean): Map<String, Any?> {
        val spanUs = if (encoded > 1) lastPtsUs - firstPtsUs else 0L
        // A clip lasts from its first frame to the end of its last one (one mean frame interval).
        val durationMs = when {
            encoded > 1 -> (spanUs + spanUs / (encoded - 1)) / 1000.0
            encoded == 1 -> 1000.0 / fps
            else -> 0.0
        }
        return mapOf(
            "path" to file.path,
            "frames" to encoded,
            "drawn" to drawn,
            "skipped" to skipped.get(),
            "sidePx" to sidePx,
            "fps" to fps,
            "bitrate" to bitrate,
            "encoder" to encoderName,
            "firstEpochMs" to firstEpochMs,
            "firstPtsUs" to if (firstPtsUs >= 0) firstPtsUs else null,
            "lastPtsUs" to if (lastPtsUs >= 0) lastPtsUs else null,
            "durationMs" to durationMs,
            "bytes" to if (file.exists()) file.length() else 0L,
            "cropMsMean" to if (cropCount > 0) cropNs / cropCount / 1e6 else null,
            "drawMsMean" to if (drawn > 0) drawNs / drawn / 1e6 else null,
            "flushed" to flushed,
            "reason" to endReason,
            "error" to error,
        )
    }
}
