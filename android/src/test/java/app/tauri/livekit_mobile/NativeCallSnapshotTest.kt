package app.tauri.livekit_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeCallSnapshotTest {
    @Test
    fun `default snapshot is the idle snapshot`() {
        val snapshot = NativeCallSnapshot()
        assertEquals(0L, snapshot.revision)
        assertNull(snapshot.callId)
        assertEquals(NativeCallWire.STATE_IDLE, snapshot.connectionState)
        assertFalse(snapshot.microphoneEnabled)
        assertFalse(snapshot.cameraEnabled)
        assertEquals(0, snapshot.participantCount)
        assertNull(snapshot.lastErrorCode)
        assertFalse(snapshot.isActive)
    }

    @Test
    fun `isActive needs a callId and an active connection state`() {
        for (state in listOf("connecting", "connected", "reconnecting")) {
            assertTrue(NativeCallSnapshot(callId = "a", connectionState = state).isActive)
        }
        for (state in listOf("idle", "failed")) {
            assertFalse(NativeCallSnapshot(callId = "a", connectionState = state).isActive)
        }
        assertFalse(NativeCallSnapshot(connectionState = "connected").isActive)
    }

    @Test
    fun `toIdle clears call facts but keeps the revision`() {
        val active =
            NativeCallSnapshot(
                revision = 7L,
                callId = "a",
                connectionState = NativeCallWire.STATE_CONNECTED,
                microphoneEnabled = true,
                cameraEnabled = true,
                participantCount = 5,
                lastErrorCode = NativeCallWire.ERR_MEDIA_FAILED,
            )
        val idle = active.toIdle()
        assertEquals(7L, idle.revision)
        assertNull(idle.callId)
        assertEquals(NativeCallWire.STATE_IDLE, idle.connectionState)
        assertFalse(idle.microphoneEnabled)
        assertFalse(idle.cameraEnabled)
        assertEquals(0, idle.participantCount)
        assertNull(idle.lastErrorCode)
        assertFalse(idle.isActive)
    }
}
