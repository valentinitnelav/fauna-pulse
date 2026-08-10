// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

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
 * Activity (the YOLO preview view). This service only (a) shows the persistent
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

        val notification: Notification = (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
            )
            .setContentTitle("FaunaPulse — recording")
            .setContentText("Detecting and logging visits. Keep the app open.")
            .setSmallIcon(applicationInfo.icon)
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

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        mainHandler.removeCallbacks(renewWakeLock)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "faunapulse_recording"
        private const val NOTIFICATION_ID = 4711
        private const val WAKELOCK_TAG = "FaunaPulse::RecordingWakeLock"
        private const val WAKELOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val WAKELOCK_RENEW_MS = 25L * 60L * 1000L
    }
}
