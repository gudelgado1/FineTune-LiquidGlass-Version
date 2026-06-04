// FineTune/Views/MenuBarPopupView+AppRows.swift
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Section Views

extension MenuBarPopupView {

    // MARK: - Media transport target

    /// Whether `bundleID` is the app the media-transport shortcuts currently drive.
    func isMediaTarget(bundleID: String?) -> Bool {
        guard let bundleID,
              let target = audioEngine.settingsManager.appSettings.mediaTargetBundleID
        else { return false }
        return target == bundleID
    }

    /// Marks `bundleID` as the media-transport target, or clears it if already set
    /// (so the marker acts as an exclusive on/off). Copy-mutate-reassign routes
    /// through `SettingsManager.updateAppSettings` for persistence.
    func toggleMediaTarget(bundleID: String?) {
        guard let bundleID else { return }
        var updated = audioEngine.settingsManager.appSettings
        updated.mediaTargetBundleID = (updated.mediaTargetBundleID == bundleID) ? nil : bundleID
        audioEngine.settingsManager.appSettings = updated
    }

    @ViewBuilder
    func appsSection(scrollProxy: ScrollViewProxy) -> some View {
        HStack {
            SectionHeader(title: "Apps")
            Spacer()
            let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
            if ignoredCount > 0 && !isEditingDevicePriority {
                Text("\(ignoredCount) ignored")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.bottom, DesignTokens.Spacing.xs)

        if permission.status != .authorized {
            PermissionBannerView(permission: permission)
        } else if isEditingDevicePriority {
            appEditModeContent
        } else if audioEngine.displayableApps.isEmpty {
            emptyStateView
        } else {
            appsContent(scrollProxy: scrollProxy)
        }
    }

    /// Edit mode content for apps: simplified rows with eye toggle + hidden section at bottom.
    private var appEditColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: DesignTokens.Spacing.xs),
            GridItem(.flexible(), spacing: DesignTokens.Spacing.xs)
        ]
    }

    @ViewBuilder
    var appEditModeContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            // Visible apps in 2-column grid
            LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                ForEach(audioEngine.displayableApps) { displayableApp in
                    switch displayableApp {
                    case .active(let app):
                        AppEditRow(
                            icon: app.icon,
                            name: app.name,
                            isIgnored: false,
                            isPinned: audioEngine.isPinned(app),
                            onToggleVisibility: { audioEngine.ignoreApp(app) },
                            onTogglePin: {
                                if audioEngine.isPinned(app) {
                                    audioEngine.unpinApp(app.persistenceIdentifier)
                                } else {
                                    audioEngine.pinApp(app)
                                }
                            }
                        )
                    case .pinnedInactive(let info):
                        AppEditRow(
                            icon: displayableApp.icon,
                            name: info.displayName,
                            isIgnored: false,
                            isPinned: true,
                            onToggleVisibility: {
                                let hiddenInfo = IgnoredAppInfo(
                                    persistenceIdentifier: info.persistenceIdentifier,
                                    displayName: info.displayName,
                                    bundleID: info.bundleID
                                )
                                audioEngine.settingsManager.ignoreApp(info.persistenceIdentifier, info: hiddenInfo)
                            },
                            onTogglePin: {
                                audioEngine.unpinApp(info.persistenceIdentifier)
                            }
                        )
                    }
                }
            }

            // Ignored apps section
            let ignoredApps = audioEngine.settingsManager.getIgnoredAppInfo()
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !ignoredApps.isEmpty {
                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xs)

                Text("Ignored")
                    .sectionHeaderStyle()
                    .padding(.bottom, DesignTokens.Spacing.xs)

                LazyVGrid(columns: appEditColumns, spacing: DesignTokens.Spacing.xs) {
                    ForEach(ignoredApps, id: \.persistenceIdentifier) { info in
                        AppEditRow(
                            icon: DisplayableApp.loadIcon(bundleID: info.bundleID),
                            name: info.displayName,
                            isIgnored: true,
                            isPinned: false,
                            onToggleVisibility: { audioEngine.unignoreApp(info.persistenceIdentifier) },
                            onTogglePin: {}
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func appsContent(scrollProxy: ScrollViewProxy) -> some View {
        let presets = audioEngine.settingsManager.getUserPresets()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(audioEngine.displayableApps) { displayableApp in
                switch displayableApp {
                case .active(let app):
                    activeAppRow(app: app, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)

                case .pinnedInactive(let info):
                    inactiveAppRow(info: info, displayableApp: displayableApp, userPresets: presets, scrollProxy: scrollProxy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Row for an active app (currently producing audio)
    @ViewBuilder
    func activeAppRow(app: AudioApp, displayableApp: DisplayableApp, userPresets: [UserEQPreset], scrollProxy: ScrollViewProxy) -> some View {
        if let deviceUID = audioEngine.getDeviceUID(for: app) {
            AppRowWithLevelPolling(
                app: app,
                volume: audioEngine.getVolume(for: app),
                isMuted: audioEngine.getMute(for: app),
                devices: sortedDevices,
                selectedDeviceUID: deviceUID,
                selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDs(for: app),
                isFollowingDefault: audioEngine.isFollowingDefault(for: app),
                defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                deviceSelectionMode: audioEngine.getDeviceSelectionMode(for: app),
                boost: audioEngine.getBoost(for: app),
                onBoostChange: { boost in
                    audioEngine.setBoost(for: app, to: boost)
                },
                getAudioLevel: { audioEngine.getAudioLevel(for: app) },
                isPopupVisible: isPopupVisible,
                onVolumeChange: { volume in
                    audioEngine.setVolume(for: app, to: volume)
                },
                onMuteChange: { muted in
                    audioEngine.setMute(for: app, to: muted)
                },
                onDeviceSelected: { newDeviceUID in
                    audioEngine.setDevice(for: app, deviceUID: newDeviceUID)
                },
                onDevicesSelected: { uids in
                    audioEngine.setSelectedDeviceUIDs(for: app, to: uids)
                },
                onDeviceModeChange: { mode in
                    audioEngine.setDeviceSelectionMode(for: app, to: mode)
                },
                onSelectFollowDefault: {
                    audioEngine.setDevice(for: app, deviceUID: nil)
                },
                onAppActivate: {
                    activateApp(pid: app.id, bundleID: app.bundleID)
                },
                eqSettings: audioEngine.getEQSettings(for: app),
                userPresets: userPresets,
                onEQChange: { settings in
                    audioEngine.setEQSettings(settings, for: app)
                },
                onUserPresetSelected: { userPreset in
                    // Apply only bandGains — preserve app's current isEnabled state
                    var current = audioEngine.getEQSettings(for: app)
                    current.bandGains = userPreset.settings.bandGains
                    audioEngine.setEQSettings(current, for: app)
                },
                onSavePreset: { name, settings in
                    audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
                },
                onDeleteUserPreset: { id in
                    audioEngine.settingsManager.deleteUserPreset(id: id)
                },
                onRenameUserPreset: { id, newName in
                    audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
                },
                isEQExpanded: expandedRowID == displayableApp.id,
                onEQToggle: {
                    toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
                },
                isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id),
                isMediaTarget: isMediaTarget(bundleID: app.bundleID),
                onToggleMediaTarget: { toggleMediaTarget(bundleID: app.bundleID) }
            )
            .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
        }
    }

    /// Row for a pinned inactive app (not currently producing audio)
    @ViewBuilder
    func inactiveAppRow(info: PinnedAppInfo, displayableApp: DisplayableApp, userPresets: [UserEQPreset], scrollProxy: ScrollViewProxy) -> some View {
        let identifier = info.persistenceIdentifier
        InactiveAppRow(
            appInfo: info,
            icon: displayableApp.icon,
            volume: audioEngine.getVolumeForInactive(identifier: identifier),
            devices: sortedDevices,
            selectedDeviceUID: audioEngine.getDeviceRoutingForInactive(identifier: identifier),
            selectedDeviceUIDs: audioEngine.getSelectedDeviceUIDsForInactive(identifier: identifier),
            isFollowingDefault: audioEngine.isFollowingDefaultForInactive(identifier: identifier),
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            deviceSelectionMode: audioEngine.getDeviceSelectionModeForInactive(identifier: identifier),
            isMuted: audioEngine.getMuteForInactive(identifier: identifier),
            boost: audioEngine.getBoostForInactive(identifier: identifier),
            onBoostChange: { boost in
                audioEngine.setBoostForInactive(identifier: identifier, to: boost)
            },
            onVolumeChange: { volume in
                audioEngine.setVolumeForInactive(identifier: identifier, to: volume)
            },
            onMuteChange: { muted in
                audioEngine.setMuteForInactive(identifier: identifier, to: muted)
            },
            onDeviceSelected: { newDeviceUID in
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: newDeviceUID)
            },
            onDevicesSelected: { uids in
                audioEngine.setSelectedDeviceUIDsForInactive(identifier: identifier, to: uids)
            },
            onDeviceModeChange: { mode in
                audioEngine.setDeviceSelectionModeForInactive(identifier: identifier, to: mode)
            },
            onSelectFollowDefault: {
                audioEngine.setDeviceRoutingForInactive(identifier: identifier, deviceUID: nil)
            },
            eqSettings: audioEngine.getEQSettingsForInactive(identifier: identifier),
            userPresets: userPresets,
            onEQChange: { settings in
                audioEngine.setEQSettingsForInactive(settings, identifier: identifier)
            },
            onUserPresetSelected: { userPreset in
                // Apply only bandGains — preserve app's current isEnabled state
                var current = audioEngine.getEQSettingsForInactive(identifier: identifier)
                current.bandGains = userPreset.settings.bandGains
                audioEngine.setEQSettingsForInactive(current, identifier: identifier)
            },
            onSavePreset: { name, settings in
                audioEngine.settingsManager.createUserPreset(name: name, settings: settings)
            },
            onDeleteUserPreset: { id in
                audioEngine.settingsManager.deleteUserPreset(id: id)
            },
            onRenameUserPreset: { id, newName in
                audioEngine.settingsManager.updateUserPreset(id: id, name: newName)
            },
            isEQExpanded: expandedRowID == displayableApp.id,
            onEQToggle: {
                toggleEQ(for: displayableApp.id, scrollProxy: scrollProxy)
            },
            isFocused: hasKeyboardEngaged && selectedRow == .app(persistenceID: displayableApp.id),
            isMediaTarget: isMediaTarget(bundleID: info.bundleID),
            onToggleMediaTarget: { toggleMediaTarget(bundleID: info.bundleID) }
        )
        .id(PopupKeyboardNavModel.RowID.app(persistenceID: displayableApp.id))
    }

    /// Toggle EQ panel for an app (shared between active and inactive rows)
    func toggleEQ(for appID: String, scrollProxy: ScrollViewProxy) {
        guard !isEQAnimating else { return }
        isEQAnimating = true

        let isExpanding = expandedRowID != appID
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedRowID == appID {
                expandedRowID = nil
            } else {
                expandedRowID = appID
            }
            if isExpanding {
                scrollProxy.scrollTo(PopupKeyboardNavModel.RowID.app(persistenceID: appID), anchor: .top)
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(0.4))
            isEQAnimating = false
        }
    }

    // MARK: - App Activation Helper

    /// Activates an app, bringing it to foreground and restoring minimized windows
    func activateApp(pid: pid_t, bundleID: String?) {
        // Step 1: Always activate via NSRunningApplication (reliable for non-minimized)
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        runningApp?.activate()

        // Step 2: Try to restore minimized windows via AppleScript
        if let bundleID = bundleID {
            // reopen + activate restores minimized windows for most apps
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)"
                    reopen
                    activate
                end tell
                """)
            script?.executeAndReturnError(nil)
        }
    }

    // MARK: - AutoEQ File Import

    /// Opens a file panel to import a ParametricEQ.txt for a device.
    ///
    /// FineTune is an `LSUIElement` (menu-bar agent — no Dock icon), so
    /// `NSOpenPanel` needs explicit foreground activation; otherwise it
    /// can open *behind* whatever app the user was previously using.
    /// The previous `resignKey()` call only dismissed our own popup but
    /// didn't bring the picker forward.
    ///
    /// Fix:
    ///   1. `NSApp.activate(ignoringOtherApps: true)` — promote FineTune
    ///      to foreground so the new window inherits key/main status.
    ///   2. `panel.level = .modalPanel` — pin the picker above all other
    ///      windows even if another app steals focus mid-animation.
    func importAutoEQFile(for deviceUID: String) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an AutoEQ ParametricEQ.txt file"
        panel.level = .modalPanel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task { @MainActor in
                if let profile = audioEngine.autoEQProfileManager.importProfile(from: url, name: name) {
                    audioEngine.setAutoEQProfile(for: deviceUID, profileID: profile.id)
                    autoEQImportError = nil
                } else {
                    autoEQImportError = "Could not read profile — check file format"
                    importErrorClearTask?.cancel()
                    importErrorClearTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation { autoEQImportError = nil }
                    }
                }
            }
        }
    }
}
