// FineTune/Views/Settings/Components/AudioOverviewCard.swift
import SwiftUI

/// At-a-glance summary of the user's audio routing and processing state, shown
/// at the top of the Audio tab. Read-only — every value resolves to a deeper
/// control either elsewhere in this tab or in the menu-bar popup. The card's
/// purpose is orientation: a returning user can verify "yes, my AirPods are
/// the default and Loudness is on" without scanning every section.
///
/// Layout is a 2×2 grid of compact info chips. Falls back gracefully when a
/// device is missing (e.g. no input mic plugged in).
@MainActor
struct AudioOverviewCard: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    // MARK: - Resolved values

    /// Human-readable name of the current default output device.
    /// Falls back to "—" so the layout never collapses to nothing.
    private var defaultOutputName: String {
        guard let uid = deviceVolumeMonitor.defaultDeviceUID,
              let device = audioEngine.outputDevices.first(where: { $0.uid == uid })
        else { return "None" }
        return device.name
    }

    private var defaultInputName: String {
        guard let uid = deviceVolumeMonitor.defaultInputDeviceUID,
              let device = audioEngine.inputDevices.first(where: { $0.uid == uid })
        else { return "None" }
        return device.name
    }

    /// Count of apps that have a non-trivial EQ enabled. Resolved by
    /// `SettingsManager.activeAppEQCount`, which encapsulates the
    /// "flat-but-enabled doesn't count" rule (see `EQSettings.isActive`).
    private var appsWithActiveEQ: Int {
        settings.activeAppEQCount
    }

    private var loudnessIsOn: Bool {
        settings.appSettings.loudnessCompensationEnabled
            && settings.appSettings.loudnessEqualizationEnabled
    }

    // MARK: - Body

    var body: some View {
        // 2×2 grid keeps the card compact even at narrow Settings widths.
        // Each Grid row pins to the same baseline for visual alignment.
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                chip(systemImage: "speaker.wave.2.fill",
                     label: "Output",
                     value: defaultOutputName,
                     tint: .blue)

                chip(systemImage: "mic.fill",
                     label: "Input",
                     value: defaultInputName,
                     tint: .purple)
            }
            GridRow {
                chip(systemImage: "slider.vertical.3",
                     label: "EQ",
                     value: appsWithActiveEQ == 0
                         ? "No apps configured"
                         : "\(appsWithActiveEQ) app\(appsWithActiveEQ == 1 ? "" : "s") active",
                     tint: appsWithActiveEQ > 0 ? .green : .secondary)

                chip(systemImage: loudnessIsOn ? "waveform.path.ecg" : "waveform",
                     label: "Loudness",
                     value: loudnessIsOn ? "On" : "Off",
                     tint: loudnessIsOn ? .green : .secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Colors.eqCardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.6)
        }
    }

    // MARK: - Chip builder

    /// One info chip in the grid: tinted symbol + small label + bold value.
    /// `Spacer(minLength: 0)` after the value lets the chip stretch to the
    /// full grid cell width so two chips in a row are evenly balanced.
    @ViewBuilder
    private func chip(
        systemImage: String,
        label: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(0.04))
        }
    }
}
