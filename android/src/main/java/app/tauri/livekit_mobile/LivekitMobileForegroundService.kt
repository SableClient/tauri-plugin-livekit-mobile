package app.tauri.livekit_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground-service notification shown while a native room exists. Audio
 * focus and routing are owned by the LiveKit SDK, not by this plugin.
 */
class LivekitMobileForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val wantsMicrophone = intent?.getBooleanExtra(EXTRA_MICROPHONE, false) ?: false
        val wantsPlayback = intent?.getBooleanExtra(EXTRA_PLAYBACK, true) ?: true
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var types = 0
                if (wantsMicrophone) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                if (wantsPlayback) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (types != 0) {
                    startForeground(NOTIFICATION_ID, buildNotification(), types)
                } else {
                    startForeground(NOTIFICATION_ID, buildNotification())
                }
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
            true
        } catch (_: SecurityException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: IllegalStateException) {
            false
        }
        if (!started) {
            stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Call audio",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    // Branding comes from the host application (launcher icon and label); the
    // plugin does not ship its own notification assets.
    private fun buildNotification(): Notification {
        val appInfo = applicationInfo
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(appInfo.icon)
            .setContentTitle(appInfo.loadLabel(packageManager))
            .setContentText("Call in progress")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        const val EXTRA_MICROPHONE = "app.tauri.livekit_mobile.extra.MICROPHONE"
        const val EXTRA_PLAYBACK = "app.tauri.livekit_mobile.extra.PLAYBACK"

        private const val CHANNEL_ID = "livekit_mobile_audio"
        private const val NOTIFICATION_ID = 1396
    }
}
