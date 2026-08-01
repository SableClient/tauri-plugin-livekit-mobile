package app.tauri.livekit_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.Person

/**
 * Foreground-service notification shown while a native room exists.
 *
 * Uses {@link NotificationCompat.CallStyle} on Android 12+ for the system
 * call UI (incoming call chip, ongoing call notification). On older
 * platforms falls back to the simpler ongoing-call style.
 *
 * Audio focus and routing are owned by the LiveKit SDK, not by this plugin.
 */
class LivekitMobileForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callDirection = intent?.getStringExtra(EXTRA_CALL_DIRECTION) ?: DIRECTION_ONGOING
        val callerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: ""
        val wantsMicrophone = intent?.getBooleanExtra(EXTRA_MICROPHONE, false) ?: false
        val wantsCamera = intent?.getBooleanExtra(EXTRA_CAMERA, false) ?: false
        val wantsPlayback = intent?.getBooleanExtra(EXTRA_PLAYBACK, true) ?: true

        val notification = when (callDirection) {
            DIRECTION_INCOMING -> buildIncomingCallNotification(callerName)
            DIRECTION_OUTGOING -> buildOutgoingCallNotification(callerName)
            else -> buildOngoingCallNotification(callerName)
        }

        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var types = 0
                if (wantsMicrophone) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                // Without this a backgrounded video call loses its capture; the
                // caller only sets the extra once CAMERA has been granted,
                // since an unmet precondition throws instead.
                if (wantsCamera) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (wantsPlayback) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                // FOREGROUND_SERVICE_TYPE_PHONE_CALL for targetSdk 34+ system-call usage.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                }
                startForeground(NOTIFICATION_ID, notification, types)
            } else {
                startForeground(NOTIFICATION_ID, notification)
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
            // A while-in-use type cannot start from the background and an
            // ongoing self-managed Telecom call is not an exemption, so this
            // has to reach the plugin rather than die here.
            sendBroadcast(buildActionIntent(ACTION_SERVICE_FAILED))
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

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID_ONGOING,
                "Call in progress",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID_INCOMING,
                "Incoming call",
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
    }

    // ── Incoming call notification (Android 12+ CallStyle) ─────────────────

    private fun buildIncomingCallNotification(callerName: String): Notification {
        val appInfo = applicationInfo
        val appLabel = appInfo.loadLabel(packageManager).toString()

        val declineIntent = buildActionIntent(ACTION_DECLINE)
        val answerIntent = buildActionIntent(ACTION_ANSWER)
        val declinePending = PendingIntent.getBroadcast(
            this, 0, declineIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val answerPending = PendingIntent.getBroadcast(
            this, 1, answerIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(callerName)
                .build()
            NotificationCompat.Builder(this, CHANNEL_ID_INCOMING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText("Incoming call from $callerName")
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(false)
                .setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        person,
                        declinePending,
                        answerPending,
                    ),
                )
                .setFullScreenIntent(buildFullScreenIntent(), true)
        } else {
            // Pre-Android 12: simple ongoing notification.
            NotificationCompat.Builder(this, CHANNEL_ID_INCOMING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText("Incoming call from $callerName")
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(false)
                .setFullScreenIntent(buildFullScreenIntent(), true)
        }
        return builder.build()
    }

    // ── Outgoing call notification ─────────────────────────────────────────

    private fun buildOutgoingCallNotification(callerName: String): Notification {
        val appInfo = applicationInfo
        val appLabel = appInfo.loadLabel(packageManager).toString()

        val hangupIntent = buildActionIntent(ACTION_HANGUP)
        val hangupPending = PendingIntent.getBroadcast(
            this, 2, hangupIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(callerName)
                .build()
            NotificationCompat.Builder(this, CHANNEL_ID_ONGOING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText("Calling $callerName…")
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setStyle(
                    NotificationCompat.CallStyle.forOngoingCall(
                        person,
                        hangupPending,
                    ),
                )
        } else {
            NotificationCompat.Builder(this, CHANNEL_ID_ONGOING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText("Calling $callerName…")
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
        }
        return builder.build()
    }

    // ── Ongoing call notification ──────────────────────────────────────────

    private fun buildOngoingCallNotification(callerName: String): Notification {
        val appInfo = applicationInfo
        val appLabel = appInfo.loadLabel(packageManager).toString()
        // CallStyle renders an empty Person as a blank row, and "Call with "
        // reads as a truncated string, so an unnamed call says so instead.
        val displayName = callerName.ifBlank { appLabel }
        val contentText = if (callerName.isBlank()) "Call in progress" else "Call with $callerName"

        val hangupIntent = buildActionIntent(ACTION_HANGUP)
        val hangupPending = PendingIntent.getBroadcast(
            this, 3, hangupIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(displayName)
                .build()
            NotificationCompat.Builder(this, CHANNEL_ID_ONGOING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText(contentText)
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setStyle(
                    NotificationCompat.CallStyle.forOngoingCall(
                        person,
                        hangupPending,
                    ),
                )
        } else {
            NotificationCompat.Builder(this, CHANNEL_ID_ONGOING)
                .setSmallIcon(appInfo.icon)
                .setContentTitle(appLabel)
                .setContentText(contentText)
                .setCategory(Notification.CATEGORY_CALL)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
        }
        return builder.build()
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    /** Builds a broadcast intent to be handled by the plugin for system call actions. */
    private fun buildActionIntent(action: String): Intent =
        Intent(ACTION_BROADCAST)
            .setPackage(packageName)
            .putExtra(EXTRA_ACTION, action)

    private fun buildFullScreenIntent(): PendingIntent {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent()
        return PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    companion object {
        // Extras from the plugin to the service.
        const val EXTRA_MICROPHONE = "app.tauri.livekit_mobile.extra.MICROPHONE"
        const val EXTRA_CAMERA = "app.tauri.livekit_mobile.extra.CAMERA"
        const val EXTRA_PLAYBACK = "app.tauri.livekit_mobile.extra.PLAYBACK"
        const val EXTRA_CALL_DIRECTION = "app.tauri.livekit_mobile.extra.CALL_DIRECTION"
        const val EXTRA_CALLER_NAME = "app.tauri.livekit_mobile.extra.CALLER_NAME"

        // Broadcast action from notification buttons back to the plugin.
        const val ACTION_BROADCAST = "app.tauri.livekit_mobile.CALL_ACTION"

        // Action values inside ACTION_BROADCAST.
        const val EXTRA_ACTION = "app.tauri.livekit_mobile.extra.CALL_ACTION"
        const val ACTION_ANSWER = "answer"
        const val ACTION_DECLINE = "decline"
        const val ACTION_HANGUP = "hangup"
        const val ACTION_SERVICE_FAILED = "service_failed"

        // Call direction values for EXTRA_CALL_DIRECTION.
        const val DIRECTION_INCOMING = "incoming"
        const val DIRECTION_OUTGOING = "outgoing"
        const val DIRECTION_ONGOING = "ongoing"

        private const val CHANNEL_ID_ONGOING = "livekit_mobile_ongoing"
        private const val CHANNEL_ID_INCOMING = "livekit_mobile_incoming"
        private const val NOTIFICATION_ID = 1396
    }
}
