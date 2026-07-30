'use strict';

var core = require('@tauri-apps/api/core');
var event = require('@tauri-apps/api/event');

/**
 * Snapshots are delivered only to the webview that connected (or reclaimed)
 * the call: a `listen` on this name in any other webview stays silent.
 */
const NATIVE_CALL_EVENT = 'plugin:livekit-mobile://native-call-event';
async function getNativeCallCapabilities() {
    return await core.invoke('plugin:livekit-mobile|getNativeCallCapabilities');
}
async function connectNativeCall(request) {
    return await core.invoke('plugin:livekit-mobile|connectNativeCall', {
        payload: request,
    });
}
async function disconnectNativeCall(request) {
    return await core.invoke('plugin:livekit-mobile|disconnectNativeCall', {
        payload: request,
    });
}
async function setNativeCallMicrophoneEnabled(request) {
    return await core.invoke('plugin:livekit-mobile|setNativeCallMicrophoneEnabled', { payload: request });
}
async function setNativeCallCameraEnabled(request) {
    return await core.invoke('plugin:livekit-mobile|setNativeCallCameraEnabled', {
        payload: request,
    });
}
async function switchNativeCallCamera(request) {
    return await core.invoke('plugin:livekit-mobile|switchNativeCallCamera', {
        payload: request,
    });
}
async function setNativeCallRemoteVideoOverlay(request) {
    return await core.invoke('plugin:livekit-mobile|setNativeCallRemoteVideoOverlay', { payload: request });
}
async function clearNativeCallRemoteVideoOverlay(request) {
    return await core.invoke('plugin:livekit-mobile|clearNativeCallRemoteVideoOverlay', { payload: request });
}
async function getNativeCallState() {
    return await core.invoke('plugin:livekit-mobile|getNativeCallState');
}
/**
 * Listens for native room snapshots. Every native change — connection state,
 * participant count, microphone/camera flips, failures (via `lastError`) —
 * arrives as one full `NativeCallSnapshot`; there are no separate event
 * kinds.
 */
async function listenNativeCallSnapshot(handler) {
    return await event.listen(NATIVE_CALL_EVENT, ({ payload }) => handler(payload));
}

exports.NATIVE_CALL_EVENT = NATIVE_CALL_EVENT;
exports.clearNativeCallRemoteVideoOverlay = clearNativeCallRemoteVideoOverlay;
exports.connectNativeCall = connectNativeCall;
exports.disconnectNativeCall = disconnectNativeCall;
exports.getNativeCallCapabilities = getNativeCallCapabilities;
exports.getNativeCallState = getNativeCallState;
exports.listenNativeCallSnapshot = listenNativeCallSnapshot;
exports.setNativeCallCameraEnabled = setNativeCallCameraEnabled;
exports.setNativeCallMicrophoneEnabled = setNativeCallMicrophoneEnabled;
exports.setNativeCallRemoteVideoOverlay = setNativeCallRemoteVideoOverlay;
exports.switchNativeCallCamera = switchNativeCallCamera;
