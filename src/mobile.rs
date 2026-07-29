use std::time::Duration;

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tauri::{
    ipc::{Channel, InvokeResponseBody},
    plugin::{mobile::PluginInvokeError, PluginApi, PluginHandle},
    AppHandle, Runtime,
};
use tokio::sync::mpsc;

use crate::{
    error::Error,
    models::{
        failure_code_from_raw, NativeCallCapabilities, NativeCallChannelEvent,
        NativeCallFailureCode, NativeCallSnapshot, NativeConnectCallFields,
        NativeDisconnectCallFields, NativeSetCameraFields, NativeSetMicrophoneFields,
    },
};

#[cfg(target_os = "android")]
const PLUGIN_IDENTIFIER: &str = "app.tauri.livekit_mobile";

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_livekit_mobile);

#[cfg(target_os = "android")]
mod platform_commands {
    pub(super) const CAPABILITIES: &str = "getNativeCallCapabilities";
    pub(super) const CONNECT: &str = "connectNativeCall";
    pub(super) const DISCONNECT: &str = "disconnectNativeCall";
    pub(super) const SET_MICROPHONE_ENABLED: &str = "setNativeCallMicrophoneEnabled";
    pub(super) const SET_CAMERA_ENABLED: &str = "setNativeCallCameraEnabled";
    pub(super) const SWITCH_CAMERA: &str = "switchNativeCallCamera";
    pub(super) const CANCEL_CONNECT: &str = "cancelNativeCallConnect";
    pub(super) const GET_STATE: &str = "getNativeCallState";
}

#[cfg(target_os = "ios")]
mod platform_commands {
    pub(super) const CAPABILITIES: &str = "capabilities";
    pub(super) const CONNECT: &str = "connect";
    pub(super) const DISCONNECT: &str = "disconnect";
    pub(super) const SET_MICROPHONE_ENABLED: &str = "setMicrophoneEnabled";
    pub(super) const SET_CAMERA_ENABLED: &str = "setCameraEnabled";
    pub(super) const SWITCH_CAMERA: &str = "switchCamera";
    pub(super) const CANCEL_CONNECT: &str = "cancelConnect";
    pub(super) const GET_STATE: &str = "getState";
}

/// Upper bound for any single native invocation, so a hung native call
/// cannot wedge the bridge actor. Connect gets a wider bound: the native
/// side may surface a microphone permission prompt before the room joins.
const NATIVE_CALL_TIMEOUT: Duration = Duration::from_secs(30);
const NATIVE_CONNECT_TIMEOUT: Duration = Duration::from_secs(60);

/// Mirrors the mobile capabilities responses: iOS reports
/// `{ microphone, backgroundAudio, camera? }`, Android reports
/// `{ microphone, audioPlayback, camera, .. }`. Absent fields degrade to
/// `false`; a resolved invocation is proof the native room bridge exists.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeCallCapabilitiesWire {
    #[serde(default)]
    microphone: bool,
    #[serde(default, alias = "audioPlayback")]
    background_audio: bool,
    #[serde(default)]
    camera: bool,
}

impl From<NativeCallCapabilitiesWire> for NativeCallCapabilities {
    fn from(native: NativeCallCapabilitiesWire) -> Self {
        Self {
            supported: true,
            microphone: native.microphone,
            background_audio: native.background_audio,
            // These commands exist only in the native room bridge.
            native_room: true,
            camera: native.camera,
        }
    }
}

#[derive(Clone)]
pub(crate) struct MobileBackend<R: Runtime> {
    handle: PluginHandle<R>,
}

impl<R: Runtime> MobileBackend<R> {
    pub(crate) fn new(handle: PluginHandle<R>) -> Self {
        Self { handle }
    }

    /// Builds the connect channel: valid snapshot events are handed straight
    /// to the actor's unbounded internal queue; anything else is dropped.
    pub(crate) fn native_call_event_channel(
        sender: mpsc::UnboundedSender<NativeCallChannelEvent>,
    ) -> Channel<NativeCallChannelEvent> {
        Channel::new(move |body: InvokeResponseBody| {
            if let Ok(event) = body.deserialize::<NativeCallChannelEvent>() {
                let _ = sender.send(event);
            }
            Ok(())
        })
    }

    /// Runs a native command with a time bound. A native rejection is
    /// sanitized into the bounded failure vocabulary; an elapsed bound is the
    /// bridge-level [`Error::Timeout`].
    async fn invoke_with_timeout<T: DeserializeOwned>(
        &self,
        command: &str,
        payload: impl Serialize,
        timeout: Duration,
    ) -> crate::Result<T> {
        match tokio::time::timeout(
            timeout,
            self.handle.run_mobile_plugin_async::<T>(command, payload),
        )
        .await
        {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(PluginInvokeError::InvokeRejected(rejection))) => Err(Error::failure(
                failure_code_from_raw(rejection.code.as_deref()),
            )),
            Ok(Err(_)) => Err(Error::failure(NativeCallFailureCode::Unexpected)),
            Err(_) => Err(Error::Timeout),
        }
    }

    async fn invoke<T: DeserializeOwned>(
        &self,
        command: &str,
        payload: impl Serialize,
    ) -> crate::Result<T> {
        self.invoke_with_timeout(command, payload, NATIVE_CALL_TIMEOUT)
            .await
    }

    pub(crate) async fn get_native_call_capabilities(
        &self,
    ) -> crate::Result<NativeCallCapabilities> {
        let native: NativeCallCapabilitiesWire =
            self.invoke(platform_commands::CAPABILITIES, ()).await?;
        Ok(native.into())
    }

    pub(crate) async fn connect_native_call(
        &self,
        request: NativeConnectCallRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke_with_timeout(platform_commands::CONNECT, request, NATIVE_CONNECT_TIMEOUT)
            .await
    }

    pub(crate) async fn disconnect_native_call(
        &self,
        request: NativeDisconnectCallRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::DISCONNECT, request).await
    }

    pub(crate) async fn cancel_native_call_connect(
        &self,
        request: NativeDisconnectCallRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::CANCEL_CONNECT, request)
            .await
    }

    pub(crate) async fn set_native_call_microphone_enabled(
        &self,
        request: NativeSetMicrophoneRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::SET_MICROPHONE_ENABLED, request)
            .await
    }

    pub(crate) async fn set_native_call_camera_enabled(
        &self,
        request: NativeSetCameraRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::SET_CAMERA_ENABLED, request)
            .await
    }

    pub(crate) async fn switch_native_call_camera(
        &self,
        request: NativeSwitchCameraRequest<'_>,
    ) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::SWITCH_CAMERA, request).await
    }

    pub(crate) async fn get_native_call_state(&self) -> crate::Result<NativeCallSnapshot> {
        self.invoke(platform_commands::GET_STATE, ()).await
    }
}

/// Native connect payload: the call fields plus the Tauri channel the native
/// room plugin uses to deliver snapshot events back into the actor.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeConnectCallRequest<'a> {
    #[serde(flatten)]
    pub fields: NativeConnectCallFields<'a>,
    pub channel: Channel<NativeCallChannelEvent>,
}

// Token must never land in logs: redact it in `Debug` (the contained fields
// already redact; `Channel` has no payload content to protect).
impl std::fmt::Debug for NativeConnectCallRequest<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NativeConnectCallRequest")
            .field("fields", &self.fields)
            .finish_non_exhaustive()
    }
}

/// Native payload for the commands that take only a call id: disconnect,
/// cancelConnect and switchCamera.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeDisconnectCallRequest<'a> {
    #[serde(flatten)]
    pub fields: NativeDisconnectCallFields<'a>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeSetMicrophoneRequest<'a> {
    #[serde(flatten)]
    pub fields: NativeSetMicrophoneFields<'a>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeSetCameraRequest<'a> {
    #[serde(flatten)]
    pub fields: NativeSetCameraFields<'a>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NativeSwitchCameraRequest<'a> {
    #[serde(flatten)]
    pub fields: NativeDisconnectCallFields<'a>,
}

pub fn init<R: Runtime, C: DeserializeOwned>(
    _app: &AppHandle<R>,
    api: PluginApi<R, C>,
) -> crate::Result<MobileBackend<R>> {
    #[cfg(target_os = "android")]
    let handle = api.register_android_plugin(PLUGIN_IDENTIFIER, "LivekitMobilePlugin")?;
    #[cfg(target_os = "ios")]
    let handle = api.register_ios_plugin(init_plugin_livekit_mobile)?;
    Ok(MobileBackend::new(handle))
}
