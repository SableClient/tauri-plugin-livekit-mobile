package app.tauri.livekit_mobile

import android.content.Context
import android.view.MotionEvent
import android.view.View
import io.livekit.android.renderer.TextureViewRenderer

/**
 * Non-interactive remote-video overlay renderer.
 *
 * The overlay is placed above the host WebView and must never intercept its
 * touches. Click/focus flags alone only influence [View.onTouchEvent]; this
 * class guarantees pass-through at dispatch level: [dispatchTouchEvent]
 * returns false for every event, so the parent always falls through to the
 * sibling below (the WebView) regardless of future flag changes.
 *
 * Verified on-device by PassThroughVideoRendererInstrumentedTest.
 */
internal class PassThroughVideoRenderer(context: Context) : TextureViewRenderer(context) {
    /** Rotated size of the last frame; main thread only, 0 until one lands. */
    var frameWidth = 0
        private set
    var frameHeight = 0
        private set

    /** Runs on the main thread after the frame size changes. */
    var onFrameSizeChanged: (() -> Unit)? = null

    init {
        isClickable = false
        isFocusable = false
        isLongClickable = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun resetFrameSize() {
        frameWidth = 0
        frameHeight = 0
    }

    override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
        super.onFrameResolutionChanged(videoWidth, videoHeight, rotation)
        val turned = rotation == 90 || rotation == 270
        val width = if (turned) videoHeight else videoWidth
        val height = if (turned) videoWidth else videoHeight
        post {
            if (width == frameWidth && height == frameHeight) return@post
            frameWidth = width
            frameHeight = height
            onFrameSizeChanged?.invoke()
        }
    }

    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean = false

    override fun onTouchEvent(event: MotionEvent?): Boolean = false
}
