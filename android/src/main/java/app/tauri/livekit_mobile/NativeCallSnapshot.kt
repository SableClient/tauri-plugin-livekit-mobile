package app.tauri.livekit_mobile

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
    val participantCount: Int = 0,
    val lastErrorCode: String? = null,
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
            participantCount = 0,
            lastErrorCode = null,
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
