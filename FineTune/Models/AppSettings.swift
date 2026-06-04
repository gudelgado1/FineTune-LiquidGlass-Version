// FineTune/Models/AppSettings.swift
import Foundation
import SwiftUI
import AppKit

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - Ignored App Info

struct IgnoredAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Enums

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable {
    case `default` = "Default"
    case speaker = "Speaker"
    case waveform = "Waveform"
    case equalizer = "Equalizer"

    var id: String { rawValue }

    /// The icon name - either asset catalog name or SF Symbol
    var iconName: String {
        switch self {
        case .default: return "MenuBarIcon"
        case .speaker: return "speaker.wave.2.fill"
        case .waveform: return "waveform"
        case .equalizer: return "slider.vertical.3"
        }
    }

    /// Whether this uses an SF Symbol (vs asset catalog image)
    var isSystemSymbol: Bool {
        self != .default
    }
}

// MARK: - HUD Style

/// Style of the on-screen HUD shown when media keys drive FineTune's volume.
/// `.tahoe` renders a small top-right pill; `.classic` renders a center-bottom panel
/// with 16 segment tiles matching Apple's pre-Tahoe HUD aesthetic.
enum HUDStyle: String, Codable, CaseIterable, Identifiable {
    case tahoe
    case classic

    var id: String { rawValue }
}

// MARK: - Appearance Preference

/// User preference for app appearance. `.system` follows macOS appearance live;
/// `.light` and `.dark` lock the override regardless of system setting.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case system
    case light
    case dark

    var id: String { rawValue }

    var description: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

extension AppearancePreference {
    /// `.system` resolves concrete because `.preferredColorScheme(nil)` doesn't
    /// re-propagate after a previously-locked value (HwS forum 23260, Apple
    /// Forums 658818). Live system flips are picked up via `WindowAppearanceBridge`.
    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// AppKit appearance override. `nil` means "inherit from window or app".
    /// Apply via `nsView.window?.appearance = value` for any `NSWindow`/`NSPanel`
    /// the app hosts (popup, popover, HUD).
    /// `.aqua` available since macOS 10.9; `.darkAqua` since 10.14.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Menu Bar Popup Layout

/// Popup width preset. Decoupled from density so the user can choose how wide the
/// popup is independently of how much vertical breathing room its rows get.
enum MenuBarPopupWidth: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case narrow
    case medium
    case wide

    var id: String { rawValue }

    var description: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide: return "Wide"
        }
    }

    /// Fixed popup width in points.
    var points: CGFloat {
        switch self {
        case .narrow: return 470
        case .medium: return 510
        case .wide: return 560
        }
    }
}

/// Popup density preset — controls outer padding and the vertical breathing room
/// between sections, without affecting width.
enum MenuBarPopupDensity: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    /// Outer padding around the popup content.
    var contentPadding: CGFloat {
        switch self {
        case .compact: return 12
        case .comfortable: return 16
        case .spacious: return 20
        }
    }

    /// Vertical spacing between the popup's major sections (devices, sound
    /// effects, apps, footer) and around their dividers.
    var sectionSpacing: CGFloat {
        switch self {
        case .compact: return 4
        case .comfortable: return 8
        case .spacious: return 12
        }
    }

    /// Ceiling on the scrollable body. Sized to stay within a 13" MacBook Air's
    /// usable height after the menu bar, since FluidMenuBarExtra does not clamp
    /// the popup against `screen.visibleFrame` vertically.
    var maxContentHeight: CGFloat {
        switch self {
        case .compact: return 560
        case .comfortable: return 660
        case .spacious: return 760
        }
    }
}

/// Resolved popup geometry, composed from independent width + density choices.
struct PopupDimensions: Equatable {
    let width: CGFloat
    let contentPadding: CGFloat
    let sectionSpacing: CGFloat
    let maxContentHeight: CGFloat
}

// MARK: - Legacy combined size (migration only)

/// Pre-split "size" preset that bundled width + density together. Retained only
/// so persisted `popupSize` values migrate into the new independent
/// `popupWidth` + `popupDensity` settings; it is no longer surfaced in the UI.
enum MenuBarPopupSize: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var description: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    /// Width half of the legacy preset, for migration.
    var legacyWidth: MenuBarPopupWidth {
        switch self {
        case .compact: return .narrow
        case .comfortable: return .medium
        case .spacious: return .wide
        }
    }

    /// Density half of the legacy preset, for migration.
    var legacyDensity: MenuBarPopupDensity {
        switch self {
        case .compact: return .compact
        case .comfortable: return .comfortable
        case .spacious: return .spacious
        }
    }
}

// MARK: - Volume Hotkey Step Size

enum VolumeHotkeyStep: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case coarse
    case normal
    case fine
    case extraFine

    var id: String { rawValue }

    var sliderDelta: Double {
        switch self {
        case .coarse:    return 1.0 / 8.0
        case .normal:    return 1.0 / 16.0
        case .fine:      return 1.0 / 32.0
        case .extraFine: return 1.0 / 64.0
        }
    }

    var description: String {
        switch self {
        case .coarse:    return "Coarse (12.5%)"
        case .normal:    return "Normal (6.25%)"
        case .fine:      return "Fine (3.13%)"
        case .extraFine: return "Extra-Fine (1.56%)"
        }
    }
}

// MARK: - App-Wide Settings Model

nonisolated struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Audio Processing
    var loudnessCompensationEnabled: Bool = false  // ISO 226:2023 equal-loudness contour compensation
    var loudnessEqualizationEnabled: Bool = false  // Real-time loudness equalization

    // Media Keys & HUD
    var hudStyle: HUDStyle = .tahoe                // Visual style of the volume HUD
    var mediaKeyControlEnabled: Bool = true        // Intercept F10/F11/F12 to drive the default output device
    var volumeHotkeyStep: VolumeHotkeyStep = .normal  // Slider-domain step per keypress; user-configurable

    // Global Hotkeys
    // Keyed by ShortcutAction.rawValue. Values mirror what KeyboardShortcuts persists in
    // its UserDefaults; settings.json is the source of truth.
    var customShortcuts: [String: ShortcutCodable] = [:]

    /// Bundle ID of the app the F7/F8/F9 media keys (Previous / Play-Pause / Next)
    /// control. `nil` means FineTune doesn't intercept those keys — they pass
    /// through to macOS as usual. Set by marking an app in the popup's Apps section.
    var mediaTargetBundleID: String? = nil

    // Appearance
    var appearance: AppearancePreference = .system  // Follow system appearance, or lock light/dark

    // Popup layout — width and density are independent.
    var popupWidth: MenuBarPopupWidth = .medium
    var popupDensity: MenuBarPopupDensity = .comfortable
    /// Whether the system "Sound Effects" (alert volume) row appears in the popup.
    var showSoundEffectsRow: Bool = true
    /// Legacy combined size — kept only so older settings files migrate into
    /// `popupWidth` + `popupDensity` (see `init(from:)`). Not shown in the UI.
    var popupSize: MenuBarPopupSize = .comfortable

    init() {}

    mutating func setUnifiedLoudnessEnabled(_ enabled: Bool) {
        loudnessCompensationEnabled = enabled
        loudnessEqualizationEnabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        defaultNewAppVolume = try c.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        lockInputDevice = try c.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        showDeviceDisconnectAlerts = try c.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        loudnessEqualizationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessEqualizationEnabled) ?? false
        hudStyle = try c.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .tahoe
        mediaKeyControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaKeyControlEnabled) ?? true
        volumeHotkeyStep = try c.decodeIfPresent(VolumeHotkeyStep.self, forKey: .volumeHotkeyStep) ?? .normal
        customShortcuts = try c.decodeIfPresent([String: ShortcutCodable].self, forKey: .customShortcuts) ?? [:]
        mediaTargetBundleID = try c.decodeIfPresent(String.self, forKey: .mediaTargetBundleID)
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system

        // Popup layout. Migrate the legacy combined `popupSize` into the new
        // independent width + density when the new keys are absent, so an
        // upgrading user keeps the size they had.
        let legacyPopupSize = try c.decodeIfPresent(MenuBarPopupSize.self, forKey: .popupSize)
        popupSize = legacyPopupSize ?? .comfortable
        popupWidth = try c.decodeIfPresent(MenuBarPopupWidth.self, forKey: .popupWidth)
            ?? legacyPopupSize?.legacyWidth ?? .medium
        popupDensity = try c.decodeIfPresent(MenuBarPopupDensity.self, forKey: .popupDensity)
            ?? legacyPopupSize?.legacyDensity ?? .comfortable
        showSoundEffectsRow = try c.decodeIfPresent(Bool.self, forKey: .showSoundEffectsRow) ?? true
    }
}

extension AppSettings {
    /// Resolved popup geometry from the current width + density selection.
    var popupDimensions: PopupDimensions {
        PopupDimensions(
            width: popupWidth.points,
            contentPadding: popupDensity.contentPadding,
            sectionSpacing: popupDensity.sectionSpacing,
            maxContentHeight: popupDensity.maxContentHeight
        )
    }
}
