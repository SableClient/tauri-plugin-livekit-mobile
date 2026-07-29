import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';

export type NativeCallConnectionState =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'failed';

/**
 * Bounded failure vocabulary shared by snapshot `lastError` and command
 * rejections. Raw native error strings and platform-specific codes never
 * cross the bridge.
 */
export type NativeCallFailureCode =
  | 'invalid_request'
  | 'busy'
  | 'permission_denied'
  | 'connect_failed'
  | 'media_failed'
  | 'disconnected'
  | 'cancelled'
  | 'unavailable'
  | 'unexpected';

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
}

/**
 * `url` is the LiveKit server URL and `token` a LiveKit access token (JWT),
 * both supplied by the host app (e.g. MatrixRTC focus negotiation). The
 * plugin never mints, refreshes, logs, or echoes the token.
 */
export interface ConnectNativeCallRequest {
  callId: string;
  url: string;
  token: string;
  microphoneEnabled: boolean;
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
  lastError?: NativeCallError;
}

/**
 * Snapshots are delivered only to the webview that connected (or reclaimed)
 * the call: a `listen` on this name in any other webview stays silent.
 */
export const NATIVE_CALL_EVENT = 'plugin:livekit-mobile://native-call-event';

export async function getNativeCallCapabilities(): Promise<NativeCallCapabilities> {
  return await invoke<NativeCallCapabilities>(
    'plugin:livekit-mobile|getNativeCallCapabilities'
  );
}

export async function connectNativeCall(
  request: ConnectNativeCallRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|connectNativeCall', {
    payload: request,
  });
}

export async function disconnectNativeCall(
  request: DisconnectNativeCallRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|disconnectNativeCall', {
    payload: request,
  });
}

export async function setNativeCallMicrophoneEnabled(
  request: SetNativeCallMicrophoneEnabledRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|setNativeCallMicrophoneEnabled',
    { payload: request }
  );
}

export async function setNativeCallCameraEnabled(
  request: SetNativeCallCameraEnabledRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|setNativeCallCameraEnabled', {
    payload: request,
  });
}

export async function switchNativeCallCamera(
  request: SwitchNativeCallCameraRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|switchNativeCallCamera', {
    payload: request,
  });
}

export async function getNativeCallState(): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|getNativeCallState');
}

/**
 * Listens for native room snapshots. Every native change — connection state,
 * participant count, microphone/camera flips, failures (via `lastError`) —
 * arrives as one full `NativeCallSnapshot`; there are no separate event
 * kinds.
 */
export async function listenNativeCallSnapshot(
  handler: (snapshot: NativeCallSnapshot) => void
): Promise<UnlistenFn> {
  return await listen<NativeCallSnapshot>(NATIVE_CALL_EVENT, ({ payload }) => handler(payload));
}
