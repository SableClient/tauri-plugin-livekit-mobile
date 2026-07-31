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
pub(crate) async fn setNativeCallScreenShareEnabled<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallScreenShareEnabledRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_screen_share_enabled(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setNativeCallPiPEnabled<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallPiPEnabledRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_pip_enabled(payload)
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
pub(crate) async fn setNativeCallRemoteVideoOverlay<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallRemoteVideoOverlayRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_remote_video_overlay(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn clearNativeCallRemoteVideoOverlay<R: Runtime>(
    app: AppHandle<R>,
    payload: ClearNativeCallRemoteVideoOverlayRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .clear_native_call_remote_video_overlay(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setNativeCallLocalVideoOverlay<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallLocalVideoOverlayRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_local_video_overlay(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn clearNativeCallLocalVideoOverlay<R: Runtime>(
    app: AppHandle<R>,
    payload: ClearNativeCallLocalVideoOverlayRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .clear_native_call_local_video_overlay(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setNativeCallEncryptionKey<R: Runtime>(
    app: AppHandle<R>,
    payload: SetNativeCallEncryptionKeyRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_native_call_encryption_key(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn reportSystemIncomingCall<R: Runtime>(
    app: AppHandle<R>,
    payload: ReportSystemIncomingCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .report_system_incoming_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn startSystemCall<R: Runtime>(
    app: AppHandle<R>,
    payload: StartSystemCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .start_system_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn answerSystemCall<R: Runtime>(
    app: AppHandle<R>,
    payload: AnswerSystemCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .answer_system_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn endSystemCall<R: Runtime>(
    app: AppHandle<R>,
    payload: EndSystemCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .end_system_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setSystemCallMuted<R: Runtime>(
    app: AppHandle<R>,
    payload: SetSystemCallMutedRequest,
) -> Result<()> {
    app.native_call_bridge()
        .set_system_call_muted(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn drainPendingSystemCallActions<R: Runtime>(
    app: AppHandle<R>,
) -> Result<Vec<SystemCallAction>> {
    app.native_call_bridge()
        .drain_pending_system_call_actions()
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn fulfillAnswerCall<R: Runtime>(
    app: AppHandle<R>,
    payload: FulfillAnswerCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .fulfill_answer_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn fulfillEndCall<R: Runtime>(
    app: AppHandle<R>,
    payload: FulfillEndCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .fulfill_end_call(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn reportSystemCallConnected<R: Runtime>(
    app: AppHandle<R>,
    payload: ReportConnectedRequest,
) -> Result<()> {
    app.native_call_bridge()
        .report_system_call_connected(payload)
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

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn getAudioRoutes<R: Runtime>(
    app: AppHandle<R>,
    payload: GetAudioRoutesRequest,
) -> Result<GetAudioRoutesResponse> {
    app.native_call_bridge()
        .get_audio_routes(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn setAudioRoute<R: Runtime>(
    app: AppHandle<R>,
    payload: SetAudioRouteRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .set_audio_route(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn sendDTMF<R: Runtime>(
    app: AppHandle<R>,
    payload: SendDTMFRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .send_dtmf(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn updateCallDisplay<R: Runtime>(
    app: AppHandle<R>,
    payload: UpdateCallDisplayRequest,
) -> Result<NativeCallSnapshot> {
    app.native_call_bridge()
        .update_call_display(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn reportSystemCallAnsweredElsewhere<R: Runtime>(
    app: AppHandle<R>,
    payload: ReportAnsweredElsewhereRequest,
) -> Result<()> {
    app.native_call_bridge()
        .report_system_call_answered_elsewhere(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn reportSystemCallDeclinedElsewhere<R: Runtime>(
    app: AppHandle<R>,
    payload: ReportDeclinedElsewhereRequest,
) -> Result<()> {
    app.native_call_bridge()
        .report_system_call_declined_elsewhere(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn reportSystemCallUnanswered<R: Runtime>(
    app: AppHandle<R>,
    payload: ReportUnansweredRequest,
) -> Result<()> {
    app.native_call_bridge()
        .report_system_call_unanswered(payload)
        .await
}

#[allow(non_snake_case)]
#[tauri_command]
pub(crate) async fn declineSystemCall<R: Runtime>(
    app: AppHandle<R>,
    payload: DeclineSystemCallRequest,
) -> Result<()> {
    app.native_call_bridge()
        .decline_system_call(payload)
        .await
}
