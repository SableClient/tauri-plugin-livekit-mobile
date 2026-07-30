# tauri-plugin-livekit-mobile

A Tauri v2 plugin that bridges a WebView-hosted call (e.g. a MatrixRTC call
in Sable) to a **native LiveKit audio room** on Android and iOS. The room
(connection, tracks, reconnections, encoding) lives in the native plugin
(LiveKit Kotlin/Swift SDK, plus an Android foreground service so audio
survives backgrounding). The native side is the single source of truth for
room state; the Rust crate is a thin transport that validates basic input,
forwards time-bounded invocations, and delivers native snapshots and events
to the owning webview.

> **Breaking:** 0.2.0 replaces the lifecycle-only `getPlatformCallCapabilities`
> / `startPlatformCallLifecycle` / `stopPlatformCallLifecycle` /
> `getPlatformCallState` API with the native call bridge below. There is no
> compatibility shim.

## Non-goals

The plugin does **not**:

- mint, refresh, validate, log, echo, or persist LiveKit access tokens;
- provide MatrixRTC or any other signaling, focus negotiation, or transport
  beyond the LiveKit room itself;
- run the LiveKit `Room`, WebRTC, or any media in the WebView;
- touch screen capture;
- run background JavaScript.

## MatrixRTC host responsibility

The host application owns everything around the room. For each call it must:

1. pick the LiveKit focus/server and obtain an access token (JWT) from its
   MatrixRTC LiveKit auth service, with a TTL that covers the call;
2. call `connectNativeCall` with `{ callId, url, token, microphoneEnabled }`,
   choosing an opaque `callId` (e.g. the Matrix call id);
3. refresh or rotate tokens out-of-band; if a token expires mid-call the
   native bridge reports a bounded failure and the host disconnects and
   reconnects with a fresh token.

The token crosses the bridge only inside the connect payload. Rust-side
`Debug` implementations redact it, and neither native plugin logs or
re-emits it.

## Supported platforms

| Platform      | Support |
| ------------- | ------- |
| Android       | Yes |
| iOS           | Yes |
| Desktop (any) | No. `getNativeCallCapabilities` reports `supported: false, nativeRoom: false, camera: false, nativeVideoOverlay: false`; room commands fail with `unavailable` |

`NativeCallCapabilities.camera` advertises per platform whether the native
lane accepts the camera commands (`setNativeCallCameraEnabled` /
`switchNativeCallCamera`).

`NativeCallCapabilities.nativeVideoOverlay` advertises whether the native lane
accepts remote-video overlay placement commands.

## Install

The crate and npm package are not yet published to crates.io / npm; use a Git
or path dependency.

Rust:

```toml
[dependencies]
tauri-plugin-livekit-mobile = { git = "https://github.com/SableClient/tauri-plugin-livekit-mobile.git" }
```

JavaScript (build output in `dist-js/` is committed, so consumers do not need
a build step):

```sh
pnpm add git+https://github.com/SableClient/tauri-plugin-livekit-mobile.git
```

Once published, the registry equivalents will be
`cargo add tauri-plugin-livekit-mobile` and
`pnpm add @sable-client/tauri-plugin-livekit-mobile`.

Register the plugin in `src-tauri/src/lib.rs` (or `main.rs`):

```rust
tauri::Builder::default()
    .plugin(tauri_plugin_livekit_mobile::init())
```

Tauri v2 registers the Android Kotlin and iOS Swift sources declared by this
crate (`build.rs`: `android_path("android")`, `ios_path("ios")`). On iOS the
plugin is bound via `ios_plugin_binding!(init_plugin_livekit_mobile)`; rebuild
the mobile scaffold (`tauri android init` / `tauri ios init`) after adding the
dependency.

## Permissions

Allow the default permission set in `src-tauri/capabilities/default.json`:

```json
{
  "permissions": ["livekit-mobile:default"]
}
```

This grants `getNativeCallCapabilities`, `connectNativeCall`,
`disconnectNativeCall`, `setNativeCallMicrophoneEnabled`,
`setNativeCallCameraEnabled`, `switchNativeCallCamera`, and
`setNativeCallRemoteVideoOverlay`, `clearNativeCallRemoteVideoOverlay`,
`setNativeCallEncryptionKey`, and `getNativeCallState`.

## Host app setup

### Android

The plugin's library manifest merges the required permissions
(`RECORD_AUDIO`, `FOREGROUND_SERVICE*`, `POST_NOTIFICATIONS`) and declares
the foreground service. No manifest edits are required in the host app.
`RECORD_AUDIO` is a runtime permission and is requested by the plugin when
connecting with `microphoneEnabled: true` (or when enabling the microphone
mid-call) if it is not granted yet.

While a call is active, the foreground service shows a single ongoing,
low-importance notification on the stable channel `livekit_mobile_audio`
(created once at service creation). The notification uses the host
application's launcher icon and label; there is no configuration API for its
content.

`CAMERA` is a runtime permission; the plugin requests it when enabling the
camera without a grant. Declining the prompt rejects
`setNativeCallCameraEnabled` with the bounded `permission_denied` code and
surfaces the same code in snapshot `lastError`.

On Android 13 (API 33) and above, `POST_NOTIFICATIONS` is a runtime
permission. Requesting it is the host app's responsibility (the plugin
declares the permission in its manifest but never asks at runtime). Without
the grant, the foreground-service notice is absent from the notification
drawer but remains visible in Task Manager; service behavior is unaffected.

### iOS

Add to the host app's `Info.plist`:

- `NSMicrophoneUsageDescription`: required when connecting with
  `microphoneEnabled: true` or turning the microphone on mid-call; the
  plugin requests record permission before enabling the microphone.
- `UIBackgroundModes` containing `audio`: required for room audio to
  continue while the app is backgrounded.

The host app must also bundle LiveKit's two binary frameworks. They are
**dynamic** libraries loaded at `@rpath`, so unlike the rest of the LiveKit
SDK they cannot be absorbed into this plugin's static archive; nothing in
Tauri's generated Xcode project embeds them on your behalf. Without them the
app fails at launch with `dyld: Library not loaded:
@rpath/LiveKitWebRTC.framework/LiveKitWebRTC`.

Download the versions pinned by `ios/Package.resolved` and list them in
`tauri.conf.json` — any `.xcframework` entry is treated as a vendor framework
and gets embedded and signed into the bundle:

```json
{
  "bundle": {
    "iOS": {
      "frameworks": [
        "frameworks/LiveKitWebRTC.xcframework",
        "frameworks/RustLiveKitUniFFI.xcframework"
      ]
    }
  }
}
```

Paths are relative to the Tauri directory (`src-tauri`). Recreate the iOS
project after changing this list. The matching release archives are
[`LiveKitWebRTC`](https://github.com/livekit/webrtc-xcframework/releases) and
[`RustLiveKitUniFFI`](https://github.com/livekit/livekit-uniffi-xcframework/releases).

## JavaScript usage

```ts
import {
  getNativeCallCapabilities,
  connectNativeCall,
  disconnectNativeCall,
  setNativeCallMicrophoneEnabled,
  setNativeCallCameraEnabled,
  switchNativeCallCamera,
  setNativeCallRemoteVideoOverlay,
  clearNativeCallRemoteVideoOverlay,
  getNativeCallState,
  listenNativeCallSnapshot,
} from '@sable-client/tauri-plugin-livekit-mobile';

const capabilities = await getNativeCallCapabilities();
if (!capabilities.supported || !capabilities.nativeRoom) {
  // Desktop or unsupported platform: there is no native room.
}

const unlisten = await listenNativeCallSnapshot((snapshot) => {
  // Every event is one full NativeCallSnapshot with a native-owned revision.
});

// Every command resolves with the same NativeCallSnapshot shape.
const state = await connectNativeCall({
  callId: 'mxc-call-id',
  url: 'wss://livekit.example',
  token: livekitJwt,
  microphoneEnabled: true,
});

await setNativeCallMicrophoneEnabled({ callId: 'mxc-call-id', enabled: false });
if (capabilities.camera) {
  await setNativeCallCameraEnabled({ callId: 'mxc-call-id', enabled: true });
  await switchNativeCallCamera({ callId: 'mxc-call-id' });
}
if (capabilities.nativeVideoOverlay) {
  await setNativeCallRemoteVideoOverlay({
    callId: 'mxc-call-id',
    participantIdentity: '@alice:example.org',
    trackId: 'TR_abcdef',
    x: 0,
    y: 0,
    width: 320,
    height: 180,
    devicePixelRatio: window.devicePixelRatio,
  });
}

// On call end:
await disconnectNativeCall({ callId: 'mxc-call-id' });
await unlisten();
```

## Bridge semantics

- **The native side owns the room.** Connection state, idempotency (repeated
  disconnects), busy handling (a second connect while one is active) and
  stale-call rejection are all decided natively. Rust never predicts, mirrors
  or replays room state: it validates basic input, forwards invocations and
  returns or forwards native snapshots.
- Every command (`connectNativeCall`, `disconnectNativeCall`,
  `setNativeCallMicrophoneEnabled`, `setNativeCallCameraEnabled`,
  `switchNativeCallCamera`, `setNativeCallRemoteVideoOverlay`,
  `clearNativeCallRemoteVideoOverlay`, `setNativeCallEncryptionKey`,
  `getNativeCallState`) resolves with the
  authoritative `NativeCallSnapshot`:

  ```ts
  {
    revision: number; // native-owned, bumped on every change
    callId: string | null;
    connectionState: 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'failed';
    microphoneEnabled: boolean;
    cameraEnabled: boolean;
    participantCount: number;
    remoteParticipants: Array<{
      identity: string; // opaque LiveKit/MatrixRTC backend identity
      camera?: { sid: string; muted: boolean; subscribed: boolean };
    }>;
    lastError?: { code: NativeCallFailureCode; message: string };
  }
  ```

  `revision` passes through the bridge untouched (Rust never creates one), so
  consumers can drop out-of-order snapshots by comparing revisions.
- `setNativeCallRemoteVideoOverlay` forwards a stateless placement for one
  remote track: `{ callId, participantIdentity, trackId, x, y, width, height,
  devicePixelRatio }`. Every value must be finite; `width`, `height`, and
  `devicePixelRatio` must be strictly positive. `x` and `y` may be negative
  for partially offscreen DOM rectangles. Rust applies no coordinate or size
  caps; native viewports own clipping and caps.
  `clearNativeCallRemoteVideoOverlay` removes the call's native remote-video
  overlay. The native side owns rendering and any overlay state; neither is
  represented in snapshots.
- `remoteParticipants` is a remote-only projection sized for rendering one
  remote-video tile per remote participant: `identity` is the opaque backend
  identity, and `camera` is present only while that participant has a remote
  camera publication (`sid` is its LiveKit track id). The bridge passes the
  roster through untouched; it keeps no roster state of its own. Missing
  keys on older natives decode as an empty list.
- Every native invocation is time-bounded (60s for connect, 30s for the
  rest) so a hung native call cannot wedge the bridge. An elapsed bound
  surfaces as an error with code `timeout`. A timed-out connect is **not**
  dropped: the bridge internally cancels the pending connect on the native
  side, reconciles with `getNativeCallState`, keeps event delivery alive
  until the native snapshot is known, and resolves with that reconciled
  snapshot (or `timeout` if the native side cannot be reached at all). The
  channel is never merely abandoned, so a room that survives cancellation is
  never orphaned from its events.

### Shared E2EE keys

The bridge is key-agnostic: it validates and forwards shared key material
(`{ identity, keyIndex, key }`, with `key` the raw bytes base64-encoded) but
never mints, stores, logs, or echoes it, and keys never appear in snapshots
or events. No key byte length is enforced; key sizes are the native side's
decision.

- Initial keys ride on `connectNativeCall` as optional `encryptionKeys`. The
  native side installs them **before** `room.connect`; omitted or empty means
  an ordinary unencrypted LiveKit call.
- `setNativeCallEncryptionKey({ callId, identity, keyIndex, key })` installs
  or rotates a key mid-call (Android: `setNativeCallEncryptionKey`, iOS:
  `setEncryptionKey`) and resolves with the current `NativeCallSnapshot`.

Blank `callId`/`identity`, or `key` material that does not base64-decode to
nonempty bytes, rejects with `invalid_request`.

### Owner webview event delivery

`connectNativeCall` records the calling webview as the call's owner. Snapshot
events are emitted on `plugin:livekit-mobile://native-call-event` **targeted
at the owner webview only** (`EventTarget::webview(label)`): there is no
global broadcast, so parallel webviews never receive another call's events. A
`listenNativeCallSnapshot` in any other webview stays silent.

If the owner webview is destroyed without calling `disconnectNativeCall`
while the native room survives, the room is orphaned: its owner label points
at a dead context. The first webview to call `getNativeCallState` while such
an otherwise unowned room is reported live becomes its new owner and receives
subsequent snapshots.

Limitations to be aware of:

- Ownership is tracked by **webview label** (the only stable identity
  Tauri command arguments expose); if an app runs two webviews sharing one
  label, both are the target. Keep webview labels unique.
- If the owner webview is destroyed without calling
  `disconnectNativeCall`, the native room keeps running until the native
  side tears it down, `getNativeCallState` is used to take over, or the
  next connect replaces it.

### Events

The native side emits one channel event shape, `{ event: "snapshot_changed",
snapshot }`, and the bridge forwards the `snapshot` payload to the owner
webview. There are no separate participant, state or failure event kinds:
connection changes, participant counts, microphone/camera flips and failures
(via `lastError`) all surface as snapshots.

### Errors

Command rejections serialize as `{ code, message }`. Codes come from one
bounded vocabulary shared with snapshot `lastError`: `invalid_request`,
`busy`, `permission_denied`, `connect_failed`, `media_failed`,
`disconnected`, `cancelled`, `unavailable`, `unexpected`, plus the
bridge-level `timeout`. Messages are static strings derived from the code;
raw native error strings and platform-specific codes are folded into this
vocabulary at the boundary and never forwarded to JavaScript.

## `dist-js` policy

`dist-js/` contains the built guest API and is **generated and committed**.
After changing `guest-js/`, run `pnpm build` and commit the result; CI fails
if `dist-js/` is stale.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
