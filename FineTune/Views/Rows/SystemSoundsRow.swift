// FineTune/Views/Rows/SystemSoundsRow.swift
import SwiftUI

/// Popup row for the macOS system **alert volume** — the same value as System
/// Settings → Sound → "Sound Effects" → Alert volume, driven through
/// `DeviceVolumeMonitor.setAlertVolume`.
///
/// Layout is a copy of `DeviceRow`/`AppRow` (same `ExpandableGlassRow` container,
/// 28 pt leading badge, name + optional subtitle, then mute + Liquid Glass slider +
/// hover-reveal percentage) so it aligns pixel-for-pixel with those rows. The
/// leading badge is decorative; the routed device is shown as the subtitle, and
/// the routing target itself is changed in Settings → Audio.
///
/// **DDC note:** the alert volume is a macOS-software scalar, independent of a
/// monitor's DDC hardware volume (VCP 0x62). A monitor exposes a single hardware
/// volume that attenuates the entire HDMI stream — effects included — so there is no
/// separate per-effects hardware level to capture. This row surfaces the macOS-side
/// controls that *are* adjustable.
struct SystemSoundsRow: View {
    let alertVolume: Float
    let onAlertVolumeChange: (Float) -> Void

    // Read-only routing info for the subtitle (routing is changed in Settings → Audio).
    let devices: [AudioDevice]
    let selectedDeviceUID: String?
    let isFollowingDefault: Bool

    let isFocused: Bool

    @State private var sliderValue: Double
    @State private var isEditing = false
    @State private var isRowHovered = false
    @State private var isPercentageEditing = false
    /// Slider position restored when unmuting from 0.
    @State private var preMuteVolume: Double = 0.5
    /// Suppresses write-back when the slider is being synced from an external
    /// alert-volume change (poll / Settings edit), mirroring `DeviceRow`.
    @State private var isUpdatingSliderFromExternal = false

    private let defaultUnmuteVolume: Double = 0.5

    init(
        alertVolume: Float,
        onAlertVolumeChange: @escaping (Float) -> Void,
        devices: [AudioDevice],
        selectedDeviceUID: String?,
        isFollowingDefault: Bool,
        isFocused: Bool = false
    ) {
        self.alertVolume = alertVolume
        self.onAlertVolumeChange = onAlertVolumeChange
        self.devices = devices
        self.selectedDeviceUID = selectedDeviceUID
        self.isFollowingDefault = isFollowingDefault
        self.isFocused = isFocused
        self._sliderValue = State(initialValue: Double(max(0, min(1, alertVolume))))
    }

    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }
    private var showMutedIcon: Bool { displayedPercentage == 0 }

    /// Where system sounds currently play — shown as the row subtitle. Returns
    /// `nil` while following the default device (the leading badge already shows
    /// that device's icon), mirroring `AppRow`'s routing subtitle behavior so the
    /// row collapses to a single line in that case.
    private var routingSubtitle: String? {
        if isFollowingDefault { return nil }
        if let uid = selectedDeviceUID, let device = devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return nil
    }

    var body: some View {
        // Same container as AppRow / DeviceRow so padding, hover surface, corner
        // radius, and height match exactly. There's no expandable panel here, so
        // `isExpanded` is always false and the expanded content is empty.
        ExpandableGlassRow(
            isExpanded: false,
            isFocused: isFocused,
            onHoverChanged: { isRowHovered = $0 }
        ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                // Leading 28 pt control — the routed device's badge, tappable to
                // re-route. Matches the device-row badge column.
                routingPicker

                // Name + optional routed-device subtitle, identical structure to
                // AppRow/DeviceRow (rowName on top, 9 pt tertiary subtitle below).
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound Effects")
                        .font(DesignTokens.Typography.rowName)
                        .lineLimit(1)
                        .help("Sound Effects")

                    if let subtitle = routingSubtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Mute: alert volume → 0, restoring the prior level on unmute.
                MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                    if showMutedIcon {
                        sliderValue = preMuteVolume > 0 ? preMuteVolume : defaultUnmuteVolume
                    } else {
                        preMuteVolume = sliderValue
                        sliderValue = 0
                    }
                }

                // Alert volume — linear 0...1 (the macOS alert scalar, not a device
                // gain, so no perceptual tier mapping is applied).
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
                // Sync from external changes only when the user isn't dragging.
                guard !isEditing else { return }
                let clamped = Double(max(0, min(1, newValue)))
                guard clamped != sliderValue else { return }
                isUpdatingSliderFromExternal = true
                sliderValue = clamped
            }
        } expandedContent: {
            EmptyView()
        }
    }

    /// Leading badge — a clean circular `DeviceBadge`, pixel-identical to the
    /// device-row badges, with a fixed bell glyph marking this as the system
    /// alert/effects channel. Decorative: routing for sound effects lives in
    /// Settings → Audio (a popup-anchored picker mis-positions, and the native
    /// menu clashed with the glass styling).
    private var routingPicker: some View {
        DeviceBadge(icon: nil, isSelected: false, fallbackSymbol: "bell.fill")
    }
}
