// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.faunapulse.app.R

/**
 * Round 319: a **foreground service** for the long analysis jobs that run on saved sessions:
 * "Find animals in videos", "Find animals in photos" and Identify organisms.
 *
 * Why this exists: in the stress test of 2026-10-20, MIUI killed Identify 22 s after the user
 * pressed Home (the app used about 1.6 GB on a 3.6 GB phone); nothing told Android the work was
 * still wanted. A foreground service with an ongoing notification does, and a partial wake lock
 * keeps the CPU going with the screen off.
 *
 * Like [RecordingService] it does no work itself: the job runs in the Flutter engine of
 * [MainActivity]. Dart holds and releases it through AnalysisKeepAlive (reference counted) over
 * the `faunapulse/keepalive` channel ("startAnalysis" / "stopAnalysis"), and sets the
 * notification's words per job.
 *
 * Type: `dataSync` on Android 10 to 14, `mediaProcessing` on Android 15+ (the type made for
 * processing media files on the phone). Both have a 6-hour daily limit on Android 15+; see
 * [onTimeout].
 *
 * All calls ([request], [release]) and the service callbacks run on the main thread, so the
 * state below needs no lock.
 */
class AnalysisService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val renewWakeLock = Runnable { refreshWakeLock() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // startForeground first, always: Android ends the app if a service started with
        // startForegroundService does not call it within a few seconds, even when Dart has
        // already released its hold.
        starting = false
        if (!startInForeground() || !wanted) {
            // Refused, or released while the service was being started.
            stopSelf()
            return START_NOT_STICKY
        }
        current = this
        acquireWakeLock()
        // The job lives in the Flutter engine: a service-only restart could not continue it.
        return START_NOT_STICKY
    }

    private fun startInForeground(): Boolean {
        val notification = buildNotification(this)
        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING,
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
                else -> startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: RuntimeException) {
            // Android 12+: ForegroundServiceStartNotAllowedException (the app went to the
            // background in between); Android 15+: the daily limit of the type is used up.
            Log.w(TAG, "startForeground refused: $e")
            false
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

    /** Same self-releasing renewal as RecordingService: an orphaned lock ends by itself. */
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

    /** Swiping FaunaPulse away in Recents ends the Flutter engine and with it the job. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /**
     * Android 15+: the type's 6-hour daily limit is reached. The service must stop at once, or
     * the system ends the app with an error. The job itself goes on, unprotected.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground service time limit reached (type $fgsType)")
        stopSelf()
    }

    override fun onDestroy() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        wakeLock = null
        mainHandler.removeCallbacks(renewWakeLock)
        if (current === this) current = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "AnalysisService"
        private const val CHANNEL_ID = "faunapulse_analysis"
        private const val NOTIFICATION_ID = 4712
        private const val WAKELOCK_TAG = "FaunaPulse::AnalysisWakeLock"
        private const val WAKELOCK_TIMEOUT_MS = 30L * 60L * 1000L
        private const val WAKELOCK_RENEW_MS = 25L * 60L * 1000L

        /** The running instance, after its startForeground. */
        private var current: AnalysisService? = null

        /** startForegroundService was called and onStartCommand has not come yet. */
        private var starting = false

        /** Whether Dart holds the service now. */
        private var wanted = false
        private var title = "FaunaPulse is analyzing"
        private var text = ""

        /**
         * Starts the service, or only changes its notification's words when it runs. Returns false
         * when Android does not allow the start (Android 12+ refuses it while the app is in the
         * background); never throws.
         */
        fun request(context: Context, newTitle: String, newText: String): Boolean {
            title = newTitle
            text = newText
            wanted = true
            val running = current
            if (running != null) {
                // Already in the foreground: a new notification with the same id replaces the old
                // one. No new start, which Android could refuse from the background.
                try {
                    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.notify(NOTIFICATION_ID, buildNotification(running))
                } catch (e: RuntimeException) {
                    Log.w(TAG, "notification update failed: $e")
                }
                return true
            }
            if (starting) return true // onStartCommand uses the newest words
            return try {
                ContextCompat.startForegroundService(context, Intent(context, AnalysisService::class.java))
                starting = true
                true
            } catch (e: RuntimeException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException) {
                    Log.w(TAG, "start not allowed from the background")
                } else {
                    Log.w(TAG, "start failed: $e")
                }
                wanted = false
                false
            }
        }

        /** Dart released its last hold (or the Activity finishes). */
        fun release(context: Context) {
            wanted = false
            // While starting, onStartCommand calls startForeground and then stops itself.
            if (current != null) {
                current = null
                context.stopService(Intent(context, AnalysisService::class.java))
            }
        }

        private const val REMINDER_CHANNEL_ID = "faunapulse_identify_waiting"
        private const val REMINDER_ID = 4713

        /**
         * Round 319, part 2: an ordinary notification (not the service's) that asks the user to open
         * FaunaPulse, shown when "Also identify them" waits because the phone has too little free
         * memory to load the model while the app is in the background. A tap opens FaunaPulse
         * where it was; the Dart side starts the identification once the app is in front and
         * cancels this. Returns false when it could not be shown (Android 13+ without the
         * notification permission, notifications turned off); never throws.
         */
        fun showReminder(context: Context, title: String, text: String): Boolean {
            return try {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val channel = NotificationChannel(
                        REMINDER_CHANNEL_ID,
                        "Identification waiting",
                        // Default importance: the user should notice it (one sound, no peeking).
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = "Shown when FaunaPulse needs to be opened to identify the animals it found."
                    }
                    manager.createNotificationChannel(channel)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !manager.areNotificationsEnabled()) return false
                val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                    PendingIntent.getActivity(context, 1, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                }
                val builder = (
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Notification.Builder(context, REMINDER_CHANNEL_ID)
                    } else {
                        @Suppress("DEPRECATION")
                        Notification.Builder(context)
                    }
                    )
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(Notification.BigTextStyle().bigText(text))
                    .setSmallIcon(R.drawable.ic_notification)
                    .setAutoCancel(true)
                if (open != null) builder.setContentIntent(open)
                manager.notify(REMINDER_ID, builder.build())
                true
            } catch (e: RuntimeException) {
                // SecurityException on Android 13+ without the permission, or anything else.
                Log.w(TAG, "reminder not shown: $e")
                false
            }
        }

        /** Removes the reminder of [showReminder], if shown. Never throws. */
        fun cancelReminder(context: Context) {
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(REMINDER_ID)
            } catch (e: RuntimeException) {
                Log.w(TAG, "reminder not removed: $e")
            }
        }

        private fun buildNotification(context: Context): Notification {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Finding and identifying animals",
                    // Low importance: persistent but silent (no sound/peeking).
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while FaunaPulse finds or identifies animals in a saved session."
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
            // A tap opens FaunaPulse where it was (singleTop Activity).
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
                PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            val builder = (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(context, CHANNEL_ID)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(context)
                }
                )
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setSmallIcon(R.drawable.ic_notification)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
            if (open != null) builder.setContentIntent(open)
            return builder.build()
        }
    }
}
