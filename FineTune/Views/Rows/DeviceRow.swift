// FineTune/Views/Rows/DeviceRow.swift
import SwiftUI

/// A row displaying a device with volume controls.
/// Used in the Output Devices section.
///
/// Volume mapping depends on the device's `volumeBackend`:
/// - **Hardware**: Identity mapping (slider == HAL scalar). CoreAudio's VirtualMainVolume
///   scalar is already audio-tapered by the driver — IOAudioLevelControl applies a dB curve
///   by default (see `setLinearScale()` in IOAudioLevelControl.h). Empirically confirmed:
///   scalar 0.50 → −50 dB, scalar 0.10 → −90 dB (100 dB range, linear-in-dB).
/// - **DDC**: Identity mapping (slider == DDC 0–100 / 100). DDC writes VCP 0x62 (Audio
///   Speaker Volume) as an integer 0–100 directly to the monitor via I2C, bypassing the HAL
///   entirely. The monitor's firmware handles perceptual mapping internally. Identity matches
///   the OSD values users see on the physical display. MonitorControl uses the same approach.
/// - **Software**: VolumeMapping x² curve. Software gain is a linear PCM amplitude multiplier
///   that needs perceptual scaling (dr-lex.be, Discord perceptual).
///
/// See: IOAudioLevelControl.h, MCCS VCP 0x62, empirical ScalarToDecibels measurement.
struct DeviceRow: View {
    let device: AudioDevice
    let isDefault: Bool
    let volume: Float
    let isMuted: Bool
    /// The device's volume backend. Determines which slider ↔ value mapping to use.
    let volumeBackend: VolumeControlTier
    let onSetDefault: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void

    // AutoEQ (all optional — existing call sites work without them)
    let autoEQProfileName: String?
    let autoEQEnabled: Bool
    let onAutoEQToggle: ((Bool) -> Void)?
    let autoEQProfileManager: AutoEQProfileManager?
    let autoEQSelection: AutoEQSelection?
    let autoEQFavoriteIDs: Set<String>
    let onAutoEQSelect: ((AutoEQProfile?) -> Void)?
    let onAutoEQImport: (() -> Void)?
    let onAutoEQToggleFavorite: ((String) -> Void)?
    let autoEQImportError: String?
    let autoEQPreampEnabled: Bool
    let onAutoEQPreampToggle: (() -> Void)?
    let isFocused: Bool
    /// Whether the inline AutoEQ inspector is open under this row. Mirrors the
    /// `isEQExpanded` pattern of `AppRow` so device AutoEQ expansion uses the
    /// same `expandedRowID` state as per-app EQ in `MenuBarPopupView`.
    let isAutoEQExpanded: Bool
    /// Caller toggles the parent's `expandedRowID` for this device's UID.
    let onAutoEQToggleExpansion: () -> Void

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isRowHovered = false
    @State private var isPercentageEditing = false
    @State private var suppressSliderAutoUnmute = false
    /// Suppresses write-back when slider is being synced from a device volume change.
    /// Breaks the quantization feedback loop on USB DACs with discrete dB steps.
    @State private var isUpdatingSliderFromDevice = false

    /// The displayed percentage value, matching EditablePercentage's formula.
    /// Used for icon and unmute logic so visual state stays consistent with the label.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when system muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because SwiftUI Slider
    /// and volume clamping can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    /// Default slider position to restore when unmuting from 0 (50%)
    private let defaultUnmuteVolume: Double = 0.5

    init(
        device: AudioDevice,
        isDefault: Bool,
        volume: Float,
        isMuted: Bool,
        volumeBackend: VolumeControlTier = .hardware,
        onSetDefault: @escaping () -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        autoEQProfileName: String? = nil,
        autoEQEnabled: Bool = false,
        onAutoEQToggle: ((Bool) -> Void)? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        autoEQSelection: AutoEQSelection? = nil,
        autoEQFavoriteIDs: Set<String> = [],
        onAutoEQSelect: ((AutoEQProfile?) -> Void)? = nil,
        onAutoEQImport: (() -> Void)? = nil,
        onAutoEQToggleFavorite: ((String) -> Void)? = nil,
        autoEQImportError: String? = nil,
        autoEQPreampEnabled: Bool = true,
        onAutoEQPreampToggle: (() -> Void)? = nil,
        isFocused: Bool = false,
        isAutoEQExpanded: Bool = false,
        onAutoEQToggleExpansion: @escaping () -> Void = {}
    ) {
        self.device = device
        self.isDefault = isDefault
        self.volume = volume
        self.isMuted = isMuted
        self.volumeBackend = volumeBackend
        self.onSetDefault = onSetDefault
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.autoEQProfileName = autoEQProfileName
        self.autoEQEnabled = autoEQEnabled
        self.onAutoEQToggle = onAutoEQToggle
        self.autoEQProfileManager = autoEQProfileManager
        self.autoEQSelection = autoEQSelection
        self.autoEQFavoriteIDs = autoEQFavoriteIDs
        self.onAutoEQSelect = onAutoEQSelect
        self.onAutoEQImport = onAutoEQImport
        self.onAutoEQToggleFavorite = onAutoEQToggleFavorite
        self.autoEQImportError = autoEQImportError
        self.autoEQPreampEnabled = autoEQPreampEnabled
        self.onAutoEQPreampToggle = onAutoEQPreampToggle
        self.isFocused = isFocused
        self.isAutoEQExpanded = isAutoEQExpanded
        self.onAutoEQToggleExpansion = onAutoEQToggleExpansion
        self._sliderValue = State(initialValue: Self.volumeToSlider(volume, backend: volumeBackend))
    }

    var body: some View {
        // Every connected output device gets the inline AutoEQ inspector,
        // even when no profile is selected yet — the user can browse, import,
        // and visualize a flat baseline curve. Same expansion mechanism as
        // the per-app EQ inspector and the DeviceEditRow inspector. The only
        // gate is `autoEQProfileManager != nil`, because without the manager
        // there is genuinely nothing the panel can do.
        if autoEQProfileManager != nil {
            ExpandableGlassRow(
                isExpanded: isAutoEQExpanded,
                isFocused: isFocused
            ) {
                deviceHeader
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Outer-chrome tap (badge area, gaps around the slider)
                        // still sets the device as default. The device-name area
                        // captures its own tap below to toggle AutoEQ expansion,
                        // so the two gestures don't collide.
                        if !isDefault {
                            onSetDefault()
                        }
                    }
            } expandedContent: {
                if let profileManager = autoEQProfileManager {
                    AutoEQExpandedPanel(
                        profileManager: profileManager,
                        selection: autoEQSelection,
                        favoriteIDs: autoEQFavoriteIDs,
                        isCorrectionEnabled: autoEQEnabled,
                        preampEnabled: autoEQPreampEnabled,
                        importErrorMessage: autoEQImportError,
                        onCorrectionToggle: { onAutoEQToggle?($0) },
                        onPreampToggle: { onAutoEQPreampToggle?() },
                        onSelectProfile: { onAutoEQSelect?($0) },
                        onImport: { onAutoEQImport?() },
                        onToggleFavorite: { onAutoEQToggleFavorite?($0) }
                    )
                }
            }
        } else {
            deviceHeader
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isDefault {
                        onSetDefault()
                    }
                }
                .hoverableRow(isFocused: isFocused)
        }
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Tinted badge replaces the prior leading RadioButton.
            // Selection is now signalled by accent-colored gradient on the
            // badge plus bold device name; the row-level gesture in `body`
            // handles tap-to-set-default.
            DeviceBadge(icon: device.icon, isSelected: isDefault)

            // Device name + optional AutoEQ profile subtitle.
            // For AutoEQ-capable devices the name area also acts as the
            // expansion trigger — clicking the name opens the inline AutoEQ
            // inspector below this row, exactly like clicking a device name
            // in Edit mode opens the Device Inspector pane. No separate
            // wand icon: the affordance is the name itself.
            HStack(spacing: DesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(device.name)
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help(device.name)

                        if autoEQProfileManager != nil {
                            // Subtle chevron hints the name is expandable.
                            // Rotates 90° when open — same motion vocabulary
                            // as the EQ button and the DeviceEditRow info button.
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(
                                    isAutoEQExpanded
                                        ? DesignTokens.Colors.accentPrimary
                                        : DesignTokens.Colors.textTertiary
                                )
                                .rotationEffect(.degrees(isAutoEQExpanded ? 90 : 0))
                                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isAutoEQExpanded)
                        }
                    }

                    if let subtitle = Self.autoEQSubtitle(profileName: autoEQProfileName, isEnabled: autoEQEnabled) {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Inner tap on the name area — toggles the AutoEQ inspector.
            // Inner gestures win over the outer row-level tap, so set-default
            // still fires on the badge area / surrounding chrome but the
            // name itself opens the inspector. Matches DeviceEditRow exactly.
            .contentShape(Rectangle())
            .onTapGesture {
                if autoEQProfileManager != nil {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        onAutoEQToggleExpansion()
                    }
                } else if !isDefault {
                    onSetDefault()
                }
            }

            // Mute button
            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    // Unmute: restore to default if displayed as 0%
                    if displayedPercentage == 0 {
                        suppressSliderAutoUnmute = isMuted
                        sliderValue = defaultUnmuteVolume
                    }
                    if isMuted {
                        onMuteToggle()  // Toggle system mute
                    }
                } else {
                    // Mute
                    onMuteToggle()  // Toggle system mute
                }
            }

            // Volume slider (Liquid Glass)
            LiquidGlassSlider(
                value: $sliderValue,
                onEditingChanged: { editing in
                    isEditing = editing
                }
            )
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .onChange(of: sliderValue) { _, newValue in
                // Skip write-back when syncing from device (breaks USB DAC quantization spiral)
                if isUpdatingSliderFromDevice {
                    isUpdatingSliderFromDevice = false
                    return
                }
                onVolumeChange(Self.sliderToVolume(newValue, backend: volumeBackend))
                if suppressSliderAutoUnmute {
                    suppressSliderAutoUnmute = false
                    return
                }
                // Auto-unmute when slider moved while muted
                if isMuted && newValue > 0 {
                    onMuteToggle()
                }
            }
            .scrollWheelStep($sliderValue, in: 0.0...1.0)

            // Editable volume percentage — collapses to zero width when hidden,
            // expands + fades in on row hover/drag/edit. No layout gap at rest.
            EditablePercentage(
                percentage: Binding(
                    get: { Int(round(sliderValue * 100)) },
                    set: { sliderValue = Double($0) / 100.0 }
                ),
                range: 0...100,
                onEditingChanged: { editing in
                    withAnimation(DesignTokens.Animation.hover) { isPercentageEditing = editing }
                }
            )
            .opacity(isRowHovered || isEditing || isPercentageEditing ? 1 : 0)
            .frame(width: isRowHovered || isEditing || isPercentageEditing ? DesignTokens.Dimensions.percentageWidth : 0)
            .clipped()
            .animation(DesignTokens.Animation.hover, value: isRowHovered || isEditing || isPercentageEditing)
        }
        .frame(height: DesignTokens.Dimensions.rowContentHeight)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.hover) { isRowHovered = hovering }
        }
        .onChange(of: volume) { _, newValue in
            // Only sync from external changes when user is NOT dragging
            guard !isEditing else { return }
            let newSlider = Self.volumeToSlider(newValue, backend: volumeBackend)
            guard newSlider != sliderValue else { return }
            isUpdatingSliderFromDevice = true
            sliderValue = newSlider
        }
    }
}

extension DeviceRow {
    // MARK: - Volume Mapping

    static func volumeToSlider(_ volume: Float, backend: VolumeControlTier) -> Double {
        VolumeMapping.sliderFraction(forSystemGain: volume, tier: backend)
    }

    static func sliderToVolume(_ slider: Double, backend: VolumeControlTier) -> Float {
        VolumeMapping.systemGain(forSliderFraction: slider, tier: backend)
    }

    // MARK: - Subtitle

    static func autoEQSubtitle(profileName: String?, isEnabled: Bool) -> String? {
        guard let profileName else { return nil }
        return isEnabled ? profileName : "\(profileName) (off)"
    }
}

// MARK: - Previews

#Preview("Device Row - Default") {
    PreviewContainer {
        VStack(spacing: 0) {
            DeviceRow(
                device: MockData.sampleDevices[0],
                isDefault: true,
                volume: 0.75,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[1],
                isDefault: false,
                volume: 1.0,
                isMuted: false,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )

            DeviceRow(
                device: MockData.sampleDevices[2],
                isDefault: false,
                volume: 0.5,
                isMuted: true,
                onSetDefault: {},
                onVolumeChange: { _ in },
                onMuteToggle: {}
            )
        }
    }
}
