// FineTune/Audio/Engine/AudioEngine+AppManagement.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@MainActor
extension AudioEngine {
    var apps: [AudioApp] {
        processMonitor.activeApps
    }

    // MARK: - Displayable Apps (Active + Pinned Inactive)

    /// Combined list of active apps and pinned inactive apps for UI display.
    /// Pinned apps appear first (sorted alphabetically), then unpinned active apps (sorted alphabetically).
    var displayableApps: [DisplayableApp] {
        let activeApps = apps
            .filter { !settingsManager.isIgnored($0.persistenceIdentifier) }
        let activeIdentifiers = Set(activeApps.map { $0.persistenceIdentifier })

        // Get pinned apps that are not currently active
        let pinnedInactiveInfos = settingsManager.getPinnedAppInfo()
            .filter { !activeIdentifiers.contains($0.persistenceIdentifier) }

        // Pinned active apps (sorted alphabetically)
        let pinnedActive = activeApps
            .filter { settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        // Pinned inactive apps (sorted alphabetically)
        let pinnedInactive = pinnedInactiveInfos
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { DisplayableApp.pinnedInactive($0) }

        // Unpinned active apps (sorted alphabetically)
        let unpinnedActive = activeApps
            .filter { !settingsManager.isPinned($0.persistenceIdentifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { DisplayableApp.active($0) }

        return pinnedActive + pinnedInactive + unpinnedActive
    }

    // MARK: - Pinning

    /// Pin an active app so it remains visible when inactive.
    func pinApp(_ app: AudioApp) {
        let info = PinnedAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.pinApp(app.persistenceIdentifier, info: info)
    }

    /// Unpin an app by its persistence identifier.
    func unpinApp(_ identifier: String) {
        settingsManager.unpinApp(identifier)
    }

    /// Check if an app is pinned.
    func isPinned(_ app: AudioApp) -> Bool {
        settingsManager.isPinned(app.persistenceIdentifier)
    }

    /// Check if an identifier is pinned (for inactive apps).
    func isPinned(identifier: String) -> Bool {
        settingsManager.isPinned(identifier)
    }

    // MARK: - Ignored Apps

    /// Hide an active app so FineTune ignores it entirely.
    func ignoreApp(_ app: AudioApp) {
        let info = IgnoredAppInfo(
            persistenceIdentifier: app.persistenceIdentifier,
            displayName: app.name,
            bundleID: app.bundleID
        )
        settingsManager.ignoreApp(app.persistenceIdentifier, info: info)

        // Tear down the live tap so audio returns to natural volume
        if let tap = taps.removeValue(forKey: app.id) {
            tap.invalidate()
        }
        appDeviceRouting.removeValue(forKey: app.id)
        followsDefault.remove(app.id)
        appliedPIDs.remove(app.id)
    }

    /// Unhide an app by its persistence identifier.
    /// Immediately creates a tap if the app is currently running.
    func unignoreApp(_ identifier: String) {
        settingsManager.unignoreApp(identifier)
        applyPersistedSettings()
    }

    /// Check if an identifier is hidden.
    func isIgnored(identifier: String) -> Bool {
        settingsManager.isIgnored(identifier)
    }

    // MARK: - Inactive App Settings (by persistence identifier)

    /// Get volume for an inactive app by persistence identifier.
    func getVolumeForInactive(identifier: String) -> Float {
        settingsManager.getVolume(for: identifier) ?? 1.0
    }

    /// Set volume for an inactive app by persistence identifier.
    func setVolumeForInactive(identifier: String, to volume: Float) {
        settingsManager.setVolume(for: identifier, to: volume)
    }

    func getBoostForInactive(identifier: String) -> BoostLevel {
        settingsManager.getBoost(for: identifier) ?? .x1
    }

    func setBoostForInactive(identifier: String, to boost: BoostLevel) {
        settingsManager.setBoost(for: identifier, to: boost)
    }

    /// Get mute state for an inactive app by persistence identifier.
    func getMuteForInactive(identifier: String) -> Bool {
        settingsManager.getMute(for: identifier) ?? false
    }

    /// Set mute state for an inactive app by persistence identifier.
    func setMuteForInactive(identifier: String, to muted: Bool) {
        settingsManager.setMute(for: identifier, to: muted)
    }

    /// Get EQ settings for an inactive app by persistence identifier.
    func getEQSettingsForInactive(identifier: String) -> EQSettings {
        settingsManager.getEQSettings(for: identifier)
    }

    /// Set EQ settings for an inactive app by persistence identifier.
    func setEQSettingsForInactive(_ settings: EQSettings, identifier: String) {
        settingsManager.setEQSettings(settings, for: identifier)
    }

    /// Get device routing for an inactive app by persistence identifier.
    func getDeviceRoutingForInactive(identifier: String) -> String? {
        settingsManager.getDeviceRouting(for: identifier)
    }

    /// Set device routing for an inactive app by persistence identifier.
    func setDeviceRoutingForInactive(identifier: String, deviceUID: String?) {
        if let deviceUID = deviceUID {
            settingsManager.setDeviceRouting(for: identifier, deviceUID: deviceUID)
        } else {
            settingsManager.setFollowDefault(for: identifier)
        }
    }

    /// Check if an inactive app follows system default device.
    func isFollowingDefaultForInactive(identifier: String) -> Bool {
        settingsManager.isFollowingDefault(for: identifier)
    }

    /// Get device selection mode for an inactive app.
    func getDeviceSelectionModeForInactive(identifier: String) -> DeviceSelectionMode {
        settingsManager.getDeviceSelectionMode(for: identifier) ?? .single
    }

    /// Set device selection mode for an inactive app.
    func setDeviceSelectionModeForInactive(identifier: String, to mode: DeviceSelectionMode) {
        settingsManager.setDeviceSelectionMode(for: identifier, to: mode)
    }

    /// Get selected device UIDs for an inactive app (multi-mode).
    func getSelectedDeviceUIDsForInactive(identifier: String) -> Set<String> {
        settingsManager.getSelectedDeviceUIDs(for: identifier) ?? []
    }

    /// Set selected device UIDs for an inactive app (multi-mode).
    func setSelectedDeviceUIDsForInactive(identifier: String, to uids: Set<String>) {
        settingsManager.setSelectedDeviceUIDs(for: identifier, to: uids)
    }

    /// Audio levels for all active apps (for VU meter visualization)
    /// Returns a dictionary mapping PID to peak audio level (0-1)
    var audioLevels: [pid_t: Float] {
        var levels: [pid_t: Float] = [:]
        for (pid, tap) in taps {
            levels[pid] = tap.audioLevel
        }
        return levels
    }

    func applyPersistedSettings() {
        guard permission.status == .authorized else { return }
        for app in apps {
            guard !appliedPIDs.contains(app.id) else { continue }
            guard !settingsManager.isIgnored(app.persistenceIdentifier) else { continue }

            // Load saved device selection mode (single vs multi)
            let savedMode = volumeState.loadSavedDeviceSelectionMode(for: app.id, identifier: app.persistenceIdentifier)
            let mode = savedMode ?? .single

            // Load saved volume, mute, and boost state
            let savedVolume = volumeState.loadSavedVolume(for: app.id, identifier: app.persistenceIdentifier)
            let savedMute = volumeState.loadSavedMute(for: app.id, identifier: app.persistenceIdentifier)
            _ = volumeState.loadSavedBoost(for: app.id, identifier: app.persistenceIdentifier)

            // Handle multi-device mode
            if mode == .multi {
                if let savedUIDs = volumeState.loadSavedSelectedDeviceUIDs(for: app.id, identifier: app.persistenceIdentifier),
                   !savedUIDs.isEmpty {
                    // Filter to currently available devices, maintaining deterministic order
                    let availableUIDs = savedUIDs.filter { deviceMonitor.device(for: $0) != nil }
                        .sorted()  // Deterministic ordering
                    if !availableUIDs.isEmpty {
                        logger.debug("Restoring multi-device mode for \(app.name) with \(availableUIDs.count) device(s)")
                        ensureTapWithDevices(for: app, deviceUIDs: availableUIDs)

                        // Mark as applied if tap created successfully
                        guard taps[app.id] != nil else { continue }
                        // Set primary device routing so the UI row renders
                        appDeviceRouting[app.id] = availableUIDs[0]
                        appliedPIDs.insert(app.id)

                        // Apply volume (with boost) and mute
                        if savedVolume != nil {
                            if let tap = taps[app.id] {
                                applyTapOutputState(to: tap, for: app.id, deviceUIDs: availableUIDs)
                            }
                        }
                        if let muted = savedMute, muted {
                            taps[app.id]?.isMuted = true
                        }
                        continue  // Skip single-device path
                    }
                    // All saved devices unavailable - fall through to single-device mode
                    logger.debug("All multi-mode devices unavailable for \(app.name), falling back to single mode")
                }
            }

            // Single-device mode (or multi-mode fallback)
            let deviceUID: String
            if settingsManager.isFollowingDefault(for: app.persistenceIdentifier) {
                // App follows system default (new app or explicitly set to follow)
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device available for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) follows system default: \(deviceUID)")
            } else if let savedDeviceUID = settingsManager.getDeviceRouting(for: app.persistenceIdentifier),
                      deviceMonitor.device(for: savedDeviceUID) != nil {
                // Explicit device routing exists and device is available
                deviceUID = savedDeviceUID
                logger.debug("Applying saved device routing to \(app.name): \(deviceUID)")
            } else {
                // Saved device temporarily unavailable: fall back to system default for now
                // Don't persist - keep original device preference for when it reconnects
                followsDefault.insert(app.id)
                guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                    logger.warning("No default device for \(app.name), deferring setup")
                    continue
                }
                deviceUID = defaultUID
                logger.debug("App \(app.name) device temporarily unavailable, using default: \(deviceUID)")
            }
            appDeviceRouting[app.id] = deviceUID

            // If a tap already exists but is on the wrong device (e.g., app reappeared
            // after the default changed while it was absent), switch it.
            if let existingTap = taps[app.id], existingTap.currentDeviceUIDs != [deviceUID] {
                let preferredSource = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
                Task {
                    if await self.switchDeviceWithRetry(existingTap, to: [deviceUID], preferredTapSourceDeviceUID: preferredSource) {
                        self.applyTapOutputState(to: existingTap, for: app.id, deviceUIDs: [deviceUID])
                        self.applyAutoEQToTap(existingTap)
                    }
                }
                appliedPIDs.insert(app.id)
                continue
            }

            // Always create tap for audio apps (always-on strategy)
            ensureTapExists(for: app, deviceUID: deviceUID)

            // Only mark as applied if tap was successfully created
            // This allows retry on next applyPersistedSettings() call if tap failed
            guard taps[app.id] != nil else { continue }
            appliedPIDs.insert(app.id)

            if savedVolume != nil {
                let effective = effectiveVolume(for: app.id, deviceUIDs: [deviceUID])
                let displayPercent = Int(effective * 100)
                logger.debug("Applying saved volume \(displayPercent)% (with boost) to \(app.name)")
                taps[app.id]?.volume = effective
            }

            if let muted = savedMute, muted {
                logger.debug("Applying saved mute state to \(app.name)")
                taps[app.id]?.isMuted = true
            }
        }
    }
}
