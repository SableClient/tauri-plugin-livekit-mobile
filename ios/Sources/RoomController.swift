import AVFoundation
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
  private var participantCount = 0
  private var remoteParticipants: [BridgeRemoteParticipant] = []
  private var lastError: BridgeError?
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

  private struct OverlaySelection {
    let participantIdentity: String
    let trackSid: String
  }

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
      participantCount: participantCount,
      remoteParticipants: remoteParticipants,
      lastError: lastError)
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
    participantCount = 0
    remoteParticipants = []
    removeOverlayView()
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

    let newRoom: Room
    if let keyProvider {
      // Frame-only E2EE via the legacy options: the newer EncryptionOptions
      // also encrypts data channels, which the web peers do not support.
      let roomOptions = RoomOptions(e2eeOptions: E2EEOptions(keyProvider: keyProvider))
      newRoom = Room(delegate: self, roomOptions: roomOptions)
    } else {
      newRoom = Room(delegate: self)
    }
    room = newRoom

    do {
      try await newRoom.connect(url: args.url, token: args.token)
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

  /// Silent teardown for plugin deinit; bumps the attempt identity so
  /// in-flight work settles with `cancelled`.
  func tearDown() async {
    attempt &+= 1
    let roomToClose = room
    room = nil
    channel = nil
    callId = nil
    connectionState = .idle
    microphoneEnabled = false
    cameraEnabled = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = nil
    removeOverlayView()
    if let roomToClose {
      await roomToClose.disconnect()
    }
  }

  // MARK: - Shared helpers (main actor)

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

    let roomToClose = room
    room = nil
    connectionState = .idle
    microphoneEnabled = false
    cameraEnabled = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = nil
    callId = nil
    removeOverlayView()
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
      remoteParticipants = Self.projectRemoteParticipants(in: room)
      participantCount = remoteParticipants.count
    }
    emitSnapshotChanged()
  }

  private func failConnect(_ invoke: Invoke, error: BridgeError) {
    connectionState = .failed
    microphoneEnabled = false
    cameraEnabled = false
    participantCount = 0
    remoteParticipants = []
    keyProvider = nil
    appliedKeyIndexes = [:]
    lastError = error
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
  /// key) plus the camera publication with remote-aware mute/subscription
  /// state. Sorted by identity so the snapshot is stable.
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
        return BridgeRemoteParticipant(identity: identity.stringValue, camera: camera)
      }
      .sorted { $0.identity < $1.identity }
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
    // Terminal, unexpected disconnect. The LiveKitError is deliberately not
    // forwarded (bounded codes only). Keep `callId`/channel so Rust sees the
    // failed snapshot; drop the dead room and its key state.
    self.room = nil
    keyProvider = nil
    appliedKeyIndexes = [:]
    microphoneEnabled = false
    cameraEnabled = false
    participantCount = 0
    remoteParticipants = []
    lastError = BridgeError(.disconnected)
    connectionState = .failed
    removeOverlayView()
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
    applyConnectionState(.connected, from: room)
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
    let projection = Self.projectRemoteParticipants(in: room)
    guard projection != remoteParticipants else { return }
    remoteParticipants = projection
    participantCount = projection.count
    emitSnapshotChanged()
  }
}
