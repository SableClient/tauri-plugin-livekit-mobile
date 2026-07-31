//! Thin transport between the guest commands and the native room plugins.
//!
//! Only validation, time-bounded invocation forwarding, and owner-webview
//! event delivery live here; the contract itself is documented in the README.

use std::marker::PhantomData;

use tauri::{async_runtime, AppHandle, Runtime};
use tokio::sync::{mpsc, oneshot};

#[cfg(mobile)]
use tauri::{Emitter, EventTarget};

#[cfg(mobile)]
use crate::mobile::{
    MobileBackend, NativeAnswerSystemCallRequest, NativeConnectCallRequest,
    NativeDisconnectCallRequest, NativeEndSystemCallRequest, NativeFulfillAnswerCallRequest,
    NativeFulfillEndCallRequest, NativeReportConnectedRequest,
    NativeReportIncomingCallRequest, NativeSetCameraRequest, NativeSetEncryptionKeyRequest,
    NativeSetLocalVideoOverlayRequest, NativeSetMicrophoneRequest,
    NativeSetRemoteVideoOverlayRequest, NativeSetScreenShareRequest,
    NativeSetSystemCallMutedRequest,
    NativeStartSystemCallRequest, NativeSwitchCameraRequest,
    NativeGetAudioRoutesRequest, NativeSetAudioRouteRequest, NativeSendDTMFRequest,
    NativeUpdateCallDisplayRequest, NativeReportAnsweredElsewhereRequest,
    NativeReportDeclinedElsewhereRequest, NativeReportUnansweredRequest,
    NativeDeclineSystemCallRequest,
};

use crate::error::{Error, Result};
#[cfg(not(mobile))]
use crate::models::NativeCallConnectionState;
use crate::models::{
    AnswerSystemCallRequest, ClearNativeCallLocalVideoOverlayRequest,
    ClearNativeCallRemoteVideoOverlayRequest, ConnectNativeCallRequest,
    DisconnectNativeCallRequest, EndSystemCallRequest, FulfillAnswerCallRequest,
    FulfillEndCallRequest, NativeCallCapabilities,
    NativeCallFailureCode, NativeCallSnapshot, ReportConnectedRequest,
    ReportSystemIncomingCallRequest,
    SetNativeCallCameraEnabledRequest, SetNativeCallEncryptionKeyRequest,
    SetNativeCallLocalVideoOverlayRequest, SetNativeCallMicrophoneEnabledRequest,
    SetNativeCallRemoteVideoOverlayRequest, SetNativeCallScreenShareEnabledRequest, SetSystemCallMutedRequest,
    StartSystemCallRequest, SwitchNativeCallCameraRequest, SystemCallAction,
    GetAudioRoutesRequest, SetAudioRouteRequest, SendDTMFRequest,
    UpdateCallDisplayRequest, ReportAnsweredElsewhereRequest,
    ReportDeclinedElsewhereRequest, ReportUnansweredRequest,
    DeclineSystemCallRequest, GetAudioRoutesResponse,
};
#[cfg(mobile)]
use crate::models::{
    NativeAnswerSystemCallFields, NativeCallChannelEvent, NativeConnectCallFields,
    NativeDisconnectCallFields, NativeEndSystemCallFields, NativeFulfillAnswerCallFields,
    NativeFulfillEndCallFields, NativeReportConnectedFields,
    NativeReportIncomingCallFields,
    NativeSetCameraFields, NativeSetEncryptionKeyFields, NativeSetLocalVideoOverlayFields,
    NativeSetMicrophoneFields, NativeSetRemoteVideoOverlayFields,
    NativeSetScreenShareFields,
    NativeSetSystemCallMutedFields, NativeStartSystemCallFields,
    NativeGetAudioRoutesFields, NativeSetAudioRouteFields, NativeSendDTMFFields,
    NativeUpdateCallDisplayFields, NativeReportAnsweredElsewhereFields,
    NativeReportDeclinedElsewhereFields, NativeReportUnansweredFields,
    NativeDeclineSystemCallFields,
};

#[cfg(mobile)]
pub(crate) const NATIVE_CALL_EVENT: &str = "plugin:livekit-mobile://native-call-event";

pub(crate) enum Command {
    GetNativeCallCapabilities(oneshot::Sender<Result<NativeCallCapabilities>>),
    ConnectNativeCall(
        ConnectNativeCallRequest,
        String,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    DisconnectNativeCall(
        DisconnectNativeCallRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallMicrophoneEnabled(
        SetNativeCallMicrophoneEnabledRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallCameraEnabled(
        SetNativeCallCameraEnabledRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallScreenShareEnabled(
        SetNativeCallScreenShareEnabledRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SwitchNativeCallCamera(
        SwitchNativeCallCameraRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallRemoteVideoOverlay(
        SetNativeCallRemoteVideoOverlayRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    ClearNativeCallRemoteVideoOverlay(
        ClearNativeCallRemoteVideoOverlayRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallLocalVideoOverlay(
        SetNativeCallLocalVideoOverlayRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    ClearNativeCallLocalVideoOverlay(
        ClearNativeCallLocalVideoOverlayRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SetNativeCallEncryptionKey(
        SetNativeCallEncryptionKeyRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    GetNativeCallState(String, oneshot::Sender<Result<NativeCallSnapshot>>),

    // System call (CallKit) commands: resolve () or Vec<SystemCallAction>.
    ReportSystemIncomingCall(
        ReportSystemIncomingCallRequest,
        oneshot::Sender<Result<()>>,
    ),
    StartSystemCall(StartSystemCallRequest, oneshot::Sender<Result<()>>),
    AnswerSystemCall(AnswerSystemCallRequest, oneshot::Sender<Result<()>>),
    EndSystemCall(EndSystemCallRequest, oneshot::Sender<Result<()>>),
    SetSystemCallMuted(SetSystemCallMutedRequest, oneshot::Sender<Result<()>>),
    DrainPendingSystemCallActions(oneshot::Sender<Result<Vec<SystemCallAction>>>),
    FulfillAnswerCall(FulfillAnswerCallRequest, oneshot::Sender<Result<()>>),
    FulfillEndCall(FulfillEndCallRequest, oneshot::Sender<Result<()>>),
    ReportSystemCallConnected(ReportConnectedRequest, oneshot::Sender<Result<()>>),

    // Extended CallKit commands
    GetAudioRoutes(
        GetAudioRoutesRequest,
        oneshot::Sender<Result<GetAudioRoutesResponse>>,
    ),
    SetAudioRoute(
        SetAudioRouteRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    SendDTMF(SendDTMFRequest, oneshot::Sender<Result<NativeCallSnapshot>>),
    UpdateCallDisplay(
        UpdateCallDisplayRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    ReportSystemCallAnsweredElsewhere(
        ReportAnsweredElsewhereRequest,
        oneshot::Sender<Result<()>>,
    ),
    ReportSystemCallDeclinedElsewhere(
        ReportDeclinedElsewhereRequest,
        oneshot::Sender<Result<()>>,
    ),
    ReportSystemCallUnanswered(
        ReportUnansweredRequest,
        oneshot::Sender<Result<()>>,
    ),
    DeclineSystemCall(DeclineSystemCallRequest, oneshot::Sender<Result<()>>),
}

#[cfg(any(mobile, test))]
fn connect_request_is_valid(request: &ConnectNativeCallRequest) -> bool {
    !(request.call_id.trim().is_empty()
        || request.url.trim().is_empty()
        || request.token.trim().is_empty())
        && request
            .encryption_keys
            .iter()
            .all(|key| encryption_key_material_is_valid(&key.identity, &key.key))
}

/// An E2EE key is well-formed when its identity is nonblank and `key` is
/// base64 that decodes to nonempty bytes. The decoded byte length is not
/// constrained: E2EE key sizes are the native side's decision, not the
/// bridge's.
#[cfg(any(mobile, test))]
fn encryption_key_material_is_valid(identity: &str, key: &str) -> bool {
    use base64::Engine;
    !identity.trim().is_empty()
        && base64::engine::general_purpose::STANDARD
            .decode(key)
            .map(|bytes| !bytes.is_empty())
            .unwrap_or(false)
}

#[cfg(any(mobile, test))]
fn call_id_is_valid(call_id: &str) -> bool {
    !call_id.trim().is_empty()
}

#[cfg(any(mobile, test))]
fn remote_video_overlay_request_is_valid(request: &SetNativeCallRemoteVideoOverlayRequest) -> bool {
    call_id_is_valid(&request.call_id)
        && !request.participant_identity.trim().is_empty()
        && !request.track_id.trim().is_empty()
        && request.x.is_finite()
        && request.y.is_finite()
        && request.width.is_finite()
        && request.width > 0.0
        && request.height.is_finite()
        && request.height > 0.0
        && request.device_pixel_ratio.is_finite()
        && request.device_pixel_ratio > 0.0
}

#[cfg(any(mobile, test))]
fn local_video_overlay_request_is_valid(request: &SetNativeCallLocalVideoOverlayRequest) -> bool {
    call_id_is_valid(&request.call_id)
        && request.x.is_finite()
        && request.y.is_finite()
        && request.width.is_finite()
        && request.width > 0.0
        && request.height.is_finite()
        && request.height > 0.0
        && request.device_pixel_ratio.is_finite()
        && request.device_pixel_ratio > 0.0
}

#[cfg(mobile)]
fn invalid_request<T>() -> Result<T> {
    Err(Error::failure(NativeCallFailureCode::InvalidRequest))
}

#[cfg(not(mobile))]
fn unavailable<T>() -> Result<T> {
    Err(Error::failure(NativeCallFailureCode::Unavailable))
}

#[cfg(not(mobile))]
fn idle_snapshot() -> NativeCallSnapshot {
    NativeCallSnapshot {
        revision: 0,
        call_id: None,
        connection_state: NativeCallConnectionState::Idle,
        microphone_enabled: false,
        camera_enabled: false,
        screen_share_enabled: false,
        participant_count: 0,
        remote_participants: Vec::new(),
        last_error: None,
        local_connection_quality: None,
    }
}

struct Actor<R: Runtime> {
    #[cfg(not(mobile))]
    _runtime: PhantomData<fn() -> R>,
    #[cfg(mobile)]
    app: AppHandle<R>,
    commands: mpsc::Receiver<Command>,
    #[cfg(mobile)]
    internal_tx: mpsc::UnboundedSender<NativeCallChannelEvent>,
    #[cfg(mobile)]
    internal_rx: mpsc::UnboundedReceiver<NativeCallChannelEvent>,
    #[cfg(mobile)]
    mobile: MobileBackend<R>,
    /// Webview label that currently receives snapshot events.
    #[cfg(mobile)]
    owner_label: Option<String>,
}

pub struct NativeCallBridge<R: Runtime> {
    commands: mpsc::Sender<Command>,
    _runtime: PhantomData<fn() -> R>,
}

impl<R: Runtime> NativeCallBridge<R> {
    #[cfg(not(mobile))]
    pub(crate) fn new(_app: AppHandle<R>) -> Self {
        let (commands, command_rx) = mpsc::channel(32);
        async_runtime::spawn(run_actor::<R>(command_rx));
        Self {
            commands,
            _runtime: PhantomData,
        }
    }

    #[cfg(mobile)]
    pub(crate) fn new(app: AppHandle<R>, mobile: MobileBackend<R>) -> Self {
        let (commands, command_rx) = mpsc::channel(32);
        let (internal_tx, internal_rx) = mpsc::unbounded_channel();
        async_runtime::spawn(run_actor(app, command_rx, internal_tx, internal_rx, mobile));
        Self {
            commands,
            _runtime: PhantomData,
        }
    }

    async fn send<T>(
        &self,
        command: impl FnOnce(oneshot::Sender<Result<T>>) -> Command,
    ) -> Result<T> {
        let (response, result) = oneshot::channel();
        self.commands
            .send(command(response))
            .await
            .map_err(|_| Error::failure(NativeCallFailureCode::Unavailable))?;
        result
            .await
            .map_err(|_| Error::failure(NativeCallFailureCode::Unavailable))?
    }

    pub async fn get_native_call_capabilities(&self) -> Result<NativeCallCapabilities> {
        self.send(Command::GetNativeCallCapabilities).await
    }

    pub async fn connect_native_call(
        &self,
        request: ConnectNativeCallRequest,
        owner_label: String,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::ConnectNativeCall(request, owner_label, response))
            .await
    }

    pub async fn disconnect_native_call(
        &self,
        request: DisconnectNativeCallRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::DisconnectNativeCall(request, response))
            .await
    }

    pub async fn set_native_call_microphone_enabled(
        &self,
        request: SetNativeCallMicrophoneEnabledRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallMicrophoneEnabled(request, response))
            .await
    }

    pub async fn set_native_call_camera_enabled(
        &self,
        request: SetNativeCallCameraEnabledRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallCameraEnabled(request, response))
            .await
    }

    pub async fn set_native_call_screen_share_enabled(
        &self,
        request: SetNativeCallScreenShareEnabledRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallScreenShareEnabled(request, response))
            .await
    }

    pub async fn switch_native_call_camera(
        &self,
        request: SwitchNativeCallCameraRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SwitchNativeCallCamera(request, response))
            .await
    }

    pub async fn set_native_call_remote_video_overlay(
        &self,
        request: SetNativeCallRemoteVideoOverlayRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallRemoteVideoOverlay(request, response))
            .await
    }

    pub async fn clear_native_call_remote_video_overlay(
        &self,
        request: ClearNativeCallRemoteVideoOverlayRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::ClearNativeCallRemoteVideoOverlay(request, response))
            .await
    }

    pub async fn set_native_call_local_video_overlay(
        &self,
        request: SetNativeCallLocalVideoOverlayRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallLocalVideoOverlay(request, response))
            .await
    }

    pub async fn clear_native_call_local_video_overlay(
        &self,
        request: ClearNativeCallLocalVideoOverlayRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::ClearNativeCallLocalVideoOverlay(request, response))
            .await
    }

    pub async fn set_native_call_encryption_key(
        &self,
        request: SetNativeCallEncryptionKeyRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetNativeCallEncryptionKey(request, response))
            .await
    }

    pub async fn get_native_call_state(&self, caller_label: String) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::GetNativeCallState(caller_label, response))
            .await
    }

    pub async fn report_system_incoming_call(
        &self,
        request: ReportSystemIncomingCallRequest,
    ) -> Result<()> {
        self.send(|response| Command::ReportSystemIncomingCall(request, response))
            .await
    }

    pub async fn start_system_call(&self, request: StartSystemCallRequest) -> Result<()> {
        self.send(|response| Command::StartSystemCall(request, response))
            .await
    }

    pub async fn answer_system_call(&self, request: AnswerSystemCallRequest) -> Result<()> {
        self.send(|response| Command::AnswerSystemCall(request, response))
            .await
    }

    pub async fn end_system_call(&self, request: EndSystemCallRequest) -> Result<()> {
        self.send(|response| Command::EndSystemCall(request, response))
            .await
    }

    pub async fn set_system_call_muted(&self, request: SetSystemCallMutedRequest) -> Result<()> {
        self.send(|response| Command::SetSystemCallMuted(request, response))
            .await
    }

    pub async fn drain_pending_system_call_actions(&self) -> Result<Vec<SystemCallAction>> {
        self.send(Command::DrainPendingSystemCallActions).await
    }

    pub async fn fulfill_answer_call(&self, request: FulfillAnswerCallRequest) -> Result<()> {
        self.send(|response| Command::FulfillAnswerCall(request, response))
            .await
    }

    pub async fn fulfill_end_call(&self, request: FulfillEndCallRequest) -> Result<()> {
        self.send(|response| Command::FulfillEndCall(request, response))
            .await
    }

    pub async fn report_system_call_connected(
        &self,
        request: ReportConnectedRequest,
    ) -> Result<()> {
        self.send(|response| Command::ReportSystemCallConnected(request, response))
            .await
    }

    pub async fn get_audio_routes(
        &self,
        request: GetAudioRoutesRequest,
    ) -> Result<GetAudioRoutesResponse> {
        self.send(|response| Command::GetAudioRoutes(request, response))
            .await
    }

    pub async fn set_audio_route(
        &self,
        request: SetAudioRouteRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SetAudioRoute(request, response))
            .await
    }

    pub async fn send_dtmf(&self, request: SendDTMFRequest) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SendDTMF(request, response))
            .await
    }

    pub async fn update_call_display(
        &self,
        request: UpdateCallDisplayRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::UpdateCallDisplay(request, response))
            .await
    }

    pub async fn report_system_call_answered_elsewhere(
        &self,
        request: ReportAnsweredElsewhereRequest,
    ) -> Result<()> {
        self.send(|response| Command::ReportSystemCallAnsweredElsewhere(request, response))
            .await
    }

    pub async fn report_system_call_declined_elsewhere(
        &self,
        request: ReportDeclinedElsewhereRequest,
    ) -> Result<()> {
        self.send(|response| Command::ReportSystemCallDeclinedElsewhere(request, response))
            .await
    }

    pub async fn report_system_call_unanswered(
        &self,
        request: ReportUnansweredRequest,
    ) -> Result<()> {
        self.send(|response| Command::ReportSystemCallUnanswered(request, response))
            .await
    }

    pub async fn decline_system_call(
        &self,
        request: DeclineSystemCallRequest,
    ) -> Result<()> {
        self.send(|response| Command::DeclineSystemCall(request, response))
            .await
    }
}

#[cfg(not(mobile))]
async fn run_actor<R: Runtime>(commands: mpsc::Receiver<Command>) {
    let mut actor: Actor<R> = Actor {
        _runtime: PhantomData,
        commands,
    };
    while let Some(command) = actor.commands.recv().await {
        actor.handle_command(command).await;
    }
}

#[cfg(mobile)]
async fn run_actor<R: Runtime>(
    app: AppHandle<R>,
    commands: mpsc::Receiver<Command>,
    internal_tx: mpsc::UnboundedSender<NativeCallChannelEvent>,
    internal_rx: mpsc::UnboundedReceiver<NativeCallChannelEvent>,
    mobile: MobileBackend<R>,
) {
    let mut actor = Actor {
        app,
        commands,
        internal_tx,
        internal_rx,
        mobile,
        owner_label: None,
    };
    loop {
        tokio::select! {
            command = actor.commands.recv() => {
                let Some(command) = command else { break };
                actor.handle_command(command).await;
            }
            internal = actor.internal_rx.recv() => {
                let Some(internal) = internal else { break };
                actor.handle_channel_event(internal);
            }
        }
    }
}

impl<R: Runtime> Actor<R> {
    async fn handle_command(&mut self, command: Command) {
        match command {
            Command::GetNativeCallCapabilities(response) => {
                self.handle_get_native_call_capabilities(response).await
            }
            Command::ConnectNativeCall(request, owner_label, response) => {
                self.handle_connect_native_call(request, owner_label, response)
                    .await
            }
            Command::DisconnectNativeCall(request, response) => {
                self.handle_disconnect_native_call(request, response).await
            }
            Command::SetNativeCallMicrophoneEnabled(request, response) => {
                self.handle_set_native_call_microphone_enabled(request, response)
                    .await
            }
            Command::SetNativeCallCameraEnabled(request, response) => {
                self.handle_set_native_call_camera_enabled(request, response)
                    .await
            }
            Command::SetNativeCallScreenShareEnabled(request, response) => {
                self.handle_set_native_call_screen_share_enabled(request, response)
                    .await
            }
            Command::SwitchNativeCallCamera(request, response) => {
                self.handle_switch_native_call_camera(request, response)
                    .await
            }
            Command::SetNativeCallRemoteVideoOverlay(request, response) => {
                self.handle_set_native_call_remote_video_overlay(request, response)
                    .await
            }
            Command::ClearNativeCallRemoteVideoOverlay(request, response) => {
                self.handle_clear_native_call_remote_video_overlay(request, response)
                    .await
            }
            Command::SetNativeCallLocalVideoOverlay(request, response) => {
                self.handle_set_native_call_local_video_overlay(request, response)
                    .await
            }
            Command::ClearNativeCallLocalVideoOverlay(request, response) => {
                self.handle_clear_native_call_local_video_overlay(request, response)
                    .await
            }
            Command::SetNativeCallEncryptionKey(request, response) => {
                self.handle_set_native_call_encryption_key(request, response)
                    .await
            }
            Command::GetNativeCallState(caller_label, response) => {
                self.handle_get_native_call_state(caller_label, response)
                    .await
            }
            Command::ReportSystemIncomingCall(request, response) => {
                self.handle_report_system_incoming_call(request, response)
                    .await
            }
            Command::StartSystemCall(request, response) => {
                self.handle_start_system_call(request, response)
                    .await
            }
            Command::AnswerSystemCall(request, response) => {
                self.handle_answer_system_call(request, response)
                    .await
            }
            Command::EndSystemCall(request, response) => {
                self.handle_end_system_call(request, response)
                    .await
            }
            Command::SetSystemCallMuted(request, response) => {
                self.handle_set_system_call_muted(request, response)
                    .await
            }
            Command::DrainPendingSystemCallActions(response) => {
                self.handle_drain_pending_system_call_actions(response)
                    .await
            }
            Command::FulfillAnswerCall(request, response) => {
                self.handle_fulfill_answer_call(request, response)
                    .await
            }
            Command::FulfillEndCall(request, response) => {
                self.handle_fulfill_end_call(request, response)
                    .await
            }
            Command::ReportSystemCallConnected(request, response) => {
                self.handle_report_system_call_connected(request, response)
                    .await
            }
            Command::GetAudioRoutes(request, response) => {
                self.handle_get_audio_routes(request, response)
                    .await
            }
            Command::SetAudioRoute(request, response) => {
                self.handle_set_audio_route(request, response)
                    .await
            }
            Command::SendDTMF(request, response) => {
                self.handle_send_dtmf(request, response)
                    .await
            }
            Command::UpdateCallDisplay(request, response) => {
                self.handle_update_call_display(request, response)
                    .await
            }
            Command::ReportSystemCallAnsweredElsewhere(request, response) => {
                self.handle_report_system_call_answered_elsewhere(request, response)
                    .await
            }
            Command::ReportSystemCallDeclinedElsewhere(request, response) => {
                self.handle_report_system_call_declined_elsewhere(request, response)
                    .await
            }
            Command::ReportSystemCallUnanswered(request, response) => {
                self.handle_report_system_call_unanswered(request, response)
                    .await
            }
            Command::DeclineSystemCall(request, response) => {
                self.handle_decline_system_call(request, response)
                    .await
            }
        }
    }

    async fn handle_get_native_call_capabilities(
        &mut self,
        response: oneshot::Sender<Result<NativeCallCapabilities>>,
    ) {
        #[cfg(mobile)]
        let result = self.mobile.get_native_call_capabilities().await;
        #[cfg(not(mobile))]
        let result = Ok(NativeCallCapabilities::current());

        let _ = response.send(result);
    }

    #[cfg(mobile)]
    async fn handle_connect_native_call(
        &mut self,
        request: ConnectNativeCallRequest,
        owner_label: String,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !connect_request_is_valid(&request) {
            let _ = response.send(invalid_request());
            return;
        }

        // The channel hands snapshot events directly to the actor queue; the
        // sender half outlives this handler inside the native invoke payload.
        let channel = MobileBackend::<R>::native_call_event_channel(self.internal_tx.clone());
        let result = self
            .mobile
            .connect_native_call(NativeConnectCallRequest {
                fields: NativeConnectCallFields {
                    call_id: &request.call_id,
                    url: &request.url,
                    token: &request.token,
                    microphone_enabled: request.microphone_enabled,
                    encryption_keys: &request.encryption_keys,
                    ice_servers: request.ice_servers.as_deref(),
                    reconnect_attempts: request.reconnect_attempts,
                },
                channel,
            })
            .await;

        let result = match result {
            Ok(snapshot) => Ok(snapshot),
            Err(Error::Timeout) => {
                // Timeout recovery: the native connect may still be resolving,
                // so cancel it natively and reconcile against the native-truth
                // snapshot instead of just abandoning the channel (which would
                // orphan a room that survives cancellation from its events).
                let _ = self
                    .mobile
                    .cancel_native_call_connect(NativeDisconnectCallRequest {
                        fields: NativeDisconnectCallFields {
                            call_id: &request.call_id,
                        },
                    })
                    .await;
                match self.mobile.get_native_call_state().await {
                    Ok(snapshot) => Ok(snapshot),
                    Err(_) => Err(Error::Timeout),
                }
            }
            Err(error) => Err(error),
        };

        match result {
            Ok(snapshot) => {
                if snapshot.is_live() {
                    self.owner_label = Some(owner_label);
                }
                let _ = response.send(Ok(snapshot));
            }
            Err(Error::Timeout) => {
                // Native state stayed unknown; keep ownership so a still
                // running room keeps delivering events.
                self.owner_label = Some(owner_label);
                let _ = response.send(Err(Error::Timeout));
            }
            Err(error) => {
                let _ = response.send(Err(error));
            }
        }
    }

    #[cfg(not(mobile))]
    async fn handle_connect_native_call(
        &mut self,
        request: ConnectNativeCallRequest,
        owner_label: String,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = (&request, &owner_label);
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_disconnect_native_call(
        &mut self,
        request: DisconnectNativeCallRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .disconnect_native_call(NativeDisconnectCallRequest {
                fields: NativeDisconnectCallFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        if matches!(&result, Ok(snapshot) if !snapshot.is_live()) {
            self.owner_label = None;
        }
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_disconnect_native_call(
        &mut self,
        request: DisconnectNativeCallRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_microphone_enabled(
        &mut self,
        request: SetNativeCallMicrophoneEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_microphone_enabled(NativeSetMicrophoneRequest {
                fields: NativeSetMicrophoneFields {
                    call_id: &request.call_id,
                    enabled: request.enabled,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_microphone_enabled(
        &mut self,
        request: SetNativeCallMicrophoneEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_camera_enabled(
        &mut self,
        request: SetNativeCallCameraEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_camera_enabled(NativeSetCameraRequest {
                fields: NativeSetCameraFields {
                    call_id: &request.call_id,
                    enabled: request.enabled,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_screen_share_enabled(
        &mut self,
        request: SetNativeCallScreenShareEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_screen_share_enabled(NativeSetScreenShareRequest {
                fields: NativeSetScreenShareFields {
                    call_id: &request.call_id,
                    enabled: request.enabled,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_camera_enabled(
        &mut self,
        request: SetNativeCallCameraEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_screen_share_enabled(
        &mut self,
        request: SetNativeCallScreenShareEnabledRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_switch_native_call_camera(
        &mut self,
        request: SwitchNativeCallCameraRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .switch_native_call_camera(NativeSwitchCameraRequest {
                fields: NativeDisconnectCallFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_remote_video_overlay(
        &mut self,
        request: SetNativeCallRemoteVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !remote_video_overlay_request_is_valid(&request) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_remote_video_overlay(NativeSetRemoteVideoOverlayRequest {
                fields: NativeSetRemoteVideoOverlayFields {
                    call_id: &request.call_id,
                    participant_identity: &request.participant_identity,
                    track_id: &request.track_id,
                    x: request.x,
                    y: request.y,
                    width: request.width,
                    height: request.height,
                    device_pixel_ratio: request.device_pixel_ratio,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_remote_video_overlay(
        &mut self,
        request: SetNativeCallRemoteVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_clear_native_call_remote_video_overlay(
        &mut self,
        request: ClearNativeCallRemoteVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .clear_native_call_remote_video_overlay(NativeDisconnectCallRequest {
                fields: NativeDisconnectCallFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_clear_native_call_remote_video_overlay(
        &mut self,
        request: ClearNativeCallRemoteVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_local_video_overlay(
        &mut self,
        request: SetNativeCallLocalVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !local_video_overlay_request_is_valid(&request) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_local_video_overlay(NativeSetLocalVideoOverlayRequest {
                fields: NativeSetLocalVideoOverlayFields {
                    call_id: &request.call_id,
                    x: request.x,
                    y: request.y,
                    width: request.width,
                    height: request.height,
                    device_pixel_ratio: request.device_pixel_ratio,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_local_video_overlay(
        &mut self,
        request: SetNativeCallLocalVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_clear_native_call_local_video_overlay(
        &mut self,
        request: ClearNativeCallLocalVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .clear_native_call_local_video_overlay(NativeDisconnectCallRequest {
                fields: NativeDisconnectCallFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_clear_native_call_local_video_overlay(
        &mut self,
        request: ClearNativeCallLocalVideoOverlayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_native_call_encryption_key(
        &mut self,
        request: SetNativeCallEncryptionKeyRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id)
            || !encryption_key_material_is_valid(&request.identity, &request.key)
        {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_native_call_encryption_key(NativeSetEncryptionKeyRequest {
                fields: NativeSetEncryptionKeyFields {
                    call_id: &request.call_id,
                    identity: &request.identity,
                    key_index: request.key_index,
                    key: &request.key,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_native_call_encryption_key(
        &mut self,
        request: SetNativeCallEncryptionKeyRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(not(mobile))]
    async fn handle_switch_native_call_camera(
        &mut self,
        request: SwitchNativeCallCameraRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    async fn handle_get_native_call_state(
        &mut self,
        caller_label: String,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        #[cfg(mobile)]
        let result = {
            let result = self.mobile.get_native_call_state().await;
            if let Ok(snapshot) = &result {
                // Ownership reclaim: the first webview to query an unowned
                // live room (e.g. after its owner webview was destroyed)
                // becomes the new event owner.
                if snapshot.is_live() && self.owner_label.is_none() && !caller_label.is_empty() {
                    self.owner_label = Some(caller_label.clone());
                }
            }
            result
        };
        #[cfg(not(mobile))]
        let result = {
            let _ = &caller_label;
            Ok(idle_snapshot())
        };

        let _ = response.send(result);
    }

    // MARK: System call (CallKit) handlers

    #[cfg(mobile)]
    async fn handle_report_system_incoming_call(
        &mut self,
        request: ReportSystemIncomingCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.uuid.trim().is_empty() || request.caller_name.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .report_system_incoming_call(NativeReportIncomingCallRequest {
                fields: NativeReportIncomingCallFields {
                    uuid: &request.uuid,
                    caller_name: &request.caller_name,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_report_system_incoming_call(
        &mut self,
        request: ReportSystemIncomingCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_start_system_call(
        &mut self,
        request: StartSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.call_id.trim().is_empty()
            || request.uuid.trim().is_empty()
            || request.caller_name.trim().is_empty()
        {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .start_system_call(NativeStartSystemCallRequest {
                fields: NativeStartSystemCallFields {
                    call_id: &request.call_id,
                    uuid: &request.uuid,
                    caller_name: &request.caller_name,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_start_system_call(
        &mut self,
        request: StartSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_answer_system_call(
        &mut self,
        request: AnswerSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.call_id.trim().is_empty() || request.uuid.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .answer_system_call(NativeAnswerSystemCallRequest {
                fields: NativeAnswerSystemCallFields {
                    call_id: &request.call_id,
                    uuid: &request.uuid,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_answer_system_call(
        &mut self,
        request: AnswerSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_end_system_call(
        &mut self,
        request: EndSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.call_id.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .end_system_call(NativeEndSystemCallRequest {
                fields: NativeEndSystemCallFields {
                    call_id: &request.call_id,
                    remote_ended: request.remote_ended,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_end_system_call(
        &mut self,
        request: EndSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_system_call_muted(
        &mut self,
        request: SetSystemCallMutedRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.call_id.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_system_call_muted(NativeSetSystemCallMutedRequest {
                fields: NativeSetSystemCallMutedFields {
                    call_id: &request.call_id,
                    muted: request.muted,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_set_system_call_muted(
        &mut self,
        request: SetSystemCallMutedRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_drain_pending_system_call_actions(
        &mut self,
        response: oneshot::Sender<Result<Vec<SystemCallAction>>>,
    ) {
        let result = self.mobile.drain_pending_system_call_actions().await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_drain_pending_system_call_actions(
        &mut self,
        response: oneshot::Sender<Result<Vec<SystemCallAction>>>,
    ) {
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_fulfill_answer_call(
        &mut self,
        request: FulfillAnswerCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.uuid.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .fulfill_answer_call(NativeFulfillAnswerCallRequest {
                fields: NativeFulfillAnswerCallFields {
                    uuid: &request.uuid,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_fulfill_answer_call(
        &mut self,
        request: FulfillAnswerCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_fulfill_end_call(
        &mut self,
        request: FulfillEndCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.uuid.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .fulfill_end_call(NativeFulfillEndCallRequest {
                fields: NativeFulfillEndCallFields {
                    uuid: &request.uuid,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_fulfill_end_call(
        &mut self,
        request: FulfillEndCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_report_system_call_connected(
        &mut self,
        request: ReportConnectedRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if request.uuid.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .report_connected(NativeReportConnectedRequest {
                fields: NativeReportConnectedFields {
                    uuid: &request.uuid,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_report_system_call_connected(
        &mut self,
        request: ReportConnectedRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    // MARK: Extended CallKit handlers

    #[cfg(mobile)]
    async fn handle_get_audio_routes(
        &mut self,
        request: GetAudioRoutesRequest,
        response: oneshot::Sender<Result<GetAudioRoutesResponse>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .get_audio_routes(NativeGetAudioRoutesRequest {
                fields: NativeGetAudioRoutesFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_get_audio_routes(
        &mut self,
        request: GetAudioRoutesRequest,
        response: oneshot::Sender<Result<GetAudioRoutesResponse>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_set_audio_route(
        &mut self,
        request: SetAudioRouteRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) || request.route_id.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .set_audio_route(NativeSetAudioRouteRequest {
                fields: NativeSetAudioRouteFields {
                    call_id: &request.call_id,
                    route_id: &request.route_id,
                },
            })
            .await;
        let _ = response.send(result.map(|r| r.receiver));
    }

    #[cfg(not(mobile))]
    async fn handle_set_audio_route(
        &mut self,
        request: SetAudioRouteRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_send_dtmf(
        &mut self,
        request: SendDTMFRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) || request.digits.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .send_dtmf(NativeSendDTMFRequest {
                fields: NativeSendDTMFFields {
                    call_id: &request.call_id,
                    digits: &request.digits,
                },
            })
            .await;
        let _ = response.send(result.map(|r| r.receiver));
    }

    #[cfg(not(mobile))]
    async fn handle_send_dtmf(
        &mut self,
        request: SendDTMFRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_update_call_display(
        &mut self,
        request: UpdateCallDisplayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        if !call_id_is_valid(&request.call_id) || request.caller_name.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .update_call_display(NativeUpdateCallDisplayRequest {
                fields: NativeUpdateCallDisplayFields {
                    call_id: &request.call_id,
                    caller_name: &request.caller_name,
                    has_video: request.has_video,
                },
            })
            .await;
        let _ = response.send(result.map(|r| r.receiver));
    }

    #[cfg(not(mobile))]
    async fn handle_update_call_display(
        &mut self,
        request: UpdateCallDisplayRequest,
        response: oneshot::Sender<Result<NativeCallSnapshot>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_report_system_call_answered_elsewhere(
        &mut self,
        request: ReportAnsweredElsewhereRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .report_system_call_answered_elsewhere(NativeReportAnsweredElsewhereRequest {
                fields: NativeReportAnsweredElsewhereFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_report_system_call_answered_elsewhere(
        &mut self,
        request: ReportAnsweredElsewhereRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_report_system_call_declined_elsewhere(
        &mut self,
        request: ReportDeclinedElsewhereRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .report_system_call_declined_elsewhere(NativeReportDeclinedElsewhereRequest {
                fields: NativeReportDeclinedElsewhereFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_report_system_call_declined_elsewhere(
        &mut self,
        request: ReportDeclinedElsewhereRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_report_system_call_unanswered(
        &mut self,
        request: ReportUnansweredRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if !call_id_is_valid(&request.call_id) {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .report_system_call_unanswered(NativeReportUnansweredRequest {
                fields: NativeReportUnansweredFields {
                    call_id: &request.call_id,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_report_system_call_unanswered(
        &mut self,
        request: ReportUnansweredRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    async fn handle_decline_system_call(
        &mut self,
        request: DeclineSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        if !call_id_is_valid(&request.call_id) || request.reason.trim().is_empty() {
            let _ = response.send(invalid_request());
            return;
        }
        let result = self
            .mobile
            .decline_system_call(NativeDeclineSystemCallRequest {
                fields: NativeDeclineSystemCallFields {
                    call_id: &request.call_id,
                    reason: &request.reason,
                },
            })
            .await;
        let _ = response.send(result);
    }

    #[cfg(not(mobile))]
    async fn handle_decline_system_call(
        &mut self,
        request: DeclineSystemCallRequest,
        response: oneshot::Sender<Result<()>>,
    ) {
        let _ = &request;
        let _ = response.send(unavailable());
    }

    #[cfg(mobile)]
    fn handle_channel_event(&mut self, event: NativeCallChannelEvent) {
        match event {
            NativeCallChannelEvent::SnapshotChanged { snapshot } => {
                // Targeted delivery: only the owner webview receives
                // snapshots; nothing is broadcast.
                let Some(label) = self.owner_label.clone() else {
                    return;
                };
                let live = snapshot.is_live();
                let _ = self
                    .app
                    .emit_to(EventTarget::webview(label), NATIVE_CALL_EVENT, snapshot);
                if !live {
                    self.owner_label = None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        call_id_is_valid, connect_request_is_valid, encryption_key_material_is_valid,
        local_video_overlay_request_is_valid, remote_video_overlay_request_is_valid,
    };
    use crate::models::{
        ConnectNativeCallRequest, EncryptionKey, SetNativeCallLocalVideoOverlayRequest,
        SetNativeCallRemoteVideoOverlayRequest,
    };

    fn connect_request(call_id: &str) -> ConnectNativeCallRequest {
        ConnectNativeCallRequest {
            call_id: call_id.into(),
            url: "wss://livekit.example".into(),
            token: "jwt".into(),
            microphone_enabled: true,
            encryption_keys: Vec::new(),
            ice_servers: None,
            reconnect_attempts: None,
        }
    }

    #[test]
    fn connect_validation_requires_nonempty_fields() {
        assert!(connect_request_is_valid(&connect_request("call")));

        assert!(!connect_request_is_valid(&connect_request(" ")));
        let mut blank_url = connect_request("call");
        blank_url.url = String::new();
        assert!(!connect_request_is_valid(&blank_url));
        let mut blank_token = connect_request("call");
        blank_token.token = "  ".into();
        assert!(!connect_request_is_valid(&blank_token));
    }

    #[test]
    fn encryption_key_material_validation() {
        // "secret" padded and "other" unpadded-well-formed base64.
        assert!(encryption_key_material_is_valid("@alice:e.org", "c2VjcmV0"));
        assert!(!encryption_key_material_is_valid(" ", "c2VjcmV0"));
        assert!(!encryption_key_material_is_valid("@alice:e.org", ""));
        assert!(!encryption_key_material_is_valid("@alice:e.org", "   "));
        assert!(!encryption_key_material_is_valid(
            "@alice:e.org",
            "not base64!!"
        ));
        // Wrong padding / truncated input is rejected.
        assert!(!encryption_key_material_is_valid(
            "@alice:e.org",
            "c2VjcmV="
        ));
    }

    #[test]
    fn connect_validation_rejects_invalid_encryption_keys() {
        let mut request = connect_request("call");
        request.encryption_keys = vec![
            EncryptionKey {
                identity: "@alice:e.org".into(),
                key_index: 0,
                key: "c2VjcmV0".into(),
            },
            EncryptionKey {
                identity: "@bob:e.org".into(),
                key_index: 1,
                key: "b3RoZXI=".into(),
            },
        ];
        assert!(connect_request_is_valid(&request));

        request.encryption_keys[1].key = "!!!".into();
        assert!(!connect_request_is_valid(&request));
        request.encryption_keys[1].key = "b3RoZXI=".into();
        request.encryption_keys[0].identity = "  ".into();
        assert!(!connect_request_is_valid(&request));
    }

    #[test]
    fn call_id_validation_rejects_empty_and_blank() {
        assert!(call_id_is_valid("call"));
        assert!(!call_id_is_valid(""));
        assert!(!call_id_is_valid("   "));
    }

    #[test]
    fn remote_video_overlay_validation_requires_identifiers_and_valid_geometry() {
        let request = SetNativeCallRemoteVideoOverlayRequest {
            call_id: "call".into(),
            participant_identity: "@alice:example.org".into(),
            track_id: "TR_abcdef".into(),
            x: -120.0,
            y: -50.0,
            width: 320.0,
            height: 180.0,
            device_pixel_ratio: 2.0,
        };
        assert!(remote_video_overlay_request_is_valid(&request));

        for invalid in [f64::NAN, f64::INFINITY, 0.0, -1.0] {
            let mut invalid_request = request.clone();
            invalid_request.width = invalid;
            assert!(!remote_video_overlay_request_is_valid(&invalid_request));
        }
        let mut invalid_x = request.clone();
        invalid_x.x = f64::NAN;
        assert!(!remote_video_overlay_request_is_valid(&invalid_x));
        let mut invalid_y = request.clone();
        invalid_y.y = f64::INFINITY;
        assert!(!remote_video_overlay_request_is_valid(&invalid_y));
        let mut invalid_height = request.clone();
        invalid_height.height = 0.0;
        assert!(!remote_video_overlay_request_is_valid(&invalid_height));
        let mut invalid_dpr = request.clone();
        invalid_dpr.device_pixel_ratio = 0.0;
        assert!(!remote_video_overlay_request_is_valid(&invalid_dpr));
        let mut blank_track = request;
        blank_track.track_id = " ".into();
        assert!(!remote_video_overlay_request_is_valid(&blank_track));
    }

    #[test]
    fn local_video_overlay_validation_requires_valid_geometry_and_call_id() {
        let request = SetNativeCallLocalVideoOverlayRequest {
            call_id: "call".into(),
            x: -120.0,
            y: -50.0,
            width: 320.0,
            height: 180.0,
            device_pixel_ratio: 2.0,
        };
        assert!(local_video_overlay_request_is_valid(&request));

        for invalid in [f64::NAN, f64::INFINITY, 0.0, -1.0] {
            let mut invalid_request = request.clone();
            invalid_request.width = invalid;
            assert!(!local_video_overlay_request_is_valid(&invalid_request));
        }
        let mut invalid_x = request.clone();
        invalid_x.x = f64::NAN;
        assert!(!local_video_overlay_request_is_valid(&invalid_x));
        let mut invalid_y = request.clone();
        invalid_y.y = f64::INFINITY;
        assert!(!local_video_overlay_request_is_valid(&invalid_y));
        let mut invalid_dpr = request.clone();
        invalid_dpr.device_pixel_ratio = 0.0;
        assert!(!local_video_overlay_request_is_valid(&invalid_dpr));
        let mut blank_call = request;
        blank_call.call_id = " ".into();
        assert!(!local_video_overlay_request_is_valid(&blank_call));
    }

    #[cfg(not(mobile))]
    #[test]
    fn desktop_idle_snapshot_has_empty_room_projection() {
        let idle = super::idle_snapshot();
        assert_eq!(idle.revision, 0);
        assert_eq!(idle.call_id, None);
        assert_eq!(idle.remote_participants, Vec::new());
        assert!(!idle.is_live());
    }
}
