import SwiftUI

@MainActor
struct AppearanceTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        appearanceSection
    }

    // MARK: - Appearance

    /// Everything visual: theme, menu bar icon, popup density. Grouped because
    /// users typically tune all three together when personalising the app.
    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            SettingsRow(
                "Theme",
                description: "Match macOS, or lock to Light or Dark",
                systemImage: "circle.lefthalf.filled"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "Menu Bar Icon",
                description: "How FineTune appears in your menu bar",
                systemImage: "menubar.rectangle"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Width",
                description: "How wide the menu bar popup is",
                systemImage: "arrow.left.and.right"
            ) {
                PopupWidthTilePicker(selection: $settings.appSettings.popupWidth)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Density",
                description: "Breathing room between sections",
                systemImage: "arrow.up.and.down"
            ) {
                PopupDensityTilePicker(selection: $settings.appSettings.popupDensity)
            }
            SettingsRowDivider()
            SettingsRow(
                "Sound Effects Row",
                description: "Show the system alert-volume control in the popup",
                systemImage: "bell"
            ) {
                Toggle("", isOn: $settings.appSettings.showSoundEffectsRow)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

}
