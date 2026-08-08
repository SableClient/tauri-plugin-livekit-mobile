package app.tauri.livekit_mobile

/** Remote-participant projection inside the snapshot. Audio-only participants
 * simply omit the camera entry; no metadata, names, or audio tracks cross.
 * Unknown connection quality is omitted rather than sent as a wire string. */
internal data class NativeRemoteParticipant(
    val identity: String,
    val camera: Camera? = null,
    val screenShare: ScreenShare? = null,
    val microphone: Microphone? = null,
    val connectionQuality: String? = null,
) {
    internal data class Camera(
        val sid: String,
        val muted: Boolean,
        val subscribed: Boolean,
    )

    internal data class ScreenShare(
        val sid: String,
        val muted: Boolean,
        val subscribed: Boolean,
    )

    internal data class Microphone(
        val sid: String,
        val muted: Boolean,
        val subscribed: Boolean,
    )
}

/**
 * Authoritative native-room snapshot. Pure immutable data; the controller owns
 * all mutation and the revision counter on its single dispatcher.
 */
internal data class NativeCallSnapshot(
    val revision: Long = 0L,
    val callId: String? = null,
    val connectionState: String = NativeCallWire.STATE_IDLE,
    val microphoneEnabled: Boolean = false,
    val cameraEnabled: Boolean = false,
    val screenShareEnabled: Boolean = false,
    val participantCount: Int = 0,
    val remoteParticipants: List<NativeRemoteParticipant> = emptyList(),
    val lastErrorCode: String? = null,
    val localConnectionQuality: String? = null,
) {
    /** True while a connect is in flight or a room is up. */
    val isActive: Boolean
        get() = callId != null && connectionState in ACTIVE_STATES

    /** Idle view of this snapshot; the controller re-applies the revision bump. */
    fun toIdle(): NativeCallSnapshot =
        copy(
            callId = null,
            connectionState = NativeCallWire.STATE_IDLE,
            microphoneEnabled = false,
            cameraEnabled = false,
            screenShareEnabled = false,
            participantCount = 0,
            remoteParticipants = emptyList(),
            lastErrorCode = null,
            localConnectionQuality = null,
        )

    companion object {
        private val ACTIVE_STATES =
            setOf(
                NativeCallWire.STATE_CONNECTING,
                NativeCallWire.STATE_CONNECTED,
                NativeCallWire.STATE_RECONNECTING,
            )
    }
}
