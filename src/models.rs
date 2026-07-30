use serde::{Deserialize, Serialize};

/// Bounded connection-state vocabulary. `connectionState` on every native
/// snapshot deserializes into this enum, so an out-of-vocabulary native state
/// drops the payload instead of crossing the bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeCallConnectionState {
    Idle,
    Connecting,
    Connected,
    Reconnecting,
    Failed,
}

/// Bounded failure vocabulary shared by command errors and snapshot
/// `lastError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeCallFailureCode {
    InvalidRequest,
    Busy,
    PermissionDenied,
    ConnectFailed,
    MediaFailed,
    Disconnected,
    Cancelled,
    Unavailable,
    Unexpected,
}

impl NativeCallFailureCode {
    /// Wire code string.
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::Busy => "busy",
            Self::PermissionDenied => "permission_denied",
            Self::ConnectFailed => "connect_failed",
            Self::MediaFailed => "media_failed",
            Self::Disconnected => "disconnected",
            Self::Cancelled => "cancelled",
            Self::Unavailable => "unavailable",
            Self::Unexpected => "unexpected",
        }
    }

    /// Static, safe message for the code. Native error strings are never
    /// forwarded.
    pub fn message(&self) -> &'static str {
        match self {
            Self::InvalidRequest => "the call request was invalid",
            Self::Busy => "another call is already active",
            Self::PermissionDenied => "a microphone or camera permission was denied",
            Self::ConnectFailed => "the call failed to connect",
            Self::MediaFailed => "a microphone or camera update failed",
            Self::Disconnected => "the call connection ended unexpectedly",
            Self::Cancelled => "the operation was cancelled",
            Self::Unavailable => "the native call controller is unavailable",
            Self::Unexpected => "the call failed unexpectedly",
        }
    }
}

/// Sanitizes a native failure-code string into the bounded vocabulary.
/// Anything unrecognized degrades to [`NativeCallFailureCode::Unexpected`].
pub fn failure_code_from_raw(raw: Option<&str>) -> NativeCallFailureCode {
    match raw {
        Some("invalid_request") => NativeCallFailureCode::InvalidRequest,
        Some("busy") => NativeCallFailureCode::Busy,
        Some("permission_denied") => NativeCallFailureCode::PermissionDenied,
        Some("connect_failed") => NativeCallFailureCode::ConnectFailed,
        Some("media_failed") => NativeCallFailureCode::MediaFailed,
        Some("disconnected") => NativeCallFailureCode::Disconnected,
        Some("cancelled") => NativeCallFailureCode::Cancelled,
        Some("unavailable") => NativeCallFailureCode::Unavailable,
        Some("unexpected") => NativeCallFailureCode::Unexpected,
        _ => NativeCallFailureCode::Unexpected,
    }
}

/// Stable `{ code, message }` failure shape embedded in snapshots as
/// `lastError` and serialized for command errors. The message always comes
/// from the bounded code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCallError {
    pub code: NativeCallFailureCode,
    pub message: String,
}

impl NativeCallError {
    pub fn from_code(code: NativeCallFailureCode) -> Self {
        Self {
            code,
            message: code.message().into(),
        }
    }
}

impl std::fmt::Display for NativeCallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCallCapabilities {
    pub supported: bool,
    pub microphone: bool,
    pub background_audio: bool,
    pub native_room: bool,
    pub camera: bool,
    pub native_video_overlay: bool,
}

impl NativeCallCapabilities {
    /// Truthful host capabilities: desktop has no native LiveKit room.
    pub fn current() -> Self {
        let supported = cfg!(any(target_os = "android", target_os = "ios"));
        Self {
            supported,
            microphone: supported,
            background_audio: supported,
            native_room: supported,
            camera: supported,
            native_video_overlay: false,
        }
    }
}

/// Raw `{ code, message? }` pair as it may arrive inside native payloads. The
/// raw message is never forwarded: the guest-visible message is derived from
/// the bounded code alone.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawNativeCallError {
    code: String,
    #[serde(default)]
    #[allow(dead_code)]
    message: Option<String>,
}

fn deserialize_bounded_last_error<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<NativeCallError>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Option::<RawNativeCallError>::deserialize(deserializer)?;
    Ok(raw.map(|raw| NativeCallError::from_code(failure_code_from_raw(Some(&raw.code)))))
}

/// Camera projection of one remote participant's camera publication.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCallRemoteCamera {
    pub sid: String,
    pub muted: bool,
    pub subscribed: bool,
}

/// Remote-only participant projection; `identity` is the opaque backend
/// identity. `camera` exists only while the participant has a remote camera
/// publication.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCallRemoteParticipant {
    pub identity: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<NativeCallRemoteCamera>,
}

/// Wire shape of the native room snapshot resolved by native commands and
/// announced over the connect channel. `revision` is native-owned and passed
/// through unchanged.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeCallSnapshot {
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub call_id: Option<String>,
    pub connection_state: NativeCallConnectionState,
    #[serde(default)]
    pub microphone_enabled: bool,
    #[serde(default)]
    pub camera_enabled: bool,
    #[serde(default)]
    pub participant_count: u32,
    // `default` keeps natives that predate the roster decodable.
    #[serde(default)]
    pub remote_participants: Vec<NativeCallRemoteParticipant>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_bounded_last_error"
    )]
    pub last_error: Option<NativeCallError>,
}

impl NativeCallSnapshot {
    /// True while the native side reports anything but an idle room.
    pub fn is_live(&self) -> bool {
        self.connection_state != NativeCallConnectionState::Idle
    }
}

/// The only channel event kind: snapshot announcements. Anything else fails
/// to deserialize here and is dropped by the channel.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum NativeCallChannelEvent {
    SnapshotChanged { snapshot: NativeCallSnapshot },
}

/// One shared-E2EE key: `key` is the raw key material, base64-encoded,
/// scoped to a participant `identity` and a `key_index`. Keys only flow
/// guest → native; they never appear in snapshots or events.
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EncryptionKey {
    pub identity: String,
    pub key_index: u32,
    pub key: String,
}

// Key material must never land in logs: redact it in `Debug`.
impl std::fmt::Debug for EncryptionKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EncryptionKey")
            .field("identity", &self.identity)
            .field("key_index", &self.key_index)
            .field("key", &"[redacted]")
            .finish()
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectNativeCallRequest {
    pub call_id: String,
    pub url: String,
    pub token: String,
    pub microphone_enabled: bool,
    /// Initial shared-E2EE keys the native side installs before
    /// `room.connect`. Empty (or omitted) means ordinary unencrypted
    /// LiveKit, keeping the plugin generic.
    #[serde(default)]
    pub encryption_keys: Vec<EncryptionKey>,
}

// Token and key material must never land in logs: redact them in `Debug`.
impl std::fmt::Debug for ConnectNativeCallRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectNativeCallRequest")
            .field("call_id", &self.call_id)
            .field("url", &self.url)
            .field("token", &"[redacted]")
            .field("microphone_enabled", &self.microphone_enabled)
            .field("encryption_keys", &self.encryption_keys)
            .finish()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DisconnectNativeCallRequest {
    pub call_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetNativeCallMicrophoneEnabledRequest {
    pub call_id: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetNativeCallCameraEnabledRequest {
    pub call_id: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchNativeCallCameraRequest {
    pub call_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetNativeCallRemoteVideoOverlayRequest {
    pub call_id: String,
    pub participant_identity: String,
    pub track_id: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub device_pixel_ratio: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClearNativeCallRemoteVideoOverlayRequest {
    pub call_id: String,
}

/// Mid-call shared-E2EE key rotation/update for one participant identity.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetNativeCallEncryptionKeyRequest {
    pub call_id: String,
    pub identity: String,
    pub key_index: u32,
    pub key: String,
}

// Key material must never land in logs: redact it in `Debug`.
impl std::fmt::Debug for SetNativeCallEncryptionKeyRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SetNativeCallEncryptionKeyRequest")
            .field("call_id", &self.call_id)
            .field("identity", &self.identity)
            .field("key_index", &self.key_index)
            .field("key", &"[redacted]")
            .finish()
    }
}

/// The connect payload fields forwarded to the native room plugins.
///
/// Kept in `models.rs` (not `mobile.rs`, which only compiles on mobile
/// targets) so the wire shape is regression-tested on the host.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeConnectCallFields<'a> {
    pub call_id: &'a str,
    pub url: &'a str,
    pub token: &'a str,
    pub microphone_enabled: bool,
    // Omitted entirely for ordinary unencrypted calls.
    #[serde(skip_serializing_if = "<[EncryptionKey]>::is_empty")]
    pub encryption_keys: &'a [EncryptionKey],
}

// Token and key material must never land in logs: redact them in `Debug`.
impl std::fmt::Debug for NativeConnectCallFields<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NativeConnectCallFields")
            .field("call_id", &self.call_id)
            .field("url", &self.url)
            .field("token", &"[redacted]")
            .field("microphone_enabled", &self.microphone_enabled)
            .field("encryption_keys", &self.encryption_keys)
            .finish()
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeDisconnectCallFields<'a> {
    pub call_id: &'a str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSetMicrophoneFields<'a> {
    pub call_id: &'a str,
    pub enabled: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSetCameraFields<'a> {
    pub call_id: &'a str,
    pub enabled: bool,
}

/// Native payload for `setNativeCallEncryptionKey` (Android) /
/// `setEncryptionKey` (iOS): one shared-E2EE key for one identity.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSetEncryptionKeyFields<'a> {
    pub call_id: &'a str,
    pub identity: &'a str,
    pub key_index: u32,
    pub key: &'a str,
}

// Key material must never land in logs: redact it in `Debug`.
impl std::fmt::Debug for NativeSetEncryptionKeyFields<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NativeSetEncryptionKeyFields")
            .field("call_id", &self.call_id)
            .field("identity", &self.identity)
            .field("key_index", &self.key_index)
            .field("key", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSetRemoteVideoOverlayFields<'a> {
    pub call_id: &'a str,
    pub participant_identity: &'a str,
    pub track_id: &'a str,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub device_pixel_ratio: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_states_are_bounded_wire_values() {
        for (state, wire) in [
            (NativeCallConnectionState::Idle, "idle"),
            (NativeCallConnectionState::Connecting, "connecting"),
            (NativeCallConnectionState::Connected, "connected"),
            (NativeCallConnectionState::Reconnecting, "reconnecting"),
            (NativeCallConnectionState::Failed, "failed"),
        ] {
            assert_eq!(serde_json::to_value(state).unwrap(), wire);
            assert_eq!(
                serde_json::from_value::<NativeCallConnectionState>(serde_json::json!(wire))
                    .unwrap(),
                state
            );
        }
        assert!(
            serde_json::from_value::<NativeCallConnectionState>(serde_json::json!("starting"))
                .is_err()
        );
    }

    #[test]
    fn failure_codes_are_bounded_wire_values_with_static_messages() {
        for (code, wire) in [
            (NativeCallFailureCode::InvalidRequest, "invalid_request"),
            (NativeCallFailureCode::Busy, "busy"),
            (NativeCallFailureCode::PermissionDenied, "permission_denied"),
            (NativeCallFailureCode::ConnectFailed, "connect_failed"),
            (NativeCallFailureCode::MediaFailed, "media_failed"),
            (NativeCallFailureCode::Disconnected, "disconnected"),
            (NativeCallFailureCode::Cancelled, "cancelled"),
            (NativeCallFailureCode::Unavailable, "unavailable"),
            (NativeCallFailureCode::Unexpected, "unexpected"),
        ] {
            assert_eq!(code.code(), wire);
            assert_eq!(serde_json::to_value(code).unwrap(), wire);
            assert!(!code.message().is_empty());
        }
        assert!(
            serde_json::from_value::<NativeCallFailureCode>(serde_json::json!("internal_error"))
                .is_err()
        );
    }

    #[test]
    fn native_failure_codes_sanitize_into_the_bounded_vocabulary() {
        for (raw, bounded) in [
            ("invalid_request", NativeCallFailureCode::InvalidRequest),
            ("busy", NativeCallFailureCode::Busy),
            ("permission_denied", NativeCallFailureCode::PermissionDenied),
            ("connect_failed", NativeCallFailureCode::ConnectFailed),
            ("media_failed", NativeCallFailureCode::MediaFailed),
            ("disconnected", NativeCallFailureCode::Disconnected),
            ("cancelled", NativeCallFailureCode::Cancelled),
            ("unavailable", NativeCallFailureCode::Unavailable),
            ("unexpected", NativeCallFailureCode::Unexpected),
        ] {
            assert_eq!(failure_code_from_raw(Some(raw)), bounded, "code {raw}");
        }
        assert_eq!(
            failure_code_from_raw(Some("whatever_else")),
            NativeCallFailureCode::Unexpected
        );
        assert_eq!(
            failure_code_from_raw(None),
            NativeCallFailureCode::Unexpected
        );
    }

    #[test]
    fn snapshot_deserializes_native_truth_with_bounded_last_error() {
        let snapshot: NativeCallSnapshot = serde_json::from_value(serde_json::json!({
            "revision": 9,
            "callId": "call-1",
            "connectionState": "connected",
            "microphoneEnabled": true,
            "cameraEnabled": false,
            "participantCount": 2,
            "lastError": { "code": "media_failed", "message": "raw native detail" }
        }))
        .unwrap();
        assert_eq!(snapshot.revision, 9, "native revision passes through");
        assert_eq!(snapshot.call_id.as_deref(), Some("call-1"));
        assert_eq!(
            snapshot.connection_state,
            NativeCallConnectionState::Connected
        );
        assert!(snapshot.microphone_enabled);
        assert!(!snapshot.camera_enabled);
        assert_eq!(snapshot.participant_count, 2);
        assert!(snapshot.is_live());
        // Natives that predated the roster parse with an empty projection.
        assert_eq!(snapshot.remote_participants, Vec::new());
        assert_eq!(
            snapshot.last_error,
            Some(NativeCallError::from_code(
                NativeCallFailureCode::MediaFailed
            ))
        );
        let message = snapshot.last_error.unwrap().message;
        assert_ne!(message, "raw native detail");
    }

    #[test]
    fn snapshot_defaults_missing_fields_and_rejects_unknown_states() {
        let idle: NativeCallSnapshot =
            serde_json::from_value(serde_json::json!({ "connectionState": "idle" })).unwrap();
        assert_eq!(idle.revision, 0);
        assert_eq!(idle.call_id, None);
        assert!(!idle.microphone_enabled);
        assert!(!idle.camera_enabled);
        assert_eq!(idle.participant_count, 0);
        assert_eq!(idle.remote_participants, Vec::new());
        assert_eq!(idle.last_error, None);
        assert!(!idle.is_live());

        assert!(serde_json::from_value::<NativeCallSnapshot>(
            serde_json::json!({ "connectionState": "negotiating" })
        )
        .is_err());
        assert!(serde_json::from_value::<NativeCallSnapshot>(serde_json::json!({})).is_err());
    }

    #[test]
    fn snapshot_serializes_camel_case_omitting_clean_last_error() {
        let clean = serde_json::to_value(NativeCallSnapshot {
            revision: 4,
            call_id: Some("call-1".into()),
            connection_state: NativeCallConnectionState::Connected,
            microphone_enabled: true,
            camera_enabled: true,
            participant_count: 3,
            remote_participants: Vec::new(),
            last_error: None,
        })
        .unwrap();
        assert_eq!(
            clean,
            serde_json::json!({
                "revision": 4,
                "callId": "call-1",
                "connectionState": "connected",
                "microphoneEnabled": true,
                "cameraEnabled": true,
                "participantCount": 3,
                "remoteParticipants": []
            })
        );

        let failed = serde_json::to_value(NativeCallSnapshot {
            revision: 5,
            call_id: Some("call-1".into()),
            connection_state: NativeCallConnectionState::Failed,
            microphone_enabled: true,
            camera_enabled: false,
            participant_count: 3,
            remote_participants: Vec::new(),
            last_error: Some(NativeCallError::from_code(
                NativeCallFailureCode::Disconnected,
            )),
        })
        .unwrap();
        assert_eq!(
            failed["lastError"],
            serde_json::json!({
                "code": "disconnected",
                "message": "the call connection ended unexpectedly"
            })
        );
    }

    #[test]
    fn remote_participants_pass_through_with_optional_camera() {
        let snapshot: NativeCallSnapshot = serde_json::from_value(serde_json::json!({
            "revision": 7,
            "callId": "call-1",
            "connectionState": "connected",
            "microphoneEnabled": true,
            "cameraEnabled": false,
            "participantCount": 2,
            "remoteParticipants": [
                {
                    "identity": "@alice:example.org",
                    "camera": { "sid": "TR_abcdef", "muted": false, "subscribed": true }
                },
                { "identity": "@bob:example.org" }
            ]
        }))
        .unwrap();
        assert_eq!(
            snapshot.remote_participants,
            vec![
                NativeCallRemoteParticipant {
                    identity: "@alice:example.org".into(),
                    camera: Some(NativeCallRemoteCamera {
                        sid: "TR_abcdef".into(),
                        muted: false,
                        subscribed: true,
                    }),
                },
                NativeCallRemoteParticipant {
                    identity: "@bob:example.org".into(),
                    camera: None,
                },
            ]
        );

        // `camera` is omitted when there is no remote camera publication.
        assert_eq!(
            serde_json::to_value(&snapshot.remote_participants).unwrap(),
            serde_json::json!([
                {
                    "identity": "@alice:example.org",
                    "camera": { "sid": "TR_abcdef", "muted": false, "subscribed": true }
                },
                { "identity": "@bob:example.org" }
            ])
        );
    }

    #[test]
    fn channel_event_only_accepts_snapshot_changed() {
        let event: NativeCallChannelEvent = serde_json::from_value(serde_json::json!({
            "event": "snapshot_changed",
            "snapshot": {
                "revision": 11,
                "callId": "call-1",
                "connectionState": "reconnecting",
                "microphoneEnabled": false,
                "cameraEnabled": false,
                "participantCount": 1
            }
        }))
        .unwrap();
        let snapshot = match event {
            NativeCallChannelEvent::SnapshotChanged { snapshot } => snapshot,
        };
        assert_eq!(snapshot.revision, 11);
        assert_eq!(
            snapshot.connection_state,
            NativeCallConnectionState::Reconnecting
        );
    }

    #[test]
    fn connect_request_deserializes_camel_case_and_debug_redacts_token() {
        let request: ConnectNativeCallRequest = serde_json::from_value(serde_json::json!({
            "callId": "call-1",
            "url": "wss://livekit.example",
            "token": "secret-jwt",
            "microphoneEnabled": false
        }))
        .unwrap();
        assert_eq!(request.call_id, "call-1");
        // Omitted `encryptionKeys`: ordinary unencrypted call.
        assert!(request.encryption_keys.is_empty());
        let debug = format!("{request:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("secret-jwt"));
    }

    #[test]
    fn connect_request_encryption_keys_parse_camel_case_and_debug_redacts_material() {
        let request: ConnectNativeCallRequest = serde_json::from_value(serde_json::json!({
            "callId": "call-1",
            "url": "wss://livekit.example",
            "token": "secret-jwt",
            "microphoneEnabled": true,
            "encryptionKeys": [
                { "identity": "@alice:example.org", "keyIndex": 0, "key": "c2VjcmV0LWtleQ==" },
                { "identity": "@bob:example.org", "keyIndex": 1, "key": "b3RoZXIta2V5" }
            ]
        }))
        .unwrap();
        assert_eq!(request.encryption_keys.len(), 2);
        assert_eq!(request.encryption_keys[0].identity, "@alice:example.org");
        assert_eq!(request.encryption_keys[0].key_index, 0);
        assert_eq!(request.encryption_keys[0].key, "c2VjcmV0LWtleQ==");

        // Empty `encryptionKeys` means the same as omitted.
        let plain: ConnectNativeCallRequest = serde_json::from_value(serde_json::json!({
            "callId": "call-1",
            "url": "wss://livekit.example",
            "token": "secret-jwt",
            "microphoneEnabled": true,
            "encryptionKeys": []
        }))
        .unwrap();
        assert!(plain.encryption_keys.is_empty());

        let debug = format!("{request:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("secret-jwt"));
        // Key material is redacted; identities and indexes stay visible.
        assert!(!debug.contains("c2VjcmV0LWtleQ=="));
        assert!(!debug.contains("b3RoZXIta2V5"));
        assert!(debug.contains("@alice:example.org"));
        assert!(debug.contains("key_index: 1"));
    }

    #[test]
    fn encryption_key_request_parses_camel_case_and_debug_redacts_material() {
        let request: SetNativeCallEncryptionKeyRequest =
            serde_json::from_value(serde_json::json!({
                "callId": "call-1",
                "identity": "@alice:example.org",
                "keyIndex": 3,
                "key": "c2VjcmV0LWtleQ=="
            }))
            .unwrap();
        assert_eq!(request.call_id, "call-1");
        assert_eq!(request.key_index, 3);
        let debug = format!("{request:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("c2VjcmV0LWtleQ=="));
    }

    #[test]
    fn native_wire_fields_serialize_camel_case_and_redact_token() {
        let fields = NativeConnectCallFields {
            call_id: "call-1",
            url: "wss://livekit.example",
            token: "secret-jwt",
            microphone_enabled: true,
            encryption_keys: &[],
        };
        // No E2EE keys: the `encryptionKeys` key is omitted entirely, so
        // natives that predate the field see an unchanged payload.
        assert_eq!(
            serde_json::to_value(&fields).unwrap(),
            serde_json::json!({
                "callId": "call-1",
                "url": "wss://livekit.example",
                "token": "secret-jwt",
                "microphoneEnabled": true
            })
        );
        let debug = format!("{fields:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("secret-jwt"));

        let keys = [EncryptionKey {
            identity: "@alice:example.org".into(),
            key_index: 0,
            key: "c2VjcmV0LWtleQ==".into(),
        }];
        let encrypted = NativeConnectCallFields {
            encryption_keys: &keys,
            ..fields
        };
        assert_eq!(
            serde_json::to_value(&encrypted).unwrap(),
            serde_json::json!({
                "callId": "call-1",
                "url": "wss://livekit.example",
                "token": "secret-jwt",
                "microphoneEnabled": true,
                "encryptionKeys": [
                    { "identity": "@alice:example.org", "keyIndex": 0, "key": "c2VjcmV0LWtleQ==" }
                ]
            })
        );
        let debug = format!("{encrypted:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("c2VjcmV0LWtleQ=="));

        // Native key-rotation payload: camelCase wire, redacted Debug.
        let rotation = NativeSetEncryptionKeyFields {
            call_id: "call-1",
            identity: "@alice:example.org",
            key_index: 2,
            key: "c2VjcmV0LWtleQ==",
        };
        assert_eq!(
            serde_json::to_value(&rotation).unwrap(),
            serde_json::json!({
                "callId": "call-1",
                "identity": "@alice:example.org",
                "keyIndex": 2,
                "key": "c2VjcmV0LWtleQ=="
            })
        );
        let debug = format!("{rotation:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("c2VjcmV0LWtleQ=="));

        assert_eq!(
            serde_json::to_value(NativeDisconnectCallFields { call_id: "call-1" }).unwrap(),
            serde_json::json!({ "callId": "call-1" })
        );
        assert_eq!(
            serde_json::to_value(NativeSetMicrophoneFields {
                call_id: "call-1",
                enabled: true
            })
            .unwrap(),
            serde_json::json!({ "callId": "call-1", "enabled": true })
        );
        assert_eq!(
            serde_json::to_value(NativeSetCameraFields {
                call_id: "call-1",
                enabled: false
            })
            .unwrap(),
            serde_json::json!({ "callId": "call-1", "enabled": false })
        );
        assert_eq!(
            serde_json::to_value(NativeSetRemoteVideoOverlayFields {
                call_id: "call-1",
                participant_identity: "@alice:example.org",
                track_id: "TR_abcdef",
                x: 10.0,
                y: 20.0,
                width: 320.0,
                height: 180.0,
                device_pixel_ratio: 2.0,
            })
            .unwrap(),
            serde_json::json!({
                "callId": "call-1",
                "participantIdentity": "@alice:example.org",
                "trackId": "TR_abcdef",
                "x": 10.0,
                "y": 20.0,
                "width": 320.0,
                "height": 180.0,
                "devicePixelRatio": 2.0
            })
        );
    }

    #[test]
    fn capabilities_serialize_camel_case_with_media_flags() {
        assert_eq!(
            serde_json::to_value(NativeCallCapabilities {
                supported: true,
                microphone: true,
                background_audio: true,
                native_room: true,
                camera: false,
                native_video_overlay: true,
            })
            .unwrap(),
            serde_json::json!({
                "supported": true,
                "microphone": true,
                "backgroundAudio": true,
                "nativeRoom": true,
                "camera": false,
                "nativeVideoOverlay": true
            })
        );
    }
}
