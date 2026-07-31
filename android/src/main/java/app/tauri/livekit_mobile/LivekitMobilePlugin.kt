package app.tauri.livekit_mobile

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.webkit.WebView
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.Permission
import app.tauri.annotation.PermissionCallback
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

@InvokeArg
internal class NativeCallEncryptionKeyEntry {
    var identity: String = ""
    var keyIndex: Int = 0
    var key: String = ""
}

@InvokeArg
internal class ConnectNativeCallArgs {
    var callId: String = ""
    var url: String = ""
    var token: String = ""
    var microphoneEnabled: Boolean = false
    var encryptionKeys: List<NativeCallEncryptionKeyEntry>? = null
    lateinit var channel: Channel
}

@InvokeArg
internal class CallIdArgs {
    var callId: String = ""
}

@InvokeArg
internal class SetNativeCallMicrophoneEnabledArgs {
    var callId: String = ""
    var enabled: Boolean = false
}

@InvokeArg
internal class SetNativeCallCameraEnabledArgs {
    var callId: String = ""
    var enabled: Boolean = false
}

@InvokeArg
internal class SetNativeCallEncryptionKeyArgs {
    var callId: String = ""
    var identity: String = ""
    var keyIndex: Int = 0
    var key: String = ""
}

@InvokeArg
internal class SetNativeCallRemoteVideoOverlayArgs {
    var callId: String = ""
    var participantIdentity: String = ""
    var trackId: String = ""
    var x: Double = 0.0
    var y: Double = 0.0
    var width: Double = 0.0
    var height: Double = 0.0
    var devicePixelRatio: Double = 0.0
}

@InvokeArg
internal class SetNativeCallLocalVideoOverlayArgs {
    var callId: String = ""
    var x: Double = 0.0
    var y: Double = 0.0
    var width: Double = 0.0
    var height: Double = 0.0
    var devicePixelRatio: Double = 0.0
}

// ── System-call (Telecom/CallKit) command argument classes ──

@InvokeArg
internal class ReportSystemIncomingCallArgs {
    var uuid: String = ""
    var callerName: String = ""
}

@InvokeArg
internal class StartSystemCallArgs {
    var callId: String = ""
    var uuid: String = ""
    var callerName: String = ""
}

@InvokeArg
internal class AnswerSystemCallArgs {
    var callId: String = ""
    var uuid: String = ""
}

@InvokeArg
internal class EndSystemCallArgs {
    var callId: String = ""
    var remoteEnded: Boolean = false
}

@InvokeArg
internal class SetSystemCallMutedArgs {
    var callId: String = ""
    var muted: Boolean = false
}

@InvokeArg
internal class FulfillCallArgs {
    var uuid: String = ""
}

@InvokeArg
internal class UpdateCallDisplayArgs {
    var callId: String = ""
    var callerName: String = ""
    var hasVideo: Boolean? = null
}

@InvokeArg
internal class SystemCallDetailsArgs {
    var callId: String = ""
}

@InvokeArg
internal class DeclineSystemCallArgs {
    var callId: String = ""
    var reason: String = ""
}

@TauriPlugin(
    permissions = [
        Permission(
            strings = ["android.permission.RECORD_AUDIO"],
            alias = "microphone",
        ),
        Permission(
            strings = ["android.permission.CAMERA"],
            alias = "camera",
        ),
    ],
)
class LivekitMobilePlugin(private val activity: Activity) : Plugin(activity) {
    /** Host WebView retained at load() so the video overlay can anchor above
     * it. Written on the main thread, read on the controller's bridge thread. */
    @Volatile
    private var hostWebView: WebView? = null

    private val videoOverlay = RemoteVideoOverlay(webViewProvider = { hostWebView })

    private val controller =
        NativeCallController(
            appContext = activity.applicationContext,
            hasMicrophonePermission = { hasRecordAudioPermission() },
            hasCameraPermission = { hasCameraPermission() },
            videoOverlay = videoOverlay,
        )

    private val callController = AndroidCallController(
        appContext = activity.applicationContext,
        plugin = this,
    )

    private val callActionReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val action = intent.getStringExtra(LivekitMobileForegroundService.EXTRA_ACTION)
            when (action) {
                LivekitMobileForegroundService.ACTION_ANSWER -> {
                    // The user tapped "Answer" on the incoming-call notification.
                    // Delegate to the call controller; it will route via CallStyle.
                }
                LivekitMobileForegroundService.ACTION_DECLINE -> {
                    // The user tapped "Decline" on the incoming-call notification.
                    // End any active call.
                    for ((callId, _) in callController.drainPendingActions()) {
                        // Just clear pending; the actual decline is handled
                        // through the system-call path.
                    }
                    callController.reset()
                }
                LivekitMobileForegroundService.ACTION_HANGUP -> {
                    // The user tapped "Hang up" on the ongoing-call notification.
                    // End any active call.
                    callController.reset()
                }
            }
        }
    }

    override fun load(webView: WebView) {
        hostWebView = webView
        val filter = IntentFilter(LivekitMobileForegroundService.ACTION_BROADCAST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(callActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(callActionReceiver, filter)
        }
    }

    private var pendingConnect: PendingConnect? = null
    private var pendingMicrophone: PendingMicrophone? = null
    private var pendingCamera: PendingCamera? = null

    private data class PendingConnect(
        val invoke: Invoke,
        val args: ConnectNativeCallArgs,
    )

    private data class PendingMicrophone(
        val invoke: Invoke,
        val args: SetNativeCallMicrophoneEnabledArgs,
    )

    private data class PendingCamera(
        val invoke: Invoke,
        val args: SetNativeCallCameraEnabledArgs,
    )

    // ── Core call commands ─────────────────────────────────────────────────

    @Command
    fun getNativeCallCapabilities(invoke: Invoke) {
        invoke.resolve(
            JSObject()
                .put("platform", "android")
                .put("microphone", true)
                .put("audioPlayback", true)
                .put("foregroundService", true)
                .put("backgroundJavascript", false)
                .put("camera", true)
                .put("nativeVideoOverlay", true)
                .put("screenShare", false)
                .put("devicePicker", false),
        )
    }

    @Command
    fun connectNativeCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(ConnectNativeCallArgs::class.java) }.getOrNull()
        if (args == null ||
            args.callId.isBlank() ||
            args.url.isBlank() ||
            args.token.isBlank() ||
            !hasChannel(args)
        ) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // Decode key material at the boundary; malformed entries fail the call.
        val encryptionKeys = decodeEncryptionKeys(args.encryptionKeys)
        if (encryptionKeys == null) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        if (controller.isBusy(args.callId)) {
            reject(invoke, NativeCallWire.ERR_BUSY)
            return
        }
        if (controller.isActiveCall(args.callId)) {
            invoke.resolve(controller.snapshotJson())
            return
        }
        if (args.microphoneEnabled && !hasRecordAudioPermission()) {
            val pending = PendingConnect(invoke, args)
            pendingConnect = pending
            try {
                requestPermissionForAliases(arrayOf("microphone"), invoke, "permissionResult")
            } catch (_: Exception) {
                pendingConnect = null
                reject(pending.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
            return
        }
        // Also register this as an outgoing system call.
        callController.startOutgoingCall(args.callId, args.callId)
        controller.connect(
            args.callId,
            args.url,
            args.token,
            args.microphoneEnabled,
            encryptionKeys,
            args.channel,
            invoke,
        )
    }

    @Command
    fun disconnectNativeCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // End the system call alongside the LiveKit room.
        callController.endCall(args.callId)
        controller.disconnect(args.callId, invoke)
    }

    @Command
    fun cancelNativeCallConnect(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        controller.cancelConnect(args.callId, invoke)
    }

    @Command
    fun setNativeCallMicrophoneEnabled(invoke: Invoke) {
        val args =
            runCatching { invoke.parseArgs(SetNativeCallMicrophoneEnabledArgs::class.java) }
                .getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        if (args.enabled &&
            controller.isActiveCall(args.callId) &&
            !hasRecordAudioPermission()
        ) {
            val pending = PendingMicrophone(invoke, args)
            pendingMicrophone = pending
            try {
                requestPermissionForAliases(arrayOf("microphone"), invoke, "permissionResult")
            } catch (_: Exception) {
                pendingMicrophone = null
                reject(pending.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
            return
        }
        controller.setMicrophoneEnabled(args.callId, args.enabled, invoke)
    }

    @Command
    fun setNativeCallCameraEnabled(invoke: Invoke) {
        val args =
            runCatching { invoke.parseArgs(SetNativeCallCameraEnabledArgs::class.java) }
                .getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        if (args.enabled &&
            controller.isActiveCall(args.callId) &&
            !hasCameraPermission()
        ) {
            val pending = PendingCamera(invoke, args)
            pendingCamera = pending
            try {
                requestPermissionForAliases(arrayOf("camera"), invoke, "permissionResult")
            } catch (_: Exception) {
                pendingCamera = null
                reject(pending.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
            return
        }
        controller.setCameraEnabled(args.callId, args.enabled, invoke)
    }

    @Command
    fun switchNativeCallCamera(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.switchCamera(args.callId, invoke)
    }

    @Command
    fun setNativeCallRemoteVideoOverlay(invoke: Invoke) {
        val args =
            runCatching { invoke.parseArgs(SetNativeCallRemoteVideoOverlayArgs::class.java) }
                .getOrNull()
        if (args == null ||
            args.callId.isBlank() ||
            args.participantIdentity.isBlank() ||
            args.trackId.isBlank()
        ) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.setRemoteVideoOverlay(
            args.callId,
            args.participantIdentity,
            args.trackId,
            args.x,
            args.y,
            args.width,
            args.height,
            args.devicePixelRatio,
            invoke,
        )
    }

    @Command
    fun clearNativeCallRemoteVideoOverlay(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.clearRemoteVideoOverlay(args.callId, invoke)
    }

    @Command
    fun setNativeCallLocalVideoOverlay(invoke: Invoke) {
        val args =
            runCatching { invoke.parseArgs(SetNativeCallLocalVideoOverlayArgs::class.java) }
                .getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.setLocalVideoOverlay(
            args.callId,
            args.x,
            args.y,
            args.width,
            args.height,
            args.devicePixelRatio,
            invoke,
        )
    }

    @Command
    fun clearNativeCallLocalVideoOverlay(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.clearLocalVideoOverlay(args.callId, invoke)
    }

    @Command
    fun setNativeCallEncryptionKey(invoke: Invoke) {
        val args =
            runCatching { invoke.parseArgs(SetNativeCallEncryptionKeyArgs::class.java) }
                .getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // Decode key material at the boundary; the controller decides whether
        // the current call accepts it.
        val material =
            NativeCallEncryption.decodeEntry(args.identity, args.keyIndex, args.key)
        if (material == null) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        controller.setEncryptionKey(args.callId, material, invoke)
    }

    @Command
    fun getNativeCallState(invoke: Invoke) {
        invoke.resolve(controller.snapshotJson())
    }

    // ── System-call (Telecom/CallKit) commands ─────────────────────────────

    @Command
    fun reportSystemIncomingCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(ReportSystemIncomingCallArgs::class.java) }.getOrNull()
        if (args == null || args.callerName.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        val callId = args.uuid.ifBlank { java.util.UUID.randomUUID().toString() }
        callController.reportIncomingCall(callId, args.callerName)
        invoke.resolve(JSObject())
    }

    @Command
    fun startSystemCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(StartSystemCallArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.startOutgoingCall(args.callId, args.callerName.ifBlank { args.callId })
        invoke.resolve(JSObject())
    }

    @Command
    fun answerSystemCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(AnswerSystemCallArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.answerCall(args.callId)
        invoke.resolve(JSObject())
    }

    @Command
    fun endSystemCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(EndSystemCallArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        invoke.resolve(JSObject())
    }

    @Command
    fun setSystemCallMuted(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(SetSystemCallMutedArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // androidx.core.telecom exposes mute as a read-only flow: there is no
        // app to system push equivalent to CXSetMutedCallAction.
        reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
    }

    @Command
    fun drainPendingSystemCallActions(invoke: Invoke) {
        invoke.resolveObject(callController.drainPendingActions().map { it.toMap() })
    }

    @Command
    fun fulfillAnswerCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(FulfillCallArgs::class.java) }.getOrNull()
        if (args == null) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // On iOS this fulfills a deferred CXAnswerCallAction.
        // On Android, the Telecom callback already fires immediately;
        // this is a no-op kept for API parity with iOS.
        invoke.resolve(JSObject())
    }

    @Command
    fun fulfillEndCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(FulfillCallArgs::class.java) }.getOrNull()
        if (args == null) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // On iOS this fulfills a deferred CXEndCallAction.
        // On Android, the Telecom callback already fires immediately;
        // this is a no-op kept for API parity with iOS.
        invoke.resolve(JSObject())
    }

    @Command
    fun reportSystemCallConnected(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(FulfillCallArgs::class.java) }.getOrNull()
        if (args == null) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // Android has no equivalent of reportOutgoingCall(connectedAt:); no-op.
        invoke.resolve(JSObject())
    }

    @Command
    fun updateCallDisplay(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(UpdateCallDisplayArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        // Telecom fixes a call's attributes when it is added; there is no
        // equivalent of CXProvider.reportCall(with:updated:).
        reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
    }

    @Command
    fun reportSystemCallAnsweredElsewhere(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(SystemCallDetailsArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        invoke.resolve(JSObject())
    }

    @Command
    fun reportSystemCallDeclinedElsewhere(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(SystemCallDetailsArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        invoke.resolve(JSObject())
    }

    @Command
    fun reportSystemCallUnanswered(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(SystemCallDetailsArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        invoke.resolve(JSObject())
    }

    @Command
    fun declineSystemCall(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(DeclineSystemCallArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
        callController.endCall(args.callId)
        invoke.resolve(JSObject())
    }

    // ── Permission callback ────────────────────────────────────────────────

    @PermissionCallback
    private fun permissionResult(invoke: Invoke) {
        val connect = pendingConnect
        if (connect != null && connect.invoke.id == invoke.id) {
            pendingConnect = null
            // Already validated in connectNativeCall; re-decoded defensively.
            val encryptionKeys = decodeEncryptionKeys(connect.args.encryptionKeys)
            if (encryptionKeys == null) {
                reject(connect.invoke, NativeCallWire.ERR_INVALID_REQUEST)
                return
            }
            if (hasRecordAudioPermission()) {
                callController.startOutgoingCall(connect.args.callId, connect.args.callId)
                controller.connect(
                    connect.args.callId,
                    connect.args.url,
                    connect.args.token,
                    connect.args.microphoneEnabled,
                    encryptionKeys,
                    connect.args.channel,
                    connect.invoke,
                )
            } else {
                reject(connect.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
            return
        }
        val microphone = pendingMicrophone
        if (microphone != null && microphone.invoke.id == invoke.id) {
            pendingMicrophone = null
            if (hasRecordAudioPermission()) {
                controller.setMicrophoneEnabled(
                    microphone.args.callId,
                    microphone.args.enabled,
                    microphone.invoke,
                )
            } else {
                reject(microphone.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
            return
        }
        val camera = pendingCamera
        if (camera != null && camera.invoke.id == invoke.id) {
            pendingCamera = null
            if (hasCameraPermission()) {
                controller.setCameraEnabled(
                    camera.args.callId,
                    camera.args.enabled,
                    camera.invoke,
                )
            } else {
                reject(camera.invoke, NativeCallWire.ERR_PERMISSION_DENIED)
            }
        }
    }

    override fun onDestroy(activity: androidx.appcompat.app.AppCompatActivity) {
        try {
            activity.unregisterReceiver(callActionReceiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered.
        }
        // Pending permission invokes must settle before the room is torn down.
        pendingConnect?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingConnect = null
        pendingMicrophone?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingMicrophone = null
        pendingCamera?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingCamera = null
        // Release the overlay on the main thread before dispose() parks it:
        // teardown must never wait on a blocked looper to drop EGL resources.
        videoOverlay.clear()
        localVideoOverlay.clear()
        callController.reset()
        controller.dispose()
        super.onDestroy(activity)
    }

    private fun reject(invoke: Invoke, code: String) {
        val safeCode = NativeCallWire.sanitize(code)
        invoke.reject(NativeCallWire.messageFor(safeCode), safeCode)
    }

    /**
     * Validates and decodes the optional initial key list: null means at least
     * one entry was malformed; an absent or empty list means a generic
     * (non-E2EE) call.
     */
    private fun decodeEncryptionKeys(
        entries: List<NativeCallEncryptionKeyEntry>?,
    ): List<NativeCallKeyMaterial>? {
        if (entries.isNullOrEmpty()) return emptyList()
        return entries.map { entry ->
            NativeCallEncryption.decodeEntry(entry.identity, entry.keyIndex, entry.key)
                ?: return null
        }
    }

    private fun hasRecordAudioPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(activity, android.Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasChannel(args: ConnectNativeCallArgs): Boolean =
        runCatching { args.channel }.isSuccess
}
