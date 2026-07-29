import Foundation
import Tauri
import XCTest

@testable import tauri_plugin_livekit_mobile

/// Pins the Rust-facing JSON contract of the bridge: the authoritative
/// snapshot shape (explicit `callId: null`, omitted `lastError`, camera flag),
/// the single `snapshot_changed` channel event, bounded enum values, and
/// invoke settlement guarantees. No LiveKit connection is established here;
/// plugin commands are driven through a headless `Invoke`.
final class WireContractTests: XCTestCase {

  // MARK: - Helpers

  private func jsonObject(_ value: Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func jsonObject(_ payload: String) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
  }

  private static func idleSnapshot(
    revision: UInt64 = 0,
    microphoneEnabled: Bool = false,
    cameraEnabled: Bool = false
  ) -> BridgeStateResponse {
    BridgeStateResponse(
      revision: revision, callId: nil, connectionState: .idle,
      microphoneEnabled: microphoneEnabled, cameraEnabled: cameraEnabled,
      participantCount: 0, lastError: nil)
  }

  /// Asserts the full snapshot keys exactly as the bridge contract requires.
  private func assertSnapshotKeys(
    _ state: [String: Any], revision: Int = 0, callId: String?,
    connectionState: String, microphoneEnabled: Bool, cameraEnabled: Bool,
    participantCount: Int, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    XCTAssertEqual(state["revision"] as? Int, revision, file: file, line: line)
    if let callId {
      XCTAssertEqual(state["callId"] as? String, callId, file: file, line: line)
    } else {
      XCTAssertTrue(state["callId"] is NSNull, "callId must be explicit null", file: file, line: line)
    }
    XCTAssertEqual(state["connectionState"] as? String, connectionState, file: file, line: line)
    XCTAssertEqual(state["microphoneEnabled"] as? Bool, microphoneEnabled, file: file, line: line)
    XCTAssertEqual(state["cameraEnabled"] as? Bool, cameraEnabled, file: file, line: line)
    XCTAssertEqual(state["participantCount"] as? Int, participantCount, file: file, line: line)
  }

  private final class InvokeRecording: @unchecked Sendable {
    private typealias InvokeResponse = (id: UInt64, payload: String?)

    private let lock = NSLock()
    private var recorded: InvokeResponse?
    private var continuation: CheckedContinuation<InvokeResponse, Never>?

    func record(_ id: UInt64, _ payload: String?) {
      lock.lock()
      if let continuation {
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: (id, payload))
      } else {
        recorded = (id, payload)
        lock.unlock()
      }
    }

    func wait() async -> (id: UInt64, payload: String?) {
      await withCheckedContinuation { continuation in
        lock.lock()
        if let recorded {
          self.recorded = nil
          lock.unlock()
          continuation.resume(returning: recorded)
        } else {
          self.continuation = continuation
          lock.unlock()
        }
      }
    }
  }

  private static let resolveId: UInt64 = 1
  private static let rejectId: UInt64 = 2

  private func makeInvoke(data: String) -> (Invoke, InvokeRecording) {
    let recording = InvokeRecording()
    let invoke = Invoke(
      command: "test",
      callback: Self.resolveId,
      error: Self.rejectId,
      sendResponse: { id, payload in recording.record(id, payload) },
      sendChannelData: { _, _ in },
      data: data)
    return (invoke, recording)
  }

  // MARK: - Bounded wire values

  func testConnectionStateWireValues() throws {
    for (state, raw) in [
      (BridgeConnectionState.idle, "idle"),
      (.connecting, "connecting"),
      (.connected, "connected"),
      (.reconnecting, "reconnecting"),
      (.failed, "failed"),
    ] as [(BridgeConnectionState, String)] {
      let value = try XCTUnwrap(
        String(data: JSONEncoder().encode(state), encoding: .utf8))
      XCTAssertEqual(value, "\"\(raw)\"")
    }
  }

  func testFailureCodeRawValuesAreThePublicBoundedSet() {
    XCTAssertEqual(BridgeFailureCode.invalidRequest.rawValue, "invalid_request")
    XCTAssertEqual(BridgeFailureCode.busy.rawValue, "busy")
    XCTAssertEqual(BridgeFailureCode.permissionDenied.rawValue, "permission_denied")
    XCTAssertEqual(BridgeFailureCode.connectFailed.rawValue, "connect_failed")
    XCTAssertEqual(BridgeFailureCode.mediaFailed.rawValue, "media_failed")
    XCTAssertEqual(BridgeFailureCode.disconnected.rawValue, "disconnected")
    XCTAssertEqual(BridgeFailureCode.cancelled.rawValue, "cancelled")
    XCTAssertEqual(BridgeFailureCode.unavailable.rawValue, "unavailable")
    XCTAssertEqual(BridgeFailureCode.unexpected.rawValue, "unexpected")
  }

  // MARK: - Snapshot shape

  func testIdleSnapshotShape() throws {
    let state = try jsonObject(Self.idleSnapshot())
    try assertSnapshotKeys(
      state, revision: 0, callId: nil, connectionState: "idle",
      microphoneEnabled: false, cameraEnabled: false, participantCount: 0)
    XCTAssertNil(state["lastError"])
  }

  func testSnapshotCarriesMediaFlagsAndBoundedLastError() throws {
    let state = try jsonObject(
      BridgeStateResponse(
        revision: 7, callId: "call-1", connectionState: .connected,
        microphoneEnabled: true, cameraEnabled: true, participantCount: 3,
        lastError: BridgeError(.mediaFailed)))
    try assertSnapshotKeys(
      state, revision: 7, callId: "call-1", connectionState: "connected",
      microphoneEnabled: true, cameraEnabled: true, participantCount: 3)
    let lastError = try XCTUnwrap(state["lastError"] as? [String: Any])
    XCTAssertEqual(lastError["code"] as? String, "media_failed")
    XCTAssertEqual(
      lastError["message"] as? String, BridgeFailureCode.mediaFailed.message)
    // The error payload must never carry secrets or environment details.
    XCTAssertNil(lastError["token"])
    XCTAssertNil(lastError["url"])
    XCTAssertNil(lastError["error"])
  }

  // MARK: - Channel event shape

  func testSnapshotChangedEventCarriesFullSnapshot() throws {
    let event = try jsonObject(
      BridgeSnapshotEvent(event: .snapshotChanged, snapshot: Self.idleSnapshot(revision: 4)))
    XCTAssertEqual(event["event"] as? String, "snapshot_changed")
    let snapshot = try XCTUnwrap(event["snapshot"] as? [String: Any])
    try assertSnapshotKeys(
      snapshot, revision: 4, callId: nil, connectionState: "idle",
      microphoneEnabled: false, cameraEnabled: false, participantCount: 0)
    XCTAssertNil(snapshot["lastError"])
    // No legacy fields may leak into the single-protocol event.
    XCTAssertNil(event["callId"])
    XCTAssertNil(event["connectionState"])
    XCTAssertNil(event["code"])
    XCTAssertNil(event["message"])
    XCTAssertNil(event["participantCount"])
  }

  func testEventKindRawValue() {
    XCTAssertEqual(BridgeEventKind.snapshotChanged.rawValue, "snapshot_changed")
  }

  // MARK: - Args decoding

  func testConnectArgsDecodeCamelCase() throws {
    let (invoke, _) = makeInvoke(data: """
      {
        "callId": "call-1",
        "url": "wss://example.test",
        "token": "T0K3N",
        "microphoneEnabled": true,
        "channel": "__CHANNEL__:7"
      }
      """)
    let args = try invoke.parseArgs(ConnectArgs.self)
    XCTAssertEqual(args.callId, "call-1")
    XCTAssertEqual(args.url, "wss://example.test")
    XCTAssertEqual(args.token, "T0K3N")
    XCTAssertTrue(args.microphoneEnabled)
    XCTAssertEqual(args.channel.id, 7)
  }

  func testCallIdOnlyArgsDecode() throws {
    let (invoke, _) = makeInvoke(data: #"{"callId": "call-1"}"#)
    let args = try invoke.parseArgs(DisconnectArgs.self)
    XCTAssertEqual(args.callId, "call-1")
  }

  func testMediaEnabledArgsDecode() throws {
    let (invoke, _) = makeInvoke(data: #"{"callId": "call-1", "enabled": false}"#)
    let mic = try invoke.parseArgs(SetMicrophoneEnabledArgs.self)
    XCTAssertEqual(mic.callId, "call-1")
    XCTAssertFalse(mic.enabled)
    let camera = try invoke.parseArgs(SetCameraEnabledArgs.self)
    XCTAssertEqual(camera.callId, "call-1")
    XCTAssertFalse(camera.enabled)
  }

  // MARK: - Invoke settlement

  func testCapabilitiesResolves() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: "{}")
    try plugin.capabilities(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["microphone"] as? Bool, true)
    XCTAssertEqual(payload["backgroundAudio"] as? Bool, true)
    XCTAssertEqual(payload["camera"] as? Bool, true)
  }

  func testGetStateResolvesIdleSnapshot() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: "{}")
    try plugin.getState(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    try assertSnapshotKeys(
      payload, revision: 0, callId: nil, connectionState: "idle",
      microphoneEnabled: false, cameraEnabled: false, participantCount: 0)
  }

  func testStaleDisconnectIsNoOpResolve() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: #"{"callId": "unknown"}"#)
    try plugin.disconnect(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["connectionState"] as? String, "idle")
    XCTAssertTrue(payload["callId"] is NSNull)
  }

  /// Timeout recovery on an idle controller must resolve the idle snapshot,
  /// never reject, and never disturb state.
  func testCancelConnectOnIdleIsNoOpResolve() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: #"{"callId": "unknown"}"#)
    try plugin.cancelConnect(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    try assertSnapshotKeys(
      payload, revision: 0, callId: nil, connectionState: "idle",
      microphoneEnabled: false, cameraEnabled: false, participantCount: 0)
  }

  func testStaleSetMicrophoneIsNoOpResolve() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(
      data: #"{"callId": "unknown", "enabled": true}"#)
    try plugin.setMicrophoneEnabled(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["connectionState"] as? String, "idle")
    XCTAssertEqual(payload["microphoneEnabled"] as? Bool, false)
    XCTAssertEqual(payload["cameraEnabled"] as? Bool, false)
  }

  func testStaleSetCameraIsNoOpResolve() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(
      data: #"{"callId": "unknown", "enabled": true}"#)
    try plugin.setCameraEnabled(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["connectionState"] as? String, "idle")
    XCTAssertEqual(payload["cameraEnabled"] as? Bool, false)
  }

  func testStaleSwitchCameraIsNoOpResolve() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: #"{"callId": "unknown"}"#)
    try plugin.switchCamera(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.resolveId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["connectionState"] as? String, "idle")
  }

  func testMalformedSetCameraRejectsInvalidRequest() async throws {
    let plugin = LivekitMobilePlugin()
    let (invoke, recording) = makeInvoke(data: #"{"callId": "call-1"}"#)
    try plugin.setCameraEnabled(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.rejectId)
    let payload = try jsonObject(try XCTUnwrap(response.payload))
    XCTAssertEqual(payload["code"] as? String, "invalid_request")
  }

  /// A malformed connect (realistic JWT-looking token included) must reject
  /// with the bounded `invalid_request` code and must never echo the token.
  func testMalformedConnectRejectsWithoutEchoingToken() async throws {
    let plugin = LivekitMobilePlugin()
    let secret = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.9fakedata.signature"
    let (invoke, recording) = makeInvoke(
      data: """
        { "callId": "call-1", "url": "wss://example.test", "token": "\(secret)" }
        """)
    try plugin.connect(invoke)
    let response = await recording.wait()
    XCTAssertEqual(response.id, Self.rejectId)
    let rawPayload = try XCTUnwrap(response.payload)
    let payload = try jsonObject(rawPayload)
    XCTAssertEqual(payload["code"] as? String, "invalid_request")
    XCTAssertEqual(
      payload["message"] as? String, BridgeFailureCode.invalidRequest.message)
    XCTAssertFalse(rawPayload.contains(secret))
  }
}
