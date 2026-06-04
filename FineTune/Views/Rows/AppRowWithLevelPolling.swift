// FineTune/Views/Rows/AppRowWithLevelPolling.swift
import SwiftUI

/// App row that polls audio levels in sync with the display refresh.
///
/// Uses `TimelineView(.animation)` instead of `Timer.scheduledTimer` so that:
/// - Updates align with display vsync (no torn frames)
/// - On ProMotion displays the VU meter runs at up to 120 Hz automatically
/// - On non-ProMotion displays it caps at the display rate (60 Hz)
/// - The timeline pauses when the popup is hidden (no wasted ticks)
/// - No separate `Timer` per row competing on the main RunLoop
struct AppRowWithLevelPolling: View {
    let app: AudioApp
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let onBoostChange: (BoostLevel) -> Void
    let getAudioLevel: () -> Float
    let isPopupVisible: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    let onAppActivate: () -> Void
    let eqSettings: EQSettings
    let userPresets: [UserEQPreset]
    let onEQChange: (EQSettings) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void
    let isEQExpanded: Bool
    let onEQToggle: () -> Void
    let isFocused: Bool
    let isMediaTarget: Bool
    let onToggleMediaTarget: () -> Void

    // No Timer/State needed — TimelineView drives reads directly from
    // `getAudioLevel()` on every display refresh tick. When the popup is
    // hidden the timeline pauses and the meter renders zero.

    init(
        app: AudioApp,
        volume: Float,
        isMuted: Bool,
        devices: [AudioDevice],
        selectedDeviceUID: String,
        selectedDeviceUIDs: Set<String> = [],
        isFollowingDefault: Bool = true,
        defaultDeviceUID: String? = nil,
        deviceSelectionMode: DeviceSelectionMode = .single,
        boost: BoostLevel = .x1,
        onBoostChange: @escaping (BoostLevel) -> Void = { _ in },
        getAudioLevel: @escaping () -> Float,
        isPopupVisible: Bool = true,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteChange: @escaping (Bool) -> Void,
        onDeviceSelected: @escaping (String) -> Void,
        onDevicesSelected: @escaping (Set<String>) -> Void = { _ in },
        onDeviceModeChange: @escaping (DeviceSelectionMode) -> Void = { _ in },
        onSelectFollowDefault: @escaping () -> Void = {},
        onAppActivate: @escaping () -> Void = {},
        eqSettings: EQSettings = EQSettings(),
        userPresets: [UserEQPreset] = [],
        onEQChange: @escaping (EQSettings) -> Void = { _ in },
        onUserPresetSelected: @escaping (UserEQPreset) -> Void = { _ in },
        onSavePreset: @escaping (String, EQSettings) -> Void = { _, _ in },
        onDeleteUserPreset: @escaping (UUID) -> Void = { _ in },
        onRenameUserPreset: @escaping (UUID, String) -> Void = { _, _ in },
        isEQExpanded: Bool = false,
        onEQToggle: @escaping () -> Void = {},
        isFocused: Bool = false,
        isMediaTarget: Bool = false,
        onToggleMediaTarget: @escaping () -> Void = {}
    ) {
        self.app = app
        self.volume = volume
        self.isMuted = isMuted
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.selectedDeviceUIDs = selectedDeviceUIDs
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.deviceSelectionMode = deviceSelectionMode
        self.boost = boost
        self.onBoostChange = onBoostChange
        self.getAudioLevel = getAudioLevel
        self.isPopupVisible = isPopupVisible
        self.onVolumeChange = onVolumeChange
        self.onMuteChange = onMuteChange
        self.onDeviceSelected = onDeviceSelected
        self.onDevicesSelected = onDevicesSelected
        self.onDeviceModeChange = onDeviceModeChange
        self.onSelectFollowDefault = onSelectFollowDefault
        self.onAppActivate = onAppActivate
        self.eqSettings = eqSettings
        self.userPresets = userPresets
        self.onEQChange = onEQChange
        self.onUserPresetSelected = onUserPresetSelected
        self.onSavePreset = onSavePreset
        self.onDeleteUserPreset = onDeleteUserPreset
        self.onRenameUserPreset = onRenameUserPreset
        self.isEQExpanded = isEQExpanded
        self.onEQToggle = onEQToggle
        self.isFocused = isFocused
        self.isMediaTarget = isMediaTarget
        self.onToggleMediaTarget = onToggleMediaTarget
    }

    var body: some View {
        // `.animation` ticks at display refresh (60 Hz / 120 Hz on ProMotion).
        // `minimumInterval` caps the rate so we don't redraw faster than the
        // VU peak smoothing factor (~30 ms attack/decay) can usefully reflect.
        // `paused` halts the schedule when the popup is hidden — zero CPU at idle.
        TimelineView(
            .animation(
                minimumInterval: DesignTokens.Timing.vuMeterUpdateInterval,
                paused: !isPopupVisible
            )
        ) { _ in
            AppRow(
                app: app,
                volume: volume,
                audioLevel: isPopupVisible ? getAudioLevel() : 0,
                devices: devices,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                deviceSelectionMode: deviceSelectionMode,
                isMuted: isMuted,
                boost: boost,
                onBoostChange: onBoostChange,
                onVolumeChange: onVolumeChange,
                onMuteChange: onMuteChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onDeviceModeChange: onDeviceModeChange,
                onSelectFollowDefault: onSelectFollowDefault,
                onAppActivate: onAppActivate,
                eqSettings: eqSettings,
                userPresets: userPresets,
                onEQChange: onEQChange,
                onUserPresetSelected: onUserPresetSelected,
                onSavePreset: onSavePreset,
                onDeleteUserPreset: onDeleteUserPreset,
                onRenameUserPreset: onRenameUserPreset,
                isEQExpanded: isEQExpanded,
                onEQToggle: onEQToggle,
                isFocused: isFocused,
                isMediaTarget: isMediaTarget,
                onToggleMediaTarget: onToggleMediaTarget
            )
        }
    }
}
