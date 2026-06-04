// FineTune/Shortcuts/ShortcutAction.swift
import Foundation

/// Actions that can be bound to a user-recordable global keyboard shortcut.
///
/// Adding a new action here is a single enum case + a corresponding arm
/// in `ShortcutsRegistry.dispatch(_:)`. The `rawValue` is the persistence key
/// in `AppSettings.customShortcuts` and must be stable across releases.
enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case togglePopup
    case targetAppVolumeUp = "frontmostAppVolumeUp"
    case targetAppVolumeDown = "frontmostAppVolumeDown"
    case targetAppMuteToggle = "frontmostAppMuteToggle"
    // NOTE: media transport (Play/Pause, Next, Previous) is NOT a recordable
    // hotkey. It's intercepted directly from the F7/F8/F9 system media keys by
    // `MediaKeyMonitor` and routed to the marked default app — see
    // `AppSettings.mediaTargetBundleID` and `MediaTransportController`.

    var displayName: String {
        switch self {
        case .togglePopup: "Toggle FineTune Popup"
        case .targetAppVolumeUp: "App Volume Up"
        case .targetAppVolumeDown: "App Volume Down"
        case .targetAppMuteToggle: "App Mute"
        }
    }

    /// Whether holding the chord should keep firing the action while held,
    /// matching macOS media-key auto-repeat. Toggles must not repeat
    /// (would flip-flop state every interval).
    var supportsRepeat: Bool {
        switch self {
        case .targetAppVolumeUp, .targetAppVolumeDown: true
        case .togglePopup, .targetAppMuteToggle: false
        }
    }
}
