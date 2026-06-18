// FineTune/Audio/Engine/AudioEngine+TapManagement.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@MainActor
extension AudioEngine {
    func updateTapForCurrentMode(for app: AudioApp) async {
        let mode = getDeviceSelectionMode(for: app)

        let deviceUIDs: [String]
        switch mode {
        case .single:
            if isFollowingDefault(for: app), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else if let deviceUID = appDeviceRouting[app.id] {
                deviceUIDs = [deviceUID]
            } else if let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
                deviceUIDs = [defaultUID]
            } else {
                logger.warning("No device available for \(app.name) in single mode")
                return
            }

        case .multi:
            let selectedUIDs = getSelectedDeviceUIDs(for: app).sorted()
            if selectedUIDs.isEmpty {
                return
            }
            deviceUIDs = selectedUIDs
        }

        // Update or create tap with the device set
        if let tap = taps[app.id] {
            // Tap exists - update devices
            if tap.currentDeviceUIDs != deviceUIDs {
                do {
                    let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
                    try await tap.updateDevices(to: deviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
                    logger.debug("Updated \(app.name) to \(deviceUIDs.count) device(s)")
                } catch {
                    logger.error("Failed to update devices for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            // No tap exists - create one
            ensureTapWithDevices(for: app, deviceUIDs: deviceUIDs)
        }
    }

    /// Creates a tap with the specified device UIDs
    func ensureTapWithDevices(for app: AudioApp, deviceUIDs: [String]) {
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }
        guard !pidsBeingRecreated.contains(app.id) else { return }  // recreation in flight
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: deviceUIDs, isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)

            try tap.activate()
            taps[app.id] = tap
            // A tap created while load-shedding is active must start bypassed too,
            // otherwise a tap recreated mid-pressure would re-introduce DSP cost.
            if isDSPLoadShed { tap.setDSPBypass(true) }

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.setAutoEQPreampEnabled(settingsManager.autoEQPreampEnabled)
            applyAutoEQToTap(tap)
            var loudnessEqSettings = LoudnessEqualizerSettings()
            loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
            tap.updateLoudnessEqualization(loudnessEqSettings)
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: settingsManager.appSettings.loudnessCompensationEnabled
            )

            logger.debug("Created tap for \(app.name) on \(deviceUIDs.count) device(s)")
        } catch {
            recordTapCreationFailure()
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }
    func ensureTapExists(for app: AudioApp, deviceUID: String) {
        guard taps[app.id] == nil else { return }
        guard !pidsBeingRecreated.contains(app.id) else { return }  // recreation in flight
        guard permission.status == .authorized else { return }

        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [deviceUID], isFollowsDefault: followsDefault.contains(app.id))
        do {
            let tap = try tapFactory(app, [deviceUID], preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: [deviceUID])

            try tap.activate()
            taps[app.id] = tap
            // A tap created while load-shedding is active must start bypassed too,
            // otherwise a tap recreated mid-pressure would re-introduce DSP cost.
            if isDSPLoadShed { tap.setDSPBypass(true) }

            // Load and apply persisted EQ settings
            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.setAutoEQPreampEnabled(settingsManager.autoEQPreampEnabled)
            applyAutoEQToTap(tap)
            var loudnessEqSettings = LoudnessEqualizerSettings()
            loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
            tap.updateLoudnessEqualization(loudnessEqSettings)
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: settingsManager.appSettings.loudnessCompensationEnabled
            )

            logger.debug("Created tap for \(app.name)")
        } catch {
            recordTapCreationFailure()
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
        }
    }

    /// Restores the default to `lastConfirmedDefaultUID` (what the user/FineTune intended).
    func cleanupStaleTaps() {
        let activePIDs = Set(apps.map { $0.id })
        let stalePIDs = Set(taps.keys).subtracting(activePIDs)

        // Distinguish apps that merely PAUSED from apps that actually QUIT.
        //
        // `apps` only contains processes whose `kAudioProcessPropertyIsRunning` is
        // true, so a paused media app drops out of it. But its audio process object
        // stays registered with the HAL (`readProcessList()`) until the app releases
        // its audio session (i.e. quits). We keep a paused app's tap "warm" so that,
        // when it resumes, the `.mutedWhenTapped` mute is already engaged and audio
        // flows straight through the existing gain stage — eliminating the brief
        // onset volume bump that a freshly-recreated tap produces (the app would
        // otherwise play at full volume for the moment before the new tap activates).
        // Only processes whose audio objects have disappeared are torn down.
        let liveObjectIDs = Set((try? AudioObjectID.readProcessList()) ?? [])
        let pausedPIDs = stalePIDs.filter { pid in
            guard let tap = taps[pid] else { return false }
            let objs = tap.app.processObjectIDs
            return !objs.isEmpty && objs.contains(where: liveObjectIDs.contains)
        }
        let goneePIDs = stalePIDs.subtracting(pausedPIDs)

        // Cancel pending cleanup for PIDs that reappeared (active) or that merely
        // paused (still alive). For reappeared PIDs, honor the PID-reuse guard so a
        // recycled PID belonging to a different app doesn't rescue the old tap.
        for pid in activePIDs.union(pausedPIDs) {
            guard let task = pendingCleanup[pid] else { continue }

            let reappearedApp = apps.first { $0.id == pid }
            let existingTap = taps[pid]

            if let reappearedApp, let existingTap,
               reappearedApp.bundleID != existingTap.app.bundleID {
                // PID was reused by a different app — let the old tap be destroyed
                logger.debug("PID \(pid) reused by different app (\(reappearedApp.bundleID ?? "nil") vs \(existingTap.app.bundleID ?? "nil")), not cancelling cleanup")
                continue
            }

            pendingCleanup.removeValue(forKey: pid)
            task.cancel()
            // Don't remove from appliedPIDs — the tap is still alive and the aggregate
            // device is still running. The process just transiently stopped audio I/O
            // (kAudioProcessPropertyIsRunning flicker) or paused. Device routing is
            // already handled by routeFollowsDefaultApps (follows-default) or stays put
            // (explicit routing). Re-processing would cause an unnecessary crossfade.
            logger.debug("Cancelled pending cleanup for PID \(pid) - app reappeared or paused")
        }

        // Schedule cleanup only for PIDs whose audio process objects are gone (quit).
        for pid in goneePIDs {
            guard pendingCleanup[pid] == nil else { continue }  // Already pending

            pendingCleanup[pid] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }

                // Double-check still stale and still gone. A paused app whose audio
                // objects are still registered must keep its warm tap (re-check the
                // HAL list, since the app may have paused — not quit — since scheduling).
                let currentPIDs = Set(self.apps.map { $0.id })
                let stillLive = Set((try? AudioObjectID.readProcessList()) ?? [])
                let stillAlive = self.taps[pid]?.app.processObjectIDs.contains(where: stillLive.contains) ?? false
                guard !currentPIDs.contains(pid), !stillAlive else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                }
                self.appDeviceRouting.removeValue(forKey: pid)
                self.followsDefault.remove(pid)
                self.appliedPIDs.remove(pid)  // Allow re-initialization if app resumes
                self.pendingCleanup.removeValue(forKey: pid)
            }
        }

        // Keep state for active apps, apps pending teardown, AND paused-but-alive apps
        // whose warm tap we're deliberately retaining.
        let pidsToKeep = activePIDs
            .union(Set(pendingCleanup.keys))
            .union(pausedPIDs)
        appliedPIDs = appliedPIDs.intersection(pidsToKeep)
        followsDefault = followsDefault.intersection(pidsToKeep)
        volumeState.cleanup(keeping: pidsToKeep)
    }

    /// Debounced stale tap cleanup — coalesces rapid app-list changes into a single cleanup pass.
    /// Uses the centralized `taskScheduler`: re-scheduling the same `.staleCleanup`
    /// ID cancels any prior pending task, giving us debounce semantics for free.
    func scheduleStaleCleanup() {
        taskScheduler.schedule(.staleCleanup, after: .milliseconds(350)) { [weak self] in
            self?.cleanupStaleTaps()
        }
    }

    // MARK: - Tap Health Monitor

    /// Starts a periodic health check that recreates unresponsive taps.
    /// Checks every 2 seconds; after 3 consecutive misses (~6s), the tap is presumed dead.
    /// Tracks `consecutiveMisses` via a closure-captured dictionary so the loop
    /// state lives only as long as the scheduled task — re-starting the monitor
    /// resets the miss counts cleanly.
    func startHealthMonitor() {
        // Arm the off-main proactive triggers (memory pressure / wake) alongside
        // the periodic monitor. Idempotent — safe to call from both the init path
        // and observePermissionGranted().
        startResilienceObservers()
        guard !taskScheduler.activeIDs.contains(.healthMonitor) else { return }
        // `consecutiveMisses` lives outside the closure so successive ticks
        // share state; the closure captures it by reference. The scheduler
        // owns the loop — restarting via stopHealthMonitor() + startHealthMonitor()
        // gives a fresh closure and a fresh miss map.
        var consecutiveMisses: [pid_t: Int] = [:]
        taskScheduler.scheduleRepeating(.healthMonitor, every: .seconds(2)) { [weak self] in
            guard let self else { return }

            // Self-heal: an actively-streaming app with no tap is otherwise never
            // retried. `applyPersistedSettings()` only runs on app-list changes, and
            // the responsiveness loop below only inspects EXISTING taps — so a one-off
            // tap-creation failure (startup race, device momentarily busy, or the
            // orphan-cleanup-vs-recreate race after a crash) would leave that app
            // uncaptured until its audio next flickers. Re-apply to create the missing
            // tap(s). MUST run before the no-taps guard so it still fires when the
            // failure left `taps` empty.
            let appsMissingTaps = self.apps.filter {
                self.taps[$0.id] == nil && !self.settingsManager.isIgnored($0.persistenceIdentifier)
            }
            if !appsMissingTaps.isEmpty {
                // Drop any stale "applied" mark so applyPersistedSettings retries them.
                for app in appsMissingTaps { self.appliedPIDs.remove(app.id) }
                self.logger.debug("Health self-heal: \(appsMissingTaps.count) active app(s) missing a tap — re-applying")
                self.applyPersistedSettings()
            }

            // Liveness pass: recreate any tap whose server-side aggregate device
            // was destroyed wholesale (coreaudiod restart under memory pressure,
            // HAL reset, system overload). This is a *direct* resource check, so —
            // unlike the callback-timing checks below — it also catches taps that
            // died before ever rendering a buffer (which `isHealthCheckEligible`
            // would otherwise skip forever). The HDMI/display-sleep guard lives
            // inside recreateDeadTaps().
            await self.recreateDeadTaps()

            // Skip the per-tap responsiveness check when no taps exist (#176)
            guard !self.taps.isEmpty else { return }

            let now = Date()

            for (pid, tap) in self.taps {
                // Skip muted apps — no callbacks while muted isn't a health signal
                guard !tap.isMuted else { continue }

                // Skip PIDs in recovery cooldown to prevent recreation thrashing
                if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                    continue
                }

                guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                // Only health-check apps that are actively streaming (isRunning=true).
                // Paused apps have no callbacks, which is normal — not a health signal.
                let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                guard isActivelyStreaming else {
                    consecutiveMisses[pid] = 0
                    continue
                }

                if tap.hasRecentAudioCallback(within: 3.0) {
                    consecutiveMisses[pid] = 0
                } else {
                    let misses = (consecutiveMisses[pid] ?? 0) + 1
                    consecutiveMisses[pid] = misses
                    self.recordHealthCheckMiss(pid: pid)

                    if misses >= 3 {
                        self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                        consecutiveMisses[pid] = 0
                        await self.recreateTap(for: pid)
                    }
                }
            }

            // Prune entries for PIDs no longer tracked
            consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
            self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
        }
    }

    func stopHealthMonitor() {
        taskScheduler.cancel(.healthMonitor)
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    func recreateTap(for pid: pid_t) async {
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        // Mark in-flight so a concurrent self-heal/ensureTap doesn't create a
        // duplicate tap during the async teardown window below (taps[pid] is nil
        // until we reinsert). Cleared on every exit path.
        pidsBeingRecreated.insert(pid)
        defer { pidsBeingRecreated.remove(pid) }
        let deviceUIDs = oldTap.currentDeviceUIDs
        let previousSourceUID = oldTap.tapSourceDeviceUID
        recordTapRecoveryAttempt(pid: pid)
        await oldTap.invalidateAsync()

        // Find the current AudioApp entry for this PID
        guard let app = apps.first(where: { $0.id == pid }) else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            appliedPIDs.remove(pid)
            tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(12)
            recordTapRecoveryResult(pid: pid, succeeded: false)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        do {
            let preferredTapSourceUID = preferredTapSourceDeviceUID(
                forOutputUIDs: deviceUIDs,
                isFollowsDefault: followsDefault.contains(app.id)
            ) ?? previousSourceUID
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
            try tap.activate()
            taps[app.id] = tap
            // A tap created while load-shedding is active must start bypassed too,
            // otherwise a tap recreated mid-pressure would re-introduce DSP cost.
            if isDSPLoadShed { tap.setDSPBypass(true) }

            let eqSettings = settingsManager.getEQSettings(for: app.persistenceIdentifier)
            tap.updateEQSettings(eqSettings)
            tap.setAutoEQPreampEnabled(settingsManager.autoEQPreampEnabled)
            applyAutoEQToTap(tap)
            var loudnessEqSettings = LoudnessEqualizerSettings()
            loudnessEqSettings.enabled = settingsManager.appSettings.loudnessEqualizationEnabled
            tap.updateLoudnessEqualization(loudnessEqSettings)
            tap.updateLoudnessCompensation(
                volume: effectiveLoudnessVolume(for: tap),
                enabled: settingsManager.appSettings.loudnessCompensationEnabled
            )

            if let firstDeviceUID = deviceUIDs.first {
                appDeviceRouting[app.id] = firstDeviceUID
            }
            appliedPIDs.insert(pid)
            tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(20)
            recordTapRecoveryResult(pid: pid, succeeded: true)
        } catch {
            tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(12)
            recordTapCreationFailure()
            recordTapRecoveryResult(pid: pid, succeeded: false)
            logger.error("Failed to recreate tap for \(app.name): \(error.localizedDescription)")
            return
        }

        // Restore mute state
        if let muted = volumeState.loadSavedMute(for: pid, identifier: app.persistenceIdentifier), muted {
            taps[pid]?.isMuted = true
        }
    }

    // MARK: - Input Device Lock

    /// Handles changes to the default input device.
}
