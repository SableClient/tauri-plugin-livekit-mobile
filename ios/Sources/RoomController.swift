import AVFoundation
import AVKit
import LiveKit
import Tauri
import UIKit
import WebKit

/// Serialized owner of the single native LiveKit room behind the bridge.
///
/// All state is main-actor isolated. LiveKit invokes RoomDelegate callbacks
/// on its own multicast queue (not main), so every delegate method hops onto
/// the main actor and verifies `room === self.room` before mutating.
///
/// `attempt` identifies the current call attempt: it is bumped whenever the
/// attempt is replaced or torn down, so stale async work settles its invoke
/// with `cancelled` at its next suspension point instead of mutating state
/// that now belongs to a newer attempt.
///
/// All state mutations publish through `emitSnapshotChanged`, which owns the
/// revision bump.
///
/// LiveKit's AudioManager owns the AVAudioSession for the room lifecycle
/// (category, mode, activation); do not configure it here. The only
/// session-adjacent work in this bridge is the media permission requests
/// before publishing.
@MainActor
final class RoomController: NSObject {
  // Nonisolated init so the plugin can construct the controller off the main
  // actor; all state access stays main-actor serialized.
  nonisolated override init() {
    super.init()
  }

  private var room: Room?
  private var channel: Channel?
  private var callId: String?
  /// Per-call E2EE key provider. Non-nil only while the current attempt is
  /// encrypted; created with all initial key material installed before the
  /// Room exists, so rotation is accepted for the whole `connecting` phase.
  private var keyProvider: BaseKeyProvider?
  /// Highest applied key index per participant identity, for the monotonic
  /// rotation guard. Never logged or exposed through the bridge.
  private var appliedKeyIndexes: [String: Int32] = [:]
  private var revision: UInt64 = 0
  private var connectionState: BridgeConnectionState = .idle
  private var microphoneEnabled = false
  private var cameraEnabled = false
  private var screenShareEnabled = false
  private var participantCount = 0
  private var remoteParticipants: [BridgeRemoteParticipant] = []
  private var lastError: BridgeError?
  /// Local connection quality from the last
  /// `room(_:participant:didUpdateConnectionQuality:)` delegate event for the
  /// local participant. Nil until the first such event arrives.
  private var localConnectionQuality: BridgeConnectionQuality? = nil
  private var attempt: UInt64 = 0

  // MARK: Remote video overlay state

  /// Weak handle to the Tauri webview, retained from `Plugin.load(webview:)`.
  /// The overlay's frame is positioned in this view's superview.
  private weak var hostWebView: WKWebView?
  /// The single non-interactive native renderer for one remote video track.
  /// It exists only while the lane requests an overlay; clearing, disconnect
  /// and teardown remove it from the view hierarchy.
  private var overlayView: VideoView?
  /// The participant/track the overlay is bound to. Stored so participant
  /// and track lifecycle delegate events can re-resolve and rebind (or
  /// clear) the attachment as publications come and go.
  private var overlaySelection: OverlaySelection?

  /// How long a dropped socket may stay in `reconnecting` before the call is
  /// reported as terminally failed.
  private static let reconnectGraceSeconds: UInt64 = 30
  /// Pending promotion of a stalled reconnect to `.failed`. Cancelled when the
  /// room reconnects or is torn down.
  private var reconnectDeadline: Task<Void, Never>?

  // MARK: Native Picture-in-Picture (iOS 15+)

  /// Whether native PiP is enabled for the current call. The JS lane
  /// controls this via `setNativeCallPiPEnabled`. PiP uses the overlay
  /// view's AVSampleBufferDisplayLayer as a content source.
  private var pipEnabled: Bool = false
  /// The AVPictureInPictureController (iOS 15+) that manages the PiP
  /// lifecycle. Non-nil when PiP is active or ready to auto-start.
  private var pipController: Any? = nil
  /// The AVPictureInPictureVideoCallViewController that hosts the sample
  /// buffer display layer for PiP content.
  private var pipViewController: Any? = nil

  private struct OverlaySelection {
    let participantIdentity: String
    let trackSid: String
  }

  // MARK: Local camera preview overlay state

  /// Second non-interactive native renderer for the local camera track.
  /// Independent from `overlayView`; the two can coexist on-screen.
  private var localOverlayView: VideoView?

  // MARK: CallKit integration

  /// Weak reference for pushing system call start/end/mute events back to
  /// the CallKit controller. Set by the plugin after init.
  weak var callKitController: CallKitController?

  /// Called from `Plugin.load(webview:)`; the reference stays weak so the
  /// plugin never extends the webview's lifetime.
  func attachHostWebView(_ webView: WKWebView) {
    hostWebView = webView
  }

  // MARK: - Snapshot

  func snapshot() -> BridgeStateResponse {
    BridgeStateResponse(
      revision: revision,
      callId: callId,
      connectionState: connectionState,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
      screenShareEnabled: screenShareEnabled,
      participantCount: participantCount,
      remoteParticipants: remoteParticipants,
      lastError: lastError,
      localConnectionQuality: localConnectionQuality)
  }

  /// Publishes the current snapshot on the active call's channel and bumps
  /// the revision. No-op without an active channel.
  private func emitSnapshotChanged() {
    guard let channel else { return }
    revision &+= 1
    try? channel.send(
      BridgeSnapshotEvent(event: .snapshotChanged, snapshot: snapshot()))
  }

  // MARK: - Commands

  func connect(_ args: ConnectArgs, invoke: Invoke) async {
    // An active attempt blocks a different call; the same call is a no-op.
    switch connectionState {
    case .connecting, .connected, .reconnecting:
      if callId == args.callId {
        invoke.resolve(snapshot())
      } else {
        reject(invoke, .busy)
      }
      return
    case .idle, .failed:
      break
    }

    // Decode the optional E2EE key material up front: malformed base64 or
    // negative indexes reject through the bounded invalid-request path
    // without disturbing any state. Absent or empty means unencrypted.
    guard let keyMaterial = Self.decodeKeyMaterial(from: args.encryptionKeys) else {
      reject(invoke, .invalidRequest)
      return
    }

    attempt &+= 1
    let attemptId = attempt

    // Clear a leftover room from a failed attempt, if any.
    if let staleRoom = room {
      room = nil
      keyProvider = nil
      appliedKeyIndexes = [:]
      removeOverlayView()
      removeLocalOverlayView()
      await staleRoom.disconnect()
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
    }

    callId = args.callId
    channel = args.channel
    lastError = nil
    microphoneEnabled = false
    cameraEnabled = false
    screenShareEnabled = false
    participantCount = 0
    remoteParticipants = []
    removeOverlayView()
    removeLocalOverlayView()
    connectionState = .connecting
    emitSnapshotChanged()

    // Install all initial per-identity keys before any suspension point so
    // rotation commands are accepted for the entire connecting phase.
    if !keyMaterial.isEmpty {
      keyProvider = Self.makeKeyProvider(keyMaterial: keyMaterial)
      appliedKeyIndexes = Self.initialAppliedKeyIndexes(for: keyMaterial)
    }

    if args.microphoneEnabled {
      let granted = await Self.requestMicrophonePermission()
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      guard granted else {
        failConnect(invoke, error: BridgeError(.permissionDenied))
        return
      }
    }

    // Re-gate audio before connecting: the engine must stay suspended until
    // CallKit grants its audio window.
    try? AudioManager.shared.setEngineAvailability(.none)

    let newRoom: Room
    if let keyProvider {
      // Frame-only E2EE via the legacy options: the newer EncryptionOptions
      // also encrypts data channels, which the web peers do not support.
      let roomOptions = RoomOptions(adaptiveStream: true, dynacast: true,
                               e2eeOptions: E2EEOptions(keyProvider: keyProvider),
                               singlePeerConnection: true)
      newRoom = Room(delegate: self, roomOptions: roomOptions)
    } else {
      newRoom = Room(delegate: self)
    }
    room = newRoom

    let connectOptions = Self.buildConnectOptions(from: args)

    do {
      try await newRoom.connect(url: args.url, token: args.token,
                                connectOptions: connectOptions)
    } catch {
      // The thrown error is deliberately discarded: native errors may embed
      // the server URL, and only bounded codes may cross the bridge.
      // failConnect drops this attempt's key provider and index state.
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      await newRoom.disconnect()
      if room === newRoom { room = nil }
      failConnect(invoke, error: BridgeError(.connectFailed))
      return
    }
    guard attemptId == attempt else {
      await newRoom.disconnect()
      rejectCancelled(invoke)
      return
    }

    // The delegate hop for the connected transition may still be queued; sync
    // from the room so the resolved snapshot is exact (the hop deduplicates).
    applyConnectionState(.connected, from: newRoom)

    if args.microphoneEnabled {
      do {
        try await newRoom.localParticipant.setMicrophone(enabled: true)
      } catch {
        guard attemptId == attempt else {
          rejectCancelled(invoke)
          return
        }
        // Partial success: the room stays alive; resolve the connected
        // snapshot with the mic off and a bounded error instead of rejecting.
        lastError = BridgeError(.mediaFailed)
        emitSnapshotChanged()
        invoke.resolve(snapshot())
        return
      }
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      microphoneEnabled = true
      emitSnapshotChanged()
    }

    invoke.resolve(snapshot())
  }

  func disconnect(callId requestedCallId: String, invoke: Invoke) async {
    await teardownMatchingCall(callId: requestedCallId, invoke: invoke)
  }

  /// Rust-side timeout recovery: identical teardown semantics to
  /// `disconnect` for the matching (possibly in-flight) attempt.
  func cancelConnect(callId requestedCallId: String, invoke: Invoke) async {
    await teardownMatchingCall(callId: requestedCallId, invoke: invoke)
  }

  func setMicrophoneEnabled(
    callId requestedCallId: String, enabled: Bool, invoke: Invoke
  ) async {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }

    attempt &+= 1
    let attemptId = attempt

    if enabled {
      let granted = await Self.requestMicrophonePermission()
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      guard granted else {
        lastError = BridgeError(.permissionDenied)
        emitSnapshotChanged()
        reject(invoke, .permissionDenied)
        return
      }
    }

    do {
      try await room.localParticipant.setMicrophone(enabled: enabled)
    } catch {
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      lastError = BridgeError(.mediaFailed)
      emitSnapshotChanged()
      reject(invoke, .mediaFailed)
      return
    }
    guard attemptId == attempt else {
      rejectCancelled(invoke)
      return
    }

    microphoneEnabled = enabled
    // Push mute state back to CallKit so the system UI stays consistent.
    if let callId {
      callKitController?.setMuted(!enabled, for: callId)
    }
    emitSnapshotChanged()
    invoke.resolve(snapshot())
  }

  func setCameraEnabled(
    callId requestedCallId: String, enabled: Bool, invoke: Invoke
  ) async {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }

    attempt &+= 1
    let attemptId = attempt

    if enabled {
      let granted = await Self.requestCameraPermission()
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      guard granted else {
        lastError = BridgeError(.permissionDenied)
        emitSnapshotChanged()
        reject(invoke, .permissionDenied)
        return
      }
    }

    do {
      try await room.localParticipant.setCamera(enabled: enabled)
      if !enabled, let publication = Self.cameraPublication(in: room) {
        // Stopping capture alone can keep the hardware session alive;
        // unpublishing guarantees the camera is released.
        try await room.localParticipant.unpublish(publication: publication)
      }
    } catch {
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      lastError = BridgeError(.mediaFailed)
      emitSnapshotChanged()
      reject(invoke, .mediaFailed)
      return
    }
    guard attemptId == attempt else {
      rejectCancelled(invoke)
      return
    }

    cameraEnabled = enabled
    callKitController?.cameraActive = enabled

    if enabled, #available(iOS 16.0, *) {
      if AVCaptureSession().isMultitaskingCameraAccessSupported {
        AVCaptureSession().isMultitaskingCameraAccessEnabled = true
        logRoom("Multitasking camera access enabled (iOS 16+)")
      }
    }

    emitSnapshotChanged()
    invoke.resolve(snapshot())
  }

  func switchCamera(callId requestedCallId: String, invoke: Invoke) async {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }

    attempt &+= 1
    let attemptId = attempt

    guard
      let publication = Self.cameraPublication(in: room),
      let track = publication.track as? LocalVideoTrack,
      let capturer = track.capturer as? CameraCapturer
    else {
      // Nothing to toggle until the camera is publishing.
      reject(invoke, .invalidRequest)
      return
    }

    do {
      try await capturer.switchCameraPosition()
    } catch {
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      lastError = BridgeError(.mediaFailed)
      emitSnapshotChanged()
      reject(invoke, .mediaFailed)
      return
    }
    guard attemptId == attempt else {
      rejectCancelled(invoke)
      return
    }

    // The camera position is intentionally not part of the snapshot.
    invoke.resolve(snapshot())
  }

  func setScreenShareEnabled(
    callId requestedCallId: String, enabled: Bool, invoke: Invoke
  ) async {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }

    attempt &+= 1
    let attemptId = attempt

    do {
      try await room.localParticipant.setScreenShare(enabled: enabled)
    } catch {
      guard attemptId == attempt else {
        rejectCancelled(invoke)
        return
      }
      lastError = BridgeError(.mediaFailed)
      emitSnapshotChanged()
      reject(invoke, .mediaFailed)
      return
    }
    guard attemptId == attempt else {
      rejectCancelled(invoke)
      return
    }

    screenShareEnabled = enabled
    emitSnapshotChanged()
    invoke.resolve(snapshot())
  }

  // MARK: - E2EE key rotation

  /// Installs rotated key material for one participant identity. The input
  /// is validated first, matching the other lanes: invalid decoded input
  /// rejects `invalid_request` regardless of call state. A stale call id or
  /// a current call without an E2EE provider (unencrypted call, failed
  /// attempt) resolves the unchanged snapshot; the provider exists exactly
  /// while an attempt is connecting, connected, or reconnecting, so those
  /// all accept updates. Replayed or older key indexes are dropped so key
  /// material never moves backwards. Deliberately emits no snapshot event
  /// and bumps no revision: key state is not part of the bridge contract
  /// and must remain invisible.
  func setEncryptionKey(
    callId requestedCallId: String, identity: String, keyIndex: Int32,
    key: String, invoke: Invoke
  ) {
    guard let material = Self.decodeKey(
      identity: identity, keyIndex: keyIndex, key: key)
    else {
      reject(invoke, .invalidRequest)
      return
    }
    guard callId == requestedCallId, let keyProvider else {
      invoke.resolve(snapshot())
      return
    }
    guard Self.keyIndexAdvances(
      material.keyIndex, after: appliedKeyIndexes[material.identity])
    else {
      invoke.resolve(snapshot())
      return
    }
    keyProvider.setKey(
      keyData: material.keyData, participantId: material.identity,
      index: material.keyIndex)
    appliedKeyIndexes[material.identity] = material.keyIndex
    invoke.resolve(snapshot())
  }

  /// Decoded per-participant key material for one call attempt.
  struct EncryptionKeyMaterial {
    let identity: String
    let keyIndex: Int32
    let keyData: Data
  }

  /// Validates and decodes one wire entry, matching the Rust gate and the
  /// Android lane: blank (empty or whitespace-only) identities, negative
  /// indexes, undecodable base64, and empty decoded key bytes are all
  /// invalid. Key material is never logged.
  nonisolated static func decodeKey(
    identity: String, keyIndex: Int32, key: String
  ) -> EncryptionKeyMaterial? {
    guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      keyIndex >= 0,
      let keyData = Data(base64Encoded: key), !keyData.isEmpty
    else { return nil }
    return EncryptionKeyMaterial(
      identity: identity, keyIndex: keyIndex, keyData: keyData)
  }

  /// Decodes optional base64 key payloads. Returns nil when any entry is
  /// undecodable (the caller rejects via the bounded invalid-request path),
  /// an empty array when the payload is absent or empty (unencrypted call).
  nonisolated static func decodeKeyMaterial(
    from payloads: [EncryptionKeyPayload]?
  ) -> [EncryptionKeyMaterial]? {
    guard let payloads, !payloads.isEmpty else { return [] }
    var material: [EncryptionKeyMaterial] = []
    material.reserveCapacity(payloads.count)
    for payload in payloads {
      guard
        let entry = Self.decodeKey(
          identity: payload.identity, keyIndex: payload.keyIndex, key: payload.key)
      else { return nil }
      material.append(entry)
    }
    return material
  }

  /// Seeds the per-identity monotonic guard from the initial keys. Every
  /// supplied entry is installed on the provider's key ring; for duplicate
  /// identities the greatest index is tracked as the latest, so only the
  /// strictly-increasing guard applies to post-connect rotation.
  nonisolated static func initialAppliedKeyIndexes(
    for keyMaterial: [EncryptionKeyMaterial]
  ) -> [String: Int32] {
    var applied: [String: Int32] = [:]
    for key in keyMaterial {
      applied[key.identity] = max(applied[key.identity] ?? .min, key.keyIndex)
    }
    return applied
  }

  /// Builds the per-call key provider matching the web lanes: per-participant
  /// keys (no shared key), HKDF derivation, ratchet window 10, key ring 256;
  /// the ratchet salt and uncrypted magic bytes keep the LiveKit defaults.
  nonisolated static func makeKeyProvider(
    keyMaterial: [EncryptionKeyMaterial]
  ) -> BaseKeyProvider {
    let provider = BaseKeyProvider(
      options: KeyProviderOptions(
        sharedKey: false,
        ratchetWindowSize: 10,
        keyRingSize: 256,
        keyDerivationAlgorithm: .hkdf))
    for key in keyMaterial {
      provider.setKey(
        keyData: key.keyData, participantId: key.identity, index: key.keyIndex)
    }
    return provider
  }

  /// Monotonic rotation guard: only a strictly newer index may advance an
  /// identity's key material.
  nonisolated static func keyIndexAdvances(
    _ newIndex: Int32, after applied: Int32?
  ) -> Bool {
    guard let applied else { return true }
    return newIndex > applied
  }

  /// Builds ``ConnectOptions`` from optional connect-args fields. Returns nil
  /// when both `iceServers` and `reconnectAttempts` are absent: the
  /// default-initialised ``ConnectOptions`` is equivalent and avoids an
  /// allocation.
  nonisolated static func buildConnectOptions(
    from args: ConnectArgs
  ) -> ConnectOptions? {
    let ice = args.iceServers?.compactMap { s -> IceServer? in
      let urls = s.urls.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      guard !urls.isEmpty else { return nil }
      let username = s.username.flatMap { $0.isEmpty ? nil : $0 }
      let credential = s.credential.flatMap { $0.isEmpty ? nil : $0 }
      return IceServer(urls: urls, username: username, credential: credential)
    }
    let hasIce = ice.flatMap { !$0.isEmpty } ?? false
    let hasReconn = args.reconnectAttempts != nil
    guard hasIce || hasReconn else { return nil }

    if let attempts = args.reconnectAttempts {
      return ConnectOptions(
        reconnectAttempts: max(attempts, 0),
        iceServers: ice ?? [])
    }
    return ConnectOptions(iceServers: ice ?? [])
  }

  // MARK: - Remote video overlay

  /// Attaches the single non-interactive `VideoView` to the resolved remote
  /// camera track and positions it over the matching DOM rect. `frame` is the
  /// viewport-relative CSS rect: CSS pixels map 1:1 to iOS logical points, so
  /// it is converted into the webview's superview coordinate space via
  /// `UIView.convert` and clipped to the webview's bounds. `devicePixelRatio`
  /// is validated but intentionally never applied on iOS.
  ///
  /// A call for the same track with a new rect only repositions the view. A
  /// missing or replaced track (unpublished/unsubscribed between the snapshot
  /// the caller acted on and this command) clears the attachment safely and
  /// still resolves the current snapshot; the selection is kept so a later
  /// track event can rebind it.
  func setRemoteVideoOverlay(
    callId requestedCallId: String,
    participantIdentity: String,
    trackSid: String,
    frame: CGRect,
    devicePixelRatio: Double,
    invoke: Invoke
  ) {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }
    // The shared lane already bounds the geometry; mirror the bound here so
    // the native side is safe on its own. Partially off-screen tiles are
    // legal, so x/y only need to be finite; size and pixel ratio must be
    // positive.
    guard Self.overlayGeometryIsValid(frame, devicePixelRatio: devicePixelRatio)
    else {
      reject(invoke, .invalidRequest)
      return
    }
    guard let webView = hostWebView, let container = webView.superview else {
      reject(invoke, .unavailable)
      return
    }
    guard let clipped = Self.overlayFrame(
      viewportRect: frame, in: webView, container: container)
    else {
      // The tile is entirely outside the visible webview area.
      reject(invoke, .invalidRequest)
      return
    }

    let view = ensureOverlayView(in: container)
    overlaySelection = OverlaySelection(
      participantIdentity: participantIdentity, trackSid: trackSid)

    guard
      let track = Self.remoteVideoTrack(
        participantIdentity: participantIdentity, trackSid: trackSid, in: room)
    else {
      // Clears safely: detach without failing the command.
      detachOverlay(from: view)
      invoke.resolve(snapshot())
      return
    }

    if view.track !== track {
      view.track = track
    }
    view.frame = clipped
    view.isHidden = false
    invoke.resolve(snapshot())
  }

  /// Removes the overlay view. A stale call id is a no-op resolve, matching
  /// the other call-scoped commands.
  func clearRemoteVideoOverlay(callId requestedCallId: String, invoke: Invoke) {
    guard callId == requestedCallId else {
      invoke.resolve(snapshot())
      return
    }
    removeOverlayView()
    invoke.resolve(snapshot())
  }

  /// Returns the single overlay view, creating it as a non-interactive
  /// sibling of the host webview on first use.
  private func ensureOverlayView(in container: UIView) -> VideoView {
    if let overlayView {
      if overlayView.superview !== container {
        overlayView.removeFromSuperview()
        container.addSubview(overlayView)
      }
      return overlayView
    }
    let view = VideoView()
    // The web content keeps all interaction; the overlay must not intercept
    // touches meant for the WebView's controls.
    view.isUserInteractionEnabled = false
    view.isHidden = true
    container.addSubview(view)
    overlayView = view
    return view
  }

  /// Detaches the renderer but keeps the (hidden) view for the next bind.
  private func detachOverlay(from view: VideoView) {
    view.track = nil
    view.isHidden = true
  }

  /// Fully releases the overlay (clear, disconnect, teardown, attempt
  /// replacement): detach the track first so `VideoView` drops its renderer
  /// subscriptions, then hide, remove from the hierarchy, drop the reference
  /// and forget the selection. A later set recreates the view cleanly.
  private func removeOverlayView() {
    guard let view = overlayView else {
      overlaySelection = nil
      return
    }
    view.track = nil
    view.isHidden = true
    view.removeFromSuperview()
    overlayView = nil
    overlaySelection = nil
  }

  /// Re-resolves the selected overlay track after participant/track
  /// lifecycle events: rebinds to the (possibly replaced) live track, or
  /// clears the attachment when the track is gone (unpublish, unsubscribe, or
  /// the participant left). Never recreates a removed view.
  private func reconcileOverlay(in room: Room) {
    guard let selection = overlaySelection, let view = overlayView else { return }
    guard
      let track = Self.remoteVideoTrack(
        participantIdentity: selection.participantIdentity,
        trackSid: selection.trackSid, in: room)
    else {
      detachOverlay(from: view)
      return
    }
    if view.track !== track {
      view.track = track
    }
    view.isHidden = false
    refreshPiPContentSourceIfNeeded()
  }

  /// Bounds for the overlay rect and pixel ratio. Tiles may be partially
  /// off-screen, so the origin only needs to be finite; the size and the
  /// pixel ratio must be finite and positive. The raw `size` is inspected:
  /// `CGRect.width`/`height` normalize away negative sizes.
  nonisolated static func overlayGeometryIsValid(
    _ rect: CGRect, devicePixelRatio: Double
  ) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
      && rect.size.width > 0 && rect.size.height > 0
      && devicePixelRatio.isFinite && devicePixelRatio > 0
  }

  /// Maps the viewport-relative CSS rect into the webview's superview
  /// coordinate space (via the view hierarchy, so transforms are honored) and
  /// clips it to the webview's own bounds. Nil when the intersection is
  /// empty; the device's pixel ratio is intentionally not applied because
  /// CSS pixels already map 1:1 to logical points. MainActor-isolated with
  /// the rest of the controller: UIView geometry is main-thread state.
  static func overlayFrame(
    viewportRect: CGRect, in webView: UIView, container: UIView
  ) -> CGRect? {
    let converted = webView.convert(viewportRect, to: container)
    let hostBounds = webView.convert(webView.bounds, to: container)
    let clipped = converted.intersection(hostBounds)
    // `isEmpty` covers null/infinite rects and non-positive dimensions.
    guard !clipped.isNull, !clipped.isEmpty else { return nil }
    return clipped
  }

  /// Resolves one remote participant's video track by identity plus track
  /// SID; nil when the participant or the publication is gone, when the
  /// publication is unsubscribed (so an unsubscribe detaches the overlay
  /// immediately), or when it carries no video track.
  nonisolated static func remoteVideoTrack(
    participantIdentity: String, trackSid: String, in room: Room
  ) -> VideoTrack? {
    guard
      let participant = room.remoteParticipants.first(where: {
        $0.key.stringValue == participantIdentity
      })?.value,
      let publication = participant.trackPublications.values
        .first(where: { $0.sid.stringValue == trackSid }),
      publication.isSubscribed,
      let track = publication.track as? VideoTrack
    else { return nil }
    return track
  }

  // MARK: - Local camera preview overlay

  /// Attaches a second, independent `VideoView` to the local camera track
  /// and positions it over the matching DOM rect. The local camera track is
  /// resolved internally (there is at most one camera track per room). The
  /// view is mirrored (selfie preview). Same geometry validation and clipping
  /// as the remote overlay.
  func setLocalVideoOverlay(
    callId requestedCallId: String,
    frame: CGRect,
    devicePixelRatio: Double,
    invoke: Invoke
  ) {
    guard callId == requestedCallId, let room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }
    guard Self.overlayGeometryIsValid(frame, devicePixelRatio: devicePixelRatio) else {
      reject(invoke, .invalidRequest)
      return
    }
    guard let webView = hostWebView, let container = webView.superview else {
      reject(invoke, .unavailable)
      return
    }
    guard let clipped = Self.overlayFrame(
      viewportRect: frame, in: webView, container: container)
    else {
      reject(invoke, .invalidRequest)
      return
    }

    let view = ensureLocalOverlayView(in: container)

    guard
      let publication = Self.cameraPublication(in: room),
      let track = publication.track as? VideoTrack
    else {
      detachLocalOverlay(from: view)
      invoke.resolve(snapshot())
      return
    }

    if view.track !== track {
      view.track = track
    }
    view.frame = clipped
    view.isHidden = false
    invoke.resolve(snapshot())
  }

  /// Removes the local overlay view. A stale call id is a no-op resolve.
  func clearLocalVideoOverlay(callId requestedCallId: String, invoke: Invoke) {
    guard callId == requestedCallId else {
      invoke.resolve(snapshot())
      return
    }
    removeLocalOverlayView()
    invoke.resolve(snapshot())
  }

  /// Returns the single local overlay view, creating it as a non-interactive,
  /// mirrored sibling of the host webview on first use.
  private func ensureLocalOverlayView(in container: UIView) -> VideoView {
    if let localOverlayView {
      if localOverlayView.superview !== container {
        localOverlayView.removeFromSuperview()
        container.addSubview(localOverlayView)
      }
      return localOverlayView
    }
    let view = VideoView()
    view.isUserInteractionEnabled = false
    view.isHidden = true
    view.mirrorMode = .mirror
    container.addSubview(view)
    localOverlayView = view
    return view
  }

  /// Detaches the local renderer but keeps the (hidden) view.
  private func detachLocalOverlay(from view: VideoView) {
    view.track = nil
    view.isHidden = true
  }

  /// Fully releases the local overlay: detach, hide, remove from hierarchy,
  /// drop the reference.
  private func removeLocalOverlayView() {
    guard let view = localOverlayView else { return }
    view.track = nil
    view.isHidden = true
    view.removeFromSuperview()
    localOverlayView = nil
  }

  /// Re-resolves the local camera track after track lifecycle events:
  /// rebinds to the (possibly replaced) live track, or clears the attachment
  /// when the track is gone. Never recreates a removed view.
  private func reconcileLocalOverlay(in room: Room) {
    guard let view = localOverlayView else { return }
    guard
      let publication = Self.cameraPublication(in: room),
      let track = publication.track as? VideoTrack
    else {
      detachLocalOverlay(from: view)
      return
    }
    if view.track !== track {
      view.track = track
    }
    view.isHidden = false
  }

  /// Silent teardown for plugin deinit; bumps the attempt identity so
  /// in-flight work settles with `cancelled`.
  func tearDown() async {
    attempt &+= 1
    reconnectDeadline?.cancel()
    reconnectDeadline = nil
    pipEnabled = false
    let roomToClose = room
    room = nil
    channel = nil
    if let callId { callKitController?.endCall(callId: callId, remoteEnded: true) }
    callId = nil
    connectionState = .idle
    microphoneEnabled = false
    cameraEnabled = false
    screenShareEnabled = false
    callKitController?.cameraActive = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = nil
    localConnectionQuality = nil
    removeOverlayView()
    removeLocalOverlayView()
    if #available(iOS 15.0, *) { stopPiP() }
    if let roomToClose {
      await roomToClose.disconnect()
    }
  }

  // MARK: - Native Picture-in-Picture (iOS 15+)

  /// Enables or disables native PiP for the current call. When enabled, the
  /// overlay renderer is switched to sample-buffer mode so that
  /// `AVSampleBufferDisplayLayer` is accessible as the PiP content source.
  /// The controller's `canStartPictureInPictureAutomaticallyFromInline` flag
  /// lets the system auto-start PiP when the app backgrounds.
  func setNativeCallPiPEnabled(callId requestedCallId: String, enabled: Bool, invoke: Invoke) {
    guard callId == requestedCallId, let _ = room else {
      invoke.resolve(snapshot())
      return
    }
    guard connectionState == .connected else {
      reject(invoke, .invalidRequest)
      return
    }

    pipEnabled = enabled

    if enabled {
      // Switch overlay to sample-buffer mode so the display layer is available.
      if let view = overlayView {
        view.renderMode = .sampleBuffer
        if let track = view.track {
          view.track = nil
          view.track = track
        }
      }
      setupPiPControllerIfPossible()
      // If already in background, start PiP explicitly.
      if UIApplication.shared.applicationState == .background,
         let ctrl = pipController as? AVPictureInPictureController,
         ctrl.isPictureInPicturePossible {
        ctrl.startPictureInPicture()
      }
    } else {
      if #available(iOS 15.0, *) { stopPiP() }
      fallbackOverlayToMetal()
    }

    invoke.resolve(snapshot())
  }

  // MARK: PiP controller lifecycle (private)

  /// Creates the `AVPictureInPictureController` with the overlay view as
  /// source and the `AVPictureInPictureVideoCallViewController` hosting the
  /// sample buffer display layer. Only called when PiP is enabled and a track
  /// is bound to the overlay.
  private func setupPiPControllerIfPossible() {
    guard #available(iOS 15.0, *), pipEnabled, pipController == nil else { return }
    guard let view = overlayView, view.track != nil,
          hostWebView?.window ?? view.window != nil else { return }
    guard let displayLayer = pipDisplayLayer() else { return }

    let vc = AVPictureInPictureVideoCallViewController()
    vc.preferredContentSize = displayLayer.bounds.size.width > 0
      ? displayLayer.bounds.size
      : CGSize(width: 180, height: 320)
    displayLayer.removeFromSuperlayer()
    displayLayer.frame = vc.view.bounds
    vc.view.layer.addSublayer(displayLayer)

    let source = AVPictureInPictureController.ContentSource(
      activeVideoCallSourceView: view, contentViewController: vc)
    let controller = AVPictureInPictureController(contentSource: source)
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.delegate = self
    pipController = controller
    pipViewController = vc
    logRoom("PiP controller configured (auto-start on background)")
  }

  /// Refreshes PiP availability as the overlay track binds or unbinds.
  /// Called from `reconcileOverlay(in:)` after a remote camera publication
  /// arrives or departs.
  private func refreshPiPContentSourceIfNeeded() {
    guard pipEnabled else { return }
    if overlayView?.track != nil {
      // Track is available: create the controller if it doesn't exist yet.
      if pipController == nil {
        setupPiPControllerIfPossible()
      }
    } else {
      // Track was removed: tear down so PiP isn't stale.
      if #available(iOS 15.0, *) { stopPiP() }
    }
  }

  /// Returns the sample buffer display layer from the overlay, forcing
  /// sample-buffer mode if needed. Nil when there is no overlay or no track.
  private func pipDisplayLayer() -> AVSampleBufferDisplayLayer? {
    guard let view = overlayView, view.track != nil else { return nil }
    if view.renderMode != .sampleBuffer {
      view.renderMode = .sampleBuffer
      if let t = view.track {
        view.track = nil
        view.track = t
      }
    }
    return view.avSampleBufferDisplayLayer
  }

  /// Stops active PiP, returns the display layer to the overlay, and
  /// releases both the video-call VC and the controller.
  @available(iOS 15.0, *)
  private func stopPiP() {
    guard let ctrl = pipController as? AVPictureInPictureController else { return }

    // Stop any in-progress PiP session.
    if ctrl.isPictureInPictureActive {
      ctrl.stopPictureInPicture()
    }

    // Return the display layer back to the overlay.
    if let vc = pipViewController as? AVPictureInPictureVideoCallViewController,
       let layer = vc.view.layer.sublayers?.first {
      layer.removeFromSuperlayer()
      returnDisplayLayerToOverlay(layer)
      vc.willMove(toParent: nil)
      vc.removeFromParent()
    }

    pipController = nil
    pipViewController = nil
    fallbackOverlayToMetal()
    logRoom("PiP stopped")
  }

  /// Places a display layer back into the overlay VideoView's renderer
  /// subview (the SampleBufferVideoRenderer).
  private func returnDisplayLayerToOverlay(_ layer: CALayer) {
    guard let view = overlayView else { return }
    for subview in view.subviews {
      if subview.layer.sublayers?.isEmpty == true || subview.layer.sublayers == nil {
        subview.layer.insertSublayer(layer, at: 0)
        layer.frame = subview.bounds
        return
      }
    }
    view.layer.insertSublayer(layer, at: 0)
    layer.frame = view.bounds
  }

  /// Reverts the overlay renderer to Metal mode (default) when PiP is
  /// disabled, so rendering uses the GPU path for best performance.
  private func fallbackOverlayToMetal() {
    guard let view = overlayView, view.renderMode != .auto else { return }
    view.renderMode = .auto
    if let t = view.track {
      view.track = nil
      view.track = t
    }
  }  // MARK: - Shared helpers (main actor)

  /// Tears down the matching attempt, emits the final idle snapshot on its
  /// outgoing channel, and resolves. A stale call id is a no-op resolve: it
  /// must never tear down a newer call that reused this controller.
  private func teardownMatchingCall(
    callId requestedCallId: String, invoke: Invoke
  ) async {
    guard callId == requestedCallId else {
      invoke.resolve(snapshot())
      return
    }

    attempt &+= 1
    reconnectDeadline?.cancel()
    reconnectDeadline = nil
    pipEnabled = false

    let roomToClose = room
    room = nil
    connectionState = .idle
    microphoneEnabled = false
    cameraEnabled = false
    screenShareEnabled = false
    callKitController?.cameraActive = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = nil
    localConnectionQuality = nil
    if let callId { callKitController?.endCall(callId: callId, remoteEnded: false) }
    callId = nil
    removeOverlayView()
    removeLocalOverlayView()
    if #available(iOS 15.0, *) { stopPiP() }
    emitSnapshotChanged()
    channel = nil

    if let roomToClose {
      await roomToClose.disconnect()
    }
    invoke.resolve(snapshot())
  }

  private func applyConnectionState(
    _ newState: BridgeConnectionState, from room: Room? = nil
  ) {
    guard connectionState != newState else { return }
    connectionState = newState
    if newState == .connected, let room {
      microphoneEnabled = room.localParticipant.isMicrophoneEnabled()
      cameraEnabled = room.localParticipant.isCameraEnabled()
      screenShareEnabled = room.localParticipant.isScreenShareEnabled()
      remoteParticipants = Self.projectRemoteParticipants(in: room)
      participantCount = remoteParticipants.count
    }
    emitSnapshotChanged()
  }

  private func failConnect(_ invoke: Invoke, error: BridgeError) {
    connectionState = .failed
    microphoneEnabled = false
    cameraEnabled = false
    screenShareEnabled = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = error
    localConnectionQuality = nil
    emitSnapshotChanged()
    invoke.reject(error.message, code: error.code.rawValue)
  }

  private func reject(_ invoke: Invoke, _ code: BridgeFailureCode) {
    invoke.reject(code.message, code: code.rawValue)
  }

  private func rejectCancelled(_ invoke: Invoke) {
    reject(invoke, .cancelled)
  }

  // MARK: - Remote participant projection

  /// Minimal remote-only projection: identity (from the room's participant
  /// key) plus the camera and screen-share publications with remote-aware
  /// mute/subscription state. Sorted by identity so the snapshot is stable.
  nonisolated static func projectRemoteParticipants(
    in room: Room
  ) -> [BridgeRemoteParticipant] {
    room.remoteParticipants
      .map { identity, participant in
        let camera =
          participant.trackPublications.values
          .filter { $0.source == .camera }
          .sorted { $0.sid.stringValue < $1.sid.stringValue }
          .first
          .map {
            BridgeRemoteCamera(
              sid: $0.sid.stringValue, muted: $0.isMuted,
              subscribed: $0.isSubscribed)
          }
        let screenShare =
          participant.trackPublications.values
          .filter { $0.source == .screenShareVideo }
          .sorted { $0.sid.stringValue < $1.sid.stringValue }
          .first
          .map {
            BridgeRemoteScreenShare(
              sid: $0.sid.stringValue, muted: $0.isMuted,
              subscribed: $0.isSubscribed)
          }
        return BridgeRemoteParticipant(
          identity: identity.stringValue, camera: camera,
          screenShare: screenShare,
          connectionQuality: Self.connectionQualityWire(participant.connectionQuality))
      }
      .sorted { $0.identity < $1.identity }
  }

  /// Extracts a human-readable room name from a LiveKit URL for CallKit
  /// caller-id display. Takes the last path component (after the final `/`).
  nonisolated static func roomName(from url: String) -> String {
    guard let parsed = URL(string: url) else { return "Call" }
    let name = parsed.lastPathComponent
    return name.isEmpty ? "Call" : name
  }

  // MARK: - Camera helpers

  /// The published camera publication if any; identified by track source via
  /// the public local video list.
  nonisolated static func cameraPublication(in room: Room) -> LocalTrackPublication? {
    room.localParticipant.localVideoTracks.first(where: { $0.source == .camera })
  }

  // MARK: - Media permissions

  /// Requests microphone access only; LiveKit owns the audio session.
  nonisolated static func requestMicrophonePermission() async -> Bool {
    if #available(iOS 17.0, macOS 14.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted:
        return true
      case .denied:
        return false
      case .undetermined:
        return await withCheckedContinuation { continuation in
          AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
          }
        }
      @unknown default:
        return false
      }
    }
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      return true
    case .denied:
      return false
    case .undetermined:
      return await withCheckedContinuation { continuation in
        session.requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }

  /// Requests camera access only; LiveKit owns device selection and capture.
  nonisolated static func requestCameraPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .denied, .restricted:
      return false
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }
}

// MARK: - RoomDelegate
//
// Called on LiveKit's multicast queue via weak references; every method hops
// onto the main actor and re-verifies room identity before touching state.

extension RoomController: RoomDelegate {
  @objc nonisolated func room(
    _ room: Room, didUpdateConnectionState connectionState: ConnectionState,
    from oldConnectionState: ConnectionState
  ) {
    Task { @MainActor [weak self] in
      self?.handleConnectionState(connectionState, from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, didDisconnectWithError error: LiveKitError?
  ) {
    Task { @MainActor [weak self] in
      self?.handleDisconnect(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode
  ) {
    Task { @MainActor [weak self] in
      self?.handleReconnecting(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode
  ) {
    Task { @MainActor [weak self] in
      self?.handleReconnected(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, participantDidConnect participant: RemoteParticipant
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, participantDidDisconnect participant: RemoteParticipant
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  // The explicit selectors below are required by the SDK: they disambiguate
  // the remote-participant variants from the local ones.

  @objc(room:remoteParticipant:didPublishTrack:) nonisolated func room(
    _ room: Room, participant: RemoteParticipant,
    didPublishTrack publication: RemoteTrackPublication
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  @objc(room:remoteParticipant:didUnpublishTrack:) nonisolated func room(
    _ room: Room, participant: RemoteParticipant,
    didUnpublishTrack publication: RemoteTrackPublication
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, participant: RemoteParticipant,
    didSubscribeTrack publication: RemoteTrackPublication
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, participant: RemoteParticipant,
    didUnsubscribeTrack publication: RemoteTrackPublication
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  @objc nonisolated func room(
    _ room: Room, participant: Participant,
    trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool
  ) {
    Task { @MainActor [weak self] in
      self?.updateRemoteParticipants(from: room)
    }
  }

  // MARK: Delegate handlers (main actor)

  private func handleConnectionState(_ state: ConnectionState, from room: Room) {
    guard room === self.room else { return }
    switch state {
    case .connecting:
      applyConnectionState(.connecting, from: room)
    case .connected:
      applyConnectionState(.connected, from: room)
    case .reconnecting:
      applyConnectionState(.reconnecting, from: room)
    case .disconnected, .disconnecting:
      // Terminal disconnects surface through didDisconnectWithError; the
      // disconnect path clears state synchronously.
      break
    }
  }

  private func handleDisconnect(from room: Room) {
    guard room === self.room else { return }
    guard connectionState != .idle, connectionState != .failed else { return }

    // If the LiveKit engine is already trying to reconnect
    // (didStartReconnectWithMode fired), this is not terminal; let the
    // reconnect cycle continue.
    if connectionState == .reconnecting {
      logRoom("Disconnect during active reconnection: letting reconnect continue")
      return
    }

    // The WebSocket dropped but LiveKit hasn't started reconnecting yet.
    // Treat as reconnecting (the phone may have locked and the socket will
    // come back once the network does), but arm a deadline so a reconnect that
    // never completes is eventually reported as failed instead of leaving the
    // snapshot pinned at `reconnecting` forever.
    logRoom("WebSocket dropped: treating as reconnecting, not failed")
    applyConnectionState(.reconnecting, from: room)
    armReconnectDeadline(for: room)
  }

  private func armReconnectDeadline(for room: Room) {
    reconnectDeadline?.cancel()
    reconnectDeadline = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.reconnectGraceSeconds * 1_000_000_000)
      guard !Task.isCancelled else { return }
      self?.failStalledReconnect(from: room)
    }
  }

  private func failStalledReconnect(from room: Room) {
    guard room === self.room, connectionState == .reconnecting else { return }
    logRoom("Reconnect did not complete within the grace period: failing the call")
    self.room = nil
    keyProvider = nil
    appliedKeyIndexes = [:]
    microphoneEnabled = false
    cameraEnabled = false
    screenShareEnabled = false
    callKitController?.cameraActive = false
    participantCount = 0
    remoteParticipants = []
    lastError = BridgeError(.disconnected)
    localConnectionQuality = nil
    connectionState = .failed
    removeOverlayView()
    removeLocalOverlayView()
    if #available(iOS 15.0, *) { stopPiP() }
    emitSnapshotChanged()
  }

  private func handleReconnecting(from room: Room) {
    guard room === self.room else { return }
    guard connectionState == .connected else { return }
    applyConnectionState(.reconnecting, from: room)
  }

  private func handleReconnected(from room: Room) {
    guard room === self.room else { return }
    guard connectionState == .reconnecting else { return }
    reconnectDeadline?.cancel()
    reconnectDeadline = nil
    applyConnectionState(.connected, from: room)
  }

  // MARK: - Connection-quality delegate & helpers

  @objc(room:participant:didUpdateConnectionQuality:) nonisolated func room(
    _ room: Room, participant: Participant,
    didUpdateConnectionQuality quality: ConnectionQuality
  ) {
    Task { @MainActor [weak self] in
      self?.handleConnectionQuality(quality, participant: participant, from: room)
    }
  }

  /// Maps the LiveKit ``ConnectionQuality`` enum to the bound wire string
  /// vocabulary ("lost" / "poor" / "good" / "excellent" / "unknown").
  nonisolated static func connectionQualityWire(
    _ q: ConnectionQuality
  ) -> BridgeConnectionQuality? {
    switch q {
    case .lost: return .lost
    case .poor: return .poor
    case .good: return .good
    case .excellent: return .excellent
    case .unknown: return nil
    }
  }

  private func handleConnectionQuality(
    _ quality: ConnectionQuality, participant: Participant, from room: Room
  ) {
    guard room === self.room else { return }
    guard connectionState == .connected || connectionState == .reconnecting
    else { return }

    if participant is LocalParticipant {
      let wire = Self.connectionQualityWire(quality)
      guard localConnectionQuality != wire else { return }
      localConnectionQuality = wire
      emitSnapshotChanged()
    } else {
      // This event always changes the remote projection (at minimum the
      // quality field), so recompute and emit unconditionally.
      updateRemoteParticipants(from: room)
    }
  }

  /// Recomputes the remote-only projection from a room event and emits one
  /// snapshot_changed when it (and with it the count) actually changed. Any
  /// participant/publication/subscription event also reconciles the video
  /// overlay against the room's current truth, even when the snapshot
  /// projection itself is unchanged.
  private func updateRemoteParticipants(from room: Room) {
    guard room === self.room else { return }
    guard connectionState == .connected || connectionState == .reconnecting
    else { return }
    reconcileOverlay(in: room)
    reconcileLocalOverlay(in: room)
    let projection = Self.projectRemoteParticipants(in: room)
    guard projection != remoteParticipants else { return }
    remoteParticipants = projection
    participantCount = projection.count
    emitSnapshotChanged()
  }
}

// MARK: - AVPictureInPictureControllerDelegate (RoomController)

@available(iOS 15.0, *)
extension RoomController: AVPictureInPictureControllerDelegate {
  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
    completionHandler: @escaping (Bool) -> Void
  ) {
    Task { @MainActor [weak self] in
      guard let self else {
        completionHandler(true)
        return
      }
      if let vc = self.pipViewController as? AVPictureInPictureVideoCallViewController,
         let layer = vc.view.layer.sublayers?.first {
        layer.removeFromSuperlayer()
        self.returnDisplayLayerToOverlay(layer)
        vc.willMove(toParent: nil)
        vc.removeFromParent()
      }
      completionHandler(true)
    }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _ controller: AVPictureInPictureController
  ) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let vc = self.pipViewController as? AVPictureInPictureVideoCallViewController,
         let layer = vc.view.layer.sublayers?.first,
         layer.superlayer == nil {
        self.returnDisplayLayerToOverlay(layer)
      }
    }
  }
}

// MARK: - Logging helper (RoomController)

private func logRoom(_ message: String) {
  #if DEBUG
  NSLog("[RoomController] \(message)")
  #endif
}
