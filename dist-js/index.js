import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

/**
 * Snapshots are delivered only to the webview that connected (or reclaimed)
 * the call: a `listen` on this name in any other webview stays silent.
 */
const NATIVE_CALL_EVENT = 'plugin:livekit-mobile://native-call-event';
async function getNativeCallCapabilities() {
    return await invoke('plugin:livekit-mobile|getNativeCallCapabilities');
}
async function connectNativeCall(request) {
    return await invoke('plugin:livekit-mobile|connectNativeCall', {
        payload: request,
    });
}
async function disconnectNativeCall(request) {
    return await invoke('plugin:livekit-mobile|disconnectNativeCall', {
        payload: request,
    });
}
async function setNativeCallMicrophoneEnabled(request) {
    return await invoke('plugin:livekit-mobile|setNativeCallMicrophoneEnabled', { payload: request });
}
async function setNativeCallCameraEnabled(request) {
    return await invoke('plugin:livekit-mobile|setNativeCallCameraEnabled', {
        payload: request,
    });
}
async function switchNativeCallCamera(request) {
    return await invoke('plugin:livekit-mobile|switchNativeCallCamera', {
        payload: request,
    });
}
async function setNativeCallRemoteVideoOverlay(request) {
    return await invoke('plugin:livekit-mobile|setNativeCallRemoteVideoOverlay', { payload: request });
}
async function clearNativeCallRemoteVideoOverlay(request) {
    return await invoke('plugin:livekit-mobile|clearNativeCallRemoteVideoOverlay', { payload: request });
}
async function getNativeCallState() {
    return await invoke('plugin:livekit-mobile|getNativeCallState');
}
/**
 * Installs or rotates a shared-E2EE key for one identity in the active
 * call. Initial keys belong on `connectNativeCall` (they are installed
 * before `room.connect`); this command covers later rotations/updates.
 */
async function setNativeCallEncryptionKey(request) {
    return await invoke('plugin:livekit-mobile|setNativeCallEncryptionKey', { payload: request });
}
/**
 * Listens for native room snapshots. Every native change (connection state,
 * participant count, microphone/camera flips, failures via `lastError`)
 * arrives as one full `NativeCallSnapshot`; there are no separate event
 * kinds.
 */
async function listenNativeCallSnapshot(handler) {
    return await listen(NATIVE_CALL_EVENT, ({ payload }) => handler(payload));
}

export { NATIVE_CALL_EVENT, clearNativeCallRemoteVideoOverlay, connectNativeCall, disconnectNativeCall, getNativeCallCapabilities, getNativeCallState, listenNativeCallSnapshot, setNativeCallCameraEnabled, setNativeCallEncryptionKey, setNativeCallMicrophoneEnabled, setNativeCallRemoteVideoOverlay, switchNativeCallCamera };
