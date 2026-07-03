// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapRegionDecoder
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterFragmentActivity() {
    // Channel name shared with the Dart side (DeviceThermal). "Thermal" here means
    // how warm/throttled the phone is during long real-time detection sessions.
    private val thermalChannel = "pollinator/thermal"

    // Channel for fast ROI cropping of full-resolution stills (RoiCaptureScheduler).
    private val cropChannel = "pollinator/crop"

    // Channel for diagnostics: capturing this app's recent logcat into an error report.
    private val diagnosticsChannel = "pollinator/diagnostics"

    // Channel for keeping long sessions alive: start/stop the recording foreground
    // service, and check/request exemption from battery optimization (RecordingKeepAlive).
    private val keepAliveChannel = "pollinator/keepalive"
    private val cropExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 15 deprecates the Window system-bar color setters. SystemBarStyle makes both bars
        // transparent through the supported API on every Android version (and disables the navigation
        // bar contrast scrim where it applies).
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, thermalChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getThermal" -> result.success(readThermal())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cropChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cropRoiJpeg" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val cx = (call.argument<Double>("cx") ?: 0.5)
                        val cy = (call.argument<Double>("cy") ?: 0.5)
                        val side = (call.argument<Double>("side") ?: 0.5)
                        val quality = (call.argument<Int>("quality") ?: 90)
                        // Max saved side in pixels; crops larger than this are
                        // downscaled before encoding. 0 (or absent) = no cap.
                        val maxPx = (call.argument<Int>("maxPx") ?: 0)
                        // Round 63: stills arrive UNROTATED (capturePhotoRaw) so the
                        // 12 MP frame never pays a full rotate; these say how to map
                        // the upright ROI into the raw pixels.
                        val rotationDegrees = (call.argument<Int>("rotationDegrees") ?: 0)
                        val isFront = (call.argument<Boolean>("isFront") ?: false)
                        if (bytes == null) {
                            result.error("bad_args", "bytes required", null)
                        } else {
                            // Decode only the ROI rectangle off the main thread, then
                            // return the result on the platform thread.
                            cropExecutor.execute {
                                val cropped = try {
                                    cropRoiJpeg(bytes, cx, cy, side, quality, maxPx, rotationDegrees, isFront)
                                } catch (e: Exception) {
                                    null
                                }
                                mainHandler.post {
                                    if (cropped != null) result.success(cropped)
                                    else result.error("crop_failed", "region decode failed", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, diagnosticsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "captureLogcat" -> {
                        val maxLines = call.argument<Int>("maxLines") ?: 3000
                        cropExecutor.execute {
                            val log = try {
                                captureLogcat(maxLines)
                            } catch (e: Exception) {
                                "logcat capture failed: ${e.message}"
                            }
                            mainHandler.post { result.success(log) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keepAliveChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        ContextCompat.startForegroundService(
                            this, Intent(this, RecordingService::class.java),
                        )
                        result.success(true)
                    }
                    "stopService" -> {
                        stopService(Intent(this, RecordingService::class.java))
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" ->
                        result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" ->
                        result.success(requestIgnoreBatteryOptimizations())
                    else -> result.notImplemented()
                }
            }
    }

    /// True when this app is exempt from battery optimization (so the OS / OEM
    /// "battery manager" won't doze or kill it during a long session). Pre-Doze
    /// devices (< API 23) are always considered exempt.
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /// Opens the system dialog asking the user to allow this app to run without
    /// battery restrictions. Falls back to the app's battery-optimization settings
    /// list if the direct request intent isn't available on the device. Returns
    /// whether an intent could be launched.
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    /// Reads this app's own recent log output (a non-rooted app only sees its own
    /// process logs) so it can be bundled into an error report. Bounded to the last
    /// [maxLines] lines with timestamps. Runs off the main thread (it spawns a
    /// process and reads its output).
    private fun captureLogcat(maxLines: Int): String {
        // -d: dump and exit; -v time: timestamped; -t: last N lines; --pid: only us.
        val pid = android.os.Process.myPid().toString()
        val process = ProcessBuilder(
            "logcat", "-d", "-v", "time", "-t", maxLines.toString(), "--pid", pid,
        ).redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        // Some OEM builds reject --pid; fall back to an unfiltered (still own-app) dump.
        return if (text.isBlank()) {
            ProcessBuilder("logcat", "-d", "-v", "time", "-t", maxLines.toString())
                .redirectErrorStream(true).start()
                .inputStream.bufferedReader().use { it.readText() }
        } else {
            text
        }
    }

    /// Crops a SQUARE region of interest out of a (full-resolution) JPEG by
    /// decoding ONLY that rectangle with [BitmapRegionDecoder] — so we never
    /// decode the whole multi-megapixel image. [cx],[cy],[side] are normalized
    /// (0..1) in the UPRIGHT image; the side is taken from the upright width and
    /// snapped to a multiple of 32 (model-friendly), matching the live readout.
    /// [maxPx] > 0 caps the SAVED side: a larger crop is downscaled (with
    /// bilinear filtering) to the largest multiple of 32 that fits the cap —
    /// never upscaled — to bound file size when the ROI is big.
    ///
    /// Round 63: the JPEG may be UNROTATED, exactly as the camera delivered it
    /// ([rotationDegrees] = clockwise rotation that would make it upright,
    /// [isFront] = mirrored preview). Instead of rotating the whole 12 MP frame
    /// (~1.5 s), the upright ROI rectangle is mapped into raw coordinates,
    /// decoded there, and only the small square is rotated/mirrored.
    private fun cropRoiJpeg(
        bytes: ByteArray,
        cx: Double,
        cy: Double,
        side: Double,
        quality: Int,
        maxPx: Int = 0,
        rotationDegrees: Int = 0,
        isFront: Boolean = false,
    ): ByteArray? {
        @Suppress("DEPRECATION")
        val decoder = BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false)
            ?: return null
        try {
            val rawW = decoder.width
            val rawH = decoder.height
            // BitmapRegionDecoder ignores EXIF, so the pixels are raw; compute
            // the upright frame the ROI fractions refer to.
            val rot = ((rotationDegrees % 360) + 360) % 360
            val sideways = rot == 90 || rot == 270
            val w = if (sideways) rawH else rawW
            val h = if (sideways) rawW else rawH
            // Square side in pixels, rounded to the nearest multiple of 32 (matches
            // the Dart snapToMultipleOf32 readout), capped to the largest 32-multiple
            // that fits the short side so saved size == displayed size.
            val cap = (min(w, h) / 32) * 32
            var px = ((side * w) / 32.0).roundToInt() * 32
            px = px.coerceIn(32, maxOf(32, cap))
            var x = (cx * w - px / 2.0).roundToInt().coerceIn(0, w - px)
            var y = (cy * h - px / 2.0).roundToInt().coerceIn(0, h - px)
            // The ROI was placed on the mirrored preview for front cameras:
            // un-mirror its X before mapping into raw coordinates.
            if (isFront) x = w - px - x
            val rr = rawRectForUprightRect(rot, rawW, rawH, x, y, x + px, y + px)
            var region: Bitmap = decoder.decodeRegion(rr, null)
            // Apply the user's target-side cap BEFORE rotating — cheaper to
            // rotate the smaller square (mirrors Dart capSavedSidePx).
            val savedCap = if (maxPx > 0) maxOf(32, (maxPx / 32) * 32) else 0
            if (savedCap in 1 until px) {
                val scaled = Bitmap.createScaledBitmap(region, savedCap, savedCap, true)
                if (scaled !== region) region.recycle()
                region = scaled
            }
            if (rot != 0 || isFront) {
                val m = Matrix()
                if (rot != 0) m.postRotate(rot.toFloat())
                if (isFront) m.postScale(-1f, 1f)
                val turned = Bitmap.createBitmap(region, 0, 0, region.width, region.height, m, true)
                if (turned !== region) region.recycle()
                region = turned
            }
            val out = ByteArrayOutputStream()
            region.compress(Bitmap.CompressFormat.JPEG, quality, out)
            region.recycle()
            return out.toByteArray()
        } finally {
            decoder.recycle()
        }
    }

    /// Where an upright-frame rectangle lands inside the RAW (unrotated) still.
    /// Mirror of `rawRectForUprightRect` in lib/pollinator/capture/roi_capture.dart
    /// (which has the unit tests) — keep the two in sync.
    private fun rawRectForUprightRect(
        rot: Int,
        rawW: Int,
        rawH: Int,
        l: Int,
        t: Int,
        r: Int,
        b: Int,
    ): Rect = when (rot) {
        90 -> Rect(t, rawH - r, b, rawH - l)
        180 -> Rect(rawW - r, rawH - b, rawW - l, rawH - t)
        270 -> Rect(rawW - b, l, rawW - t, r)
        else -> Rect(l, t, r, b)
    }

    /// Returns the battery temperature (a good proxy for how warm the phone is)
    /// in degrees Celsius, plus the OS "thermal status" (NONE..SHUTDOWN) that
    /// tells us whether the system is actively throttling to cool down. Also
    /// returns the live battery power figures (current, voltage, remaining charge,
    /// and whether it is charging) so the app can estimate how much ENERGY a
    /// recording session uses:
    ///   - power right now (watts) = |current| (amps) × voltage (volts);
    ///   - total session energy can also be cross-checked from how much the
    ///     "charge counter" (remaining capacity) dropped over the session.
    /// All of these come from the framework BatteryManager, which a normal
    /// (non-rooted) app is allowed to read.
    private fun readThermal(): Map<String, Any?> {
        val out = HashMap<String, Any?>()

        // Battery temperature comes from the sticky battery-changed broadcast as
        // tenths of a degree Celsius (e.g. 312 -> 31.2 °C).
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tenths = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        out["batteryTempC"] =
            if (tenths != null && tenths != Int.MIN_VALUE) tenths / 10.0 else null

        // Battery voltage, reported by the same broadcast in millivolts (e.g.
        // 4012 -> 4.012 V). Null if the device doesn't report it.
        val mv = intent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, Int.MIN_VALUE)
        out["batteryVoltageMv"] = if (mv != null && mv != Int.MIN_VALUE && mv > 0) mv else null

        // Whether the phone is plugged in / charging. An energy estimate is only
        // meaningful while UNplugged (in the field), so the app warns if a session
        // ran on AC/USB power.
        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        out["isCharging"] = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL

        // Instantaneous current (microamps) and remaining charge (microamp-hours)
        // from BatteryManager. CURRENT_NOW's sign and exact units vary by phone
        // model, so the Dart side takes the magnitude; CHARGE_COUNTER is the
        // reliable basis for the session-total energy. Both can be absent on some
        // devices, so null-guard the sentinel Long.MIN_VALUE.
        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        if (bm != null) {
            val currentUa = bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            out["batteryCurrentUa"] = if (currentUa != Long.MIN_VALUE && currentUa != 0L) currentUa else null
            val chargeUah = bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
            out["chargeCounterUah"] = if (chargeUah != Long.MIN_VALUE && chargeUah > 0L) chargeUah else null
        } else {
            out["batteryCurrentUa"] = null
            out["chargeCounterUah"] = null
        }

        // Thermal status (API 29+): NONE, LIGHT, MODERATE, SEVERE, CRITICAL,
        // EMERGENCY, SHUTDOWN. Higher means the phone is throttling harder.
        val pm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            getSystemService(Context.POWER_SERVICE) as PowerManager
        } else {
            null
        }
        out["thermalStatus"] = if (pm != null) {
            when (pm.currentThermalStatus) {
                PowerManager.THERMAL_STATUS_NONE -> "none"
                PowerManager.THERMAL_STATUS_LIGHT -> "light"
                PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                else -> "unknown"
            }
        } else {
            null
        }

        // Thermal headroom (API 30+): a normalized "how close to throttling" figure
        // where 0 = cool and 1 = the temperature at which the system starts slowing
        // down to cool off (can briefly exceed 1). It comes from the SoC/skin
        // thermal sensors, so unlike battery temperature it reacts quickly and is
        // comparable across phones — it directly shows when a phone throttles (and
        // its FPS drops). Returns null when unsupported (some devices report NaN).
        out["thermalHeadroom"] = if (pm != null &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val hr = pm.getThermalHeadroom(0) // 0 s forecast = right now
                if (hr.isNaN()) null else hr.toDouble()
            } catch (e: Exception) {
                null
            }
        } else {
            null
        }
        return out
    }
}
