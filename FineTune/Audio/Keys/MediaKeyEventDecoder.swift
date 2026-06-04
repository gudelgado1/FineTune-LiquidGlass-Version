// FineTune/Audio/Keys/MediaKeyEventDecoder.swift
import Foundation

nonisolated enum MediaKeyEvent: Equatable {
    case volumeUp(isRepeat: Bool)
    case volumeDown(isRepeat: Bool)
    case muteToggle
    // Transport keys (F7/F8/F9) — routed to the marked default media app.
    case playPause
    case nextTrack
    case previousTrack

    /// True for the transport keys, which are sent to the chosen app via
    /// AppleScript rather than applied to the default output device.
    var isTransport: Bool {
        switch self {
        case .playPause, .nextTrack, .previousTrack: return true
        case .volumeUp, .volumeDown, .muteToggle: return false
        }
    }
}

protocol MediaKeyEventDecoding: Sendable {
    func decode(data1: Int) -> MediaKeyEvent?
}

/// Decodes `NSSystemDefined.data1` using `<IOKit/hidsystem/ev_keymap.h>`
/// constants: NX_KEYTYPE_SOUND_UP=0, SOUND_DOWN=1, MUTE=7, PLAY=16, NEXT=17,
/// PREVIOUS=18 (the F8/F9/F7 media keys). Unknown subtypes → nil.
struct IOKitMediaKeyDecoder: MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent? {
        let keyType = Int32((data1 & 0xFFFF0000) >> 16)
        let keyFlags = Int32(data1 & 0xFFFF)
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0xFF) != 0

        guard isDown else { return nil }

        switch keyType {
        case 0:  return .volumeUp(isRepeat: isRepeat)
        case 1:  return .volumeDown(isRepeat: isRepeat)
        case 7:  return isRepeat ? nil : .muteToggle
        case 16: return isRepeat ? nil : .playPause       // NX_KEYTYPE_PLAY (F8)
        case 17: return isRepeat ? nil : .nextTrack       // NX_KEYTYPE_NEXT (F9)
        case 18: return isRepeat ? nil : .previousTrack   // NX_KEYTYPE_PREVIOUS (F7)
        default: return nil
        }
    }
}
