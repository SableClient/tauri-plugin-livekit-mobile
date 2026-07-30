const COMMANDS: &[&str] = &[
    "getNativeCallCapabilities",
    "connectNativeCall",
    "disconnectNativeCall",
    "setNativeCallMicrophoneEnabled",
    "setNativeCallCameraEnabled",
    "switchNativeCallCamera",
    "setNativeCallRemoteVideoOverlay",
    "clearNativeCallRemoteVideoOverlay",
    "getNativeCallState",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .ios_path("ios")
        .build();
}
