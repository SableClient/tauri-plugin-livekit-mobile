# tauri-plugin-call-lifecycle

A Tauri v2 plugin that owns the platform call lifecycle for calls whose media
is owned by the WebView: an Android foreground service (microphone /
media-playback types, so mic use survives backgrounding) and an iOS
`AVAudioSession` (category, activation, interruption and route events).

Rust mediates a single session-scoped state machine (`idle` / `active`)
over a Tokio actor, and forwards bounded platform
audio events to JavaScript.

## Non-goals

The plugin does **not**:

- own WebRTC, a LiveKit `Room`, or any media rendering; tracks are created
  and owned by JavaScript running in the WebView;
- touch the camera or screen capture;
- provide its own signaling, transport, or network stack;
- run background JavaScript.

## Supported platforms

| Platform      | Support |
| ------------- | ------- |
| Android       | Yes     |
| iOS           | Yes     |
| Desktop (any) | No — calls report `supported: false` and start fails with `platform_call_unsupported` |

## Install

The crate and npm package are not yet published to crates.io / npm; use a Git
or path dependency.

Rust:

```toml
[dependencies]
tauri-plugin-call-lifecycle = { git = "https://github.com/SableClient/tauri-plugin-call-lifecycle.git" }
```

JavaScript (build output in `dist-js/` is committed, so consumers do not need
a build step):

```sh
pnpm add git+https://github.com/SableClient/tauri-plugin-call-lifecycle.git
```

Once published, the registry equivalents will be
`cargo add tauri-plugin-call-lifecycle` and
`pnpm add @sable-client/tauri-plugin-call-lifecycle`.

Register the plugin in `src-tauri/src/lib.rs` (or `main.rs`):

```rust
tauri::Builder::default()
    .plugin(tauri_plugin_call_lifecycle::init())
```

Tauri v2 registers the Android Kotlin and iOS Swift sources declared by this
crate (`build.rs`: `android_path("android")`, `ios_path("ios")`). On iOS the
plugin is bound via `ios_plugin_binding!(init_plugin_call_lifecycle)`; rebuild
the mobile scaffold (`tauri android init` / `tauri ios init`) after adding the
dependency.

## Permissions

Allow the default permission set in `src-tauri/capabilities/default.json`:

```json
{
  "permissions": ["call-lifecycle:default"]
}
```

This grants `getPlatformCallCapabilities`, `startPlatformCallLifecycle`,
`stopPlatformCallLifecycle`, and `getPlatformCallState`.

## Host app setup

### Android

The plugin's library manifest merges the required permissions
(`RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, `FOREGROUND_SERVICE`,
`FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`,
`POST_NOTIFICATIONS`) and declares the foreground service. No manifest edits
are required in the host app. `RECORD_AUDIO` is a runtime permission and is
requested by the plugin when a session is started with `microphone: true`.

While a session is active, the foreground service shows a single ongoing,
low-importance notification on the stable channel `call_lifecycle_audio`
(created once at service creation). The notification uses the host
application's launcher icon and label; there is no configuration API for its
content.

On Android 13 (API 33) and above, `POST_NOTIFICATIONS` is a runtime
permission. Requesting it is the host app's responsibility (the plugin
declares the permission in its manifest but never asks at runtime). Without
the grant, the foreground-service notice is absent from the notification
drawer but remains visible in Task Manager; service behavior, including all
lifecycle guarantees, is unaffected.

### iOS

Add to the host app's `Info.plist`:

- `NSMicrophoneUsageDescription` — required when starting a session with
  `microphone: true`; the plugin requests record permission before
  configuring the audio session.
- `UIBackgroundModes` containing `audio` — required for call audio to
  continue while the app is backgrounded.

## JavaScript usage

```ts
import {
  getPlatformCallCapabilities,
  startPlatformCallLifecycle,
  stopPlatformCallLifecycle,
  listenPlatformCallEvent,
} from '@sable-client/tauri-plugin-call-lifecycle';

const capabilities = await getPlatformCallCapabilities();
if (!capabilities.supported) {
  // Desktop or unsupported platform: run the call without platform lifecycle.
}

const unlisten = await listenPlatformCallEvent((event) => {
  // Bounded events: focus_changed, route_changed, interrupted,
  // media_reset, failed.
});

const state = await startPlatformCallLifecycle({
  sessionId: 'call-123',
  microphone: true,
  playback: true,
});

// On call end:
await stopPlatformCallLifecycle({ sessionId: 'call-123' });
await unlisten();
```

## Lifecycle semantics

- `sessionId` is an opaque, caller-chosen identifier. One platform session
  exists at a time; a `start` with a different session while active fails
  with `busy`.
- `start` with the same `sessionId` and identical media flags is idempotent
  and returns the current state.
- `stop` with the `sessionId` of the most recently stopped session is
  idempotent and returns the current state. A `stop` naming any other session
  (e.g. one replaced by a newer session, or an unknown one) is rejected with
  a `platform_call_stale_session` command error and can never tear down the
  active session.
- Every state transition and event carries a monotonically increasing
  `revision` so consumers can drop out-of-order events.
- Events are delivered on `plugin:call-lifecycle://platform-event`, exposed
  as `listenPlatformCallEvent`.

### Errors

Command errors serialize as `{ code, message }` with these stable codes:
`platform_call_unsupported`, `platform_call_busy`,
`platform_call_stale_session`, `platform_call_start_failed`,
`platform_call_stop_failed`, `actor_unavailable`. Native error details are
never included.

Asynchronous `failed` events carry a bounded `PlatformCallFailureCode` mapped
from the native payloads: `busy`, `permission_denied`, `audio_unavailable`,
`start_failed`, `stop_failed`. Raw native error strings are never forwarded
to JavaScript.

## `dist-js` policy

`dist-js/` contains the built guest API and is **generated and committed**.
After changing `guest-js/`, run `pnpm build` and commit the result; CI fails
if `dist-js/` is stale.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
