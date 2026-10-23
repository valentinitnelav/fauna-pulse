// FaunaPulse: foreground service that keeps a long recording session running.

package com.ultralytics.yolo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.faunapulse.app.R

/**
 * A minimal **foreground service** that keeps a recording session's process alive
 * for long (multi-hour / multi-day) field runs.
 *
 * Why this exists: a normal app can be killed or throttled by Android (and, more
 * aggressively, by OEM "battery managers" such as MIUI) once a session has been
 * running a while. A foreground service with an ongoing notification tells the OS
 * "this is important user-visible work — do not reclaim it", which is the
 * canonical way to make a long-running capture reliable.
 *
 * It deliberately does NOT touch the camera — the camera is owned by the Flutter
 * Activity (the YOLO preview view). Since round 292 the camera keeps running while the
 * screen is off; Android allows that because this service has the `camera` type and was
 * started while the app was on screen. This service only (a) shows the persistent
 * notification and (b) holds a partial wake lock so a momentary screen blip can't
 * suspend the CPU mid-session. It is declared with the `camera` foreground-service
 * type because the app's protected work IS a continuous camera session (and that
 * type, unlike `dataSync`, has no Android-15 daily runtime cap).
 *
 * Started/stopped from [MainActivity]'s `faunapulse/keepalive` method channel when
 * a recording begins/ends.
 */
class RecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val renewWakeLock = Runnable { refreshWakeLock() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        acquireWakeLock()
        running = true
        // The camera belongs to the Activity. If Android kills the process, a
        // service-only restart cannot resume recording and would only waste
        // battery with an orphan notification and wake lock.
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Recording session",
                // Low importance: persistent but silent (no sound/peeking).
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while a FaunaPulse session is recording."
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        // Round 319: also says that swiping the app away stops the recording
        // (onTaskRemoved below ends the service); BigTextStyle shows all of it.
        val text = "Recording, also with the screen off. To stop, open FaunaPulse. " +
            "Do not swipe FaunaPulse away from recent apps: that also stops the recording."
        val notification: Notification = (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            )
            .setContentTitle("FaunaPulse — recording")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .build()

        // On Android 11+ pass the explicit foreground-service type. The
        // `camera` type matches the ongoing camera
        // session the app runs in the Activity.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKELOCK_TAG).apply {
            setReferenceCounted(false)
        }
        refreshWakeLock()
    }

    /**
     * Keeps multi-day sessions supported while making an orphaned lock
     * self-releasing. One renewal every 25 minutes is negligible next to the
     * continuously running camera and inference workload.
     */
    private fun refreshWakeLock() {
        val lock = wakeLock ?: return
        mainHandler.removeCallbacks(renewWakeLock)
        try {
            if (lock.isHeld) lock.release()
            lock.acquire(WAKELOCK_TIMEOUT_MS)
            mainHandler.postDelayed(renewWakeLock, WAKELOCK_RENEW_MS)
        } catch (_: RuntimeException) {
            // Best effort: the foreground service still protects the process.
        }
    }

    /**
     * Swiping FaunaPulse away in Recents finishes the Activity, and with it the Flutter
     * engine and the camera, so the recording ends. Without this the service would stay
     * (foreground services survive task removal) and keep the "Recording" notification and
     * the wake lock while nothing is recorded (stress test D2b, 2026-10-20). onDestroy does
     * the clean-up. The session stays "incomplete": Dart cannot write its end row here.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        running = false
        mainHandler.removeCallbacks(renewWakeLock)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        /** Round 292: whether the service runs, so a scheduled window that starts while the
         *  screen is off does not start it again from the background (Android 12+ may refuse
         *  a background start; the service is already protecting the process). */
        @Volatile
        var running = false
            private set
        private const val CHANNEL_ID = "faunapulse_recording"
        private const val NOTIFICATION_ID = 4711
        private const val WAKELOCK_TAG = "FaunaPulse::RecordingWakeLock"
        private const val WAKELOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val WAKELOCK_RENEW_MS = 25L * 60L * 1000L
    }
}
