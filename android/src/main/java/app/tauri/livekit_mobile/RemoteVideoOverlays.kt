package app.tauri.livekit_mobile

import android.webkit.WebView
import io.livekit.android.room.Room

internal class RemoteVideoOverlays(
    private val webViewProvider: () -> WebView?,
) {
    private val tiles = LinkedHashMap<String, RemoteVideoOverlay>()

    @Volatile private var takeover: RemoteVideoOverlay? = null

    fun attach(
        rooms: List<Room>,
        participantIdentity: String,
        trackSid: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        devicePixelRatio: Double,
    ): OverlayAttachResult {
        val tile = synchronized(tiles) {
            tiles.getOrPut(trackSid) { RemoteVideoOverlay(webViewProvider) }
        }
        return tile.attach(
            rooms,
            participantIdentity,
            trackSid,
            x,
            y,
            width,
            height,
            devicePixelRatio,
        )
    }

    fun reconcile(rooms: List<Room>) {
        all().forEach { it.reconcile(rooms) }
    }

    fun clear(trackSid: String) {
        val tile = synchronized(tiles) { tiles.remove(trackSid) } ?: return
        if (takeover === tile) takeover = null
        tile.clear()
    }

    fun clear() {
        val removed = synchronized(tiles) { tiles.values.toList().also { tiles.clear() } }
        takeover = null
        removed.forEach { it.clear() }
    }

    fun setFullWindow(enabled: Boolean): Boolean {
        if (!enabled) {
            val previous = takeover ?: return true
            takeover = null
            return previous.setFullWindow(false)
        }
        val bound = all().filter { it.bound }
        val chosen = bound.firstOrNull { it.screenShare } ?: bound.firstOrNull() ?: return true
        takeover = chosen
        return chosen.setFullWindow(true)
    }

    private fun all(): List<RemoteVideoOverlay> = synchronized(tiles) { tiles.values.toList() }
}
