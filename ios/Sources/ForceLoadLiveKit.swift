import LiveKit

// Workaround for ld64's lazy archive-member extraction dropping ObjC-visible
// class extensions from a static library (Swift SR-14217 / Apple QA1490).
//
// `Room.add(delegate:)` and friends are declared in a *class extension*
// (`extension Room: MulticastDelegateProtocol`) in
// `Room+MulticastDelegate.swift`; incremental SwiftPM builds emit their
// ObjC-side method list as a separate archive member. Cross-module callers
// (including LiveKit's own `MetricsManager.register(room:)`) send
// `addDelegate:` through `objc_msgSend`, which references only the selector
// string, never a symbol. The linker hence never extracts the member, and the
// binary crashes with
//   `-[LiveKit.Room addDelegate:]: unrecognized selector sent to instance`
// as soon as a Room is constructed. The same fate can hit the
// `allParticipants` ObjC exposure from `Room+Convenience.swift`, and the
// Participant/Track delegate pairs.
//
// The documented fix (`-ObjC` in OTHER_LDFLAGS, per Apple QA1490 and Swift
// SR-14217) is not usable here: the plugin's archive embeds its own copy of
// the Tauri Swift API next to the app's, and `-ObjC` force-loads both
// (verified: 428 duplicate symbols at link time). Instead, this file emits
// plain *symbol* references to the affected members; the linker then pulls
// exactly those members out of the archive and nothing else.
//
// The `@_silgen_name` strings are the mangled symbols as the linker sees them
// (no leading-underscore prefix). They were verified against the archive
// built from the LiveKit pin in `Package.swift`; if that pin moves, recheck:
//   nm -mU <swift-out>/libtauri-plugin-livekit-mobile.a | grep 8delegate

@_silgen_name("$s7LiveKit4RoomC3add8delegateyAA0C8Delegate_p_tF")
private func _lkRoomAddDelegate(_ room: Room, _ delegate: RoomDelegate)

@_silgen_name("$s7LiveKit4RoomC6remove8delegateyAA0C8Delegate_p_tF")
private func _lkRoomRemoveDelegate(_ room: Room, _ delegate: RoomDelegate)

@_silgen_name("$s7LiveKit4RoomC15allParticipantsSDyAA11ParticipantC8IdentityCAFGvg")
private func _lkRoomGetAllParticipants(_ room: Room) -> [Participant.Identity: Participant]

@_silgen_name("$s7LiveKit11ParticipantC3add8delegateyAA0C8Delegate_p_tF")
private func _lkParticipantAddDelegate(_ participant: Participant, _ delegate: ParticipantDelegate)

@_silgen_name("$s7LiveKit11ParticipantC6remove8delegateyAA0C8Delegate_p_tF")
private func _lkParticipantRemoveDelegate(_ participant: Participant, _ delegate: ParticipantDelegate)

@_silgen_name("$s7LiveKit5TrackC3add8delegateyAA0C8Delegate_p_tF")
private func _lkTrackAddDelegate(_ track: Track, _ delegate: TrackDelegate)

@_silgen_name("$s7LiveKit5TrackC6remove8delegateyAA0C8Delegate_p_tF")
private func _lkTrackRemoveDelegate(_ track: Track, _ delegate: TrackDelegate)

// CameraCapturer (and BufferCapturer/ScreenCapturer) inherit the multicast
// category from VideoCapturer; registering the base class's category covers
// all of them. Signatures are loose (`AnyObject`); these are never called,
// only address-taken to force-link the category members. Types exist and are
// public in the LiveKit module.
@_silgen_name("$s7LiveKit13VideoCapturerC3add8delegateyAA0cD8Delegate_p_tF")
private func _lkVideoCapturerAddDelegate(_ capturer: AnyObject, _ delegate: AnyObject)

@_silgen_name("$s7LiveKit13VideoCapturerC6remove8delegateyAA0cD8Delegate_p_tF")
private func _lkVideoCapturerRemoveDelegate(_ capturer: AnyObject, _ delegate: AnyObject)

@_silgen_name("$s7LiveKit9VideoViewC3add8delegateyAA0cD8Delegate_p_tF")
private func _lkVideoViewAddDelegate(_ view: AnyObject, _ delegate: AnyObject)

@_silgen_name("$s7LiveKit9VideoViewC6remove8delegateyAA0cD8Delegate_p_tF")
private func _lkVideoViewRemoveDelegate(_ view: AnyObject, _ delegate: AnyObject)

/// Emits undefined-symbol references to the members above. Called once from
/// the plugin's `load(webview:)` (a member the host always links); at runtime
/// the function only materializes function values; nothing is called.
@inline(never)
@discardableResult
func forceLinkLiveKitObjCSurface() -> Int {
  let refs: [Any] = [
    _lkRoomAddDelegate as (Room, RoomDelegate) -> Void,
    _lkRoomRemoveDelegate as (Room, RoomDelegate) -> Void,
    _lkRoomGetAllParticipants as (Room) -> [Participant.Identity: Participant],
    _lkParticipantAddDelegate as (Participant, ParticipantDelegate) -> Void,
    _lkParticipantRemoveDelegate as (Participant, ParticipantDelegate) -> Void,
    _lkTrackAddDelegate as (Track, TrackDelegate) -> Void,
    _lkTrackRemoveDelegate as (Track, TrackDelegate) -> Void,
    _lkVideoCapturerAddDelegate as (AnyObject, AnyObject) -> Void,
    _lkVideoCapturerRemoveDelegate as (AnyObject, AnyObject) -> Void,
    _lkVideoViewAddDelegate as (AnyObject, AnyObject) -> Void,
    _lkVideoViewRemoveDelegate as (AnyObject, AnyObject) -> Void,
  ]
  return refs.count
}
