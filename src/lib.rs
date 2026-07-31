use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime,
};

pub use models::*;

mod actor;
mod commands;
mod error;
#[cfg(mobile)]
mod mobile;
mod models;

pub use error::{Error, Result};

use actor::NativeCallBridge;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access the native call bridge APIs.
pub trait NativeCallExt<R: Runtime> {
    fn native_call_bridge(&self) -> &NativeCallBridge<R>;
}

impl<R: Runtime, T: Manager<R>> crate::NativeCallExt<R> for T {
    fn native_call_bridge(&self) -> &NativeCallBridge<R> {
        self.state::<NativeCallBridge<R>>().inner()
    }
}

/// Initializes the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("livekit-mobile")
        .invoke_handler(tauri::generate_handler![
            commands::getNativeCallCapabilities,
            commands::connectNativeCall,
            commands::disconnectNativeCall,
            commands::setNativeCallMicrophoneEnabled,
            commands::setNativeCallCameraEnabled,
            commands::switchNativeCallCamera,
            commands::setNativeCallRemoteVideoOverlay,
            commands::clearNativeCallRemoteVideoOverlay,
            commands::setNativeCallLocalVideoOverlay,
            commands::clearNativeCallLocalVideoOverlay,
            commands::reportSystemIncomingCall,
            commands::startSystemCall,
            commands::answerSystemCall,
            commands::endSystemCall,
            commands::setSystemCallMuted,
            commands::drainPendingSystemCallActions,
            commands::fulfillAnswerCall,
            commands::fulfillEndCall,
            commands::reportSystemCallConnected,
            commands::setNativeCallEncryptionKey,
            commands::getNativeCallState,
            commands::getAudioRoutes,
            commands::setAudioRoute,
            commands::sendDTMF,
            commands::updateCallDisplay,
            commands::reportSystemCallAnsweredElsewhere,
            commands::reportSystemCallDeclinedElsewhere,
            commands::reportSystemCallUnanswered,
            commands::declineSystemCall,
        ])
        .setup(|app, api| {
            #[cfg(mobile)]
            let mobile_backend = mobile::init(app, api)?;
            #[cfg(not(mobile))]
            let _ = api;

            #[cfg(mobile)]
            let bridge = NativeCallBridge::new(app.clone(), mobile_backend);
            #[cfg(not(mobile))]
            let bridge = NativeCallBridge::new(app.clone());
            app.manage(bridge);
            Ok(())
        })
        .build()
}
