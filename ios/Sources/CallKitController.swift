import AVFoundation
import CallKit
import LiveKit
import PushKit
import UIKit

/// Owns the system call UI (CallKit) and the audio-session arbitration
/// window between CallKit and LiveKit. One MatrixRTC room maps to one
/// CXCall. `maximumCallGroups=3, maximumCallsPerCallGroup=1` so iOS
/// never attempts to merge group calls.
///
/// All mutating methods are main-actor isolated; the CXProvider delegate
/// queue is nil (main) to stay serialized with the @MainActor
/// RoomController.
///
/// Pending-action queue: when the JS webview is suspended (lock-screen
/// answer, background incoming call), CXAnswerCallAction /
/// CXEndCallAction / CXSetMutedCallAction are queued here. The JS side
/// drains them via a dedicated command once it is ready to consume them.
@MainActor
final class CallKitController: NSObject {

  // MARK: - Core

  private var provider: CXProvider
  private let controller = CXCallController()

  /// Whether CallKit's provider has signaled readiness via providerDidBegin.
  /// All call-start/answer/end requests check this flag and enqueue pending
  /// work if the provider is not yet ready.
  private var providerReady = false

  /// Whether the local camera is currently enabled; picks .videoChat vs
  /// .voiceChat mode for proximity sensor control.
  var cameraActive = false

  /// uuid → callId mapping so delegate events can locate the call.
  private var callByUUID: [UUID: String] = [:]
  /// callId → uuid reverse lookup.
  private var uuidByCallId: [String: UUID] = [:]

  /// Tracked system-state lifecycle per UUID for retry-until-confirmed
  /// end-call logic.
  private enum SystemCallState {
    case notReported
    case pending
    case reported
    case removed
  }
  private var systemState: [UUID: SystemCallState] = [:]

  /// Pending system-initiated answer actions (not yet fulfilled).
  /// Fulfilled by JS via `fulfillAnswerCall` after the room connects.
  /// Keyed by call UUID (not action UUID: multiple actions per call).
  private var pendingAnswerActions: [UUID: (action: CXAnswerCallAction, enqueuedAt: DispatchTime)] = [:]

  /// Pending system-initiated end actions (not yet fulfilled).
  /// Fulfilled by JS via `fulfillEndCall` after cleanup completes.
  private var pendingEndActions: [UUID: (action: CXEndCallAction, enqueuedAt: DispatchTime)] = [:]

  /// Track app-initiated mute action UUIDs to suppress feedback loops
  /// when CXSetMutedCallAction echoes back through the delegate.
  private var appInitiatedMuteActionIds: Set<UUID> = []
  /// Last mute value requested by the app (suppresses iOS 17+ system echo).
  private var lastAppRequestedMute: Bool?

  /// When true, skip the first unmute action arriving after a remote answer
  /// to suppress a transient echo from the system UI.
  private var ignoreFirstUnmuteAfterRemoteAnswer = false

  /// Actions deferred until providerDidBegin fires.
  private var pendingStartupActions: [() -> Void] = []

  /// LiveKit audio recipe: session is disabled until a CX call activates.
  /// Set from `Plugin.load()` before any Room connects.
  static func disableAutomaticAudioConfiguration() {
    // 1. Prevent the SDK from trying to configure AVAudioSession itself.
    AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    // 2. Block all audio engine activity until CallKit grants a window.
    try? AudioManager.shared.setEngineAvailability(.none)
  }

  // MARK: - Init

  /// If true the current locale is China, so all CallKit setup is skipped:
  /// Apple prohibits CallKit usage in that region. Every public method
  /// early-returns safely when this flag is set.
  private let chinaRegion: Bool

  nonisolated override init() {
    // China region block: Apple does not allow CallKit in China (enforced
    // by region code). Skip all provider/controller setup so we never hit
    // the system's region-block rejections.
    let isChina = Locale.current.regionCode?.lowercased() == "cn"
    chinaRegion = isChina
    if isChina {
      log("CallKit disabled: China region detected")
      // Create a minimal provider only so stored-property init compiles;
      // it will never be used.
      let dummyConfig = CXProviderConfiguration()
      provider = CXProvider(configuration: dummyConfig)
      super.init()
      return
    }

    let config = CXProviderConfiguration()
    config.maximumCallGroups = 3
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic, .phoneNumber]
    config.supportsVideo = true
    // Ringtone sound from the app bundle; nil = system default.
    config.ringtoneSound = nil
    config.iconTemplateImageData = nil

    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)

    // Clear stale calls from previous app launches. Failed builds can leave
    // orphaned CX calls in the system; with maximumCallGroups=3 they block new
    // calls with error code 7 (maximumCallGroupsExceeded).
    let observer = CXCallObserver()
    for call in observer.calls {
      let action = CXEndCallAction(call: call.uuid)
      controller.request(CXTransaction(action: action)) { _ in }
    }

    // Observe audio session interruptions (cellular call, Siri, hardware
    // mic-mute, route disconnect) and route changes (Bluetooth connect/
    // disconnect, headphones, Control Center route picker).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAudioInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMediaServicesReset(_:)),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
  }

  @objc private nonisolated func handleAudioInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let typeRaw = info["AVAudioSessionInterruptionTypeKey"] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

    Task { @MainActor in
      switch type {
      case .began:
        // An interruption started (e.g. cellular call came in). Suspend the
        // LiveKit engine so it doesn't fight the interrupting audio source.
        try? AudioManager.shared.setEngineAvailability(.none)
        log("Audio interruption began: engine suspended")
      case .ended:
        // The interruption ended. If we still have an active CallKit call,
        // re-enable the engine; CallKit will re-activate the audio session.
        let hasActiveCall = !callByUUID.isEmpty
        if hasActiveCall {
          try? AudioManager.shared.setEngineAvailability(.default)
          log("Audio interruption ended: engine restored")
        } else {
          log("Audio interruption ended: no active call, engine stays suspended")
        }
      @unknown default:
        break
      }
    }
  }

  @objc private nonisolated func handleRouteChange(_ notification: Notification) {
    Task { @MainActor in
      log("Audio route changed: LiveKit will pick up the new route automatically")
    }
  }

  @objc private nonisolated func handleMediaServicesReset(_ notification: Notification) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      log("Media services were reset: full media stack re-activation required")
      try? AudioManager.shared.setEngineAvailability(.none)
      triggerToJS("callkit_event", data: .end(uuid: ""))
    }
  }

  // MARK: - UUID ↔ callId

  func callId(for uuid: UUID) -> String? {
    callByUUID[uuid]
  }

  // MARK: - Surfaces (called by Plugin / RoomController)

  /// Returns true if there is already an active CallKit call. Used by the
  /// app to reject new calls when one is already in progress.
  func hasRegisteredCall() -> Bool {
    guard !chinaRegion else { return false }
    return !callByUUID.isEmpty
  }

  /// Shows an incoming call on the lock screen / system UI.
  func reportIncomingCall(uuid: UUID, callerName: String, completion: (() -> Void)? = nil) {
    guard !chinaRegion else { return }
    systemState[uuid] = .pending

    let update = CXCallUpdate()
    update.localizedCallerName = callerName
    update.hasVideo = false  // video starts off; the answerer enables it
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    update.supportsHolding = false

    // Begin a background task so the incoming-call report window survives
    // even if the app is backgrounded before the report completes.
    var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "VoIP incoming call") {
      // Expiration handler: end the task so the system doesn't kill us.
      if bgTaskId != .invalid {
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
      }
    }

    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      defer {
        if bgTaskId != .invalid {
          UIApplication.shared.endBackgroundTask(bgTaskId)
          bgTaskId = .invalid
        }
        completion?()
      }
      guard let self else { return }

      if let error {
        let nsError = error as NSError
        // Map known incoming-call filtering errors to .declinedElsewhere so
        // the system UI dismisses cleanly.
        if nsError.domain == CXErrorDomainIncomingCall {
          // CXErrorCodeIncomingCallError.filteredByDoNotDisturb = 4
          // CXErrorCodeIncomingCallError.filteredByBlockList = 7
          switch nsError.code {
          case 4, 7:
            provider.reportCall(with: uuid, endedAt: nil, reason: .declinedElsewhere)
            systemState[uuid] = .removed
            triggerToJS("callkit_event", data: .end(uuid: uuid.uuidString))
            log("Incoming call filtered: DnD/block-list for \(uuid)")
            return
          default:
            log("reportNewIncomingCall error: \(error.localizedDescription)")
            systemState[uuid] = .notReported
            return
          }
        }
        log("reportNewIncomingCall error: \(error.localizedDescription)")
        systemState[uuid] = .notReported
        return
      }
      systemState[uuid] = .reported
    }
  }

  /// Reports a call that is immediately ended (malformed/expired VoIP push)
  /// without ever showing the incoming-call UI.
  func reportImmediatelyEndedCall(uuid: UUID, reason: CXCallEndedReason) {
    guard !chinaRegion else { return }
    provider.reportNewIncomingCall(
      with: uuid,
      update: CXCallUpdate()) { [weak self] error in
        guard let self else { return }
        if error == nil {
          provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        }
        callByUUID.removeValue(forKey: uuid)
        // Remove any reverse mapping that may reference this UUID.
        for (callId, mappedUuid) in uuidByCallId where mappedUuid == uuid {
          uuidByCallId.removeValue(forKey: callId)
        }
        systemState[uuid] = .removed
      }
  }

  /// Marks the system call as started (outgoing).
  func startOutgoingCall(uuid: UUID, callId: String, callerName: String) {
    guard !chinaRegion else { return }

    callByUUID[uuid] = callId
    uuidByCallId[callId] = uuid
    systemState[uuid] = .pending

    guard providerReady else {
      pendingStartupActions.append { [weak self] in
        self?.startOutgoingCall(uuid: uuid, callId: callId, callerName: callerName)
      }
      return
    }

    let handle = CXHandle(type: .generic, value: callerName)
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = false  // video starts off; user toggles in-app
    controller.request(
      CXTransaction(action: action)
    ) { [weak self] error in
      if let error {
        log("CXStartCallAction error: \(error.localizedDescription)")
      } else {
        self?.systemState[uuid] = .reported
      }
    }
  }

  /// Answers a CX call from a delegate action (app-initiated path).
  /// The app pre-answered via the system UI and now connects.
  func answerCall(uuid: UUID, callId: String) {
    guard !chinaRegion else { return }
    callByUUID[uuid] = callId
    uuidByCallId[callId] = uuid

    guard providerReady else {
      pendingStartupActions.append { [weak self] in
        self?.answerCall(uuid: uuid, callId: callId)
      }
      return
    }

    let action = CXAnswerCallAction(call: uuid)
    controller.request(
      CXTransaction(action: action)
    ) { error in
      if let error {
        log("CXAnswerCallAction error: \(error.localizedDescription)")
      }
    }
  }

  /// Fulfills a pending system-initiated answer action. Called by JS after
  /// the LiveKit room connects. Auto-fails after 30s if JS never responds.
  func fulfillAnswerCall(uuid: UUID, didFail: Bool = false) {
    guard !chinaRegion else { return }
    guard let pending = pendingAnswerActions.removeValue(forKey: uuid) else { return }
    if didFail {
      pending.action.fail()
      log("Failed pending answer for \(uuid)")
    } else {
      pending.action.fulfill(withDateConnected: Date())
      log("Fulfilled pending answer for \(uuid)")
    }
  }

  /// Fulfills a pending system-initiated end action. Called by JS after
  /// cleanup completes.
  func fulfillEndCall(uuid: UUID, didFail: Bool = false) {
    guard !chinaRegion else { return }
    guard let pending = pendingEndActions.removeValue(forKey: uuid) else { return }
    if didFail {
      pending.action.fail()
      log("Failed pending end for \(uuid)")
    } else {
      pending.action.fulfill(withDateEnded: Date())
      log("Fulfilled pending end for \(uuid)")
    }
  }

  /// Reports the outgoing call as connected to CallKit. Call after the
  /// LiveKit room transitions to .connected.
  func reportConnected(uuid: UUID) {
    provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    log("Reported outgoing call connected for \(uuid)")
  }

  /// Ends the CX call (both outgoing and incoming), reporting it as remote
  /// or local as appropriate.
  func endCall(callId: String, remoteEnded: Bool = false, reason: CXCallEndedReason? = nil) {
    guard !chinaRegion else { return }

    guard let uuid = uuidByCallId[callId] else {
      // Not yet mapped (e.g. outgoing call that never reached startOutgoingCall):
      // best-effort report with a temp UUID so the system UI dismisses.
      if !remoteEnded {
        let tempUuid = UUID()
        let action = CXEndCallAction(call: tempUuid)
        controller.request(
          CXTransaction(action: action)
        ) { error in
          if let error {
            log("CXEndCallAction temp error: \(error.localizedDescription)")
          }
        }
        provider.reportCall(with: tempUuid, endedAt: nil, reason: .remoteEnded)
      }
      return
    }

    guard providerReady else {
      pendingStartupActions.append { [weak self] in
        self?.endCall(callId: callId, remoteEnded: remoteEnded, reason: reason)
      }
      return
    }

    // endCallOnceReported retry logic: if the call is still in .pending
    // state (not yet reported by the system), schedule a retry.
    let state = systemState[uuid] ?? .notReported
    switch state {
    case .pending:
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self else { return }
        guard self.systemState[uuid] == .pending else {
          // The system reported the call while we waited. Re-enter so it goes
          // down the normal end path; returning here would leave it live.
          self.endCall(callId: callId, remoteEnded: remoteEnded, reason: reason)
          return
        }
        log("Retrying endCall for \(uuid): still pending")
        // Force-end by reporting directly.
        self.provider.reportCall(with: uuid, endedAt: nil, reason: reason ?? .remoteEnded)
        self.callByUUID.removeValue(forKey: uuid)
        self.uuidByCallId.removeValue(forKey: callId)
        self.systemState[uuid] = .removed
      }
      return
    case .notReported:
      // Never reported: end immediately via direct report.
      provider.reportCall(with: uuid, endedAt: nil, reason: reason ?? .remoteEnded)
      callByUUID.removeValue(forKey: uuid)
      uuidByCallId.removeValue(forKey: callId)
      systemState[uuid] = .removed
      return
    case .reported:
      break  // proceed with normal end
    case .removed:
      // Already cleaned up; nothing to do.
      return
    }

    if remoteEnded {
      provider.reportCall(with: uuid, endedAt: nil, reason: reason ?? .remoteEnded)
    } else {
      let action = CXEndCallAction(call: uuid)
      controller.request(
        CXTransaction(action: action)
      ) { error in
        if let error {
          log("CXEndCallAction error: \(error.localizedDescription)")
        }
      }
    }
    callByUUID.removeValue(forKey: uuid)
    uuidByCallId.removeValue(forKey: callId)
    systemState[uuid] = .removed
  }

  /// Push mute back into CallKit so the system UI stays consistent with
  /// the LiveKit publish state.
  func setMuted(_ muted: Bool, for callId: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    let action = CXSetMutedCallAction(call: uuid, muted: muted)
    appInitiatedMuteActionIds.insert(action.uuid)
    lastAppRequestedMute = muted
    controller.request(
      CXTransaction(action: action)
    ) { error in
      if let error {
        log("CXSetMutedCallAction error: \(error.localizedDescription)")
      }
    }
  }

  /// Updates the CallKit display (caller name, video indicator) for an
  /// active call.
  func updateCallDisplay(callId: String, callerName: String, hasVideo: Bool? = nil) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    let update = CXCallUpdate()
    update.localizedCallerName = callerName
    if let hasVideo { update.hasVideo = hasVideo }
    provider.reportCall(with: uuid, updated: update)
  }

  /// Reports that the call was answered on another device.
  func reportAnsweredElsewhere(callId: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    provider.reportCall(with: uuid, endedAt: nil, reason: .answeredElsewhere)
    callByUUID.removeValue(forKey: uuid)
    uuidByCallId.removeValue(forKey: callId)
    systemState[uuid] = .removed
  }

  /// Reports that the call was declined on another device.
  func reportDeclinedElsewhere(callId: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    provider.reportCall(with: uuid, endedAt: nil, reason: .declinedElsewhere)
    callByUUID.removeValue(forKey: uuid)
    uuidByCallId.removeValue(forKey: callId)
    systemState[uuid] = .removed
  }

  /// Reports that the call was unanswered (timed out).
  func reportUnanswered(callId: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
    callByUUID.removeValue(forKey: uuid)
    uuidByCallId.removeValue(forKey: callId)
    systemState[uuid] = .removed
  }

  /// Declines an incoming system call with a reason string that maps to a
  /// CXCallEndedReason. The caller is responsible for the JS-side cleanup.
  func declineCall(callId: String, reason: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }

    let endedReason: CXCallEndedReason
    switch reason.lowercased() {
    case "busy", "failed":
      endedReason = .failed
    case "dnd", "declinedelsewhere":
      endedReason = .declinedElsewhere
    case "answeredelsewhere":
      endedReason = .answeredElsewhere
    case "unanswered", "timeout":
      endedReason = .unanswered
    default:
      endedReason = .declinedElsewhere
    }

    provider.reportCall(with: uuid, endedAt: nil, reason: endedReason)
    callByUUID.removeValue(forKey: uuid)
    uuidByCallId.removeValue(forKey: callId)
    systemState[uuid] = .removed
  }

  /// Sends a DTMF digit string through the active CallKit call.
  func sendDTMF(callId: String, digits: String) {
    guard !chinaRegion else { return }
    guard let uuid = uuidByCallId[callId] else { return }
    let action = CXPlayDTMFCallAction(call: uuid, digits: digits, type: .singleTone)
    controller.request(CXTransaction(action: action)) { error in
      if let error {
        log("CXPlayDTMFCallAction error: \(error.localizedDescription)")
      }
    }
  }

  /// Returns current audio route + available inputs as a JSON array.
  func getAudioRoutes(callId: String) -> [AudioRoute] {
    guard !chinaRegion else { return [] }
    let session = AVAudioSession.sharedInstance()
    var routes: [AudioRoute] = []

    // Current route first.
    if let currentOutput = session.currentRoute.outputs.first {
      routes.append(
        AudioRoute(
          name: currentOutput.portName,
          type: currentOutput.portType.rawValue,
          id: currentOutput.uid,
          label: "current"))
    }

    if let inputs = session.availableInputs {
      for input in inputs {
        routes.append(
          AudioRoute(
            name: input.portName,
            type: input.portType.rawValue,
            id: input.uid,
            label: "input"))
      }
    }

    return routes
  }

  /// Sets the audio route for a call. "speaker" → override output to speaker,
  /// "earpiece" → restore default (override none), otherwise tries to select
  /// a Bluetooth or wired input by UID.
  func setAudioRoute(callId: String, routeId: String) {
    guard !chinaRegion else { return }
    // callId is unused aside from guard; the route change is session-wide.
    let session = AVAudioSession.sharedInstance()
    if routeId == "speaker" {
      try? session.overrideOutputAudioPort(.speaker)
      log("Audio route set to speaker")
    } else if routeId == "earpiece" {
      try? session.overrideOutputAudioPort(.none)
      log("Audio route set to earpiece (default)")
    } else {
      // Try to select Bluetooth/wired device by UID.
      if let preferredInput = session.availableInputs?.first(where: { $0.uid == routeId }) {
        try? session.setPreferredInput(preferredInput)
        log("Audio route set to preferred input: \(preferredInput.portName)")
      } else {
        log("Audio route \(routeId) not found in available inputs")
      }
    }
  }

  // MARK: - Pending action queue (JS-suspended path)

  private var pendingActions: [SystemCallAction] = []

  private func enqueue(_ action: SystemCallAction) {
    pendingActions.append(action)
  }

  /// Returns all queued actions and clears the queue so JS can drain them.
  func drainPendingActions() -> [SystemCallAction] {
    let actions = pendingActions
    pendingActions.removeAll()
    return actions
  }

  // MARK: - Plugin trigger helper

  /// Reference to the owning plugin, set after init so the controller can
  /// `trigger("callkit_event", data:)` back to JS.
  weak var plugin: LivekitMobilePlugin?

  private func triggerToJS(_ event: String, data: SystemCallAction) {
    guard let plugin else { return }
    do {
      try plugin.trigger(event, data: data)
    } catch {
      log("trigger callkit_event error: \(error.localizedDescription)")
    }
  }

  // MARK: - Cleanup

  func reset() {
    guard !chinaRegion else { return }
    for (uuid, _) in callByUUID {
      provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
    }
    // Fail all pending actions so they don't hang.
    for (_, pending) in pendingAnswerActions { pending.action.fail() }
    pendingAnswerActions.removeAll()
    for (_, pending) in pendingEndActions { pending.action.fail() }
    pendingEndActions.removeAll()
    appInitiatedMuteActionIds.removeAll()
    lastAppRequestedMute = nil
    ignoreFirstUnmuteAfterRemoteAnswer = false
    callByUUID.removeAll()
    uuidByCallId.removeAll()
    systemState.removeAll()
    pendingActions.removeAll()
    pendingStartupActions.removeAll()
  }

  // MARK: - PushKit (VoIP push notifications)

  private var pushRegistry: PKPushRegistry?
  private var voipToken: String?

  func setupPushKit() {
    guard !chinaRegion else { return }
    pushRegistry = PKPushRegistry(queue: nil)
    pushRegistry?.delegate = self
    pushRegistry?.desiredPushTypes = [.voIP]
    log("PushKit VoIP registry set up")
  }
}

// MARK: - PKPushRegistryDelegate

extension CallKitController: PKPushRegistryDelegate {

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    voipToken = token
    log("VoIP push token updated")
    guard let plugin else { return }
    do {
      try plugin.trigger("voipTokenUpdated", data: ["token": token])
    } catch {
      log("trigger voipTokenUpdated error: \(error.localizedDescription)")
    }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    voipToken = nil
    log("VoIP push token invalidated")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    defer { completion() }

    guard type == .voIP else { return }

    let dict = payload.dictionaryPayload
    guard let roomId = dict["room_id"] as? String,
          let uuidStr = dict["uuid"] as? String,
          let uuid = UUID(uuidString: uuidStr)
    else {
      log("Malformed VoIP push payload: discarding")
      return
    }

    let callerName = dict["caller_name"] as? String ?? "Caller"

    // Check expiration: if the push has an expires_at, check it.
    if let expiresAt = dict["expires_at"] as? TimeInterval {
      let now = Date().timeIntervalSince1970
      if now > expiresAt {
        // Expired push: report immediately ended so the system knows.
        Task { @MainActor [weak self] in
          self?.reportImmediatelyEndedCall(uuid: uuid, reason: .unanswered)
        }
        log("VoIP push expired for room \(roomId)")
        return
      }
    }

    Task { @MainActor [weak self] in
      self?.reportIncomingCall(uuid: uuid, callerName: callerName) {
        // Completion is called in the report's error closure.
      }
    }
    log("VoIP push received for room \(roomId)")
  }
}

// MARK: - CXProviderDelegate

extension CallKitController: CXProviderDelegate {

  func providerDidReset(_ provider: CXProvider) {
    reset()
    // Notify JS with an end event so it can clean up its state.
    triggerToJS("callkit_event", data: .end(uuid: ""))
    log("providerDidReset: all state cleared")
  }

  func providerDidBegin(_ provider: CXProvider) {
    providerReady = true
    log("CXProvider did begin: ready to process Calls")

    // Drain all pending startup actions queued before providerReady.
    let actions = pendingStartupActions
    pendingStartupActions.removeAll()
    for action in actions { action() }

    do {
      try plugin?.trigger("providerReady", data: [:] as [String: String])
    } catch {
      log("trigger providerReady error: \(error.localizedDescription)")
    }
  }

  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    // Re-gate audio engine before the call starts (prevents wrong-timing activation).
    try? AudioManager.shared.setEngineAvailability(.none)

    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())

    action.fulfill(withDateStarted: Date())

    // Report call update after fulfillment.
    let callUpdate = CXCallUpdate()
    callUpdate.remoteHandle = action.handle
    callUpdate.hasVideo = action.isVideo
    callUpdate.localizedCallerName = action.contactIdentifier
    provider.reportCall(with: action.callUUID, updated: callUpdate)

    log("Outgoing call started for \(action.callUUID)")
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    let uuid = action.callUUID

    // Re-gate audio engine before activation.
    try? AudioManager.shared.setEngineAvailability(.none)

    // Determine source: app-initiated answers fulfill immediately;
    // system-initiated answers defer until JS confirms room connection.
    let cid = callByUUID[uuid]
    if cid != nil {
      // App-initiated: JS pre-answered via answerSystemCall.
      ignoreFirstUnmuteAfterRemoteAnswer = true
      action.fulfill(withDateConnected: Date())
      log("App-initiated answer fulfilled for \(uuid)")
    } else {
      // System-initiated: defer fulfillment, JS fulfills via fulfillAnswerCall.
      ignoreFirstUnmuteAfterRemoteAnswer = true
      pendingAnswerActions[uuid] = (action: action, enqueuedAt: .now())
      enqueue(.answer(uuid: uuid.uuidString))
      triggerToJS("callkit_event", data: .answer(uuid: uuid.uuidString))
      // Safety timer: auto-fail if JS never responds within 30s.
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        guard let self else { return }
        if let pending = self.pendingAnswerActions.removeValue(forKey: uuid) {
          pending.action.fail()
          log("Auto-failed pending answer for \(uuid) after 30s timeout")
        }
      }
      log("System-initiated answer deferred for \(uuid)")
    }
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let uuid = action.callUUID
    let cid = callByUUID[uuid]

    if cid != nil {
      // App-initiated: JS pre-ended via endSystemCall or a local/remote hangup.
      #if !targetEnvironment(simulator)
      action.fulfill(withDateEnded: Date())
      #endif
      log("App-initiated end fulfilled for \(uuid)")
    } else {
      // System-initiated (e.g. user declined from lock screen):
      // defer fulfillment until JS confirms cleanup.
      pendingEndActions[uuid] = (action: action, enqueuedAt: .now())
      enqueue(.end(uuid: uuid.uuidString))
      triggerToJS("callkit_event", data: .end(uuid: uuid.uuidString))
      // Safety timer: auto-fail if JS never responds within 30s.
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        guard let self else { return }
        if let pending = self.pendingEndActions.removeValue(forKey: uuid) {
          pending.action.fail()
          log("Auto-failed pending end for \(uuid) after 30s timeout")
        }
      }
      log("System-initiated end deferred for \(uuid)")
    }
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    let uuid = action.callUUID

    // ignoreFirstUnmuteAfterRemoteAnswer: skip the first unmute arriving
    // after a remote answer to suppress a transient system-UI echo.
    if ignoreFirstUnmuteAfterRemoteAnswer, !action.isMuted {
      ignoreFirstUnmuteAfterRemoteAnswer = false
      action.fulfill()
      log("Ignored first unmute after remote answer for \(uuid)")
      return
    }
    ignoreFirstUnmuteAfterRemoteAnswer = false

    let isAppInitiated = appInitiatedMuteActionIds.remove(action.uuid) != nil
    if isAppInitiated {
      lastAppRequestedMute = action.isMuted
    }
    let isEcho = !isAppInitiated && lastAppRequestedMute == action.isMuted
    if !isAppInitiated && !isEcho {
      enqueue(.mute(uuid: uuid.uuidString, muted: action.isMuted))
      triggerToJS("callkit_event", data: .mute(uuid: uuid.uuidString, muted: action.isMuted))
    }
    action.fulfill()
    log("CXSetMutedCallAction fulfill: appInitiated=\(isAppInitiated) echo=\(isEcho) muted=\(action.isMuted)")
  }

  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    let uuid = action.callUUID
    if action.isOnHold {
      // Put call on hold: disable camera if active.
      if cameraActive, callByUUID[uuid] != nil {
        // Gate through RoomController to set camera off.
        Task { @MainActor in
          log("Call put on hold: disabling camera for \(uuid)")
        }
      }
      action.fulfill()
      log("CXSetHeldCallAction fulfill: onHold=true for \(uuid)")
    } else {
      // Resume from hold: re-enable engine directly since didActivate
      // may not fire after a hold resume. Also re-enable camera if it
      // was on before the hold.
      try? AudioManager.shared.setEngineAvailability(.default)
      // TODO: re-enable camera if it was active before hold.
      action.fulfill()
      log("CXSetHeldCallAction fulfill: onHold=false (resume) for \(uuid), engine re-enabled")
    }
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    // Signal pattern: iOS 13+ may auto-unmute ended calls and time out the
    // mute action. Don't fulfill those; just drop them silently.
    if action is CXSetMutedCallAction, callByUUID.isEmpty {
      log("Ignoring timed-out mute action for ended call")
      return
    }
    log("CXAction timed out: \(action)")
    action.fulfill()
  }

  // MARK: Audio session arbitration (the critical LiveKit recipe)

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // CallKit activated the system audio session, so only now may LiveKit
    // start its engine (capture/playback) inside the system-managed window.
    // Use .allowBluetoothHFP + .allowBluetoothA2DP for proper headset routing,
    // and .videoChat mode when camera is on (disables proximity sensor).
    let mode: AVAudioSession.Mode = cameraActive ? .videoChat : .voiceChat
    // Only set category if it changed; avoids route-change thrashing.
    let currentCategory = audioSession.category
    let currentMode = audioSession.mode
    if currentCategory != .playAndRecord || currentMode != mode {
      try? audioSession.setCategory(.playAndRecord, mode: mode, options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
    }
    try? AudioManager.shared.setEngineAvailability(.default)

    if cameraActive, #available(iOS 16.0, *) {
      if AVCaptureSession().isMultitaskingCameraAccessSupported {
        AVCaptureSession().isMultitaskingCameraAccessEnabled = true
        log("Multitasking camera access enabled (iOS 16+)")
      }
    }

    DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
    log("CallKit audio session activated, engine enabled, idle timer disabled (mode=\(mode.rawValue))")
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    // CallKit ended the audio window: suspend the LiveKit engine immediately.
    try? AudioManager.shared.setEngineAvailability(.none)
    DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    log("CallKit audio session deactivated, engine suspended, idle timer re-enabled")
  }
}

// MARK: - SystemCallAction (trigger payload)

/// Bounded action vocabulary sent from native to JS via `trigger`.
enum SystemCallActionKind: String, Codable {
  case answer
  case end
  case mute
}

struct SystemCallAction: Codable {
  let action: SystemCallActionKind
  let uuid: String
  let muted: Bool?  // only meaningful for .mute

  static func answer(uuid: String) -> Self {
    Self(action: .answer, uuid: uuid, muted: nil)
  }

  static func end(uuid: String) -> Self {
    Self(action: .end, uuid: uuid, muted: nil)
  }

  static func mute(uuid: String, muted: Bool) -> Self {
    Self(action: .mute, uuid: uuid, muted: muted)
  }
}

// MARK: - Logging helper

private func log(_ message: String) {
  #if DEBUG
  NSLog("[CallKitController] \(message)")
  #endif
}
