import { type UnlistenFn } from '@tauri-apps/api/event';
export type NativeCallConnectionState = 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'failed';
/**
 * Bounded failure vocabulary shared by snapshot `lastError` and command
 * rejections. Raw native error strings and platform-specific codes never
 * cross the bridge.
 */
export type NativeCallFailureCode = 'invalid_request' | 'busy' | 'permission_denied' | 'connect_failed' | 'media_failed' | 'disconnected' | 'cancelled' | 'unavailable' | 'unexpected';
/**
 * Command rejection code: the bounded failure vocabulary plus the
 * bridge-level `timeout` (a native invocation exceeded its time bound).
 */
export type NativeCallErrorCode = NativeCallFailureCode | 'timeout';
export interface NativeCallError {
    code: NativeCallFailureCode;
    message: string;
}
export interface NativeCallCapabilities {
    supported: boolean;
    microphone: boolean;
    backgroundAudio: boolean;
    nativeRoom: boolean;
    camera: boolean;
    nativeVideoOverlay: boolean;
}
/**
 * One shared-E2EE key: raw key material (`key`, base64-encoded) for one
 * participant `identity` at `keyIndex`. Keys only flow guest → native; they
 * never appear in snapshots or events.
 */
export interface EncryptionKey {
    identity: string;
    keyIndex: number;
    key: string;
}
/**
 * `url` is the LiveKit server URL and `token` a LiveKit access token (JWT),
 * both supplied by the host app (e.g. MatrixRTC focus negotiation). The
 * plugin never mints, refreshes, logs, or echoes the token.
 *
 * `encryptionKeys` are initial shared-E2EE keys installed by the native side
 * before `room.connect`. Omitted or empty means an ordinary unencrypted
 * LiveKit call; use `setNativeCallEncryptionKey` for later rotations.
 */
export interface ConnectNativeCallRequest {
    callId: string;
    url: string;
    token: string;
    microphoneEnabled: boolean;
    encryptionKeys?: EncryptionKey[];
}
/** Rotates or installs a shared-E2EE key mid-call. */
export interface SetNativeCallEncryptionKeyRequest {
    callId: string;
    identity: string;
    keyIndex: number;
    key: string;
}
export interface DisconnectNativeCallRequest {
    callId: string;
}
export interface SetNativeCallMicrophoneEnabledRequest {
    callId: string;
    enabled: boolean;
}
export interface SetNativeCallCameraEnabledRequest {
    callId: string;
    enabled: boolean;
}
export interface SwitchNativeCallCameraRequest {
    callId: string;
}
/**
 * Positions a native-rendered remote video track in CSS pixels. `x` and `y`
 * may be negative for a partially offscreen DOM rectangle; all geometry is
 * finite, and `width`, `height`, and `devicePixelRatio` must be positive.
 */
export interface SetNativeCallRemoteVideoOverlayRequest {
    callId: string;
    participantIdentity: string;
    trackId: string;
    x: number;
    y: number;
    width: number;
    height: number;
    devicePixelRatio: number;
}
export interface ClearNativeCallRemoteVideoOverlayRequest {
    callId: string;
}
/**
 * One remote participant's camera publication (track id, mute and
 * subscription state).
 */
export interface NativeCallRemoteCamera {
    sid: string;
    muted: boolean;
    subscribed: boolean;
}
/**
 * Remote-only participant projection. `identity` is the opaque
 * LiveKit/MatrixRTC backend identity. `camera` exists only while the
 * participant has a remote camera publication.
 */
export interface NativeCallRemoteParticipant {
    identity: string;
    camera?: NativeCallRemoteCamera;
}
/**
 * The single authoritative shape of the native room, resolved by every
 * command and delivered by every event. `revision` is owned and bumped by
 * the native side on every change and passes through the bridge untouched;
 * consumers can drop out-of-order snapshots by comparing it.
 */
export interface NativeCallSnapshot {
    revision: number;
    callId: string | null;
    connectionState: NativeCallConnectionState;
    microphoneEnabled: boolean;
    cameraEnabled: boolean;
    participantCount: number;
    remoteParticipants: NativeCallRemoteParticipant[];
    lastError?: NativeCallError;
}
/**
 * Snapshots are delivered only to the webview that connected (or reclaimed)
 * the call: a `listen` on this name in any other webview stays silent.
 */
export declare const NATIVE_CALL_EVENT = "plugin:livekit-mobile://native-call-event";
export declare function getNativeCallCapabilities(): Promise<NativeCallCapabilities>;
export declare function connectNativeCall(request: ConnectNativeCallRequest): Promise<NativeCallSnapshot>;
export declare function disconnectNativeCall(request: DisconnectNativeCallRequest): Promise<NativeCallSnapshot>;
export declare function setNativeCallMicrophoneEnabled(request: SetNativeCallMicrophoneEnabledRequest): Promise<NativeCallSnapshot>;
export declare function setNativeCallCameraEnabled(request: SetNativeCallCameraEnabledRequest): Promise<NativeCallSnapshot>;
export declare function switchNativeCallCamera(request: SwitchNativeCallCameraRequest): Promise<NativeCallSnapshot>;
export declare function setNativeCallRemoteVideoOverlay(request: SetNativeCallRemoteVideoOverlayRequest): Promise<NativeCallSnapshot>;
export declare function clearNativeCallRemoteVideoOverlay(request: ClearNativeCallRemoteVideoOverlayRequest): Promise<NativeCallSnapshot>;
export declare function getNativeCallState(): Promise<NativeCallSnapshot>;
/**
 * Installs or rotates a shared-E2EE key for one identity in the active
 * call. Initial keys belong on `connectNativeCall` (they are installed
 * before `room.connect`); this command covers later rotations/updates.
 */
export declare function setNativeCallEncryptionKey(request: SetNativeCallEncryptionKeyRequest): Promise<NativeCallSnapshot>;
/**
 * Listens for native room snapshots. Every native change — connection state,
 * participant count, microphone/camera flips, failures (via `lastError`) —
 * arrives as one full `NativeCallSnapshot`; there are no separate event
 * kinds.
 */
export declare function listenNativeCallSnapshot(handler: (snapshot: NativeCallSnapshot) => void): Promise<UnlistenFn>;
