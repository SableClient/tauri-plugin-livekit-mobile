package app.tauri.livekit_mobile

import android.content.Context
import android.net.Uri
import android.os.Build
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import androidx.annotation.RequiresApi
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallsManager
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Android system-call integration on androidx.core.telecom.
 *
 * Mirrors ios/CallKitController.swift where the platform allows: register the
 * app with Telecom, report incoming/outgoing calls, answer and end them, and
 * queue system-initiated actions so JS can drain them once it is awake again.
 *
 * {@code CallsManager.addCall} suspends for the whole lifetime of a call, so
 * each call owns a coroutine plus the {@link CallControlScope} handed to its
 * block; that scope is the only way to answer or disconnect afterwards.
 *
 * Two CallKit capabilities have no core-telecom equivalent and are absent:
 * pushing mute into the system ({@code isMuted} is a read-only Flow, so mute
 * only travels system to app) and changing the call display once the call has
 * been added.
 *
 * CallsManager requires API 26; below that every entry point is a no-op.
 */
internal class AndroidCallController(
    private val appContext: Context,
    private val plugin: Plugin,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private class ActiveCall {
        @Volatile
        var job: Job? = null

        @Volatile
        var control: CallControlScope? = null
    }

    /** callId → the coroutine and control scope owning that Telecom call. */
    private val activeCalls = ConcurrentHashMap<String, ActiveCall>()

    /** Pending system-initiated actions (answer, end, mute) for JS to drain. */
    private val pendingActions = mutableListOf<SystemCallAction>()

    private var callsManager: CallsManager? = null

    // ── Registration ──────────────────────────────────────────────────────

    /** Idempotent; also called lazily before the first call is added. */
    fun registerWithTelecom() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (callsManager != null) return
        try {
            val manager = CallsManager(appContext)
            manager.registerAppWithTelecom(
                CallsManager.CAPABILITY_BASELINE or
                    CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING,
            )
            callsManager = manager
            triggerEvent("provider_ready", JSObject())
        } catch (_: Exception) {
            // Telecom may be unavailable on this device; stay a no-op.
        }
    }

    private fun telecomManager(): CallsManager? {
        registerWithTelecom()
        return callsManager
    }

    // ── Surfaces (called by plugin commands) ──────────────────────────────

    fun hasRegisteredCall(): Boolean = activeCalls.isNotEmpty()

    /**
     * Shows an incoming call on the system UI (lock screen, notification).
     * The caller MUST post a foreground notification within 5s.
     */
    fun reportIncomingCall(callId: String, callerName: String) {
        val manager = telecomManager() ?: return
        addCall(manager, callId, callerName, CallAttributesCompat.DIRECTION_INCOMING)
    }

    /** Starts an outgoing call in the system UI. */
    fun startOutgoingCall(callId: String, callerName: String) {
        val manager = telecomManager() ?: return
        addCall(manager, callId, callerName, CallAttributesCompat.DIRECTION_OUTGOING)
    }

    /** Answers a pending incoming call from the app side (JS initiated). */
    fun answerCall(callId: String) {
        val control = activeCalls[callId]?.control ?: return
        control.launch { control.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL) }
    }

    /** Ends a call: both local hangup and remote-end path. */
    fun endCall(callId: String) {
        val active = activeCalls.remove(callId) ?: return
        val control = active.control
        if (control == null) {
            // Still waiting on Telecom to hand us a control scope: cancelling
            // the addCall coroutine is the only way to withdraw the call.
            active.job?.cancel()
            return
        }
        control.launch { control.disconnect(DisconnectCause(DisconnectCause.LOCAL)) }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun addCall(
        manager: CallsManager,
        callId: String,
        callerName: String,
        direction: Int,
    ) {
        if (activeCalls.containsKey(callId)) return
        val active = ActiveCall()
        activeCalls[callId] = active
        val attributes = CallAttributesCompat(
            displayName = callerName,
            // API 26/27 require a sip: address; callId keeps the caller's
            // identity out of the system call log.
            address = Uri.fromParts(PhoneAccount.SCHEME_SIP, callId, null),
            direction = direction,
            callType = CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
            // No hold/stream/transfer, matching the iOS call configuration.
            callCapabilities = 0,
        )
        active.job = scope.launch {
            try {
                manager.addCall(
                    attributes,
                    onAnswer = { enqueue(SystemCallAction.answer(callId)) },
                    onDisconnect = { enqueue(SystemCallAction.end(callId)) },
                    onSetActive = {},
                    onSetInactive = {},
                ) {
                    active.control = this
                    launch {
                        // The only mute signal core-telecom offers. Calls start
                        // unmuted, so the flow's initial value is not an event.
                        var reported = false
                        isMuted.collect { muted ->
                            if (muted != reported) {
                                reported = muted
                                enqueue(SystemCallAction.mute(callId, muted))
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // Telecom refused or dropped the call (permission, call limit,
                // registration timeout). Nothing to surface beyond cleanup.
            } finally {
                activeCalls.remove(callId, active)
            }
        }
    }

    // ── Pending action queue (JS-suspended path) ──────────────────────────

    private fun enqueue(action: SystemCallAction) {
        synchronized(pendingActions) { pendingActions.add(action) }
        triggerEvent("callkit_event", action.toJSObject())
    }

    /** Returns all queued actions and clears the queue so JS can drain them. */
    fun drainPendingActions(): List<SystemCallAction> =
        synchronized(pendingActions) {
            val actions = pendingActions.toList()
            pendingActions.clear()
            actions
        }

    // ── Cleanup ───────────────────────────────────────────────────────────

    fun reset() {
        for (callId in activeCalls.keys.toList()) {
            endCall(callId)
        }
        synchronized(pendingActions) { pendingActions.clear() }
    }

    // ── Event helper ──────────────────────────────────────────────────────

    private fun triggerEvent(event: String, data: JSObject) {
        plugin.trigger(event, data)
    }
}

// ── SystemCallAction (trigger payload, mirrors Swift side) ────────────────

internal data class SystemCallAction(
    val action: String,
    val uuid: String,
    val muted: Boolean? = null,
) {
    fun toJSObject(): JSObject =
        JSObject().apply {
            put("action", action)
            put("uuid", uuid)
            muted?.let { put("muted", it) }
        }

    fun toMap(): Map<String, Any> =
        buildMap {
            put("action", action)
            put("uuid", uuid)
            muted?.let { put("muted", it) }
        }

    companion object {
        fun answer(uuid: String) = SystemCallAction("answer", uuid)
        fun end(uuid: String) = SystemCallAction("end", uuid)
        fun mute(uuid: String, muted: Boolean) = SystemCallAction("mute", uuid, muted)
    }
}
