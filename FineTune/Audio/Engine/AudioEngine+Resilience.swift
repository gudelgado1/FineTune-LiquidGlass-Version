// FineTune/Audio/Engine/AudioEngine+Resilience.swift
import AppKit
import AudioToolbox
import Foundation
import os

/// Values read together off-main; no engine or tap objects cross to the worker.
nonisolated struct WakeRecoverySnapshot: Sendable {
    let liveProcessObjectIDs: Set<AudioObjectID>
    let aliveDeviceIDs: Set<AudioDeviceID>
    let displayDeviceIDs: Set<AudioDeviceID>
    var nominalSampleRates: [AudioDeviceID: Double] = [:]

    static func read(deviceIDs: [AudioDeviceID]) -> Self? {
        guard let processIDs = try? AudioObjectID.readProcessList() else { return nil }
        var alive: Set<AudioDeviceID> = []
        var displays: Set<AudioDeviceID> = []
        var sampleRates: [AudioDeviceID: Double] = [:]
        for id in deviceIDs {
            if id.isDeviceAlive() { alive.insert(id) }
            let transport = id.readTransportType()
            if transport == .displayPort || transport == .hdmi { displays.insert(id) }
            if let rate = try? id.readNominalSampleRate(), rate.isFinite, rate > 0 {
                sampleRates[id] = rate
            }
        }
        return Self(liveProcessObjectIDs: Set(processIDs), aliveDeviceIDs: alive,
                    displayDeviceIDs: displays, nominalSampleRates: sampleRates)
    }

    func clockChanged(from clock: TapRenderClock?) -> Bool {
        guard let clock, let rate = nominalSampleRates[clock.aggregateDeviceID],
              rate.isFinite, rate > 0 else { return false }
        // Nominal rates describe the format; actual clock drift is intentionally
        // not compared, since it fluctuates during normal playback.
        return rate != clock.sampleRate
    }
}

// MARK: - System-pressure resilience
//
// Hardening for the "computer gets overloaded / RAM fills up → app freezes →
// comes back without capturing audio" scenario. Under extreme memory pressure
// macOS can kill/restart `coreaudiod`, which destroys every aggregate device and
// process tap FineTune created *server-side* while each ProcessTapController still
// believes it is `activated`. The IO procs never fire again.
//
// Two complementary mechanisms live here:
//
//   1. **Liveness recovery** (`recreateDeadTaps`) — a direct check that each tap's
//      aggregate device still exists. Unlike the callback-timing health check, it
//      catches taps that died before ever rendering a buffer, and it does NOT
//      depend on the MainActor health loop having ticked recently.
//
//   2. **Proactive triggers** (`startResilienceObservers`) — a memory-pressure
//      source and a system-wake observer that fire *exactly* when the system
//      recovers, kicking liveness revalidation immediately instead of waiting for
//      the next 2 s health tick. The memory-pressure source also sheds per-callback
//      DSP load while pressure is critical, reducing the chance of an IO-thread
//      overload/dropout in the first place.
//
// These mechanisms are device-agnostic: they operate at the per-app tap /
// aggregate-device layer, so they protect capture for every output (built-in,
// HDMI, DisplayPort, USB, Bluetooth, AirPlay, multi-device aggregates).

@MainActor
extension AudioEngine {

    private func readWakeRecoverySnapshot() async -> WakeRecoverySnapshot? {
        guard !Task.isCancelled, !taps.isEmpty, !wakeRecoveryQueryInFlight,
              audioSystemHealth.allowsPeriodicHALWork else { return nil }
        wakeRecoveryQueryInFlight = true
        defer { wakeRecoveryQueryInFlight = false }
        let generation = wakeRecoveryGeneration
        let deviceIDs = Array(Set(taps.values.flatMap { tap in
            let outputs = tap.currentDeviceUIDs.compactMap { deviceMonitor.device(for: $0)?.id }
            return outputs + (tap.renderClock.map { [$0.aggregateDeviceID] } ?? [])
        }))
        let query = wakeRecoveryQuery
        let result = await HALExecutor.run(timeout: wakeRecoveryTimeout) { query(deviceIDs) }
        guard !Task.isCancelled, generation == wakeRecoveryGeneration else { return nil }
        guard let completed = result else {
            audioSystemHealth.reportTimeout()
            return nil
        }
        guard audioSystemHealth.allowsPeriodicHALWork, let snapshot = completed else { return nil }
        audioSystemHealth.reportSuccess()
        return snapshot
    }

    // MARK: Liveness recovery

    /// Recreates any tap whose underlying aggregate device was destroyed
    /// server-side (coreaudiod restart, HAL reset, overload). Honors the
    /// per-PID recovery cooldown to avoid thrashing.
    ///
    /// HDMI / display-sleep guard: a tap is only recreated when its destination
    /// device is still present and alive. If the device itself vanished (a very
    /// common case for HDMI/DisplayPort monitors going to sleep), the
    /// device-disconnect / priority-fallback path owns recovery — recreating on a
    /// dead device would just fail and burn the cooldown.
    func recreateDeadTaps() async {
        guard !taps.isEmpty else { return }
        // Every check below is HAL IPC. With the daemon wedged they would all
        // hang, and recreating a tap would hang harder — the breaker's recovery
        // probe is the only traffic allowed until the audio system answers.
        guard audioSystemHealth.allowsPeriodicHALWork else { return }
        let now = Date()

        for (pid, tap) in taps {
            // Fast path: a tap that rendered audio in the last second is provably
            // alive — its IO proc is firing — so skip the HAL `isResourceAlive`
            // IPC entirely. This keeps the common case (audio actively playing)
            // free of coreaudiod queries, which matters most under the very
            // overload this recovery exists to handle. `hasRecentAudioCallback`
            // reads a lock-free host-time var; no IPC.
            if tap.hasRecentAudioCallback(within: 1.0) { continue }
            guard !tap.isResourceAlive else { continue }
            if let cooldownEnd = tapRecoveryCooldownUntil[pid], now < cooldownEnd { continue }

            let targetAlive = tap.currentDeviceUIDs.contains { uid in
                guard let id = deviceMonitor.device(for: uid)?.id else { return false }
                return isAliveCheck(id)
            }

            if targetAlive {
                logger.warning("Liveness: tap for PID \(pid) has a dead aggregate device — recreating")
                DiagnosticLog.log("liveness: pid=\(pid) aggregate dead, target alive — recreating")
                await recreateTap(for: pid)
            } else {
                logger.notice("Liveness: tap for PID \(pid) aggregate dead and target device(s) gone — deferring to device fallback")
                DiagnosticLog.log("liveness: pid=\(pid) aggregate dead AND target device gone — deferring to device fallback")
            }
        }
    }

    /// Handles system wake from standby. Aggregate devices can survive sleep as
    /// "zombies" — the device object is still alive (so `deviceLiveness()` returns
    /// `.alive` and the liveness watchdog skips it) but its sub-device was
    /// reconfigured across sleep and it no longer delivers audio. No cheap signal
    /// distinguishes a zombie from a healthy tap, so after a settle delay (for the
    /// HAL to re-enumerate devices) we force-rebuild every *active* tap. The brief
    /// blip on a genuinely-healthy tap is acceptable right after wake.
    /// Shared wake recovery. Fired by BOTH `didWakeNotification` (real system
    /// sleep) and `screensDidWakeNotification` (display sleep). The screens
    /// trigger is essential: a desktop held awake by power assertions never
    /// system-sleeps, so `didWakeNotification` never fires there — yet display
    /// sleep still kills the monitor's DisplayPort/HDMI audio, and its taps
    /// revive as zombies. When both notifications fire (laptops), the shared
    /// task IDs coalesce the two into one sweep.
    func handleSystemDidWake(trigger: String = "systemDidWake") {
        wakeRecoveryGeneration &+= 1
        DiagnosticLog.log("wake: \(trigger) received — scheduling rebuild passes (2s, 12s)")
        setDSPLoadShed(false)
        taskScheduler.schedule(.wakeRebuild, after: .seconds(2)) { [weak self] in
            guard let self else { return }
            let forced = await self.rebuildDisplayRoutedTaps(respectCooldown: false)
            await self.rebuildActiveTapsAfterWake(excluding: forced)
        }
        // Second sweep once slow devices (Bluetooth, HDMI/DP monitors) have had
        // time to re-enumerate: the 2 s pass skips a stuck tap whose target
        // device hasn't reappeared yet (targetAlive guard), so it would otherwise
        // wait on the much slower health-monitor miss path. Healthy taps have
        // recent callbacks by then and are skipped, so the extra pass is cheap.
        // The display force pass respects cooldowns here so a tap already
        // force-rebuilt at 2 s (fresh 20 s cooldown) isn't blipped a second time.
        taskScheduler.schedule(.wakeRebuildSecondPass, after: .seconds(12)) { [weak self] in
            guard let self else { return }
            let forced = await self.rebuildDisplayRoutedTaps(respectCooldown: true)
            await self.rebuildActiveTapsAfterWake(excluding: forced, respectCooldown: true)
        }
    }

    /// Force-rebuilds every eligible tap routed through a display-transport
    /// device (DisplayPort/HDMI), REGARDLESS of callback recency.
    ///
    /// Why force: after display sleep the monitor's audio device can revive as
    /// the worst zombie type — the aggregate stays alive AND its IO proc keeps
    /// firing, but output goes nowhere. Both the callback-timing health check
    /// and the liveness watchdog report it healthy, so without this pass the
    /// apps routed to the monitor stay muted (`.mutedWhenTapped`) indefinitely.
    /// The cost is a brief blip on a genuinely-healthy monitor-routed tap right
    /// after display wake — its audio was interrupted by the display sleeping
    /// anyway.
    ///
    /// - Parameter respectCooldown: `true` in the second wake pass so taps
    ///   force-rebuilt in the first pass (fresh success cooldown) are skipped.
    /// - Returns: PIDs rebuilt here, so the selective sweep that follows doesn't
    ///   immediately re-rebuild them (a just-activated tap has no callbacks yet
    ///   and would otherwise look "stuck").
    @discardableResult
    func rebuildDisplayRoutedTaps(respectCooldown: Bool) async -> Set<pid_t> {
        let candidates = taps.map { (pid: $0.key, tap: $0.value, routes: $0.value.currentDeviceUIDs) }
        guard let snapshot = await readWakeRecoverySnapshot() else { return [] }
        let activePIDs = Set(apps.map { $0.id })
        let liveObjectIDs = snapshot.liveProcessObjectIDs
        let now = Date()
        let displayCandidates = candidates.filter { pid, tap, routes in
            guard taps[pid] === tap, tap.currentDeviceUIDs == routes else { return false }
            if respectCooldown, let cooldownEnd = tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                return false
            }
            let routedThroughDisplay = tap.currentDeviceUIDs.contains { uid in
                guard let device = deviceMonitor.device(for: uid) else { return false }
                return snapshot.displayDeviceIDs.contains(device.id)
            }
            guard routedThroughDisplay else { return false }
            let isActive = activePIDs.contains(pid)
            let isPausedAlive = !tap.app.processObjectIDs.isEmpty
                && !liveObjectIDs.isDisjoint(with: tap.app.processObjectIDs)
            guard isActive || isPausedAlive else { return false }
            // Only rebuild once the display's audio device is actually back.
            let targetAlive = tap.currentDeviceUIDs.contains { uid in
                guard let id = deviceMonitor.device(for: uid)?.id else { return false }
                return snapshot.aliveDeviceIDs.contains(id)
            }
            return targetAlive
        }
        let displayPIDs = displayCandidates.map(\.pid)
        guard !displayPIDs.isEmpty else { return [] }
        logger.notice("Display wake: force-rebuilding \(displayPIDs.count) display-routed tap(s)")
        DiagnosticLog.log("wake: force-rebuilding \(displayPIDs.count) display-routed tap(s): \(displayPIDs)")
        var rebuilt: Set<pid_t> = []
        for (pid, tap, routes) in displayCandidates {
            guard !Task.isCancelled, audioSystemHealth.allowsPeriodicHALWork else { break }
            guard taps[pid] === tap, tap.currentDeviceUIDs == routes else { continue }
            tapRecoveryCooldownUntil.removeValue(forKey: pid)
            await recreateTap(for: pid, knownLiveProcessObjectIDs: liveObjectIDs)
            rebuilt.insert(pid)
        }
        return rebuilt
    }

    /// Rebuilds the *stuck* taps after standby, clearing their per-PID cooldown
    /// first (wake is an explicit rebuild event).
    ///
    /// A recent callback proves that the IO proc is running, but its clock may
    /// have changed while the UID stayed the same. Rebuild when the aggregate's
    /// nominal sample rate no longer matches the rate used to configure DSP,
    /// as well as when callbacks stalled. All HAL reads remain off-main and
    /// deadline-bounded; the render thread never queries device properties.
    ///
    /// The target-device-alive guard keeps a tap whose device is still asleep
    /// (e.g. an HDMI monitor) out of the rebuild — the `recreateDeadTaps()`
    /// fallback / device-disconnect path owns that case.
    ///
    /// Caveat: this can't detect the rare "IO proc fires but output goes nowhere"
    /// zombie (callbacks keep arriving). If that surfaces, switching output
    /// rebuilds the tap; the common post-standby failure is a stalled IO proc,
    /// which this catches.
    /// - Parameter excluding: PIDs just force-rebuilt by the display pass — a
    ///   freshly-activated tap has no callbacks yet and would look "stuck" here.
    func rebuildActiveTapsAfterWake(excluding: Set<pid_t> = [], respectCooldown: Bool = false) async {
        let candidates = taps.map {
            (pid: $0.key, tap: $0.value, routes: $0.value.currentDeviceUIDs, clock: $0.value.renderClock)
        }
        guard let snapshot = await readWakeRecoverySnapshot() else { return }
        let activePIDs = Set(apps.map { $0.id })
        let liveObjectIDs = snapshot.liveProcessObjectIDs
        let now = Date()
        let stuckCandidates = candidates.filter { pid, tap, routes, clock in
            guard taps[pid] === tap, tap.currentDeviceUIDs == routes,
                  tap.renderClock == clock,
                  !excluding.contains(pid) else { return false }
            if respectCooldown, let cooldownEnd = tapRecoveryCooldownUntil[pid], now < cooldownEnd {
                return false
            }
            // Active apps AND paused-but-alive apps (warm taps) are both
            // eligible: a healthy warm tap keeps firing its IO proc even while
            // the app is paused (the aggregate keeps clocking), so "no recent
            // callback" identifies the post-standby zombie either way. Leaving
            // a paused zombie behind used to mute the app for many seconds —
            // or forever, if the user kept pause/playing — after wake.
            let isActive = activePIDs.contains(pid)
            let isPausedAlive = !tap.app.processObjectIDs.isEmpty
                && !liveObjectIDs.isDisjoint(with: tap.app.processObjectIDs)
            guard isActive || isPausedAlive else { return false }
            guard !tap.hasRecentAudioCallback(within: 2.0) || snapshot.clockChanged(from: clock) else { return false }
            let targetAlive = tap.currentDeviceUIDs.contains { uid in
                guard let id = deviceMonitor.device(for: uid)?.id else { return false }
                return snapshot.aliveDeviceIDs.contains(id)
            }
            return targetAlive
        }
        let stuckPIDs = stuckCandidates.map(\.pid)
        if !stuckPIDs.isEmpty {
            logger.notice("Wake: rebuilding \(stuckPIDs.count) tap(s) with stalled callbacks or a changed clock")
            for (pid, tap, routes, clock) in stuckCandidates {
                guard !Task.isCancelled, audioSystemHealth.allowsPeriodicHALWork else { break }
                guard taps[pid] === tap, tap.currentDeviceUIDs == routes, tap.renderClock == clock else { continue }
                if snapshot.clockChanged(from: clock), let clock,
                   let rate = snapshot.nominalSampleRates[clock.aggregateDeviceID] {
                    DiagnosticLog.log("wake: pid=\(pid) render clock changed \(clock.sampleRate) → \(rate) Hz — rebuilding")
                } else {
                    DiagnosticLog.log("wake: pid=\(pid) no recent callback — rebuilding")
                }
                tapRecoveryCooldownUntil.removeValue(forKey: pid)
                await recreateTap(for: pid, knownLiveProcessObjectIDs: liveObjectIDs)
            }
        }
        // Dead aggregates also have no callbacks and are covered above. Leave
        // other taps to the periodic liveness pass, avoiding synchronous HAL
        // reads on the wake path after its deadline-bounded snapshot.
    }

    /// Rebuilds engine state after `coreaudiod` was restarted.
    ///
    /// A daemon restart destroys EVERY server-side object at once: process taps,
    /// our private aggregate devices, and the AudioObjectIDs of the real devices
    /// and audio processes. So nothing cached survives — unlike the wake paths,
    /// which repair individual taps, this re-reads the world from scratch.
    ///
    /// Local teardown is best-effort: the old IDs no longer exist, so the HAL
    /// calls in `invalidate()` just return errors (they run off the main thread
    /// via `destroyAsync`). Their real job here is untracking the dead aggregate
    /// IDs from `CrashGuard`.
    func resyncAfterCoreAudioRestart() async {
        captureRebuildTask?.cancel()
        _ = await captureRebuildTask?.value
        logger.notice("Resyncing engine after Core Audio restart")

        // 1. Drop every tap and all per-PID coordination state.
        discardAllTaps()

        // 2. Re-enumerate devices and audio processes — every ID is new.
        processMonitor.stop()
        deviceMonitor.stop()
        deviceVolumeMonitor.stop()
        deviceMonitor.start()
        deviceVolumeMonitor.start()
        if permission.status == .authorized {
            processMonitor.start()
        }

        // 3. Let the HAL settle before rebuilding taps on the fresh device IDs.
        try? await Task.sleep(for: .milliseconds(500))

        // 4. Rebuild taps from persisted settings, and re-seed the default we track.
        lastConfirmedDefaultUID = deviceVolumeMonitor.defaultDeviceUID
        applyPersistedSettings()
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.notice("Engine resync complete — \(self.taps.count) tap(s) rebuilt")
        DiagnosticLog.log("coreaudio: engine resync complete — \(taps.count) tap(s) rebuilt")
    }

    /// Tears down every tap and clears all per-PID coordination state, leaving
    /// the monitors and device state untouched. Shared by the Core Audio resync
    /// and the manual capture rebuild.
    private func discardAllTaps(invalidate: Bool = true) {
        wakeRecoveryGeneration &+= 1
        if invalidate {
            for tap in taps.values { tap.invalidate() }
        }
        taps.removeAll()
        appliedPIDs.removeAll()
        pidsBeingCreated.removeAll()
        pidsBeingRecreated.removeAll()
        tapRecreationTokens.removeAll()
        tapRecoveryCooldownUntil.removeAll()
        for task in pendingCleanup.values { task.cancel() }
        pendingCleanup.removeAll()
    }

    /// Recreates the capture for every app, WITHOUT touching `coreaudiod`.
    ///
    /// The light-touch sibling of the Core Audio reset: it fixes taps that went
    /// stale or zombie while the daemon itself is healthy (an app whose volume
    /// slider stopped doing anything, an app missing from the list, capture lost
    /// after a device change). No administrator password, and no system-wide
    /// audio interruption — only FineTune's own taps are rebuilt.
    ///
    /// Refuses to run while the audio system is unresponsive: every step here is
    /// HAL work, so the Core Audio reset is the correct tool in that state.
    ///
    /// - Returns: how many taps exist after the rebuild, or `nil` if it was
    ///   refused because the audio system isn't answering.
    @discardableResult
    func rebuildAllTaps() async -> Int? {
        if let task = captureRebuildTask { return await task.value }
        guard audioSystemHealth.allowsPeriodicHALWork else {
            DiagnosticLog.log("capture: manual rebuild REFUSED — audio system unresponsive")
            return nil
        }

        logger.notice("Manual capture rebuild requested")
        DiagnosticLog.log("capture: manual rebuild requested (\(taps.count) tap(s) live)")

        let task = Task<Int?, Never> { @MainActor [self] in
            let retired = Array(taps.values)
            let alreadyRetiring = Array(pendingTapTeardowns.values)
            discardAllTaps(invalidate: false)
            // Keep every creation path gated until actual HAL teardown finishes.
            // A fixed delay did not stop the health loop from recreating early.
            for tap in retired { await tap.invalidateAsync() }
            for teardown in alreadyRetiring { await teardown.value }
            guard !Task.isCancelled else { return nil }
            processMonitor.refreshNow()
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, audioSystemHealth.allowsPeriodicHALWork else { return nil }
            captureRebuildTask = nil
            applyPersistedSettings()
            DiagnosticLog.log("capture: manual rebuild complete — \(taps.count) tap(s)")
            return taps.count
        }
        captureRebuildTask = task
        let result = await task.value
        // The task clears the gate before synchronous creation on success.
        // On cancellation it remains held until all old resources are retired.
        if result == nil { captureRebuildTask = nil }
        return result
    }

    /// Debounced entry point for the proactive triggers. Coalesces bursts
    /// (memory-pressure storms, device-list churn, repeated foreground events)
    /// into a single `recreateDeadTaps()` pass ~400 ms later, so we never spin
    /// the HAL liveness query / recreate loop under sustained load. The periodic
    /// health monitor calls `recreateDeadTaps()` directly (already 2 s-throttled).
    func scheduleLivenessRevalidation() {
        taskScheduler.schedule(.livenessRevalidate, after: .milliseconds(400)) { [weak self] in
            await self?.recreateDeadTaps()
        }
    }

    // MARK: DSP load-shedding

    /// Enables/disables per-callback DSP bypass across all taps. Under critical
    /// memory pressure we drop the optional EQ / AutoEQ / loudness stage so audio
    /// keeps flowing (unprocessed) instead of risking an IO-thread overload.
    func setDSPLoadShed(_ shed: Bool) {
        guard shed != isDSPLoadShed else { return }
        isDSPLoadShed = shed
        for tap in taps.values { tap.setDSPBypass(shed) }
        logger.notice("DSP load-shedding \(shed ? "ENABLED (critical memory pressure)" : "disabled")")
        DiagnosticLog.log("dsp load-shed: \(shed ? "ENABLED" : "disabled")")
    }

    // MARK: Proactive observers

    /// Arms the memory-pressure source, system-wake observer, screens-wake
    /// observer, and app-activation observer. Idempotent.
    func startResilienceObservers() {
        startMemoryPressureMonitor()
        startWakeObserver()
        startScreensWakeObserver()
        startDidBecomeActiveObserver()
    }

    /// Cancels the memory-pressure source and removes the wake / activation observers.
    func stopResilienceObservers() {
        wakeRecoveryGeneration &+= 1
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            wakeObserver = nil
        }
        if let token = screensWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            screensWakeObserver = nil
        }
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
    }

    /// Handles a memory-pressure transition. Internal (not private) so it can be
    /// driven directly from tests without a real DispatchSource.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        DiagnosticLog.log("memory pressure event: \(event.rawValue) (1=normal 2=warning 4=critical)")
        if event.contains(.critical) {
            logger.notice("Critical memory pressure — shedding DSP load and revalidating taps")
            setDSPLoadShed(true)
            scheduleLivenessRevalidation()
        } else if event.contains(.warning) {
            logger.info("Memory-pressure warning — revalidating tap liveness")
            scheduleLivenessRevalidation()
        } else if event.contains(.normal) {
            setDSPLoadShed(false)
        }
    }

    private func startMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = DispatchSource.MemoryPressureEvent(rawValue: source.data)
            Task { @MainActor in self?.handleMemoryPressure(event) }
        }
        source.resume()
        memoryPressureSource = source
        logger.debug("Memory-pressure resilience monitor started")
    }

    private func startWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake(trigger: "didWakeNotification")
            }
        }
        logger.debug("System-wake resilience observer started")
    }

    /// Display wake. On desktops held awake by power assertions this is the ONLY
    /// wake signal that ever fires (`didWakeNotification` requires real system
    /// sleep, which never happens there) — and display sleep is exactly what
    /// kills DisplayPort/HDMI audio. Routes into the same shared wake recovery;
    /// the shared task IDs coalesce with `didWakeNotification` on laptops.
    private func startScreensWakeObserver() {
        guard screensWakeObserver == nil else { return }
        screensWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake(trigger: "screensDidWakeNotification")
            }
        }
        logger.debug("Screens-wake resilience observer started")
    }

    private func startDidBecomeActiveObserver() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleLivenessRevalidation()
            }
        }
        logger.debug("App-activation resilience observer started")
    }
}
