// FaunaPulse (round 225): reads a video file frame by frame for offline ("AI later") detection.
//
// Plain-language terms used below:
//  - "extractor" (MediaExtractor): reads the compressed frames ("samples") out of the .mp4 box.
//  - "decoder" (MediaCodec): the phone's video chip that turns compressed samples back into
//    pictures. It outputs YUV, the colour format of video: a full-size brightness plane (Y) plus
//    two colour-difference planes (U, V) at half width and half height.
//  - "PTS" (presentation time stamp): when a frame is shown, in microseconds from the clip start.
//    Phone videos often have a variable frame rate, so all timing here uses PTS, never
//    frame index x (1 / fps).
//  - "rotation": phones store portrait video sideways plus a "rotate by N degrees clockwise"
//    tag. All ROI fractions and output boxes refer to the UPRIGHT picture, as in live sessions.
//
// Only the ROI rectangle is converted from YUV to RGB (a whole 4K frame would cost ~10x more),
// and the rotation is applied while writing the pixels, so no full-frame bitmap ever exists.
// A clip is read front to back; the Dart side asks for a few frames at a time ([next]) so a
// long clip never holds the method channel for minutes.

package com.ultralytics.yolo

import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.nio.ByteBuffer
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class VideoFrameSource private constructor(
  private val extractor: MediaExtractor,
  private val decoder: MediaCodec,
  private val inputFormat: MediaFormat,
  private val rotation: Int,
  private val ptsTable: LongArray,
  private val roi: DoubleArray?,
  private val maxSidePx: Int,
  minIntervalUs: Long,
  startPtsUs: Long,
) {
  companion object {
    /** Error text for files the decoder path cannot read correctly. */
    private const val TEN_BIT_MESSAGE =
      "This video is 10-bit / HDR. Re-export it as 8-bit H.264 (standard dynamic range) and import again."

    /** Clip facts for the import sheet and the analysis header; no decoding. */
    fun info(path: String): Map<String, Any?> {
      val mmr = MediaMetadataRetriever()
      val meta = try {
        mmr.setDataSource(path)
        fun key(k: Int) = mmr.extractMetadata(k)
        mapOf(
          "durationMs" to key(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull(),
          "rotation" to (key(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0),
          "dateRaw" to key(MediaMetadataRetriever.METADATA_KEY_DATE),
          "creationEpochMs" to parseMp4Date(key(MediaMetadataRetriever.METADATA_KEY_DATE)),
          "captureFps" to key(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toDoubleOrNull(),
        )
      } finally {
        runCatching { mmr.release() }
      }
      val ex = MediaExtractor()
      try {
        ex.setDataSource(path)
        val track = videoTrack(ex) ?: return meta + mapOf("unsupportedReason" to "No video track in this file.")
        val fmt = ex.getTrackFormat(track)
        ex.selectTrack(track)
        val pts = ptsTable(ex)
        val rot = meta["rotation"] as Int
        val w = fmt.intOr(MediaFormat.KEY_WIDTH, 0)
        val h = fmt.intOr(MediaFormat.KEY_HEIGHT, 0)
        val sideways = rot == 90 || rot == 270
        return meta + mapOf(
          "mime" to fmt.getString(MediaFormat.KEY_MIME),
          "width" to if (sideways) h else w, // upright size, as the user sees the video
          "height" to if (sideways) w else h,
          "frameCount" to pts.size,
          "firstPtsUs" to pts.firstOrNull(),
          "lastPtsUs" to pts.lastOrNull(),
          // Mean rate from the real time stamps; "nominalFps" is what the file claims.
          "meanFps" to if (pts.size > 1 && pts.last() > pts.first()) (pts.size - 1) * 1e6 / (pts.last() - pts.first()) else null,
          "nominalFps" to fmt.intOr(MediaFormat.KEY_FRAME_RATE, 0).takeIf { it > 0 },
          "unsupportedReason" to unsupportedReason(fmt),
        )
      } finally {
        runCatching { ex.release() }
      }
    }

    /**
     * Opens [path] for decoding. [roi] = (cx, cy, side) as fractions of the upright frame (the
     * live ROI convention) or null for the whole frame. Sampling starts at [startPtsUs] and then
     * takes one frame per [minIntervalUs] (0 = every frame). [maxSidePx] caps the converted
     * picture: a larger area is averaged down by a whole-number step.
     */
    fun open(path: String, roi: DoubleArray?, startPtsUs: Long, minIntervalUs: Long, maxSidePx: Int): VideoFrameSource {
      val ex = MediaExtractor()
      var dec: MediaCodec? = null
      try {
        ex.setDataSource(path)
        val track = videoTrack(ex) ?: throw IllegalArgumentException("No video track in this file.")
        val fmt = ex.getTrackFormat(track)
        unsupportedReason(fmt)?.let { throw IllegalArgumentException(it) }
        ex.selectTrack(track)
        val pts = ptsTable(ex)
        ex.seekTo(startPtsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val mmr = MediaMetadataRetriever()
        val rot = try {
          mmr.setDataSource(path)
          mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } finally {
          runCatching { mmr.release() }
        }
        val mime = fmt.getString(MediaFormat.KEY_MIME)!!
        dec = MediaCodec.createDecoderByType(mime)
        // "Flexible" YUV: we read the planes through Image, whatever the chip's own layout is.
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        dec.configure(fmt, null, null, 0)
        dec.start()
        return VideoFrameSource(ex, dec, fmt, ((rot % 360) + 360) % 360, pts, roi, max(32, maxSidePx), max(0L, minIntervalUs), startPtsUs)
      } catch (e: Throwable) {
        runCatching { dec?.release() }
        runCatching { ex.release() }
        throw e
      }
    }

    private fun videoTrack(ex: MediaExtractor): Int? =
      (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }

    /** Every sample time of the selected track, sorted = display order (reads no picture data). */
    private fun ptsTable(ex: MediaExtractor): LongArray {
      ex.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
      var out = LongArray(1024)
      var n = 0
      while (true) {
        val t = ex.sampleTime
        if (t < 0) break
        if (n == out.size) out = out.copyOf(n * 2)
        out[n++] = t
        if (!ex.advance()) break
      }
      return out.copyOf(n).also { it.sort() }
    }

    /** Plain-language reason this file can't be read correctly, or null when it can. */
    private fun unsupportedReason(fmt: MediaFormat): String? {
      val mime = fmt.getString(MediaFormat.KEY_MIME) ?: return "Unknown video format."
      if (mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) return TEN_BIT_MESSAGE
      val profile = fmt.intOr(MediaFormat.KEY_PROFILE, -1)
      val tenBitProfiles = when (mime) {
        MediaFormat.MIMETYPE_VIDEO_HEVC -> setOf(2, 4096, 8192) // Main10, Main10 HDR10, HDR10+
        MediaFormat.MIMETYPE_VIDEO_VP9 -> setOf(4, 8, 4096, 8192, 16384, 32768) // Profile 2/3 (+HDR)
        "video/av01" -> setOf(2, 4096, 8192) // Main10 (+HDR)
        MediaFormat.MIMETYPE_VIDEO_AVC -> setOf(16) // High10
        else -> emptySet()
      }
      if (profile in tenBitProfiles) return TEN_BIT_MESSAGE
      val transfer = fmt.intOr(MediaFormat.KEY_COLOR_TRANSFER, -1)
      if (transfer == MediaFormat.COLOR_TRANSFER_ST2084 || transfer == MediaFormat.COLOR_TRANSFER_HLG) return TEN_BIT_MESSAGE
      return null
    }

    /** MP4 creation time ("20260924T101500.000Z", UTC) to epoch ms; null when absent or unset (1904/1970). */
    internal fun parseMp4Date(raw: String?): Long? {
      val m = Regex("""^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})""").find(raw ?: return null) ?: return null
      val v = m.groupValues.drop(1).map { it.toInt() }
      if (v[0] < 1980) return null
      val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
      cal.clear()
      cal.set(v[0], v[1] - 1, v[2], v[3], v[4], v[5])
      return cal.timeInMillis
    }

    private fun MediaFormat.intOr(key: String, fallback: Int): Int =
      if (containsKey(key)) runCatching { getInteger(key) }.getOrDefault(fallback) else fallback
  }

  // --- decode state -------------------------------------------------------------------------

  private val info = MediaCodec.BufferInfo()
  private var inputDone = false
  private var outputDone = false
  private val sampler = PtsSampler(minIntervalUs, startPtsUs)
  private var outFormat: MediaFormat? = null
  private var namesSent = false

  // Filled from the first decoded picture (the true size can differ from the file header).
  private var frameW = 0
  private var frameH = 0
  private var roiPx: IntArray? = null // upright x, y, width, height (px) of the analysed area
  private var pixels = IntArray(0)
  private var bitmap: Bitmap? = null
  private var yRow = ByteArray(0)
  private var uRow = ByteArray(0)
  private var vRow = ByteArray(0)
  private var acc = IntArray(0)

  /**
   * Decodes until [maxFrames] sampled frames were detected, [budgetMs] passed (after at least one
   * frame), or the clip ended. [predict] runs the detector on the upright ROI bitmap and returns
   * boxes as (left, top, right, bottom, conf, classIndex) in that bitmap's pixels, plus names.
   */
  fun next(maxFrames: Int, budgetMs: Long, predict: (Bitmap) -> Pair<List<FloatArray>, List<String>>): Map<String, Any?> {
    val t0 = System.nanoTime()
    var lastOutputNs = t0
    var decodeNs = 0L
    var convertNs = 0L
    var inferNs = 0L
    var decoded = 0
    var names: List<String>? = null
    val frames = ArrayList<Map<String, Any>>()
    while (!outputDone && frames.size < maxFrames) {
      if (frames.isNotEmpty() && (System.nanoTime() - t0) / 1_000_000 >= budgetMs) break
      val td = System.nanoTime()
      feedInput()
      val idx = decoder.dequeueOutputBuffer(info, 10_000)
      decodeNs += System.nanoTime() - td
      when {
        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outFormat = decoder.outputFormat
        idx < 0 -> {
          // A healthy decoder answers within a few frames; a silent one would hang the job.
          // After the last sample went in, silence just means some decoders never flag the end.
          if ((System.nanoTime() - lastOutputNs) / 1_000_000 > 5_000) {
            if (inputDone) outputDone = true
            else throw IllegalStateException("The video decoder stopped responding near ${sampler.nextDueUs / 1_000_000} s.")
          }
        }
        else -> {
          lastOutputNs = System.nanoTime()
          if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
          val pts = info.presentationTimeUs
          val take = info.size > 0 && sampler.take(pts)
          if (take) {
            val tc = System.nanoTime()
            val image = decoder.getOutputImage(idx) ?: throw IllegalStateException("The decoder returned no picture.")
            val bmp = try { convert(image) } finally { image.close() }
            decoder.releaseOutputBuffer(idx, false)
            convertNs += System.nanoTime() - tc
            val ti = System.nanoTime()
            val (boxes, n) = predict(bmp)
            inferNs += System.nanoTime() - ti
            if (!namesSent) { names = n; namesSent = true }
            frames.add(mapOf("pts" to pts, "frame" to frameIndex(pts), "boxes" to toFrameBoxes(boxes, bmp)))
          } else {
            decoder.releaseOutputBuffer(idx, false)
          }
          if (info.size > 0) decoded++
        }
      }
    }
    val r = roiPx
    return mapOf(
      "frames" to frames,
      "done" to outputDone,
      "decoded" to decoded,
      "frameWidth" to frameW,
      "frameHeight" to frameH,
      "roi" to r?.toList(),
      "names" to names,
      "decodeMs" to decodeNs / 1e6,
      "convertMs" to convertNs / 1e6,
      "inferMs" to inferNs / 1e6,
    )
  }

  fun close() {
    runCatching { decoder.stop() }
    runCatching { decoder.release() }
    runCatching { extractor.release() }
    bitmap?.recycle()
    bitmap = null
  }

  private fun feedInput() {
    if (inputDone) return
    while (true) {
      val i = decoder.dequeueInputBuffer(0)
      if (i < 0) return
      val buf = decoder.getInputBuffer(i)!!
      val n = extractor.readSampleData(buf, 0)
      if (n < 0) {
        decoder.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        inputDone = true
        return
      }
      decoder.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
      extractor.advance()
    }
  }

  /** 0-based position of [pts] among all frames in display order (what CVAT calls frame N-1). */
  private fun frameIndex(pts: Long): Int {
    val i = java.util.Arrays.binarySearch(ptsTable, pts)
    return if (i >= 0) i else -i - 1
  }

  /** Boxes from bitmap pixels to 0..1 of the whole upright frame, 4 decimals (live raw_detections shape). */
  private fun toFrameBoxes(boxes: List<FloatArray>, bmp: Bitmap): List<List<Any>> {
    val r = roiPx!!
    val sx = r[2].toDouble() / bmp.width
    val sy = r[3].toDouble() / bmp.height
    fun r4(v: Double) = (v * 10_000).roundToInt() / 10_000.0
    return boxes.map { b ->
      listOf<Any>(
        r4((r[0] + b[0] * sx) / frameW), r4((r[1] + b[1] * sy) / frameH),
        r4((r[0] + b[2] * sx) / frameW), r4((r[1] + b[3] * sy) / frameH),
        r4(b[4].toDouble()), b[5].toInt(),
      )
    }
  }

  // --- YUV -> RGB of the ROI only ------------------------------------------------------------

  private fun convert(image: android.media.Image): Bitmap {
    val crop = image.cropRect
    val rawW = crop.width()
    val rawH = crop.height()
    val planes = image.planes
    // 10-bit output ("P010") stores 2 bytes per brightness sample; our 8-bit math would be garbage.
    if (planes[0].pixelStride != 1 || outFormat?.intOr(MediaFormat.KEY_COLOR_FORMAT, 0) == 54) {
      throw IllegalArgumentException(TEN_BIT_MESSAGE)
    }
    val sideways = rotation == 90 || rotation == 270
    val upW = if (sideways) rawH else rawW
    val upH = if (sideways) rawW else rawH
    if (frameW != upW || frameH != upH) {
      frameW = upW
      frameH = upH
      roiPx = roiRect(upW, upH)
    }
    val (ux, uy, rw, rh) = roiPx!!
    // Upright rectangle -> raw buffer rectangle (port of MainActivity.rawRectForUprightRect).
    val l = ux; val t = uy; val r = ux + rw; val b = uy + rh
    val raw = when (rotation) {
      90 -> intArrayOf(t, rawH - r, b, rawH - l)
      180 -> intArrayOf(rawW - r, rawH - b, rawW - l, rawH - t)
      270 -> intArrayOf(rawW - b, l, rawW - t, r)
      else -> intArrayOf(l, t, r, b)
    }
    val spanW = raw[2] - raw[0]
    val spanH = raw[3] - raw[1]
    val step = max(1, max(spanW, spanH) / maxSidePx)
    val outW = spanW / step
    val outH = spanH / step
    val bmpW = if (sideways) outH else outW
    val bmpH = if (sideways) outW else outH
    if (pixels.size != outW * outH) pixels = IntArray(outW * outH)
    if (acc.size < outW) acc = IntArray(outW)

    val (yOff, yMul, coef) = colourCoefficients(rawW, rawH)
    val (rv, gu, gv, bu) = coef
    val yPlane = planes[0]; val uPlane = planes[1]; val vPlane = planes[2]
    val yBuf = yPlane.buffer; val uBuf = uPlane.buffer; val vBuf = vPlane.buffer
    val yRs = yPlane.rowStride
    val uvRs = uPlane.rowStride; val uvPs = uPlane.pixelStride
    val x0 = crop.left + raw[0]
    val yLen = outW * step
    if (yRow.size < yLen) yRow = ByteArray(yLen)
    val cx0 = x0 shr 1
    val cx1 = (x0 + (outW - 1) * step + step / 2) shr 1
    val cLen = (cx1 - cx0) * uvPs + 1
    if (uRow.size < cLen) { uRow = ByteArray(cLen); vRow = ByteArray(cLen) }
    val area = step * step

    // The loop below runs once per output pixel (millions per frame), so it only touches locals
    // and walks the output index by a fixed step instead of recomputing the rotation each time.
    val yr = yRow; val ur = uRow; val vr = vRow; val ac = acc; val out = pixels
    val vRs = vPlane.rowStride; val vPs = vPlane.pixelStride
    val dx = when (rotation) { 90 -> bmpW; 180 -> -1; 270 -> -bmpW; else -> 1 }
    for (oy in 0 until outH) {
      val sy0 = crop.top + raw[1] + oy * step
      if (step == 1) {
        readRow(yBuf, sy0 * yRs + x0, yr, yLen)
      } else {
        java.util.Arrays.fill(ac, 0, outW, 0)
        for (k in 0 until step) {
          readRow(yBuf, (sy0 + k) * yRs + x0, yr, yLen)
          var sx = 0
          for (ox in 0 until outW) {
            var sum = 0
            for (j in 0 until step) sum += yr[sx + j].toInt() and 0xFF
            ac[ox] += sum
            sx += step
          }
        }
      }
      val cy = (sy0 + step / 2) shr 1
      readRow(uBuf, cy * uvRs + cx0 * uvPs, ur, cLen)
      readRow(vBuf, cy * vRs + cx0 * vPs, vr, cLen)
      // Where raw pixel (0, oy) lands in the upright bitmap.
      var dst = when (rotation) {
        90 -> outH - 1 - oy
        180 -> (outH - 1 - oy) * bmpW + outW - 1
        270 -> (outW - 1) * bmpW + oy
        else -> oy * bmpW
      }
      var xs = x0 + step / 2 // raw x of this pixel's colour sample
      for (ox in 0 until outW) {
        val yv = if (step == 1) yr[ox].toInt() and 0xFF else ac[ox] / area
        val ci = ((xs shr 1) - cx0) * uvPs
        val u = (ur[ci].toInt() and 0xFF) - 128
        val v = (vr[ci].toInt() and 0xFF) - 128
        val c = (yv - yOff) * yMul
        var red = (c + rv * v + 512) shr 10
        var green = (c - gu * u - gv * v + 512) shr 10
        var blue = (c + bu * u + 512) shr 10
        if (red < 0) red = 0 else if (red > 255) red = 255
        if (green < 0) green = 0 else if (green > 255) green = 255
        if (blue < 0) blue = 0 else if (blue > 255) blue = 255
        out[dst] = -0x1000000 or (red shl 16) or (green shl 8) or blue
        dst += dx
        xs += step
      }
    }
    val bmp = bitmap?.takeIf { it.width == bmpW && it.height == bmpH }
      ?: Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888).also { bitmap?.recycle(); bitmap = it }
    bmp.setPixels(pixels, 0, bmpW, 0, 0, bmpW, bmpH)
    return bmp
  }

  /** Upright analysed area (x, y, w, h): the live photo crop's rounding (MainActivity.cropRoiJpeg), or the whole frame. */
  private fun roiRect(upW: Int, upH: Int): IntArray {
    val rr = roi ?: return intArrayOf(0, 0, upW, upH)
    val cap = (min(upW, upH) / 32) * 32
    val px = (((rr[2] * upW) / 32.0).roundToInt() * 32).coerceIn(32, max(32, cap))
    return intArrayOf(
      (rr[0] * upW - px / 2.0).roundToInt().coerceIn(0, upW - px),
      (rr[1] * upH - px / 2.0).roundToInt().coerceIn(0, upH - px),
      px,
      px,
    )
  }

  private fun readRow(buf: ByteBuffer, pos: Int, into: ByteArray, len: Int) {
    val n = min(len, buf.limit() - pos)
    buf.position(pos)
    buf.get(into, 0, n)
  }

  /**
   * Fixed-point (x1024) YUV->RGB factors: (Y offset, Y multiplier, [rv, gu, gv, bu]). Colour
   * standard and range come from the decoder output or the file; when neither says, HD video
   * (720p and up) is BT.709 and smaller video BT.601, both "limited range" (Y from 16 to 235),
   * which is what phone cameras record.
   */
  private fun colourCoefficients(rawW: Int, rawH: Int): Triple<Int, Int, IntArray> {
    fun key(k: String): Int = outFormat?.intOr(k, -1)?.takeIf { it > 0 } ?: inputFormat.intOr(k, -1)
    val standard = key(MediaFormat.KEY_COLOR_STANDARD)
    val bt601 = standard == MediaFormat.COLOR_STANDARD_BT601_PAL || standard == MediaFormat.COLOR_STANDARD_BT601_NTSC ||
      (standard <= 0 && min(rawW, rawH) < 720)
    val full = key(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL
    return when {
      !full && !bt601 -> Triple(16, 1192, intArrayOf(1836, 218, 546, 2163))
      !full && bt601 -> Triple(16, 1192, intArrayOf(1634, 401, 833, 2066))
      full && !bt601 -> Triple(0, 1024, intArrayOf(1613, 192, 479, 1900))
      else -> Triple(0, 1024, intArrayOf(1436, 352, 731, 1815))
    }
  }
}

/**
 * Picks frames for a target analysis rate (same rule as the round-129 time-lapse clock): take a
 * frame once its PTS reaches the next deadline, with 1/10 interval tolerance for timing jitter.
 * After a long gap the grid restarts at the taken frame instead of bursting to catch up.
 * [intervalUs] 0 = every frame. Frames must arrive in display order.
 */
internal class PtsSampler(private val intervalUs: Long, startUs: Long) {
  var nextDueUs = startUs
    private set

  fun take(pts: Long): Boolean {
    if (pts < nextDueUs - intervalUs / 10) return false
    nextDueUs = when {
      intervalUs == 0L -> pts + 1 // every frame, but never the same time stamp twice
      pts - nextDueUs >= intervalUs -> pts + intervalUs
      else -> nextDueUs + intervalUs
    }
    return true
  }
}
