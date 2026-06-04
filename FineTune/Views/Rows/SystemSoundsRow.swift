// FineTune/Views/Rows/SystemSoundsRow.swift
import SwiftUI

/// Popup row for the macOS system **alert volume** plus an expandable selector for
/// the **system-sounds output device** (`kAudioHardwarePropertyDefaultSystemOutputDevice`
/// — System Settings → Sound → "Play sound effects through").
///
/// Layout mirrors `AppRow`: a leading badge, the name + a chevron that expands an
/// inline panel (the same motion vocabulary as the per-app EQ / per-device AutoEQ),
/// then mute + Liquid Glass alert slider + hover-reveal percentage. The expanded
/// panel lists the output devices so sound effects can be routed straight from the
/// popup instead of only Settings → Audio.
///
/// **DDC note:** the alert volume is a macOS-software scalar, independent of a
/// monitor's DDC hardware volume (VCP 0x62).
struct SystemSoundsRow: View {
    let alertVolume: Float
    let onAlertVolumeChange: (Float) -> Void

    // Routing: where system sound effects play, and the selector callbacks.
    let devices: [AudioDevice]
    let selectedDeviceUID: String?
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?

    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelectDevice: (String) -> Void
    let onSelectFollowDefault: () -> Void

    let isFocused: Bool

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isRowHovered = false
    @State private var isPercentageEditing = false
    /// Slider position restored when unmuting from 0.
    @State private var preMuteVolume: Double = 0.5
    /// Suppresses write-back when the slider is synced from an external change.
    @State private var isUpdatingSliderFromExternal = false

    private let defaultUnmuteVolume: Double = 0.5

    init(
        alertVolume: Float,
        onAlertVolumeChange: @escaping (Float) -> Void,
        devices: [AudioDevice],
        selectedDeviceUID: String?,
        isFollowingDefault: Bool,
        defaultDeviceUID: String?,
        isExpanded: Bool,
        onToggleExpand: @escaping () -> Void,
        onSelectDevice: @escaping (String) -> Void,
        onSelectFollowDefault: @escaping () -> Void,
        isFocused: Bool = false
    ) {
        self.alertVolume = alertVolume
        self.onAlertVolumeChange = onAlertVolumeChange
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isFollowingDefault = isFollowingDefault
        self.defaultDeviceUID = defaultDeviceUID
        self.isExpanded = isExpanded
        self.onToggleExpand = onToggleExpand
        self.onSelectDevice = onSelectDevice
        self.onSelectFollowDefault = onSelectFollowDefault
        self.isFocused = isFocused
        self._sliderValue = State(initialValue: Double(max(0, min(1, alertVolume))))
    }

    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }
    private var showMutedIcon: Bool { displayedPercentage == 0 }

    /// Where system sounds currently play — shown as the row subtitle. `nil` while
    /// following the default (the row collapses to a single line, like `AppRow`).
    private var routingSubtitle: String? {
        if isFollowingDefault { return nil }
        if let uid = selectedDeviceUID, let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return nil
    }

    var body: some View {
        ExpandableGlassRow(
            isExpanded: isExpanded,
            isFocused: isFocused,
            onHoverChanged: { isRowHovered = $0 }
        ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Leading bell badge — marks this as the system alert/effects channel.
                DeviceBadge(icon: nil, isSelected: false, fallbackSymbol: "bell.fill")

                // Name + chevron — tapping toggles the inline device selector, the
                // same motion as the per-app EQ and per-device AutoEQ panels.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Sound Effects")
                            .font(DesignTokens.Typography.rowName)
                            .lineLimit(1)
                            .help("Sound Effects")

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(
                                isExpanded
                                    ? DesignTokens.Colors.accentPrimary
                                    : DesignTokens.Colors.textTertiary
                            )
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isExpanded)
                    }

                    if let subtitle = routingSubtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }

                // Mute: alert volume → 0, restoring the prior level on unmute.
                MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                    if showMutedIcon {
                        sliderValue = preMuteVolume > 0 ? preMuteVolume : defaultUnmuteVolume
                    } else {
                        preMuteVolume = sliderValue
                        sliderValue = 0
                    }
                }

                // Alert volume — linear 0...1 macOS scalar (no perceptual tier mapping).
                LiquidGlassSlider(
                    value: $sliderValue,
                    onEditingChanged: { editing in isEditing = editing }
                )
                .opacity(showMutedIcon ? 0.5 : 1.0)
                .onChange(of: sliderValue) { _, newValue in
                    if isUpdatingSliderFromExternal {
                        isUpdatingSliderFromExternal = false
                        return
                    }
                    onAlertVolumeChange(Float(newValue))
                }
                .scrollWheelStep($sliderValue, in: 0.0...1.0)

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
            .onChange(of: alertVolume) { _, newValue in
                guard !isEditing else { return }
                let clamped = Double(max(0, min(1, newValue)))
                guard clamped != sliderValue else { return }
                isUpdatingSliderFromExternal = true
                sliderValue = clamped
            }
        } expandedContent: {
            deviceSelector
        }
    }

    /// Inline list of output devices for routing system sound effects — "System
    /// Audio" (follow default) plus each connected device, with the active one
    /// checked. Occupies the same expanded-content slot the EQ panel uses.
    private var deviceSelector: some View {
        let followSymbol = devices.first(where: { $0.uid == defaultDeviceUID })?.id.suggestedIconSymbol() ?? "circle.dashed"
        return VStack(spacing: 1) {
            SoundEffectsDeviceOption(
                label: "System Audio",
                symbol: followSymbol,
                isSelected: isFollowingDefault,
                action: onSelectFollowDefault
            )
            ForEach(devices, id: \.uid) { device in
                SoundEffectsDeviceOption(
                    label: device.name,
                    symbol: device.id.suggestedIconSymbol(),
                    isSelected: !isFollowingDefault && device.uid == selectedDeviceUID,
                    action: { onSelectDevice(device.uid) }
                )
            }
        }
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, 2)
    }
}

/// One selectable device row inside the Sound Effects expanded panel.
private struct SoundEffectsDeviceOption: View {
    let label: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary)

                Text(label)
                    .font(DesignTokens.Typography.rowName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.accentPrimary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
