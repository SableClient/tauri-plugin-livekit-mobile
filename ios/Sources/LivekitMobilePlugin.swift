import Foundation
import Tauri

// Wire contract summary (the shared Rust bridge owns the full schema):
// - Commands: capabilities, connect, disconnect, cancelConnect,
//   setMicrophoneEnabled, setCameraEnabled, switchCamera, getState.
// - Every response is the authoritative snapshot
//   { revision, callId|null, connectionState, microphoneEnabled,
//     cameraEnabled, participantCount, lastError?: {code, message} }.
// - The only channel event is { event: "snapshot_changed", snapshot }.
//
// `token` is a LiveKit JWT: used only transiently to connect, and never
// logged, stored, or echoed back. Only bounded codes and static messages
// cross this boundary; native errors (which may embed URLs) are discarded.

struct ConnectArgs: Decodable {
  let callId: String
  let url: String
  let token: String
  let microphoneEnabled: Bool
  let channel: Channel
}

struct DisconnectArgs: Decodable {
  let callId: String
}

struct SetMicrophoneEnabledArgs: Decodable {
  let callId: String
  let enabled: Bool
}

struct SetCameraEnabledArgs: Decodable {
  let callId: String
  let enabled: Bool
}

// `cancelConnect` and `switchCamera` reuse the `{ callId }` payload of
// `DisconnectArgs`.

enum BridgeConnectionState: String, Encodable {
  case idle
  case connecting
  case connected
  case reconnecting
  case failed
}

/// Bounded failure codes; the raw values are part of the public contract.
/// Messages are static so they can never contain tokens, URLs, or native
/// error details.
enum BridgeFailureCode: String, Encodable {
  case invalidRequest = "invalid_request"
  case busy
  case permissionDenied = "permission_denied"
  case connectFailed = "connect_failed"
  case mediaFailed = "media_failed"
  case disconnected
  case cancelled
  case unavailable
  case unexpected

  var message: String {
    switch self {
    case .invalidRequest: return "Invalid request."
    case .busy: return "Another call is active."
    case .permissionDenied: return "Microphone or camera permission was denied."
    case .connectFailed: return "Failed to connect to the room."
    case .mediaFailed: return "Failed to change the media state."
    case .disconnected: return "Disconnected from the room."
    case .cancelled: return "The operation was superseded by a newer one."
    case .unavailable: return "The native call controller is unavailable."
    case .unexpected: return "An unexpected error occurred."
    }
  }
}

struct BridgeError: Encodable {
  let code: BridgeFailureCode
  let message: String

  init(_ code: BridgeFailureCode) {
    self.code = code
    self.message = code.message
  }
}

struct BridgeRemoteCamera: Encodable, Equatable {
  let sid: String
  let muted: Bool
  let subscribed: Bool
}

struct BridgeRemoteParticipant: Encodable, Equatable {
  let identity: String
  /// Present only while the participant has a camera publication.
  let camera: BridgeRemoteCamera?
}

struct BridgeStateResponse: Encodable {
  let revision: UInt64
  let callId: String?
  let connectionState: BridgeConnectionState
  let microphoneEnabled: Bool
  let cameraEnabled: Bool
  let participantCount: Int
  let remoteParticipants: [BridgeRemoteParticipant]
  let lastError: BridgeError?

  // Custom encoding: `callId` must be an explicit JSON null when idle, while
  // the optional `lastError` key is omitted when absent.
  private enum CodingKeys: String, CodingKey {
    case revision
    case callId
    case connectionState
    case microphoneEnabled
    case cameraEnabled
    case participantCount
    case remoteParticipants
    case lastError
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(revision, forKey: .revision)
    try container.encode(callId, forKey: .callId)
    try container.encode(connectionState, forKey: .connectionState)
    try container.encode(microphoneEnabled, forKey: .microphoneEnabled)
    try container.encode(cameraEnabled, forKey: .cameraEnabled)
    try container.encode(participantCount, forKey: .participantCount)
    try container.encode(remoteParticipants, forKey: .remoteParticipants)
    try container.encodeIfPresent(lastError, forKey: .lastError)
  }
}

enum BridgeEventKind: String, Encodable {
  case snapshotChanged = "snapshot_changed"
}

/// The only payload ever sent over the call's event channel.
struct BridgeSnapshotEvent: Encodable {
  let event: BridgeEventKind
  let snapshot: BridgeStateResponse
}

struct BridgeCapabilities: Encodable {
  let microphone: Bool
  let backgroundAudio: Bool
  let camera: Bool
}

/// Tauri-facing surface; all work is serialized through ``RoomController`` on
/// the main actor and every invoke settles exactly once.
///
/// Host app requirements: `NSMicrophoneUsageDescription` and
/// `NSCameraUsageDescription` in Info.plist, and the `audio`
/// `UIBackgroundModes` entry for room audio to survive backgrounding.
final class LivekitMobilePlugin: Plugin {
  private let controller = RoomController()

  deinit {
    // The task retains the controller until teardown finishes; teardown bumps
    // the attempt identity so in-flight work settles with `cancelled`.
    Task { @MainActor [controller] in
      await controller.tearDown()
    }
  }

  @objc public func capabilities(_ invoke: Invoke) throws {
    invoke.resolve(
      BridgeCapabilities(microphone: true, backgroundAudio: true, camera: true))
  }

  @objc public func connect(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(ConnectArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.connect(args, invoke: invoke)
    }
  }

  @objc public func disconnect(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(DisconnectArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.disconnect(callId: args.callId, invoke: invoke)
    }
  }

  /// Timeout recovery for Rust: tears down the matching (possibly in-flight)
  /// attempt and resolves the idle snapshot; stale call ids are a no-op.
  @objc public func cancelConnect(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(DisconnectArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.cancelConnect(callId: args.callId, invoke: invoke)
    }
  }

  @objc public func setMicrophoneEnabled(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(SetMicrophoneEnabledArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.setMicrophoneEnabled(
        callId: args.callId, enabled: args.enabled, invoke: invoke)
    }
  }

  @objc public func setCameraEnabled(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(SetCameraEnabledArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.setCameraEnabled(
        callId: args.callId, enabled: args.enabled, invoke: invoke)
    }
  }

  @objc public func switchCamera(_ invoke: Invoke) throws {
    guard let args = try? invoke.parseArgs(DisconnectArgs.self) else {
      reject(invoke, .invalidRequest)
      return
    }
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      await controller.switchCamera(callId: args.callId, invoke: invoke)
    }
  }

  @objc public func getState(_ invoke: Invoke) throws {
    Task { @MainActor [weak controller] in
      guard let controller else {
        reject(invoke, .unavailable)
        return
      }
      invoke.resolve(controller.snapshot())
    }
  }

  private func reject(_ invoke: Invoke, _ code: BridgeFailureCode) {
    invoke.reject(code.message, code: code.rawValue)
  }
}

@_cdecl("init_plugin_livekit_mobile")
func initPlugin() -> Plugin {
  LivekitMobilePlugin()
}
