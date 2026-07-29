package app.tauri.livekit_mobile

import android.app.Activity
import android.content.pm.PackageManager
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
internal class ConnectNativeCallArgs {
    var callId: String = ""
    var url: String = ""
    var token: String = ""
    var microphoneEnabled: Boolean = false
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
    private val controller =
        NativeCallController(
            appContext = activity.applicationContext,
            hasMicrophonePermission = { hasRecordAudioPermission() },
            hasCameraPermission = { hasCameraPermission() },
        )

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
        controller.connect(
            args.callId,
            args.url,
            args.token,
            args.microphoneEnabled,
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
        controller.disconnect(args.callId, invoke)
    }

    @Command
    fun cancelNativeCallConnect(invoke: Invoke) {
        val args = runCatching { invoke.parseArgs(CallIdArgs::class.java) }.getOrNull()
        if (args == null || args.callId.isBlank()) {
            reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
            return
        }
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
    fun getNativeCallState(invoke: Invoke) {
        invoke.resolve(controller.snapshotJson())
    }

    @PermissionCallback
    private fun permissionResult(invoke: Invoke) {
        val connect = pendingConnect
        if (connect != null && connect.invoke.id == invoke.id) {
            pendingConnect = null
            if (hasRecordAudioPermission()) {
                controller.connect(
                    connect.args.callId,
                    connect.args.url,
                    connect.args.token,
                    connect.args.microphoneEnabled,
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
        // Pending permission invokes must settle before the room is torn down.
        pendingConnect?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingConnect = null
        pendingMicrophone?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingMicrophone = null
        pendingCamera?.let { reject(it.invoke, NativeCallWire.ERR_CANCELLED) }
        pendingCamera = null
        controller.dispose()
        super.onDestroy(activity)
    }

    private fun reject(invoke: Invoke, code: String) {
        val safeCode = NativeCallWire.sanitize(code)
        invoke.reject(NativeCallWire.messageFor(safeCode), safeCode)
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
