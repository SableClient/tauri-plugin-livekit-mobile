import { invoke } from '@tauri-apps/api/core';
import { addPluginListener, type PluginListener } from '@tauri-apps/api/core';
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
 * One TURN/STUN server entry: `urls` is an array of URLs (at least one
 * nonempty), with optional `username` and `credential`.
 */
export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/**
 * `url` is the LiveKit server URL and `token` a LiveKit access token (JWT),
 * both supplied by the host app (e.g. MatrixRTC focus negotiation). The
 * plugin never mints, refreshes, logs, or echoes the token.
 *
 * `encryptionKeys` are initial shared-E2EE keys installed by the native side
 * before `room.connect`. Omitted or empty means an ordinary unencrypted
 * LiveKit call; use `setNativeCallEncryptionKey` for later rotations.
 *
 * `iceServers` are optional TURN/STUN servers forwarded to LiveKit
 * ``ConnectOptions``. `reconnectAttempts` overrides the default count (10).
 */
export interface ConnectNativeCallRequest {
  callId: string;
  url: string;
  token: string;
  microphoneEnabled: boolean;
  encryptionKeys?: EncryptionKey[];
  iceServers?: IceServer[];
  reconnectAttempts?: number;
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
 * Positions a native-rendered local camera preview in CSS pixels. No
 * `participantIdentity`/`trackId`: the local camera is singular per room.
 */
export interface SetNativeCallLocalVideoOverlayRequest {
  callId: string;
  x: number;
  y: number;
  width: number;
  height: number;
  devicePixelRatio: number;
}

export interface ClearNativeCallLocalVideoOverlayRequest {
  callId: string;
}

/**
 * System-call (CallKit) commands. These commands are fire-and-forget from
 * the JS perspective: they resolve `void` / `null`. Only
 * `drainPendingSystemCallActions` returns data (the queued actions).
 */
export interface ReportSystemIncomingCallRequest {
  uuid: string;
  callerName: string;
}

export interface StartSystemCallRequest {
  callId: string;
  uuid: string;
  callerName: string;
}

export interface AnswerSystemCallRequest {
  callId: string;
  uuid: string;
}

export interface EndSystemCallRequest {
  callId: string;
  remoteEnded?: boolean;
}

export interface SetSystemCallMutedRequest {
  callId: string;
  muted: boolean;
}

export interface GetAudioRoutesRequest {
  callId: string;
}

export interface SetAudioRouteRequest {
  callId: string;
  routeId: string;
}

export interface SendDTMFRequest {
  callId: string;
  digits: string;
}

export interface UpdateCallDisplayRequest {
  callId: string;
  callerName: string;
  hasVideo?: boolean;
}

export interface ReportAnsweredElsewhereRequest {
  callId: string;
}

export interface ReportDeclinedElsewhereRequest {
  callId: string;
}

export interface ReportUnansweredRequest {
  callId: string;
}

export interface DeclineSystemCallRequest {
  callId: string;
  reason: string;
}

export type SystemCallActionKind = 'answer' | 'end' | 'mute';

export interface SystemCallAction {
  action: SystemCallActionKind;
  uuid: string;
  muted?: boolean;
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
  /** Bounded connection-quality string: "lost"/"poor"/"good"/"excellent";
   *  omitted when unknown. */
  connectionQuality?: string;
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
  /** Bounded connection-quality string for the local participant:
   *  "lost"/"poor"/"good"/"excellent"; omitted when unknown. */
  localConnectionQuality?: string;
}

/**
 * Wire shape for `getAudioRoutes` response: an array of audio routes plus
 * the native room snapshot.
 */
export interface GetAudioRoutesResponse {
  routes: unknown;
  receiver: NativeCallSnapshot;
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

export async function setNativeCallRemoteVideoOverlay(
  request: SetNativeCallRemoteVideoOverlayRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|setNativeCallRemoteVideoOverlay',
    { payload: request }
  );
}

export async function clearNativeCallRemoteVideoOverlay(
  request: ClearNativeCallRemoteVideoOverlayRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|clearNativeCallRemoteVideoOverlay',
    { payload: request }
  );
}

export async function setNativeCallLocalVideoOverlay(
  request: SetNativeCallLocalVideoOverlayRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|setNativeCallLocalVideoOverlay',
    { payload: request }
  );
}

export async function clearNativeCallLocalVideoOverlay(
  request: ClearNativeCallLocalVideoOverlayRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|clearNativeCallLocalVideoOverlay',
    { payload: request }
  );
}

export async function getNativeCallState(): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|getNativeCallState');
}

export async function reportSystemIncomingCall(
  request: ReportSystemIncomingCallRequest
): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|reportSystemIncomingCall', {
    payload: request,
  });
}

export async function startSystemCall(request: StartSystemCallRequest): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|startSystemCall', { payload: request });
}

export async function answerSystemCall(request: AnswerSystemCallRequest): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|answerSystemCall', { payload: request });
}

export async function endSystemCall(request: EndSystemCallRequest): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|endSystemCall', { payload: request });
}

export async function setSystemCallMuted(request: SetSystemCallMutedRequest): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|setSystemCallMuted', { payload: request });
}

export async function drainPendingSystemCallActions(): Promise<SystemCallAction[]> {
  return await invoke<SystemCallAction[]>('plugin:livekit-mobile|drainPendingSystemCallActions');
}

export async function fulfillAnswerCall(uuid: string): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|fulfillAnswerCall', { payload: { uuid } });
}

export async function fulfillEndCall(uuid: string): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|fulfillEndCall', { payload: { uuid } });
}

export async function reportSystemCallConnected(uuid: string): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|reportSystemCallConnected', { payload: { uuid } });
}

export async function getAudioRoutes(
  request: GetAudioRoutesRequest
): Promise<GetAudioRoutesResponse> {
  return await invoke<GetAudioRoutesResponse>('plugin:livekit-mobile|getAudioRoutes', {
    payload: request,
  });
}

export async function setAudioRoute(
  request: SetAudioRouteRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|setAudioRoute', {
    payload: request,
  });
}

export async function sendDTMF(request: SendDTMFRequest): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|sendDTMF', {
    payload: request,
  });
}

export async function updateCallDisplay(
  request: UpdateCallDisplayRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>('plugin:livekit-mobile|updateCallDisplay', {
    payload: request,
  });
}

export async function reportSystemCallAnsweredElsewhere(
  request: ReportAnsweredElsewhereRequest
): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|reportSystemCallAnsweredElsewhere', {
    payload: request,
  });
}

export async function reportSystemCallDeclinedElsewhere(
  request: ReportDeclinedElsewhereRequest
): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|reportSystemCallDeclinedElsewhere', {
    payload: request,
  });
}

export async function reportSystemCallUnanswered(
  request: ReportUnansweredRequest
): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|reportSystemCallUnanswered', {
    payload: request,
  });
}

export async function declineSystemCall(
  request: DeclineSystemCallRequest
): Promise<void> {
  return await invoke<void>('plugin:livekit-mobile|declineSystemCall', {
    payload: request,
  });
}

/**
 * Listens for system-call actions triggered by CallKit (answer, end, mute).
 * These arrive from the native side when the system UI (lock screen, call
 * screen) is interacted with. The listener must be registered before any
 * call starts: it's a plugin-level listener, not per-call.
 */
export async function onSystemCallAction(
  handler: (action: SystemCallAction) => void
): Promise<PluginListener> {
  return await addPluginListener('livekit-mobile', 'callkit_event', handler);
}

/**
 * Installs or rotates a shared-E2EE key for one identity in the active
 * call. Initial keys belong on `connectNativeCall` (they are installed
 * before `room.connect`); this command covers later rotations/updates.
 */
export async function setNativeCallEncryptionKey(
  request: SetNativeCallEncryptionKeyRequest
): Promise<NativeCallSnapshot> {
  return await invoke<NativeCallSnapshot>(
    'plugin:livekit-mobile|setNativeCallEncryptionKey',
    { payload: request }
  );
}

/**
 * Listens for native room snapshots. Every native change (connection state,
 * participant count, microphone/camera flips, failures via `lastError`)
 * arrives as one full `NativeCallSnapshot`; there are no separate event
 * kinds.
 */
export async function listenNativeCallSnapshot(
  handler: (snapshot: NativeCallSnapshot) => void
): Promise<UnlistenFn> {
  return await listen<NativeCallSnapshot>(NATIVE_CALL_EVENT, ({ payload }) => handler(payload));
}
