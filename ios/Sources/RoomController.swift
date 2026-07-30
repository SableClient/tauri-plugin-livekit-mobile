import AVFoundation
import LiveKit
import Tauri

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
  private var revision: UInt64 = 0
  private var connectionState: BridgeConnectionState = .idle
  private var microphoneEnabled = false
  private var cameraEnabled = false
  private var participantCount = 0
  private var remoteParticipants: [BridgeRemoteParticipant] = []
  private var lastError: BridgeError?
  private var attempt: UInt64 = 0

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

    attempt &+= 1
    let attemptId = attempt

    // Clear a leftover room from a failed attempt, if any.
    if let staleRoom = room {
      room = nil
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
    connectionState = .connecting
    emitSnapshotChanged()

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

    let newRoom = Room(delegate: self)
    room = newRoom

    do {
      try await newRoom.connect(url: args.url, token: args.token)
    } catch {
      // The thrown error is deliberately discarded: native errors may embed
      // the server URL, and only bounded codes may cross the bridge.
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
    lastError = nil
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
    lastError = nil
    callId = nil
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
    // failed snapshot; drop the dead room.
    self.room = nil
    microphoneEnabled = false
    cameraEnabled = false
    participantCount = 0
    remoteParticipants = []
    lastError = BridgeError(.disconnected)
    connectionState = .failed
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
  /// snapshot_changed when it (and with it the count) actually changed.
  private func updateRemoteParticipants(from room: Room) {
    guard room === self.room else { return }
    guard connectionState == .connected || connectionState == .reconnecting
    else { return }
    let projection = Self.projectRemoteParticipants(in: room)
    guard projection != remoteParticipants else { return }
    remoteParticipants = projection
    participantCount = projection.count
    emitSnapshotChanged()
  }
}
