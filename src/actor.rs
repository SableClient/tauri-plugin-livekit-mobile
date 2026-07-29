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
    MobileBackend, NativeConnectCallRequest, NativeDisconnectCallRequest, NativeSetCameraRequest,
    NativeSetMicrophoneRequest, NativeSwitchCameraRequest,
};

use crate::error::{Error, Result};
#[cfg(not(mobile))]
use crate::models::NativeCallConnectionState;
use crate::models::{
    ConnectNativeCallRequest, DisconnectNativeCallRequest, NativeCallCapabilities,
    NativeCallFailureCode, NativeCallSnapshot, SetNativeCallCameraEnabledRequest,
    SetNativeCallMicrophoneEnabledRequest, SwitchNativeCallCameraRequest,
};
#[cfg(mobile)]
use crate::models::{
    NativeCallChannelEvent, NativeConnectCallFields, NativeDisconnectCallFields,
    NativeSetCameraFields, NativeSetMicrophoneFields,
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
    SwitchNativeCallCamera(
        SwitchNativeCallCameraRequest,
        oneshot::Sender<Result<NativeCallSnapshot>>,
    ),
    GetNativeCallState(String, oneshot::Sender<Result<NativeCallSnapshot>>),
}

#[cfg(any(mobile, test))]
fn connect_request_is_valid(request: &ConnectNativeCallRequest) -> bool {
    !(request.call_id.trim().is_empty()
        || request.url.trim().is_empty()
        || request.token.trim().is_empty())
}

#[cfg(any(mobile, test))]
fn call_id_is_valid(call_id: &str) -> bool {
    !call_id.trim().is_empty()
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
        participant_count: 0,
        last_error: None,
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

    pub async fn switch_native_call_camera(
        &self,
        request: SwitchNativeCallCameraRequest,
    ) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::SwitchNativeCallCamera(request, response))
            .await
    }

    pub async fn get_native_call_state(&self, caller_label: String) -> Result<NativeCallSnapshot> {
        self.send(|response| Command::GetNativeCallState(caller_label, response))
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
            Command::SwitchNativeCallCamera(request, response) => {
                self.handle_switch_native_call_camera(request, response)
                    .await
            }
            Command::GetNativeCallState(caller_label, response) => {
                self.handle_get_native_call_state(caller_label, response)
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

    #[cfg(not(mobile))]
    async fn handle_set_native_call_camera_enabled(
        &mut self,
        request: SetNativeCallCameraEnabledRequest,
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
    use super::{call_id_is_valid, connect_request_is_valid};
    use crate::models::ConnectNativeCallRequest;

    fn connect_request(call_id: &str) -> ConnectNativeCallRequest {
        ConnectNativeCallRequest {
            call_id: call_id.into(),
            url: "wss://livekit.example".into(),
            token: "jwt".into(),
            microphone_enabled: true,
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
    fn call_id_validation_rejects_empty_and_blank() {
        assert!(call_id_is_valid("call"));
        assert!(!call_id_is_valid(""));
        assert!(!call_id_is_valid("   "));
    }
}
