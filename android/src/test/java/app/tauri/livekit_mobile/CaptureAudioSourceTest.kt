package app.tauri.livekit_mobile

import android.media.MediaRecorder
import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureAudioSourceTest {
    @Test
    fun `noise suppression keeps the voice communication source`() {
        assertEquals(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            captureAudioSource(noiseSuppression = true, unprocessedSupported = true),
        )
    }

    @Test
    fun `without noise suppression the microphone is unprocessed`() {
        assertEquals(
            MediaRecorder.AudioSource.UNPROCESSED,
            captureAudioSource(noiseSuppression = false, unprocessedSupported = true),
        )
    }

    @Test
    fun `devices without an unprocessed source fall back to voice recognition`() {
        assertEquals(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            captureAudioSource(noiseSuppression = false, unprocessedSupported = false),
        )
    }
}
