package app.tauri.livekit_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeCallBackendsTest {
    private val a = NativeCallBackend("a", "wss://a.example", "token-a")
    private val b = NativeCallBackend("b", "wss://b.example", "token-b")

    @Test
    fun `a publisher among distinct complete backends is valid`() {
        assertTrue(isValidBackendSet("a", listOf(a)))
        assertTrue(isValidBackendSet("b", listOf(a, b)))
    }

    @Test
    fun `a publisher missing from the backends is invalid`() {
        assertFalse(isValidBackendSet("c", listOf(a, b)))
        assertFalse(isValidBackendSet("a", emptyList()))
    }

    @Test
    fun `blank id, url or token is invalid`() {
        assertFalse(isValidBackendSet("a", listOf(a, b.copy(id = " "))))
        assertFalse(isValidBackendSet("a", listOf(a, b.copy(url = ""))))
        assertFalse(isValidBackendSet("a", listOf(a, b.copy(token = "  "))))
    }

    @Test
    fun `duplicate ids are invalid`() {
        assertFalse(isValidBackendSet("a", listOf(a, a.copy(url = "wss://other.example"))))
    }

    private fun participant(
        identity: String,
        microphone: Boolean = false,
        quality: String? = null,
    ) =
        NativeRemoteParticipant(
            identity = identity,
            microphone =
                if (microphone) NativeRemoteParticipant.Microphone("TR_$identity", false, true)
                else null,
            connectionQuality = quality,
        )

    @Test
    fun `merge dedupes by identity and sorts`() {
        val merged =
            mergeRemoteParticipants(
                listOf(
                    listOf(participant("carol"), participant("alice")),
                    listOf(participant("bob"), participant("alice")),
                ),
            )
        assertEquals(listOf("alice", "bob", "carol"), merged.map { it.identity })
    }

    @Test
    fun `merge prefers the entry with publications`() {
        val publishing = participant("alice", microphone = true, quality = "good")
        val idle = participant("alice", quality = "poor")
        assertEquals(publishing, mergeRemoteParticipants(listOf(listOf(idle), listOf(publishing))).single())
        assertEquals(publishing, mergeRemoteParticipants(listOf(listOf(publishing), listOf(idle))).single())
    }

    @Test
    fun `merge keeps the earlier room on a tie`() {
        val first = participant("alice", quality = "good")
        val second = participant("alice", quality = "poor")
        assertEquals(first, mergeRemoteParticipants(listOf(listOf(first), listOf(second))).single())
        val firstPublishing = participant("alice", microphone = true, quality = "good")
        val secondPublishing = participant("alice", microphone = true, quality = "poor")
        assertEquals(
            firstPublishing,
            mergeRemoteParticipants(listOf(listOf(firstPublishing), listOf(secondPublishing))).single(),
        )
    }

    @Test
    fun `merge of no rooms is empty`() {
        assertTrue(mergeRemoteParticipants(emptyList()).isEmpty())
    }

    @Test
    fun `publishes covers every media source`() {
        assertFalse(participant("a").publishes)
        assertTrue(participant("a", microphone = true).publishes)
        assertTrue(
            NativeRemoteParticipant("a", camera = NativeRemoteParticipant.Camera("c", false, true)).publishes,
        )
        assertTrue(
            NativeRemoteParticipant("a", screenShare = NativeRemoteParticipant.ScreenShare("s", false, true))
                .publishes,
        )
        assertTrue(
            NativeRemoteParticipant("a", screenShareAudio = NativeRemoteParticipant.Microphone("m", false, true))
                .publishes,
        )
    }
}
