// FineTune/Views/Settings/Components/AudioOverviewCard.swift
import SwiftUI

/// At-a-glance summary of the user's audio routing and processing state, shown
/// at the top of the Audio tab. Read-only — every value resolves to a deeper
/// control either elsewhere in this tab or in the menu-bar popup. The card's
/// purpose is orientation: a returning user can verify "yes, my AirPods are
/// the default and Loudness is on" without scanning every section.
///
/// Aligned property rows keep long device names readable without truncation.
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
        SettingsSection("Overview") {
            overviewRow("Output device", value: defaultOutputName)
            SettingsRowDivider()
            overviewRow("Input device", value: defaultInputName)
            SettingsRowDivider()
            overviewRow("Equalizer", value: appsWithActiveEQ == 0
                        ? "No apps configured" : "\(appsWithActiveEQ) app\(appsWithActiveEQ == 1 ? "" : "s") active")
            SettingsRowDivider()
            overviewRow("Loudness", value: loudnessIsOn ? "Enabled" : "Disabled")
        }
    }

    private func overviewRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
