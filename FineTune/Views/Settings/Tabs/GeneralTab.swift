// FineTune/Views/Settings/Tabs/GeneralTab.swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// General app preferences. Sections are consolidated into conceptual groups
/// — `General` (system integration), `Appearance` (visual style across menu
/// bar and popup), `Backup` (export/import of settings), and a `Danger Zone`
/// at the bottom for destructive actions. This shape matches Apple's System
/// Settings density: each section holds multiple related rows instead of
/// having one section per toggle.
@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false
    @State private var backupErrorMessage: String?

    /// Counts shown in the reset confirmation so the user sees exactly what
    /// will be wiped. Re-evaluated each time the dialog opens via the
    /// `.confirmationDialog` data binding.
    private var resetSummary: String {
        let volumes = settings.appSettings.launchAtLogin ? "" : ""
        _ = volumes // (placeholder so we don't keep an unused warning)
        let eqCount = settings.activeAppEQCount
        return "This cannot be undone. "
            + "\(eqCount) app EQ \(eqCount == 1 ? "setting" : "settings"), "
            + "plus all volume preferences, device routings, hotkeys, "
            + "and AutoEQ selections, will be removed."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            generalSection
            appearanceSection
            backupSection
            dangerZoneSection

            if let error = backupErrorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetSummary)
        }
    }

    // MARK: - General

    /// System integration toggles: how FineTune relates to login, notifications,
    /// and other OS-level behaviours.
    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow(
                "Launch at Login",
                description: "Start FineTune when you log in",
                systemImage: "power"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Device Disconnect Alerts",
                description: "Notify when a connected audio device disappears",
                systemImage: "bell"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
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

    // MARK: - Backup

    /// Export the in-memory settings as a portable JSON file, and import a
    /// previously-exported file back. Useful for migrating between Macs or
    /// keeping a snapshot before experimenting with EQs and routings.
    private var backupSection: some View {
        SettingsSection("Backup") {
            SettingsRow(
                "Export Settings",
                description: "Save all preferences to a .json file",
                systemImage: "square.and.arrow.up"
            ) {
                Button("Export…") { exportSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            SettingsRowDivider()
            SettingsRow(
                "Import Settings",
                description: "Restore preferences from a previously exported file",
                systemImage: "square.and.arrow.down"
            ) {
                Button("Import…") { importSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Danger Zone

    /// Destructive actions live in their own visually-distinct card at the
    /// bottom. The red-tinted button and explicit "Danger Zone" framing makes
    /// the reset action impossible to trigger by accident while still keeping
    /// it discoverable.
    private var dangerZoneSection: some View {
        SettingsSection("Danger Zone") {
            SettingsRow(
                "Reset All Settings",
                description: "Clear every volume, EQ, AutoEQ, and device routing",
                systemImage: "arrow.counterclockwise"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Export / Import actions

    /// Encodes the current settings to JSON and writes them to a
    /// user-chosen file. Uses a date-stamped default filename so successive
    /// exports don't overwrite each other accidentally.
    private func exportSettings() {
        backupErrorMessage = nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let dateStamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "FineTune-Settings-\(dateStamp).json"
        panel.message = "Export FineTune settings as a JSON snapshot"

        // LSUIElement apps need explicit foreground activation for save
        // panels — otherwise the picker can drop behind whatever other
        // window had focus, same trick as `importAutoEQFile`.
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try settings.exportData()
                    try data.write(to: url, options: [.atomic])
                } catch {
                    backupErrorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Reads a previously-exported JSON file and replaces the in-memory
    /// settings. Invalid input surfaces an error message inline instead of
    /// silently failing or crashing.
    private func importSettings() {
        backupErrorMessage = nil

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import a previously exported FineTune settings JSON"

        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try Data(contentsOf: url)
                    try settings.importData(data)
                } catch {
                    backupErrorMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
