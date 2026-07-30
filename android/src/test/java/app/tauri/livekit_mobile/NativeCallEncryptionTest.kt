package app.tauri.livekit_mobile

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeCallEncryptionTest {
    private fun base64Of(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    @Test
    fun `decodeEntry accepts a valid entry and preserves raw bytes`() {
        val raw = byteArrayOf(0, 1, 2, 127, -128, -1, 42, 96, 13, 37)
        val material = NativeCallEncryption.decodeEntry("@alice:example.org", 3, base64Of(raw))
        requireNotNull(material)
        assertEquals("@alice:example.org", material.identity)
        assertEquals(3, material.keyIndex)
        assertTrue(material.key.contentEquals(raw))
    }

    @Test
    fun `decodeEntry rejects malformed wire entries`() {
        // Invalid base64 payloads.
        assertNull(NativeCallEncryption.decodeEntry("@a:b.c", 0, "not-a-base64-key!"))
        assertNull(NativeCallEncryption.decodeEntry("@a:b.c", 0, "AAAAA")) // truncated
        assertNull(NativeCallEncryption.decodeEntry("@a:b.c", 0, "QUJD RA==")) // whitespace
        // Empty or missing key material.
        assertNull(NativeCallEncryption.decodeEntry("@a:b.c", 0, ""))
        // Blank identity and negative indexes never reach the provider.
        assertNull(NativeCallEncryption.decodeEntry("", 0, base64Of(byteArrayOf(1))))
        assertNull(NativeCallEncryption.decodeEntry("   ", 0, base64Of(byteArrayOf(1))))
        assertNull(NativeCallEncryption.decodeEntry("@a:b.c", -1, base64Of(byteArrayOf(1))))
    }

    @Test
    fun `decodeEntry holds a defensive copy of the decoded bytes`() {
        val raw = byteArrayOf(7, 7, 7, 7)
        val material = NativeCallEncryption.decodeEntry("@a:b.c", 0, base64Of(raw))
        requireNotNull(material)
        raw.fill(0)
        assertTrue(material.key.contentEquals(byteArrayOf(7, 7, 7, 7)))
    }

    @Test
    fun `key index guard accepts a first key per identity`() {
        val guard = KeyIndexGuard()
        assertTrue(guard.accepts("@a:b.c", 0))
        guard.record("@a:b.c", 0)
        assertEquals(0, guard.latestFor("@a:b.c"))
    }

    @Test
    fun `key index guard only accepts strictly increasing indexes`() {
        val guard = KeyIndexGuard()
        guard.record("@a:b.c", 4)
        assertTrue(guard.accepts("@a:b.c", 5))
        // Replay of the current index is rejected.
        assertTrue(!guard.accepts("@a:b.c", 4))
        // Older indexes are rejected.
        assertTrue(!guard.accepts("@a:b.c", 0))
        guard.record("@a:b.c", 5)
        assertEquals(5, guard.latestFor("@a:b.c"))
        // Recording a rejected index must not move the cursor backwards.
        guard.record("@a:b.c", 2)
        assertEquals(5, guard.latestFor("@a:b.c"))
    }

    @Test
    fun `key index guard tracks identities independently`() {
        val guard = KeyIndexGuard()
        guard.record("@a:b.c", 7)
        assertTrue(guard.accepts("@b:b.c", 0))
        guard.record("@b:b.c", 0)
        assertEquals(7, guard.latestFor("@a:b.c"))
        assertEquals(0, guard.latestFor("@b:b.c"))
    }

    @Test
    fun `initial ring entries recorded out of order keep the greatest index as latest`() {
        // iOS parity: an initial list may install multiple indexes for the same
        // identity (every ring entry is retained natively); the tracked latest
        // must be the greatest regardless of arrival order.
        val guard = KeyIndexGuard()
        guard.record("@a:b.c", 2)
        guard.record("@a:b.c", 5)
        guard.record("@a:b.c", 3)
        assertEquals(5, guard.latestFor("@a:b.c"))
        assertTrue(guard.accepts("@a:b.c", 6))
        assertTrue(!guard.accepts("@a:b.c", 5))
        assertTrue(!guard.accepts("@a:b.c", 3))
    }

    @Test
    fun `key index guard tolerates concurrent reads while recording`() {
        val guard = KeyIndexGuard()
        guard.record("@a:b.c", 1)
        val readers =
            (1..4).map {
                Thread {
                    repeat(500) {
                        guard.latestFor("@a:b.c")
                        guard.accepts("@a:b.c", 2)
                    }
                }
            }
        readers.forEach(Thread::start)
        repeat(500) { guard.record("@a:b.c", it + 2) }
        readers.forEach(Thread::join)
        assertEquals(501, guard.latestFor("@a:b.c"))
        assertTrue(!guard.accepts("@a:b.c", 501))
        assertTrue(guard.accepts("@a:b.c", 502))
    }
}
