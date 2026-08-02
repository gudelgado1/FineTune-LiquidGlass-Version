import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class LivenessProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?

    init(activeApps: [AudioApp]) {
        self.activeApps = activeApps
    }

    func start() {}
    func stop() {}
}

/// Tap mock whose aggregate-liveness and DSP-bypass state are directly settable,
/// so we can simulate a tap whose server-side aggregate was destroyed.
private final class LivenessTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var currentDeviceUIDs: [String]
    var tapSourceDeviceUID: String?

    var resourceAlive: Bool
    /// Independent from `resourceAlive` so tests can exercise the
    /// "recently rendered → skip the HAL liveness query" fast path.
    var recentCallback = false
    private(set) var dspBypass = false
    private(set) var activateCallCount = 0
    private(set) var invalidateAsyncCallCount = 0

    init(app: AudioApp, deviceUIDs: [String], resourceAlive: Bool = true) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
        self.resourceAlive = resourceAlive
    }

    var isResourceAlive: Bool { resourceAlive }
    func setDSPBypass(_ bypass: Bool) { dspBypass = bypass }

    func activate() throws { activateCallCount += 1 }
    func invalidate() {}
    func invalidateAsync() async { invalidateAsyncCallCount += 1 }
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
        tapSourceDeviceUID = preferredTapSourceDeviceUID
    }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
        tapSourceDeviceUID = preferredTapSourceDeviceUID
    }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { recentCallback }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        tapSourceDeviceUID = preferredDeviceUID
    }
}

@Suite("AudioEngine — tap liveness recovery", .serialized)
@MainActor
struct AudioEngineLivenessTests {
    @Test("dead aggregate + alive device → tap is recreated on the same route")
    func deadAggregateWithAliveDeviceRecreates() async {
        let app = makeApp(pid: 71001)
        let device = makeDevice(id: 701, uid: "spk", name: "Speaker")
        var replacement: LivenessTap?
        let harness = makeHarness(
            app: app,
            devices: [device],
            aliveIDs: [device.id]
        ) { app, uids, source in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            tap.tapSourceDeviceUID = source
            replacement = tap
            return tap
        }
        let dead = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[app.id] = dead

        await harness.engine.recreateDeadTaps()

        #expect(dead.invalidateAsyncCallCount == 1)
        #expect(replacement != nil)
        #expect(harness.engine.taps[app.id] === replacement)
        #expect(replacement?.activateCallCount == 1)
        #expect(harness.engine.taps[app.id]?.currentDeviceUIDs == [device.uid])
    }

    @Test("dead aggregate + dead device → tap is NOT recreated (deferred to fallback)")
    func deadAggregateWithDeadDeviceDefers() async {
        let app = makeApp(pid: 71002)
        let device = makeDevice(id: 702, uid: "hdmi", name: "HDMI Monitor")
        var factoryCalls = 0
        let harness = makeHarness(
            app: app,
            devices: [device],
            aliveIDs: []  // device present in monitor but reports NOT alive (e.g. display asleep)
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
        }
        let dead = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[app.id] = dead

        await harness.engine.recreateDeadTaps()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === dead)
        #expect(dead.invalidateAsyncCallCount == 0)
    }

    @Test("live tap is left untouched")
    func liveTapIsNotRecreated() async {
        let app = makeApp(pid: 71003)
        let device = makeDevice(id: 703, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(
            app: app,
            devices: [device],
            aliveIDs: [device.id]
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
        }
        let live = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        harness.engine.taps[app.id] = live

        await harness.engine.recreateDeadTaps()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === live)
    }

    @Test("recently-rendering tap skips the liveness query and is not recreated")
    func recentlyRenderingTapSkipsLivenessCheck() async {
        let app = makeApp(pid: 71011)
        let device = makeDevice(id: 711, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        // Tap reports a dead aggregate, but it rendered audio within the last
        // second — the IO proc is provably firing, so the fast path must trust
        // that and skip recreation (and the HAL query).
        let tap = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: false)
        tap.recentCallback = true
        harness.engine.taps[app.id] = tap

        await harness.engine.recreateDeadTaps()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === tap)
    }

    @Test("respects recovery cooldown")
    func respectsCooldown() async {
        let app = makeApp(pid: 71004)
        let device = makeDevice(id: 704, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(
            app: app,
            devices: [device],
            aliveIDs: [device.id]
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
        }
        let dead = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[app.id] = dead
        harness.engine.tapRecoveryCooldownUntil[app.id] = Date().addingTimeInterval(30)

        await harness.engine.recreateDeadTaps()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === dead)
    }

    @Test("DSP load-shedding toggles bypass on all taps and is idempotent")
    func loadSheddingTogglesBypass() {
        let app = makeApp(pid: 71005)
        let device = makeDevice(id: 705, uid: "spk", name: "Speaker")
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            LivenessTap(app: app, deviceUIDs: uids)
        }
        let tap = LivenessTap(app: app, deviceUIDs: [device.uid])
        harness.engine.taps[app.id] = tap

        harness.engine.setDSPLoadShed(true)
        #expect(tap.dspBypass == true)
        #expect(harness.engine.isDSPLoadShed == true)

        harness.engine.setDSPLoadShed(false)
        #expect(tap.dspBypass == false)
        #expect(harness.engine.isDSPLoadShed == false)
    }

    @Test("critical memory pressure enables DSP load-shedding")
    func criticalMemoryPressureSheds() {
        let app = makeApp(pid: 71006)
        let device = makeDevice(id: 706, uid: "spk", name: "Speaker")
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            LivenessTap(app: app, deviceUIDs: uids)
        }
        let tap = LivenessTap(app: app, deviceUIDs: [device.uid])
        harness.engine.taps[app.id] = tap

        harness.engine.handleMemoryPressure(.critical)
        #expect(harness.engine.isDSPLoadShed == true)
        #expect(tap.dspBypass == true)

        harness.engine.handleMemoryPressure(.normal)
        #expect(harness.engine.isDSPLoadShed == false)
        #expect(tap.dspBypass == false)
    }

    @Test("device-list change revalidates and recreates a dead tap")
    func deviceListChangeRecreatesDeadTap() async {
        let app = makeApp(pid: 71007)
        let device = makeDevice(id: 707, uid: "spk", name: "Speaker")
        var replacement: LivenessTap?
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            replacement = tap
            return tap
        }
        let dead = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[app.id] = dead

        // Engine wires onDeviceListChanged in init even with monitors off.
        // The trigger is debounced ~400 ms, so wait past that before asserting.
        harness.deviceMonitor.onDeviceListChanged?()
        try? await Task.sleep(for: .milliseconds(700))

        #expect(replacement != nil)
        #expect(harness.engine.taps[app.id] === replacement)
    }

    @Test("wake rebuild recreates a stuck active tap (no recent callback) and bypasses cooldown")
    func wakeRebuildRecreatesStuckTap() async {
        let app = makeApp(pid: 71008)
        let device = makeDevice(id: 708, uid: "spk", name: "Speaker")
        var replacement: LivenessTap?
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            replacement = tap
            return tap
        }
        // Stuck zombie: alive object AND no recent callback (IO proc stalled across
        // sleep). App is active → wake must rebuild it, bypassing any cooldown.
        let zombie = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        zombie.recentCallback = false
        harness.engine.taps[app.id] = zombie
        harness.engine.tapRecoveryCooldownUntil[app.id] = Date().addingTimeInterval(30)

        await harness.engine.rebuildActiveTapsAfterWake()

        #expect(zombie.invalidateAsyncCallCount == 1)
        #expect(replacement != nil)
        #expect(harness.engine.taps[app.id] === replacement)
        #expect(replacement?.activateCallCount == 1)
    }

    @Test("wake rebuild leaves a healthy active tap (recent callback) untouched")
    func wakeRebuildSkipsHealthyTap() async {
        let app = makeApp(pid: 71015)
        let device = makeDevice(id: 715, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        // Healthy: IO proc still delivering callbacks → not stuck → must be left
        // alone (no blip, no main-thread activate() block) even though wake fired.
        let healthy = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        healthy.recentCallback = true
        harness.engine.taps[app.id] = healthy

        await harness.engine.rebuildActiveTapsAfterWake()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === healthy)
        #expect(healthy.invalidateAsyncCallCount == 0)
    }

    @Test("wake rebuild recreates a PAUSED app's zombie tap (process objects still registered)")
    func wakeRebuildRecreatesPausedZombieTap() async {
        let activeApp = makeApp(pid: 71016)
        let pausedApp = makeApp(pid: 71017, objectIDs: [990017])
        let device = makeDevice(id: 716, uid: "spk", name: "Speaker")
        var replacement: LivenessTap?
        let harness = makeHarness(
            app: activeApp,
            devices: [device],
            aliveIDs: [device.id],
            liveProcessObjects: { [AudioObjectID(990017)] }
        ) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            replacement = tap
            return tap
        }
        // Post-standby zombie of a *paused* app: not in activeApps, but its audio
        // process objects are still registered (warm tap) and its IO proc stalled.
        let zombie = LivenessTap(app: pausedApp, deviceUIDs: [device.uid], resourceAlive: true)
        zombie.recentCallback = false
        harness.engine.taps[pausedApp.id] = zombie

        await harness.engine.rebuildActiveTapsAfterWake()

        #expect(zombie.invalidateAsyncCallCount == 1)
        #expect(replacement != nil)
        #expect(harness.engine.taps[pausedApp.id] === replacement)
    }

    @Test("wake rebuild leaves a healthy PAUSED warm tap alone (recent callback)")
    func wakeRebuildSkipsHealthyPausedTap() async {
        let activeApp = makeApp(pid: 71020)
        let pausedApp = makeApp(pid: 71021, objectIDs: [990021])
        let device = makeDevice(id: 720, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(
            app: activeApp,
            devices: [device],
            aliveIDs: [device.id],
            liveProcessObjects: { [AudioObjectID(990021)] }
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        // Healthy warm tap: the aggregate keeps clocking during pause, so its IO
        // proc still fires — must be left alone (no blip on the paused app).
        let warmTap = LivenessTap(app: pausedApp, deviceUIDs: [device.uid], resourceAlive: true)
        warmTap.recentCallback = true
        harness.engine.taps[pausedApp.id] = warmTap

        await harness.engine.rebuildActiveTapsAfterWake()

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[pausedApp.id] === warmTap)
        #expect(warmTap.invalidateAsyncCallCount == 0)
    }

    @Test("recreateTap rebuilds a paused-but-alive app's tap from the old tap's snapshot")
    func recreateTapRebuildsPausedAliveApp() async {
        let activeApp = makeApp(pid: 71022)
        let pausedApp = makeApp(pid: 71023, objectIDs: [990023])
        let device = makeDevice(id: 722, uid: "spk", name: "Speaker")
        var replacement: LivenessTap?
        let harness = makeHarness(
            app: activeApp,
            devices: [device],
            aliveIDs: [device.id],
            liveProcessObjects: { [AudioObjectID(990023)] }
        ) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            replacement = tap
            return tap
        }
        let dead = LivenessTap(app: pausedApp, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[pausedApp.id] = dead

        await harness.engine.recreateTap(for: pausedApp.id)

        #expect(dead.invalidateAsyncCallCount == 1)
        #expect(harness.engine.taps[pausedApp.id] === replacement)
        #expect(replacement?.app.id == pausedApp.id)
    }

    @Test("recreateTap still gives up when the app quit (no live process objects)")
    func recreateTapSkipsQuitApp() async {
        let activeApp = makeApp(pid: 71024)
        let quitApp = makeApp(pid: 71025, objectIDs: [990025])
        let device = makeDevice(id: 724, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(
            app: activeApp,
            devices: [device],
            aliveIDs: [device.id],
            liveProcessObjects: { [] }  // no registered objects → the app is gone
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        let dead = LivenessTap(app: quitApp, deviceUIDs: [device.uid], resourceAlive: false)
        harness.engine.taps[quitApp.id] = dead

        await harness.engine.recreateTap(for: quitApp.id)

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[quitApp.id] == nil)
    }

    @Test("wake rebuild leaves inactive (warm/paused) taps alone")
    func wakeRebuildSkipsInactiveTap() async {
        let activeApp = makeApp(pid: 71009)
        let pausedApp = makeApp(pid: 71010)
        let device = makeDevice(id: 709, uid: "spk", name: "Speaker")
        let harness = makeHarness(app: activeApp, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
        }
        // Only activeApp is in activeApps; the paused tap is alive (warm).
        let pausedTap = LivenessTap(app: pausedApp, deviceUIDs: [device.uid], resourceAlive: true)
        harness.engine.taps[pausedApp.id] = pausedTap

        await harness.engine.rebuildActiveTapsAfterWake()

        #expect(harness.engine.taps[pausedApp.id] === pausedTap)
        #expect(pausedTap.invalidateAsyncCallCount == 0)
    }

    // MARK: - Display-wake force rebuild

    @Test("display wake force-rebuilds a display-routed tap even with recent callbacks (invisible zombie)")
    func displayWakeForceRebuildsDisplayRoutedTap() async {
        let app = makeApp(pid: 71027)
        let monitor = makeDevice(id: 727, uid: "dell-dp", name: "DELL U2724DE")
        var replacement: LivenessTap?
        let harness = makeHarness(
            app: app,
            devices: [monitor],
            aliveIDs: [monitor.id],
            displayDeviceIDs: [monitor.id]
        ) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            replacement = tap
            return tap
        }
        // The worst zombie: aggregate alive AND IO proc still firing, but output
        // goes nowhere after display sleep. Callback/liveness checks see healthy.
        let zombie = LivenessTap(app: app, deviceUIDs: [monitor.uid], resourceAlive: true)
        zombie.recentCallback = true
        harness.engine.taps[app.id] = zombie

        let forced = await harness.engine.rebuildDisplayRoutedTaps(respectCooldown: false)

        #expect(forced == [app.id])
        #expect(zombie.invalidateAsyncCallCount == 1)
        #expect(harness.engine.taps[app.id] === replacement)
    }

    @Test("display wake leaves non-display taps alone")
    func displayWakeSkipsNonDisplayTap() async {
        let app = makeApp(pid: 71028)
        let speaker = makeDevice(id: 728, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(
            app: app,
            devices: [speaker],
            aliveIDs: [speaker.id],
            displayDeviceIDs: []  // no display-transport devices
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        let healthy = LivenessTap(app: app, deviceUIDs: [speaker.uid], resourceAlive: true)
        healthy.recentCallback = true
        harness.engine.taps[app.id] = healthy

        let forced = await harness.engine.rebuildDisplayRoutedTaps(respectCooldown: false)

        #expect(forced.isEmpty)
        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === healthy)
    }

    @Test("display wake second pass respects a fresh recovery cooldown (no double blip)")
    func displayWakeSecondPassRespectsCooldown() async {
        let app = makeApp(pid: 71029)
        let monitor = makeDevice(id: 729, uid: "dell-dp", name: "DELL U2724DE")
        var factoryCalls = 0
        let harness = makeHarness(
            app: app,
            devices: [monitor],
            aliveIDs: [monitor.id],
            displayDeviceIDs: [monitor.id]
        ) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        let tap = LivenessTap(app: app, deviceUIDs: [monitor.uid], resourceAlive: true)
        harness.engine.taps[app.id] = tap
        // Simulate "already force-rebuilt at the 2 s pass" (success cooldown).
        harness.engine.tapRecoveryCooldownUntil[app.id] = Date().addingTimeInterval(20)

        let forced = await harness.engine.rebuildDisplayRoutedTaps(respectCooldown: true)

        #expect(forced.isEmpty)
        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === tap)
    }

    @Test("selective wake sweep skips PIDs just force-rebuilt by the display pass")
    func wakeSweepSkipsExcludedPIDs() async {
        let app = makeApp(pid: 71030)
        let device = makeDevice(id: 730, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        // Looks "stuck" (no callbacks yet) — exactly like a tap the display pass
        // recreated milliseconds ago. Must be skipped when excluded.
        let fresh = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        fresh.recentCallback = false
        harness.engine.taps[app.id] = fresh

        await harness.engine.rebuildActiveTapsAfterWake(excluding: [app.id])

        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === fresh)
    }

    // MARK: - Manual capture rebuild

    @Test("manual rebuild tears down every tap and recreates capture for active apps")
    func manualRebuildRecreatesTaps() async {
        let app = makeApp(pid: 71031)
        let device = makeDevice(id: 731, uid: "spk", name: "Speaker")
        var created: [LivenessTap] = []
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            let tap = LivenessTap(app: app, deviceUIDs: uids, resourceAlive: true)
            created.append(tap)
            return tap
        }
        let stale = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        harness.engine.taps[app.id] = stale
        harness.engine.appliedPIDs.insert(app.id)
        // A cooldown must not block an explicitly user-requested rebuild.
        harness.engine.tapRecoveryCooldownUntil[app.id] = Date().addingTimeInterval(30)

        let count = await harness.engine.rebuildAllTaps()

        #expect(count == 1)
        #expect(created.count == 1)
        #expect(harness.engine.taps[app.id] === created.first)
        #expect(harness.engine.taps[app.id] !== stale)
        #expect(harness.engine.tapRecoveryCooldownUntil.isEmpty)
    }

    @Test("manual rebuild refuses (and changes nothing) while the audio system is unresponsive")
    func manualRebuildRefusedWhenHALDown() async {
        let app = makeApp(pid: 71032)
        let device = makeDevice(id: 732, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        let existing = LivenessTap(app: app, deviceUIDs: [device.uid], resourceAlive: true)
        harness.engine.taps[app.id] = existing

        // Trip the breaker: every step of a rebuild is HAL work, so it must not
        // run — and must not destroy the taps it can't recreate.
        harness.engine.audioSystemHealth.reportTimeout()
        harness.engine.audioSystemHealth.reportTimeout()

        let result = await harness.engine.rebuildAllTaps()

        #expect(result == nil)
        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] === existing)
        harness.engine.audioSystemHealth.stop()
    }

    // MARK: - Throttling / anti-thrashing

    @Test("rapid liveness-revalidation triggers coalesce into one scheduled pass (debounce)")
    func debounceCoalescesRapidRevalidations() {
        let app = makeApp(pid: 71013)
        let device = makeDevice(id: 713, uid: "spk", name: "Speaker")
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            LivenessTap(app: app, deviceUIDs: uids)
        }
        // Monitors are off in the harness → scheduler starts empty.
        let before = harness.engine.taskScheduler.activeCount
        for _ in 0..<25 { harness.engine.scheduleLivenessRevalidation() }
        let after = harness.engine.taskScheduler.activeCount

        // 25 bursty triggers must collapse to a single pending revalidation.
        #expect(after - before == 1)
        #expect(harness.engine.taskScheduler.activeIDs.contains(.livenessRevalidate))
    }

    @Test("in-flight recreation guard blocks a duplicate tap creation (race fix)")
    func inFlightGuardBlocksDuplicateCreation() {
        let app = makeApp(pid: 71014)
        let device = makeDevice(id: 714, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        // Simulate recreateTap mid-flight (taps[pid] briefly nil): self-heal must
        // NOT create a second tap and leak the duplicate's aggregate device.
        harness.engine.pidsBeingRecreated.insert(app.id)
        harness.engine.ensureTapExists(for: app, deviceUID: device.uid)
        #expect(factoryCalls == 0)
        #expect(harness.engine.taps[app.id] == nil)

        // Once the recreation completes, creation proceeds normally.
        harness.engine.pidsBeingRecreated.remove(app.id)
        harness.engine.ensureTapExists(for: app, deviceUID: device.uid)
        #expect(factoryCalls == 1)
        #expect(harness.engine.taps[app.id] != nil)
    }

    @Test("re-entrant creation during the activate window creates no duplicate tap")
    func nestedCreationReentryCreatesNoDuplicate() {
        let app = makeApp(pid: 71026)
        let device = makeDevice(id: 726, uid: "spk", name: "Speaker")
        var factoryCalls = 0
        var engineRef: AudioEngine?
        let harness = makeHarness(app: app, devices: [device], aliveIDs: [device.id]) { app, uids, _ in
            factoryCalls += 1
            // Simulate the nested-run-loop re-entry: activate() pumps the main
            // queue (waitUntilReady), letting a health-monitor tick call back
            // into ensureTapExists for the SAME pid before taps[pid] is set.
            // The pidsBeingCreated guard must swallow this inner call.
            if factoryCalls == 1 {
                engineRef?.ensureTapExists(for: app, deviceUID: uids[0])
            }
            return LivenessTap(app: app, deviceUIDs: uids)
        }
        engineRef = harness.engine

        harness.engine.ensureTapExists(for: app, deviceUID: device.uid)

        #expect(factoryCalls == 1)
        #expect(harness.engine.taps[app.id] != nil)
    }

    // MARK: - Helpers

    private func makeHarness(
        app: AudioApp,
        devices: [AudioDevice],
        aliveIDs: Set<AudioDeviceID>,
        liveProcessObjects: (() -> Set<AudioObjectID>)? = nil,
        displayDeviceIDs: Set<AudioDeviceID> = [],
        tapFactory: @escaping @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling
    ) -> (engine: AudioEngine, deviceMonitor: MockAudioDeviceMonitor) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        settings.setDevicePriorityOrder(devices.map(\.uid))
        let permission = AudioRecordingPermission()
        permission.setStatusForTesting(.authorized)
        let deviceMonitor = MockAudioDeviceMonitor()
        for device in devices {
            deviceMonitor.addOutputDevice(device)
        }
        let volume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        if let first = devices.first {
            _ = volume.setDefaultDevice(first.id)
        }
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            processMonitor: LivenessProcessMonitor(activeApps: [app]),
            deviceVolumeMonitor: volume,
            tapFactory: tapFactory,
            isAlive: { aliveIDs.contains($0) },
            liveProcessObjects: liveProcessObjects,
            isDisplayTransport: { displayDeviceIDs.contains($0) },
            startMonitorsAutomatically: false
        )
        return (engine, deviceMonitor)
    }

    private func makeApp(pid: pid_t, objectIDs: [AudioObjectID] = []) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: objectIDs,
            name: "LivenessTest",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.finetune.tests.liveness.\(pid)"
        )
    }

    private func makeDevice(id: AudioDeviceID, uid: String, name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: false)
    }
}
