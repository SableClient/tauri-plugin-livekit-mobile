package app.tauri.livekit_mobile

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import app.tauri.plugin.Channel
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSArray
import app.tauri.plugin.JSObject
import io.livekit.android.LiveKit
import io.livekit.android.e2ee.E2EEOptions
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.participant.Participant
import io.livekit.android.room.participant.RemoteParticipant
import io.livekit.android.room.track.LocalVideoTrack
import io.livekit.android.room.track.Track
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Serialized owner of the LiveKit room and the native-call wire contract.
 *
 * All room access and snapshot mutation happen on a single daemon-thread
 * dispatcher, and every command settles its invoke exactly once. The snapshot
 * (with its native-owned revision) is authoritative; LiveKit events only feed
 * it. A monotonic attempt counter plus the connect job make an in-flight
 * connect cancellable and guard against callbacks from superseded attempts.
 * Room tokens and raw native errors never cross the bridge.
 */
internal class NativeCallController(
    private val appContext: Context,
    private val hasMicrophonePermission: () -> Boolean,
    private val hasCameraPermission: () -> Boolean = { false },
    private val videoOverlay: RemoteVideoOverlay = RemoteVideoOverlay { null },
    private val localVideoOverlay: LocalVideoOverlay = LocalVideoOverlay { null },
) {
    private val dispatcher =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "native-call-bridge").apply { isDaemon = true }
        }.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    /** Authoritative snapshot; only mutated on the bridge thread. */
    @Volatile
    private var snapshot = NativeCallSnapshot()

    private var channel: Channel? = null
    private var room: Room? = null

    /** Per-call E2EE state; set before room.connect, destroyed with the room. */
    private var e2ee: NativeCallE2EEKeys? = null
    private var eventJob: Job? = null
    private var connectJob: Job? = null
    private var attempt = 0L
    private var intentionalDisconnect = false

    fun snapshotJson(): JSObject {
        val current = snapshot
        return JSObject().apply {
            put("revision", current.revision)
            val id = current.callId
            if (id != null) put("callId", id) else put("callId", JSONObject.NULL)
            put("connectionState", current.connectionState)
            put("microphoneEnabled", current.microphoneEnabled)
            put("cameraEnabled", current.cameraEnabled)
            put("participantCount", current.participantCount)
            put(
                "remoteParticipants",
                JSArray().apply {
                    current.remoteParticipants.forEach { participant ->
                        put(
                            JSObject().apply {
                                put("identity", participant.identity)
                                participant.camera?.let { camera ->
                                    put(
                                        "camera",
                                        JSObject()
                                            .put("sid", camera.sid)
                                            .put("muted", camera.muted)
                                            .put("subscribed", camera.subscribed),
                                    )
                                }
                            },
                        )
                    }
                },
            )
            current.lastErrorCode?.let { code ->
                put(
                    "lastError",
                    JSObject()
                        .put("code", code)
                        .put("message", NativeCallWire.messageFor(code)),
                )
            }
        }
    }

    fun isBusy(requestedCallId: String): Boolean =
        snapshot.isActive && snapshot.callId != requestedCallId

    fun isActiveCall(callId: String): Boolean =
        snapshot.isActive && snapshot.callId == callId

    fun connect(
        callId: String,
        url: String,
        token: String,
        microphoneEnabled: Boolean,
        encryptionKeys: List<NativeCallKeyMaterial>,
        callChannel: Channel,
        invoke: Invoke,
    ) {
        connectJob =
            scope.launch {
                val currentAttempt = ++attempt
                intentionalDisconnect = false
                channel = callChannel
                transition {
                    copy(
                        callId = callId,
                        connectionState = NativeCallWire.STATE_CONNECTING,
                        microphoneEnabled = false,
                        cameraEnabled = false,
                        participantCount = 0,
                        remoteParticipants = emptyList(),
                        lastErrorCode = null,
                    )
                }
                startCallForegroundService(preferMicrophone = microphoneEnabled)
                emitSnapshotChanged()

                val newRoom =
                    try {
                        LiveKit.create(appContext)
                    } catch (_: Exception) {
                        failConnect(currentAttempt, null, invoke, NativeCallWire.ERR_CONNECT_FAILED)
                        return@launch
                    }
                room = newRoom
                eventJob =
                    launch {
                        newRoom.events.collect { event ->
                            if (currentAttempt == attempt && room === newRoom) {
                                handleRoomEvent(event)
                            }
                        }
                    }
                if (encryptionKeys.isNotEmpty()) {
                    // E2EE calls only: create a fresh per-call provider, install
                    // the full key ring, and wire it before connect. Any JNI/SDK
                    // failure settles this invoke through the bounded connect
                    // error path, which releases the room and destroys the
                    // provider via teardownRoom instead of leaking either.
                    try {
                        val keys = NativeCallE2EEKeys()
                        e2ee = keys
                        encryptionKeys.forEach(keys::installRingEntry)
                        newRoom.e2eeOptions = E2EEOptions(keyProvider = keys)
                    } catch (_: Exception) {
                        failConnect(
                            currentAttempt,
                            null,
                            invoke,
                            NativeCallWire.ERR_CONNECT_FAILED,
                        )
                        return@launch
                    }
                }
                try {
                    newRoom.connect(url, token)
                } catch (cancelled: CancellationException) {
                    // A cancel/disconnect raced this attempt; it already owns
                    // the snapshot. Settle this invoke and drop the orphan room.
                    runCatching { newRoom.disconnect() }
                    runCatching { newRoom.release() }
                    reject(invoke, NativeCallWire.ERR_CANCELLED)
                    return@launch
                } catch (_: Exception) {
                    failConnect(currentAttempt, newRoom, invoke, NativeCallWire.ERR_CONNECT_FAILED)
                    return@launch
                }
                if (currentAttempt != attempt || room !== newRoom) {
                    // Superseded while connecting; the superseder owns the state.
                    runCatching { newRoom.disconnect() }
                    runCatching { newRoom.release() }
                    reject(invoke, NativeCallWire.ERR_CANCELLED)
                    return@launch
                }

                var microphoneActive = false
                var microphoneError: String? = null
                if (microphoneEnabled && hasMicrophonePermission()) {
                    microphoneActive =
                        try {
                            newRoom.localParticipant.setMicrophoneEnabled(true)
                            true
                        } catch (_: CancellationException) {
                            reject(invoke, NativeCallWire.ERR_CANCELLED)
                            return@launch
                        } catch (_: Exception) {
                            microphoneError = NativeCallWire.ERR_MEDIA_FAILED
                            false
                        }
                } else if (microphoneEnabled) {
                    microphoneError = NativeCallWire.ERR_PERMISSION_DENIED
                }
                if (currentAttempt != attempt || room !== newRoom) {
                    reject(invoke, NativeCallWire.ERR_CANCELLED)
                    return@launch
                }

                transition {
                    copy(
                        connectionState = NativeCallWire.STATE_CONNECTED,
                        microphoneEnabled = microphoneActive,
                        lastErrorCode = microphoneError?.let(NativeCallWire::sanitize),
                        participantCount = newRoom.remoteParticipants.size,
                        remoteParticipants = remoteParticipantsProjection(newRoom),
                    )
                }
                emitSnapshotChanged()
                invoke.resolve(snapshotJson())
            }
    }

    fun disconnect(callId: String, invoke: Invoke) = endCall(callId, invoke)

    fun cancelConnect(callId: String, invoke: Invoke) = endCall(callId, invoke)

    /** Cancels any in-flight connect and tears the matching room down; safe to
     * run while a connect is suspended. Settles with an idle snapshot. */
    private fun endCall(callId: String, invoke: Invoke) {
        scope.launch {
            ++attempt
            if (snapshot.callId != callId) {
                // A stale request must never tear down a replacement call.
                invoke.resolve(snapshotJson())
                return@launch
            }
            intentionalDisconnect = true
            connectJob?.cancel()
            teardownRoom()
            stopCallForegroundService()
            transition { toIdle() }
            emitSnapshotChanged()
            channel = null
            invoke.resolve(snapshotJson())
        }
    }

    fun setMicrophoneEnabled(callId: String, enabled: Boolean, invoke: Invoke) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            val currentRoom = room
            if (currentRoom == null) {
                reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                return@launch
            }
            if (snapshot.microphoneEnabled == enabled) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            if (enabled && !hasMicrophonePermission()) {
                reject(invoke, NativeCallWire.ERR_PERMISSION_DENIED)
                return@launch
            }
            try {
                currentRoom.localParticipant.setMicrophoneEnabled(enabled)
            } catch (_: Exception) {
                transition { copy(lastErrorCode = NativeCallWire.ERR_MEDIA_FAILED) }
                emitSnapshotChanged()
                reject(invoke, NativeCallWire.ERR_MEDIA_FAILED)
                return@launch
            }
            transition { copy(microphoneEnabled = enabled) }
            if (enabled) startCallForegroundService(preferMicrophone = true)
            emitSnapshotChanged()
            invoke.resolve(snapshotJson())
        }
    }

    fun setCameraEnabled(callId: String, enabled: Boolean, invoke: Invoke) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            val currentRoom = room
            if (currentRoom == null) {
                reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                return@launch
            }
            if (snapshot.cameraEnabled == enabled) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            if (enabled && !hasCameraPermission()) {
                reject(invoke, NativeCallWire.ERR_PERMISSION_DENIED)
                return@launch
            }
            try {
                currentRoom.localParticipant.setCameraEnabled(enabled)
            } catch (_: Exception) {
                transition { copy(lastErrorCode = NativeCallWire.ERR_MEDIA_FAILED) }
                emitSnapshotChanged()
                reject(invoke, NativeCallWire.ERR_MEDIA_FAILED)
                return@launch
            }
            transition { copy(cameraEnabled = enabled) }
            emitSnapshotChanged()
            invoke.resolve(snapshotJson())
        }
    }

    fun switchCamera(callId: String, invoke: Invoke) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            val currentRoom = room
            if (currentRoom == null) {
                reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                return@launch
            }
            val cameraTrack =
                currentRoom.localParticipant
                    .getTrackPublication(Track.Source.CAMERA)
                    ?.track as? LocalVideoTrack
            if (cameraTrack == null) {
                // No published camera track yet; enabling must happen first.
                transition { copy(lastErrorCode = NativeCallWire.ERR_MEDIA_FAILED) }
                emitSnapshotChanged()
                reject(invoke, NativeCallWire.ERR_MEDIA_FAILED)
                return@launch
            }
            try {
                cameraTrack.switchCamera()
            } catch (_: Exception) {
                transition { copy(lastErrorCode = NativeCallWire.ERR_MEDIA_FAILED) }
                emitSnapshotChanged()
                reject(invoke, NativeCallWire.ERR_MEDIA_FAILED)
                return@launch
            }
            invoke.resolve(snapshotJson())
        }
    }

    fun setRemoteVideoOverlay(
        callId: String,
        participantIdentity: String,
        trackSid: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        devicePixelRatio: Double,
        invoke: Invoke,
    ) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            val currentRoom = room
            if (currentRoom == null) {
                reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                return@launch
            }
            when (
                videoOverlay.attach(
                    currentRoom,
                    participantIdentity,
                    trackSid,
                    x,
                    y,
                    width,
                    height,
                    devicePixelRatio,
                )
            ) {
                is RemoteVideoOverlay.AttachResult.Attached -> invoke.resolve(snapshotJson())
                is RemoteVideoOverlay.AttachResult.InvalidGeometry ->
                    reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
                is RemoteVideoOverlay.AttachResult.TrackUnavailable ->
                    reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                is RemoteVideoOverlay.AttachResult.HostUnavailable ->
                    reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                is RemoteVideoOverlay.AttachResult.Failed ->
                    reject(invoke, NativeCallWire.ERR_UNEXPECTED)
            }
        }
    }

    fun clearRemoteVideoOverlay(callId: String, invoke: Invoke) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            videoOverlay.clear()
            invoke.resolve(snapshotJson())
        }
    }

    fun setLocalVideoOverlay(
        callId: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        devicePixelRatio: Double,
        invoke: Invoke,
    ) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            val currentRoom = room
            if (currentRoom == null) {
                reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                return@launch
            }
            when (
                localVideoOverlay.attach(currentRoom, x, y, width, height, devicePixelRatio)
            ) {
                is LocalVideoOverlay.AttachResult.Attached -> invoke.resolve(snapshotJson())
                // The app reports geometry optimistically, possibly before the
                // camera publishes; the publish event rebinds the tile.
                is LocalVideoOverlay.AttachResult.TrackUnavailable ->
                    invoke.resolve(snapshotJson())
                is LocalVideoOverlay.AttachResult.InvalidGeometry ->
                    reject(invoke, NativeCallWire.ERR_INVALID_REQUEST)
                is LocalVideoOverlay.AttachResult.HostUnavailable ->
                    reject(invoke, NativeCallWire.ERR_UNAVAILABLE)
                is LocalVideoOverlay.AttachResult.Failed ->
                    reject(invoke, NativeCallWire.ERR_UNEXPECTED)
            }
        }
    }

    fun clearLocalVideoOverlay(callId: String, invoke: Invoke) {
        scope.launch {
            if (snapshot.callId != callId) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            localVideoOverlay.clear()
            invoke.resolve(snapshotJson())
        }
    }

    /**
     * Installs a rotated encryption key into the current call's provider.
     * Works while connecting or connected; installs are serialized on the
     * bridge thread so racing rotations cannot drop a valid update. Stale
     * call ids, non-E2EE calls, and guard-rejected indexes resolve the
     * current snapshot unchanged without emitting snapshot changes.
     */
    fun setEncryptionKey(
        callId: String,
        material: NativeCallKeyMaterial,
        invoke: Invoke,
    ) {
        scope.launch {
            val keys = e2ee
            if (snapshot.callId != callId || keys == null) {
                invoke.resolve(snapshotJson())
                return@launch
            }
            try {
                keys.installRotation(material)
            } catch (_: Exception) {
                // A failed install must still settle the invoke, bounded.
                reject(invoke, NativeCallWire.ERR_UNEXPECTED)
                return@launch
            }
            invoke.resolve(snapshotJson())
        }
    }

    /** Queues teardown on the bridge thread and blocks the caller briefly so
     * onDestroy guarantees the room is released before the scope is cancelled. */
    fun dispose() {
        val done = CountDownLatch(1)
        scope.launch {
            ++attempt
            intentionalDisconnect = true
            connectJob?.cancel()
            channel = null
            teardownRoom()
            stopCallForegroundService()
            transition { toIdle() }
            done.countDown()
        }
        done.await(DISPOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        scope.cancel()
    }

    private fun failConnect(
        currentAttempt: Long,
        failedRoom: Room?,
        invoke: Invoke,
        code: String,
    ) {
        if (currentAttempt != attempt) {
            if (failedRoom != null) {
                runCatching { failedRoom.disconnect() }
                runCatching { failedRoom.release() }
            }
            reject(invoke, NativeCallWire.ERR_CANCELLED)
            return
        }
        transition {
            copy(
                connectionState = NativeCallWire.STATE_FAILED,
                lastErrorCode = NativeCallWire.sanitize(code),
            )
        }
        teardownRoom()
        stopCallForegroundService()
        emitSnapshotChanged()
        reject(invoke, code)
    }

    private fun handleRoomEvent(event: RoomEvent) {
        when (event) {
            is RoomEvent.Connected -> {
                transition {
                    copy(
                        connectionState = NativeCallWire.STATE_CONNECTED,
                        participantCount = room?.remoteParticipants?.size ?: 0,
                        remoteParticipants = remoteParticipantsProjection(room),
                    )
                }
                emitSnapshotChanged()
            }
            is RoomEvent.Reconnecting -> {
                if (snapshot.connectionState != NativeCallWire.STATE_CONNECTED) return
                transition { copy(connectionState = NativeCallWire.STATE_RECONNECTING) }
                emitSnapshotChanged()
            }
            is RoomEvent.Reconnected -> {
                transition {
                    copy(
                        connectionState = NativeCallWire.STATE_CONNECTED,
                        participantCount = room?.remoteParticipants?.size ?: 0,
                        remoteParticipants = remoteParticipantsProjection(room),
                    )
                }
                emitSnapshotChanged()
            }
            is RoomEvent.Disconnected -> {
                if (intentionalDisconnect) return
                transition {
                    copy(
                        connectionState = NativeCallWire.STATE_FAILED,
                        lastErrorCode = NativeCallWire.ERR_DISCONNECTED,
                    )
                }
                teardownRoom()
                stopCallForegroundService()
                emitSnapshotChanged()
            }
            is RoomEvent.ParticipantConnected -> {
                transition {
                    copy(
                        participantCount = room?.remoteParticipants?.size ?: 0,
                        remoteParticipants = remoteParticipantsProjection(room),
                    )
                }
                videoOverlay.reconcile(room)
                emitSnapshotChanged()
            }
            is RoomEvent.ParticipantDisconnected -> {
                transition {
                    copy(
                        participantCount = room?.remoteParticipants?.size ?: 0,
                        remoteParticipants = remoteParticipantsProjection(room),
                    )
                }
                videoOverlay.reconcile(room)
                emitSnapshotChanged()
            }
            // Remote publication lifecycle only affects the remote projection;
            // local publishes/mutes must not churn the snapshot. The overlay
            // reconciles on every remote track lifecycle event so it never
            // retains an unpublished/unsubscribed/replaced track.
            is RoomEvent.TrackPublished -> {
                applyRemoteProjectionIfChanged(event.participant)
                videoOverlay.reconcile(room)
                localVideoOverlay.reconcile(room)
            }
            is RoomEvent.TrackUnpublished -> {
                applyRemoteProjectionIfChanged(event.participant)
                videoOverlay.reconcile(room)
                localVideoOverlay.reconcile(room)
            }
            is RoomEvent.TrackMuted ->
                applyRemoteProjectionIfChanged(event.participant)
            is RoomEvent.TrackUnmuted ->
                applyRemoteProjectionIfChanged(event.participant)
            is RoomEvent.TrackSubscribed -> {
                applyRemoteProjectionIfChanged()
                videoOverlay.reconcile(room)
            }
            is RoomEvent.TrackUnsubscribed -> {
                applyRemoteProjectionIfChanged()
                videoOverlay.reconcile(room)
            }
            else -> Unit
        }
    }

    /**
     * Smallest authoritative remote-only projection: identity, plus the remote
     * CAMERA publication (sid, muted, remote-aware subscribed) when one exists.
     * Sorted so identical room state always projects to an equal list.
     */
    private fun remoteParticipantsProjection(
        currentRoom: Room?,
    ): List<NativeRemoteParticipant> {
        val participants = currentRoom?.remoteParticipants ?: return emptyList()
        return participants.entries
            .map { (identity, participant) ->
                // sid is non-null in 2.27.0; sort so several camera
                // publications project deterministically (matches iOS).
                val camera =
                    participant.trackPublications.values
                        .filter { it.source == Track.Source.CAMERA }
                        .sortedBy { it.sid }
                        .firstOrNull()
                        ?.let { publication ->
                            NativeRemoteParticipant.Camera(
                                sid = publication.sid,
                                muted = publication.muted,
                                subscribed = publication.subscribed,
                            )
                        }
                NativeRemoteParticipant(identity = identity.value, camera = camera)
            }
            .sortedBy { it.identity }
    }

    /** Recomputes the remote-only projection after a publication event, skipping
     * local participants and no-op changes (no revision bump, no emit). */
    private fun applyRemoteProjectionIfChanged(participant: Participant? = null) {
        if (participant != null && participant !is RemoteParticipant) return
        val projection = remoteParticipantsProjection(room)
        if (snapshot.remoteParticipants == projection) return
        transition { copy(remoteParticipants = projection) }
        emitSnapshotChanged()
    }

    private fun transition(transform: NativeCallSnapshot.() -> NativeCallSnapshot) {
        val current = snapshot
        val next = current.transform()
        snapshot =
            next.copy(revision = if (current.revision == Long.MAX_VALUE) 1L else current.revision + 1L)
    }

    private fun teardownRoom() {
        // The renderer's EGL context belongs to the room: drop it first.
        videoOverlay.clear()
        localVideoOverlay.clear()
        eventJob?.cancel()
        eventJob = null
        val endingRoom = room
        room = null
        if (endingRoom != null) {
            runCatching { endingRoom.disconnect() }
            runCatching { endingRoom.release() }
        }
        // Destroy key material and the native provider after the room (and its
        // frame cryptors) are fully released.
        val endingKeys = e2ee
        e2ee = null
        endingKeys?.destroy()
    }

    private fun emitSnapshotChanged() {
        val activeChannel = channel ?: return
        activeChannel.send(
            JSObject().apply {
                put("event", NativeCallWire.EVENT_SNAPSHOT_CHANGED)
                put("snapshot", snapshotJson())
            },
        )
    }

    private fun reject(invoke: Invoke, code: String) {
        val safeCode = NativeCallWire.sanitize(code)
        invoke.reject(NativeCallWire.messageFor(safeCode), safeCode)
    }

    /** The microphone service type is only requested once RECORD_AUDIO has
     * already been granted, or startForeground throws on Android 14+. */
    private fun startCallForegroundService(preferMicrophone: Boolean) {
        val intent =
            Intent(appContext, LivekitMobileForegroundService::class.java)
                .putExtra(
                    LivekitMobileForegroundService.EXTRA_MICROPHONE,
                    preferMicrophone && hasMicrophonePermission(),
                )
                .putExtra(LivekitMobileForegroundService.EXTRA_PLAYBACK, true)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(appContext, intent)
            } else {
                @Suppress("DEPRECATION")
                appContext.startService(intent)
            }
        } catch (_: RuntimeException) {
            // startForegroundService throws SecurityException/IllegalStateException
            // (both RuntimeExceptions) on missing grants or background-start
            // restrictions.
            transition { copy(lastErrorCode = NativeCallWire.ERR_UNAVAILABLE) }
        }
    }

    private fun stopCallForegroundService() {
        runCatching {
            appContext.stopService(Intent(appContext, LivekitMobileForegroundService::class.java))
        }
    }

    private companion object {
        const val DISPOSE_TIMEOUT_MS = 3_000L
    }
}
