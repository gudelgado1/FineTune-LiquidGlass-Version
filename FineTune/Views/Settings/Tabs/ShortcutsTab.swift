// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Status badges
    //
    // Section headers expose at-a-glance state so users can scan the tab
    // without opening every card. Each badge resolves the same source of
    // truth the rows themselves use, so they stay in sync automatically
    // through SwiftUI's data flow (@Bindable settings, @Bindable status).

    private var mediaKeysBadge: String {
        if !settings.appSettings.mediaKeyControlEnabled { return "Disabled" }
        if !accessibility.isTrustedCached { return "Needs Accessibility" }
        if mediaKeyStatus.isOffline { return "Offline" }
        return "Active"
    }

    private var hotkeysBadge: String {
        let configured = ShortcutAction.allCases
            .reduce(into: 0) { count, action in
                if KeyboardShortcuts.getShortcut(for: shortcutsRegistry.name(for: action)) != nil {
                    count += 1
                }
            }
        switch configured {
        case 0: return "None set"
        case 1: return "1 configured"
        default: return "\(configured) configured"
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Volume Step",
                description: "How much each keypress changes the volume. Applies to media keys, configured hotkeys, and arrow-key nav in the popup."
            ) {
                Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                    ForEach(VolumeHotkeyStep.allCases) { step in
                        Text(step.description).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys", badge: mediaKeysBadge) {
            SettingsRow(
                "Media Keys Control",
                description: "Use F11/F12 (or volume keys) to control FineTune"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            // The Accessibility prompt now lives as a persistent banner at
            // the top of the Settings window (see `AccessibilityBanner` in
            // SettingsRootView), reachable from every tab. We don't duplicate
            // it inline here.

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "HUD Style",
                    description: "How the volume indicator appears"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        SettingsSection("Hotkeys", badge: hotkeysBadge) {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                HotkeyRow(
                    action: action,
                    description: description(for: action),
                    shortcutsRegistry: shortcutsRegistry
                )
            }
        }
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "Show or hide the menu bar popup"
        case .targetAppVolumeUp: "Raise volume for the app playing audio"
        case .targetAppVolumeDown: "Lower volume for the app playing audio"
        case .targetAppMuteToggle: "Mute or unmute the app playing audio"
        }
    }
}

// MARK: - Hotkey Row

/// One hotkey configuration row: the `KeyboardShortcuts.Recorder` for binding
/// a key combination, plus a hover-revealed reset button (`↺`) that clears
/// the binding without forcing the user through the recorder's UI. Tracking
/// hover per-row (rather than at the section level) keeps the chrome quiet —
/// the reset only appears for the row the mouse is over, and only when a
/// shortcut is currently set.
@MainActor
private struct HotkeyRow: View {
    let action: ShortcutAction
    let description: String
    let shortcutsRegistry: ShortcutsRegistry

    @State private var isHovered = false
    @State private var isResetHovered = false
    /// Bumped whenever we clear the shortcut, so the recorder re-reads its
    /// stored value and the `hasShortcut` check below reflects reality.
    @State private var refreshTick = 0

    /// Live check: is there a binding set for this action right now?
    private var hasShortcut: Bool {
        _ = refreshTick
        return KeyboardShortcuts.getShortcut(for: shortcutsRegistry.name(for: action)) != nil
    }

    var body: some View {
        SettingsRow(action.displayName, description: description) {
            HStack(spacing: 6) {
                // Reset button — only meaningful when a shortcut exists; on
                // hover only, so the row stays visually quiet at rest.
                if hasShortcut && isHovered {
                    Button {
                        KeyboardShortcuts.reset(shortcutsRegistry.name(for: action))
                        refreshTick &+= 1
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                isResetHovered
                                    ? Color.primary
                                    : DesignTokens.Colors.textTertiary
                            )
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isResetHovered = $0 }
                    .help("Reset shortcut")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }

                KeyboardShortcuts.Recorder(
                    for: shortcutsRegistry.name(for: action),
                    onChange: { newShortcut in
                        shortcutsRegistry.recordCallback(for: action)(newShortcut)
                        refreshTick &+= 1
                    }
                )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
