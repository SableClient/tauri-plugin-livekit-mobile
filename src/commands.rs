// The attribute is aliased to `tauri_command` on purpose: tauri-typegen scans
// every .rs file under `src-tauri/` and treats a bare `#[command]` attribute as
// a root command, which would emit unusable unprefixed root bindings for these
// namespaced plugin commands that the guest-js API already exposes.
use tauri::{command as tauri_command, AppHandle, Runtime, Webview};

use crate::models::*;
use crate::NativeCallExt;
use crate::Result;

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn getNativeCallCapabilities<R: Runtime>(
    app: AppHandle<R>,
) -> Result<NativeCallCapabilities> {
    app.native_call_bridge()
        .get_native_call_capabilities()
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn connectNativeCall<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
    payload: ConnectNativeCallRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .connect_native_call(payload, webview.label().to_string())
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn disconnectNativeCall<R: Runtime>(
    app: AppHandle<R>,
    payload: DisconnectNativeCallRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .disconnect_native_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setNativeCallMicrophoneEnabled<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallMicrophoneEnabledRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_microphone_enabled(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setNativeCallCameraEnabled<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallCameraEnabledRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_camera_enabled(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn switchNativeCallCamera<R: Runtime>(
    app: AppHandle<R>,
    payload: SwitchNativeCallCameraRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .switch_native_call_camera(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn getNativeCallState<R: Runtime>(
    app: AppHandle<R>,
    webview: Webview<R>,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .get_native_call_state(webview.label().to_string())
        .await
}
