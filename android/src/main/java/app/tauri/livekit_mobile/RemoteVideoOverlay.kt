package app.tauri.livekit_mobile

import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.livekit.android.room.Room
import io.livekit.android.room.track.RemoteTrackPublication
import io.livekit.android.room.track.VideoTrack
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.ceil
import kotlin.math.floor

/** Physical-pixel rect for the overlay view: CSS rect converted and clipped. */
internal data class OverlayRect(
    val left: Int,
    val top: Int,
    val width: Int,
    val height: Int,
)

/** Raw overlay request kept for later rebinding while a track is detached. */
internal data class OverlaySpec(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    val devicePixelRatio: Double,
)

/**
 * Converts a WebView-viewport-relative CSS rect into a physical Android pixel
 * rect clipped to the WebView itself (`viewportWidthPx`/`viewportHeightPx`).
 *
 * All edge math happens in the Double domain and the viewport intersection is
 * computed before any Int conversion, so huge-but-finite inputs clip cleanly
 * instead of overflowing. Edges convert with floor/ceil after clipping so any
 * pixel the intersection touches is covered. Offsets may be negative (an
 * element can straddle the viewport edge); size and ratio must be finite and
 * strictly positive. Returns null when the intersection is empty.
 */
internal fun overlayRectFromCss(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    devicePixelRatio: Double,
    viewportWidthPx: Int,
    viewportHeightPx: Int,
): OverlayRect? {
    if (!x.isFinite() || !y.isFinite() || !width.isFinite() || !height.isFinite() ||
        !devicePixelRatio.isFinite() ||
        width <= 0.0 || height <= 0.0 || devicePixelRatio <= 0.0
    ) {
        return null
    }
    if (viewportWidthPx <= 0 || viewportHeightPx <= 0) return null

    val left = x * devicePixelRatio
    val top = y * devicePixelRatio
    val right = left + width * devicePixelRatio
    val bottom = top + height * devicePixelRatio

    val clippedLeft = maxOf(left, 0.0)
    val clippedTop = maxOf(top, 0.0)
    val clippedRight = minOf(right, viewportWidthPx.toDouble())
    val clippedBottom = minOf(bottom, viewportHeightPx.toDouble())
    if (clippedRight <= clippedLeft || clippedBottom <= clippedTop) return null

    // Post-intersection conversion is bounded by the viewport: no overflow.
    val leftInt = floor(clippedLeft).toInt()
    val topInt = floor(clippedTop).toInt()
    val rightInt = ceil(clippedRight).toInt()
    val bottomInt = ceil(clippedBottom).toInt()
    return OverlayRect(
        left = leftInt,
        top = topInt,
        width = rightInt - leftInt,
        height = bottomInt - topInt,
    )
}

/**
 * Owns the single remote-camera overlay: one [PassThroughVideoRenderer]
 * sibling placed directly above the host WebView.
 *
 * Callers stay on the controller's bridge thread, so the fields are
 * single-writer; every view/renderer mutation is marshalled onto the main
 * thread and awaited so failures map onto a bounded outcome. `generation`
 * guards marshalled blocks against a teardown that landed between the bridge
 * capture and the main-thread run (and once more just before field commit, so
 * a block that outlived the marshal timeout still cannot resurrect state).
 *
 * Lifecycle model, driven by [reconcile] from LiveKit track events:
 * - ATTACHED: sink bound, tile visible.
 * - DETACHED: the track disappeared (unpublished/unsubscribed/left). The sink
 *   is detached and the tile hidden immediately, but the selection
 *   (identity, SID, geometry) is preserved so a later publish/subscribe event
 *   rebinds it automatically. No stale frame or track is ever shown.
 * - [clear] (explicit clear, disconnect, dispose) forgets the selection and
 *   releases everything.
 *
 * A track only resolves while its remote publication is `subscribed` and
 * carries a non-null [VideoTrack]; unsubscription detaches immediately.
 */
internal class RemoteVideoOverlay(
    private val webViewProvider: () -> WebView?,
) {
    internal sealed interface AttachResult {
        data object Attached : AttachResult

        data object InvalidGeometry : AttachResult

        data object TrackUnavailable : AttachResult

        data object HostUnavailable : AttachResult

        data object Failed : AttachResult
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var renderer: PassThroughVideoRenderer? = null

    /** Null while DETACHED: the selection survives, the sink does not. */
    @Volatile private var attachedTrack: VideoTrack? = null

    @Volatile private var selectedIdentity: String? = null

    @Volatile private var selectedTrackSid: String? = null

    @Volatile private var selectedSpec: OverlaySpec? = null

    @Volatile private var generation = 0L

    /**
     * Attaches the remote camera track to the overlay. The same track only
     * re-lays the view; a different track moves the sink over. An unavailable
     * track records the selection, detaches/hides any current tile, and
     * reports [AttachResult.TrackUnavailable]; a later publish/subscribe
     * rebinds it via [reconcile]. Any failure after renderer/view creation or
     * attachment (including a marshal timeout whose queued block could still
     * run) invalidates the generation and rolls back to a fully released,
     * selection-less state.
     */
    fun attach(
        room: Room,
        participantIdentity: String,
        trackSid: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        devicePixelRatio: Double,
    ): AttachResult {
        val spec = OverlaySpec(x, y, width, height, devicePixelRatio)
        val track = resolveSubscribedVideoTrack(room, participantIdentity, trackSid)
        if (track == null) {
            // Record the selection so a later publish rebinds automatically;
            // hide any current tile without forgetting it.
            selectedIdentity = participantIdentity
            selectedTrackSid = trackSid
            selectedSpec = spec
            if (!detachOnMainThread()) {
                clear()
            }
            return AttachResult.TrackUnavailable
        }
        val capturedGeneration = generation
        return runCatching {
                onMainThread {
                    if (generation != capturedGeneration) {
                        return@onMainThread AttachResult.Failed
                    }
                    val webView = webViewProvider()
                        ?: return@onMainThread AttachResult.HostUnavailable
                    val parent = webView.parent as? ViewGroup
                        ?: return@onMainThread AttachResult.HostUnavailable
                    val rect =
                        overlayRectFromCss(
                            x,
                            y,
                            width,
                            height,
                            devicePixelRatio,
                            webView.width,
                            webView.height,
                        )
                            ?: return@onMainThread AttachResult.InvalidGeometry

                    val previous = renderer
                    val view = previous ?: PassThroughVideoRenderer(webView.context)
                    try {
                        if (previous == null) {
                            room.initVideoRenderer(view)
                        }
                        if (attachedTrack !== track) {
                            attachedTrack?.removeRenderer(view)
                            track.addRenderer(view)
                        }

                        view.layoutParams = ViewGroup.LayoutParams(rect.width, rect.height)
                        if (view.parent !== parent) {
                            (view.parent as? ViewGroup)?.removeView(view)
                            val webViewIndex = parent.indexOfChild(webView)
                            val index =
                                if (webViewIndex >= 0) webViewIndex + 1 else parent.childCount
                            parent.addView(view, index)
                        }
                        // The clipped rect is WebView viewport-relative; the
                        // view sits in the WebView's parent, so translate by
                        // the parent-relative origin. Translations survive
                        // parent re-layouts.
                        view.translationX = webView.left + webView.translationX + rect.left
                        view.translationY = webView.top + webView.translationY + rect.top
                        view.visibility = View.VISIBLE

                        if (generation != capturedGeneration) {
                            // The marshal timed out / a teardown landed while
                            // this block ran: rollback instead of resurrecting
                            // state the bridge already forgot.
                            rollbackFailedAttach(view, track)
                            return@onMainThread AttachResult.Failed
                        }
                        renderer = view
                        attachedTrack = track
                        selectedIdentity = participantIdentity
                        selectedTrackSid = trackSid
                        selectedSpec = spec
                        AttachResult.Attached
                    } catch (failure: Exception) {
                        rollbackFailedAttach(view, track)
                        AttachResult.Failed
                    }
                }
            }
            .getOrElse {
                // A queued block may still run later; invalidate it, then drop
                // any partial state through the wedged-main-safe clear path.
                generation++
                clear()
                AttachResult.Failed
            }
    }

    /**
     * Re-resolves the selection after a LiveKit track lifecycle event:
     * - ATTACHED + selection gone → detach + hide (selection preserved).
     * - ATTACHED + replaced track → rebind the sink in place.
     * - DETACHED + selection back (publish/subscribe) → rebind + show.
     * Any failure clears fully. No-op while nothing is selected.
     */
    fun reconcile(room: Room?) {
        val identity = selectedIdentity ?: return
        val trackSid = selectedTrackSid ?: return
        val spec = selectedSpec ?: return
        val resolved = room?.let { resolveSubscribedVideoTrack(it, identity, trackSid) }
        val view = renderer
        if (view == null) {
            // Nothing to detach; reattach from scratch once the track exists.
            if (room != null && resolved != null) {
                attach(room, identity, trackSid, spec.x, spec.y, spec.width, spec.height,
                    spec.devicePixelRatio)
            }
            return
        }
        if (resolved == null) {
            if (!detachOnMainThread()) {
                clear()
            }
            return
        }
        if (resolved === attachedTrack && view.visibility == View.VISIBLE) return
        val completed =
            runCatching {
                    onMainThread {
                        // The selection/view may have changed while queued.
                        if (renderer !== view || selectedIdentity != identity ||
                            selectedTrackSid != trackSid
                        ) {
                            return@onMainThread true
                        }
                        if (attachedTrack !== resolved) {
                            attachedTrack?.removeRenderer(view)
                            resolved.addRenderer(view)
                            attachedTrack = resolved
                        }
                        if (view.visibility != View.VISIBLE) {
                            val webView =
                                webViewProvider() ?: return@onMainThread false
                            val parent = webView.parent as? ViewGroup
                                ?: return@onMainThread false
                            val rect =
                                overlayRectFromCss(
                                    spec.x,
                                    spec.y,
                                    spec.width,
                                    spec.height,
                                    spec.devicePixelRatio,
                                    webView.width,
                                    webView.height,
                                )
                            // A degenerate viewport keeps the tile hidden; the
                            // sink stays bound so video resumes after layout.
                            if (rect != null) {
                                view.layoutParams =
                                    ViewGroup.LayoutParams(rect.width, rect.height)
                                if (view.parent !== parent) {
                                    (view.parent as? ViewGroup)?.removeView(view)
                                    parent.addView(view)
                                }
                                view.translationX =
                                    webView.left + webView.translationX + rect.left
                                view.translationY =
                                    webView.top + webView.translationY + rect.top
                                view.visibility = View.VISIBLE
                            }
                        }
                        true
                    }
                }
                .getOrElse { false }
        if (!completed) clear()
    }

    /**
     * Explicit clear / disconnect / dispose: forget the selection and release
     * everything; never throws. The fields reset first on the caller thread,
     * so a wedged main thread still drops the sink/EGL eagerly while the
     * dying hierarchy discards the view.
     */
    fun clear() {
        generation++
        val view = renderer
        val track = attachedTrack
        renderer = null
        attachedTrack = null
        selectedIdentity = null
        selectedTrackSid = null
        selectedSpec = null
        if (view == null) return
        runCatching {
                onMainThread {
                    if (track != null) runCatching { track.removeRenderer(view) }
                    (view.parent as? ViewGroup)?.removeView(view)
                    // May share the view with a timed-out attach rollback.
                    runCatching { view.release() }
                }
            }
            .onFailure {
                if (track != null) runCatching { track.removeRenderer(view) }
                runCatching { view.release() }
            }
    }

    /**
     * Temporary detach: drop the sink and hide the tile but keep the view,
     * renderer, and selection so [reconcile] can rebind. The `attachedTrack`
     * reference is retained until the main-thread removal actually succeeds,
     * since clearing it earlier would let a marshal timeout/failure orphan the
     * renderer as a sink on the old track, which the follow-up [clear] must
     * then still be able to reach. Returns false when the main-thread step
     * failed and callers should [clear] instead (the kept reference lets that
     * clear remove the sink through its wedged-main fallback).
     */
    private fun detachOnMainThread(): Boolean {
        val view = renderer ?: return true
        return runCatching {
                onMainThread {
                    if (renderer !== view) return@onMainThread
                    attachedTrack?.let { track ->
                        // Only forget the track once the sink is really gone.
                        track.removeRenderer(view)
                        attachedTrack = null
                    }
                    view.visibility = View.GONE
                }
            }
            .isSuccess
    }

    /**
     * Transactional rollback for a failed [attach]: detach the view from both
     * the previous and the attempted track, remove it from the hierarchy,
     * release its EGL resources, and forget every owner reference. Runs on the
     * main thread from the attach catch-block; every step is isolated so one
     * failure cannot mask the remaining cleanup.
     */
    private fun rollbackFailedAttach(
        view: PassThroughVideoRenderer,
        attemptedTrack: VideoTrack,
    ) {
        attachedTrack?.let { runCatching { it.removeRenderer(view) } }
        runCatching { attemptedTrack.removeRenderer(view) }
        runCatching { (view.parent as? ViewGroup)?.removeView(view) }
        runCatching { view.release() }
        renderer = null
        attachedTrack = null
        selectedIdentity = null
        selectedTrackSid = null
        selectedSpec = null
    }

    /**
     * Resolves a remote participant's video track by identity + track SID, but
     * only while the publication is subscribed and carries a non-null track;
     * an unsubscribed publication detaches immediately rather than replaying
     * its last frame.
     */
    private fun resolveSubscribedVideoTrack(
        room: Room,
        participantIdentity: String,
        trackSid: String,
    ): VideoTrack? {
        val participant =
            room.remoteParticipants.entries
                .firstOrNull { (identity, _) -> identity.value == participantIdentity }
                ?.value
                ?: return null
        val publication =
            participant.trackPublications.values.firstOrNull { it.sid == trackSid }
                as? RemoteTrackPublication
                ?: return null
        if (!publication.subscribed) return null
        return publication.track as? VideoTrack
    }

    /** Runs a mutation on the main thread; bridge callers block briefly. */
    private fun <T> onMainThread(block: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        val latch = CountDownLatch(1)
        val box = arrayOfNulls<Result<T>>(1)
        mainHandler.post {
            box[0] = runCatching(block)
            latch.countDown()
        }
        if (!latch.await(MAIN_THREAD_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            throw TimeoutException("main thread did not run the overlay mutation")
        }
        return box[0]!!.getOrThrow()
    }

    private companion object {
        const val MAIN_THREAD_TIMEOUT_MS = 3_000L
    }
}
