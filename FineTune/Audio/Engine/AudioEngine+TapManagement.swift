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
        guard captureRebuildTask == nil else { return }
        guard !deviceUIDs.isEmpty else { return }
        guard taps[app.id] == nil else { return }
        guard !pidsBeingRecreated.contains(app.id) else { return }  // recreation in flight
        guard !pidsBeingCreated.contains(app.id) else { return }  // creation in flight (nested run loop re-entry)
        guard permission.status == .authorized else { return }

        // activate() below pumps a nested run loop (waitUntilReady), which can
        // re-enter this method for the same pid via the health monitor or
        // onAppsChanged before `taps[app.id]` is set — creating a duplicate tap
        // whose aggregate device leaks. Mark creation in flight for the window.
        pidsBeingCreated.insert(app.id)
        defer { pidsBeingCreated.remove(app.id) }

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
        guard captureRebuildTask == nil else { return }
        guard taps[app.id] == nil else { return }
        guard !pidsBeingRecreated.contains(app.id) else { return }  // recreation in flight
        guard !pidsBeingCreated.contains(app.id) else { return }  // creation in flight (nested run loop re-entry)
        guard permission.status == .authorized else { return }

        // Same nested-run-loop guard as ensureTapWithDevices: activate() can
        // re-enter tap creation for this pid before the tap lands in `taps`.
        pidsBeingCreated.insert(app.id)
        defer { pidsBeingCreated.remove(app.id) }

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
            DiagnosticLog.log("tap: created for \(app.name)#\(app.id) on \(deviceUID)")
        } catch {
            recordTapCreationFailure()
            logger.error("Failed to create tap for \(app.name): \(error.localizedDescription)")
            DiagnosticLog.log("tap: CREATE FAILED for \(app.name)#\(app.id) on \(deviceUID): \(error.localizedDescription)")
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
        let liveObjectIDs = liveProcessObjectIDs()
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
                let stillLive = self.liveProcessObjectIDs()
                let stillAlive = self.taps[pid]?.app.processObjectIDs.contains(where: stillLive.contains) ?? false
                guard !currentPIDs.contains(pid), !stillAlive else {
                    self.pendingCleanup.removeValue(forKey: pid)
                    return
                }

                // Now safe to cleanup
                if let tap = self.taps.removeValue(forKey: pid) {
                    tap.invalidate()
                    self.logger.debug("Cleaned up stale tap for PID \(pid)")
                    DiagnosticLog.log("cleanup: pid=\(pid) app quit — tap torn down")
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
        var gapDetectors: [pid_t: (identity: ObjectIdentifier, detector: RenderStutterDetector)] = [:]
        var tickCount = 0
        taskScheduler.scheduleRepeating(.healthMonitor, every: .seconds(2)) { [weak self] in
            guard let self else { return }
            guard self.captureRebuildTask == nil else { return }

            // Stand down while the audio system is unresponsive. Tap creation and
            // liveness queries are all blocking HAL IPC; ticking through them
            // every 2 s against a wedged daemon strands a thread per attempt and
            // buys nothing — AudioSystemHealth owns recovery from here.
            guard self.audioSystemHealth.allowsPeriodicHALWork else { return }

            // Heartbeat every ~5 min (150 × 2 s ticks). Gaps between heartbeat
            // timestamps in the diagnostic log expose process throttling /
            // App Nap during unattended periods (display asleep) — the prime
            // suspect when the whole machine goes silent and never recovers.
            tickCount += 1
            if tickCount % 150 == 1 {
                DiagnosticLog.log("health: heartbeat tick=\(tickCount) taps=\(self.taps.count) activeApps=\(self.apps.count)")
            }

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
                DiagnosticLog.log("health: self-heal — \(appsMissingTaps.count) active app(s) missing a tap: \(appsMissingTaps.map { "\($0.name)#\($0.id)" })")
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
                guard !tap.isMuted else { gapDetectors.removeValue(forKey: pid); continue }

                // Skip PIDs in recovery cooldown to prevent recreation thrashing
                if let cooldownEnd = self.tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                    gapDetectors.removeValue(forKey: pid)
                    continue
                }

                guard tap.isHealthCheckEligible(minActiveSeconds: 5.0) else { continue }

                // Only health-check apps that are actively streaming (isRunning=true).
                // Paused apps have no NEW misses while paused — but do NOT reset the
                // counter here: a post-standby zombie tap only misses while the app
                // plays, and the user's natural pause/play retries used to zero the
                // count each time, so 3 consecutive misses were never reached and the
                // dead tap kept muting the app forever. Freezing the count across
                // pauses lets recovery finish on the next play.
                let isActivelyStreaming = self.processMonitor.activeApps.contains { $0.id == pid }
                guard isActivelyStreaming else { gapDetectors.removeValue(forKey: pid); continue }

                let identity = ObjectIdentifier(tap)
                var detector = gapDetectors[pid].flatMap { $0.identity == identity ? $0.detector : nil }
                    ?? RenderStutterDetector()
                let render = tap.renderDiagnostics
                let stuttering = detector.observe(longGapCount: render.longGapCount)
                gapDetectors[pid] = (identity, detector)
                if stuttering {
                    DiagnosticLog.log("health: pid=\(pid) repeated render gaps (>50ms and >4 buffer periods), total=\(render.longGapCount) — recreating")
                    gapDetectors.removeValue(forKey: pid)
                    consecutiveMisses[pid] = 0
                    await self.recreateTap(for: pid)
                    continue
                }

                if tap.hasRecentAudioCallback(within: 3.0) {
                    consecutiveMisses[pid] = 0
                } else {
                    let misses = (consecutiveMisses[pid] ?? 0) + 1
                    consecutiveMisses[pid] = misses
                    self.recordHealthCheckMiss(pid: pid)
                    DiagnosticLog.log("health: pid=\(pid) callback miss \(misses)/3")

                    if misses >= 3 {
                        self.logger.warning("Tap for PID \(pid) unresponsive (\(misses) misses), recreating")
                        consecutiveMisses[pid] = 0
                        await self.recreateTap(for: pid)
                    }
                }
            }

            // Prune entries for PIDs no longer tracked
            consecutiveMisses = consecutiveMisses.filter { self.taps[$0.key] != nil }
            gapDetectors = gapDetectors.filter { self.taps[$0.key] != nil }
            self.tapRecoveryCooldownUntil = self.tapRecoveryCooldownUntil.filter { self.taps[$0.key] != nil }
        }
    }

    func stopHealthMonitor() {
        taskScheduler.cancel(.healthMonitor)
    }

    /// Tears down and recreates a tap for a given PID, preserving routing and settings.
    /// Async: awaits full CoreAudio resource teardown before creating the replacement tap
    /// to prevent orphaned IO procs from accumulating (issue #176).
    func recreateTap(for pid: pid_t, knownLiveProcessObjectIDs: Set<AudioObjectID>? = nil) async {
        guard !Task.isCancelled else { return }
        guard let oldTap = taps.removeValue(forKey: pid) else { return }
        // Mark in-flight so a concurrent self-heal/ensureTap doesn't create a
        // duplicate tap during the async teardown window below (taps[pid] is nil
        // until we reinsert). Cleared on every exit path.
        pidsBeingRecreated.insert(pid)
        let recreationToken = UUID()
        tapRecreationTokens[pid] = recreationToken
        defer {
            // A reset may have started another recovery for this PID while
            // teardown was suspended. Its coordination state belongs to it.
            if tapRecreationTokens[pid] == recreationToken {
                tapRecreationTokens.removeValue(forKey: pid)
                pidsBeingRecreated.remove(pid)
            }
        }
        let previousDeviceUIDs = oldTap.currentDeviceUIDs
        let previousSourceUID = oldTap.tapSourceDeviceUID
        let previouslyFollowedDefault = followsDefault.contains(pid)
        recordTapRecoveryAttempt(pid: pid)
        DiagnosticLog.log("recreate: pid=\(pid) app=\(oldTap.app.name) devices=\(previousDeviceUIDs) — tearing down old tap")
        let teardown = Task { await oldTap.invalidateAsync() }
        pendingTapTeardowns[recreationToken] = teardown
        defer { pendingTapTeardowns.removeValue(forKey: recreationToken) }
        await teardown.value

        // stop/reset can run during teardown. Never resurrect a discarded tap
        // or overwrite a replacement owned by a newer recovery.
        guard tapRecreationTokens[pid] == recreationToken, taps[pid] == nil else { return }
        guard !Task.isCancelled else {
            appliedPIDs.remove(pid)
            return
        }

        // Find the current AudioApp entry for this PID. A *paused* app is absent
        // from `apps` (kAudioProcessPropertyIsRunning is false) but its audio
        // process objects stay registered with the HAL until it quits — the same
        // distinction cleanupStaleTaps uses to keep its tap warm. Recreate from
        // the old tap's app snapshot in that case, so a paused app's dead/zombie
        // tap is rebuilt warm instead of silently muting the app on resume.
        let app: AudioApp
        if let activeApp = apps.first(where: { $0.id == pid }) {
            app = activeApp
        } else if !oldTap.app.processObjectIDs.isEmpty,
                  !(knownLiveProcessObjectIDs ?? liveProcessObjectIDs()).isDisjoint(with: oldTap.app.processObjectIDs) {
            app = oldTap.app
        } else {
            logger.debug("No active app for PID \(pid), skipping tap recreation")
            DiagnosticLog.log("recreate: pid=\(pid) app gone (not active, no live process objects) — dropping tap")
            appliedPIDs.remove(pid)
            tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(12)
            recordTapRecoveryResult(pid: pid, succeeded: false)
            return
        }

        // Allow re-initialization
        appliedPIDs.remove(pid)

        // Device/default changes update routing even while taps[pid] is absent.
        // Resolve that current intent instead of restoring the pre-await route.
        let deviceUIDs: [String]
        if getDeviceSelectionMode(for: app) == .multi, !getSelectedDeviceUIDs(for: app).isEmpty {
            deviceUIDs = getSelectedDeviceUIDs(for: app).sorted()
        } else if followsDefault.contains(pid), let defaultUID = deviceVolumeMonitor.defaultDeviceUID {
            deviceUIDs = [defaultUID]
        } else if let routedUID = appDeviceRouting[pid] {
            deviceUIDs = [routedUID]
        } else {
            deviceUIDs = previousDeviceUIDs
        }

        do {
            let resolvedSourceUID = preferredTapSourceDeviceUID(
                forOutputUIDs: deviceUIDs,
                isFollowsDefault: followsDefault.contains(app.id)
            )
            let routingUnchanged = deviceUIDs == previousDeviceUIDs
                && followsDefault.contains(pid) == previouslyFollowedDefault
            let preferredTapSourceUID = resolvedSourceUID ?? (routingUnchanged ? previousSourceUID : nil)
            let tap = try tapFactory(app, deviceUIDs, preferredTapSourceUID)
            applyTapOutputState(to: tap, for: app.id, deviceUIDs: deviceUIDs)
            try tap.activate()
            // activate() pumps the run loop while waiting for HAL readiness,
            // so lifecycle invalidation can also happen before publication.
            guard tapRecreationTokens[pid] == recreationToken, !Task.isCancelled, taps[pid] == nil else {
                tap.invalidate()
                return
            }
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
            DiagnosticLog.log("recreate: pid=\(pid) app=\(app.name) SUCCESS")
        } catch {
            guard tapRecreationTokens[pid] == recreationToken, !Task.isCancelled else { return }
            tapRecoveryCooldownUntil[pid] = Date().addingTimeInterval(12)
            recordTapCreationFailure()
            recordTapRecoveryResult(pid: pid, succeeded: false)
            logger.error("Failed to recreate tap for \(app.name): \(error.localizedDescription)")
            DiagnosticLog.log("recreate: pid=\(pid) app=\(app.name) FAILED: \(error.localizedDescription)")
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
