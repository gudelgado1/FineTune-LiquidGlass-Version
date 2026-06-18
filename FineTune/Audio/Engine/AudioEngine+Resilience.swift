// FineTune/Audio/Engine/AudioEngine+Resilience.swift
import AppKit
import Foundation
import os

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
                await recreateTap(for: pid)
            } else {
                logger.notice("Liveness: tap for PID \(pid) aggregate dead and target device(s) gone — deferring to device fallback")
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
    func handleSystemDidWake() {
        setDSPLoadShed(false)
        taskScheduler.schedule(.wakeRebuild, after: .seconds(2)) { [weak self] in
            await self?.rebuildActiveTapsAfterWake()
        }
    }

    /// Rebuilds the *stuck* taps after standby, clearing their per-PID cooldown
    /// first (wake is an explicit rebuild event).
    ///
    /// Selective by design: a healthy aggregate fires its IO proc continuously —
    /// even while the app outputs silence — so a tap that delivered a callback in
    /// the last couple of seconds is provably still capturing and is left alone.
    /// Only active taps with NO recent callback (a stalled/zombie IO proc, the
    /// post-standby failure) are torn down and recreated. This avoids an
    /// unnecessary audio blip and the per-tap `activate()` main-thread block on
    /// every healthy tap each time the machine wakes.
    ///
    /// The target-device-alive guard keeps a tap whose device is still asleep
    /// (e.g. an HDMI monitor) out of the rebuild — the `recreateDeadTaps()`
    /// fallback / device-disconnect path owns that case.
    ///
    /// Caveat: this can't detect the rare "IO proc fires but output goes nowhere"
    /// zombie (callbacks keep arriving). If that surfaces, switching output
    /// rebuilds the tap; the common post-standby failure is a stalled IO proc,
    /// which this catches.
    func rebuildActiveTapsAfterWake() async {
        let activePIDs = Set(apps.map { $0.id })
        let stuckPIDs: [pid_t] = taps.compactMap { pid, tap in
            guard activePIDs.contains(pid) else { return nil }
            guard !tap.hasRecentAudioCallback(within: 2.0) else { return nil }
            let targetAlive = tap.currentDeviceUIDs.contains { uid in
                guard let id = deviceMonitor.device(for: uid)?.id else { return false }
                return isAliveCheck(id)
            }
            return targetAlive ? pid : nil
        }
        if !stuckPIDs.isEmpty {
            logger.notice("Wake: rebuilding \(stuckPIDs.count) stuck tap(s) (no recent callback after settle)")
            for pid in stuckPIDs {
                tapRecoveryCooldownUntil.removeValue(forKey: pid)
                await recreateTap(for: pid)
            }
        }
        // Catch any taps that died outright (e.g. their device vanished).
        await recreateDeadTaps()
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
    }

    // MARK: Proactive observers

    /// Arms the memory-pressure source, system-wake observer, and app-activation
    /// observer. Idempotent.
    func startResilienceObservers() {
        startMemoryPressureMonitor()
        startWakeObserver()
        startDidBecomeActiveObserver()
    }

    /// Cancels the memory-pressure source and removes the wake / activation observers.
    func stopResilienceObservers() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            wakeObserver = nil
        }
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
            didBecomeActiveObserver = nil
        }
    }

    /// Handles a memory-pressure transition. Internal (not private) so it can be
    /// driven directly from tests without a real DispatchSource.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
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
            Task { @MainActor in
                self?.handleSystemDidWake()
            }
        }
        logger.debug("System-wake resilience observer started")
    }

    private func startDidBecomeActiveObserver() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleLivenessRevalidation()
            }
        }
        logger.debug("App-activation resilience observer started")
    }
}
