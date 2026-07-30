package app.tauri.livekit_mobile

import io.livekit.android.e2ee.KeyProvider
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import livekit.org.webrtc.FrameCryptorFactory
import livekit.org.webrtc.FrameCryptorKeyDerivationAlgorithm
import livekit.org.webrtc.FrameCryptorKeyProvider

/**
 * One decoded key-install request. `key` is raw binary key material; it must
 * never be logged or cross the bridge in a snapshot.
 */
internal class NativeCallKeyMaterial(
    val identity: String,
    val keyIndex: Int,
    key: ByteArray,
) {
    /** Defensive copy so the caller cannot mutate (or zero) our key bytes. */
    val key: ByteArray = key.copyOf()
}

/** Wire-side decoding and the MatrixRTC-interop E2EE constants. */
internal object NativeCallEncryption {
    // MatrixRTC interoperability values (match the JS SDK frame-cryptor options).
    const val RATCHET_SALT = "LKFrameEncryptionKey"
    const val MAGIC_BYTES = "LK-ROCKS"
    const val RATCHET_WINDOW_SIZE = 10
    const val KEY_RING_SIZE = 256

    /** Validates and decodes one wire entry; null when the entry is invalid. */
    fun decodeEntry(
        identity: String,
        keyIndex: Int,
        encodedKey: String,
    ): NativeCallKeyMaterial? {
        if (identity.isBlank() || keyIndex < 0) return null
        val bytes =
            try {
                Base64.getDecoder().decode(encodedKey)
            } catch (_: IllegalArgumentException) {
                return null
            }
        if (bytes.isEmpty()) return null
        return NativeCallKeyMaterial(identity, keyIndex, bytes)
    }
}

/**
 * Per-identity monotonic guard for key indexes: a rotation key is only accepted
 * when its index is strictly greater than the last recorded index for that
 * identity. [record] keeps the greatest index seen, so out-of-order initial
 * ring entries cannot move the cursor backwards. The map is thread-safe
 * because LiveKit/WebRTC may call getLatestKeyIndex off the bridge thread
 * while installs happen on it.
 */
internal class KeyIndexGuard {
    private val latest = ConcurrentHashMap<String, Int>()

    fun accepts(identity: String, keyIndex: Int): Boolean =
        keyIndex > (latest[identity] ?: -1)

    fun record(identity: String, keyIndex: Int) {
        while (true) {
            val current = latest[identity]
            if (current != null && current >= keyIndex) return
            val updated =
                if (current == null) {
                    latest.putIfAbsent(identity, keyIndex) == null
                } else {
                    latest.replace(identity, current, keyIndex)
                }
            if (updated) return
        }
    }

    fun latestFor(identity: String): Int? = latest[identity]
}

/**
 * Per-call, non-shared E2EE key provider with MatrixRTC interoperability
 * parameters (HKDF derivation, salt `LKFrameEncryptionKey`, magic bytes
 * `LK-ROCKS`, ratchet window 10, key ring 256).
 *
 * Keys are raw binary and are installed exclusively through the public
 * underlying [FrameCryptorKeyProvider] ByteArray setter; the String-based
 * mutators of the interface stay unused because String conversion corrupts
 * binary key material. A fresh instance is created per call; [destroy] zeroes
 * every stored JVM copy of key bytes and disposes the native provider.
 */
internal class NativeCallE2EEKeys : KeyProvider {
    private val guard = KeyIndexGuard()
    private val keyCopies = ArrayList<ByteArray>()

    override val rtcKeyProvider: FrameCryptorKeyProvider =
        FrameCryptorFactory.createFrameCryptorKeyProvider(
            /* enableSharedKey = */ false,
            NativeCallEncryption.RATCHET_SALT.toByteArray(Charsets.UTF_8),
            NativeCallEncryption.RATCHET_WINDOW_SIZE,
            NativeCallEncryption.MAGIC_BYTES.toByteArray(Charsets.UTF_8),
            /* failureTolerance = */ -1,
            NativeCallEncryption.KEY_RING_SIZE,
            /* discardFrameWhenCryptorNotReady = */ false,
            FrameCryptorKeyDerivationAlgorithm.HKDF,
        )

    /** This provider is per-call and never shared. */
    override var enableSharedKey: Boolean = false

    /**
     * Installs one entry of the initial key list. Matching the iOS behavior,
     * multiple indexes for the same identity are all installed so the key ring
     * retains every supplied entry; the tracked latest index is the greatest
     * one. May throw when the underlying JNI layer is unavailable.
     */
    fun installRingEntry(material: NativeCallKeyMaterial) {
        rtcKeyProvider.setKey(material.identity, material.keyIndex, material.key)
        guard.record(material.identity, material.keyIndex)
        keyCopies.add(material.key)
    }

    /**
     * Installs a rotation update; only indexes strictly greater than the
     * recorded latest for that identity are installed. Returns false when the
     * guard rejects the key as stale or retransmitted. May throw when the
     * underlying JNI layer is unavailable.
     */
    fun installRotation(material: NativeCallKeyMaterial): Boolean {
        if (!guard.accepts(material.identity, material.keyIndex)) return false
        rtcKeyProvider.setKey(material.identity, material.keyIndex, material.key)
        guard.record(material.identity, material.keyIndex)
        keyCopies.add(material.key)
        return true
    }

    /**
     * Mirrors BaseKeyProvider semantics (0 when nothing was set) so the E2EE
     * manager stamps frame cryptors with the latest accepted index. Stored
     * indexes are only written through [install], so they stay monotonic.
     */
    override fun getLatestKeyIndex(participantId: String): Int =
        guard.latestFor(participantId) ?: 0

    /** Zeroes every JVM copy of decoded key bytes and releases the native provider. */
    fun destroy() {
        keyCopies.forEach { it.fill(0) }
        keyCopies.clear()
        runCatching { rtcKeyProvider.dispose() }
    }

    // Raw binary keys only: the String-based setters are never wired to the
    // bridge, and String conversion would corrupt binary key material.
    override fun setKey(key: String, participantId: String?, index: Int?) = Unit

    override fun setSharedKey(key: String, index: Int?): Boolean = false

    override fun ratchetSharedKey(index: Int?): ByteArray =
        rtcKeyProvider.ratchetSharedKey(index ?: 0)

    override fun exportSharedKey(index: Int?): ByteArray =
        rtcKeyProvider.exportSharedKey(index ?: 0)

    override fun ratchetKey(participantId: String, index: Int?): ByteArray =
        rtcKeyProvider.ratchetKey(participantId, index ?: 0)

    override fun exportKey(participantId: String, index: Int?): ByteArray =
        rtcKeyProvider.exportKey(participantId, index ?: 0)

    override fun setSifTrailer(trailer: ByteArray) = rtcKeyProvider.setSifTrailer(trailer)
}
