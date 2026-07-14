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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        acquireWakeLock()
        // START_STICKY: if the OS ever kills and recreates us, come back up (the
        // Activity, if still alive, keeps recording; otherwise this is harmless).
        return START_STICKY
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

        // On Android 10+ pass the explicit foreground-service type; on 14+ this
        // typed call is mandatory. The `camera` type matches the ongoing camera
        // session the app runs in the Activity.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
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
            // No timeout: the lock is held for the life of the service and released
            // in onDestroy. The Activity's FLAG_KEEP_SCREEN_ON keeps the screen on;
            // this just guards the CPU against momentary blips.
            acquire()
        }
    }

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "faunapulse_recording"
        private const val NOTIFICATION_ID = 4711
        private const val WAKELOCK_TAG = "FaunaPulse::RecordingWakeLock"
    }
}
