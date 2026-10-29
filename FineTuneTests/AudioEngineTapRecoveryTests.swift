import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class RecoveryProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?

    init(activeApps: [AudioApp]) {
        self.activeApps = activeApps
    }

    func start() {}
    func stop() {}
}

@MainActor
private final class RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entryContinuation?.resume()
            entryContinuation = nil
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        let suspended = continuation
        continuation = nil
        suspended?.resume()
    }
}

private final class RecoveryTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var currentDeviceUIDs: [String]
    var tapSourceDeviceUID: String?

    private(set) var activateCallCount = 0
    private(set) var invalidateCallCount = 0
    private(set) var invalidateAsyncCallCount = 0
    var invalidationGate: RecoveryGate?

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate() throws {
        activateCallCount += 1
    }

    func invalidate() {
        invalidateCallCount += 1
    }

    func invalidateAsync() async {
        invalidateAsyncCallCount += 1
        await invalidationGate?.wait()
    }

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
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        tapSourceDeviceUID = preferredDeviceUID
    }
}

@Suite("AudioEngine — tap recovery")
@MainActor
struct AudioEngineTapRecoveryTests {
    @Test("failed tap recreation uses short retry cooldown instead of long success cooldown")
    func failedRecreationUsesShortCooldown() async {
        let app = makeApp(pid: 51001)
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        let engine = makeEngine(app: app) { _, _, _ in
            struct CreationError: Error {}
            throw CreationError()
        }
        engine.taps[app.id] = oldTap

        await engine.recreateTap(for: app.id)

        #expect(oldTap.invalidateAsyncCallCount == 1)
        #expect(engine.taps[app.id] == nil)
        let retryInterval = engine.tapRecoveryCooldownUntil[app.id]?.timeIntervalSinceNow ?? 0
        #expect(retryInterval > 0)
        #expect(retryInterval <= 16)
        #expect(retryInterval >= 10)
    }

    @Test("successful tap recreation preserves routing and installs long cooldown")
    func successfulRecreationPreservesRouting() async {
        let app = makeApp(pid: 51002)
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a", "device-b"])
        var replacement: RecoveryTap?
        let engine = makeEngine(app: app) { app, deviceUIDs, sourceUID in
            let tap = RecoveryTap(app: app, deviceUIDs: deviceUIDs)
            tap.tapSourceDeviceUID = sourceUID
            replacement = tap
            return tap
        }
        engine.taps[app.id] = oldTap

        await engine.recreateTap(for: app.id)

        #expect(oldTap.invalidateAsyncCallCount == 1)
        #expect(replacement?.activateCallCount == 1)
        #expect(engine.taps[app.id] === replacement)
        #expect(engine.taps[app.id]?.currentDeviceUIDs == ["device-a", "device-b"])
        #expect(engine.appDeviceRouting[app.id] == "device-a")
        let cooldownInterval = engine.tapRecoveryCooldownUntil[app.id]?.timeIntervalSinceNow ?? 0
        #expect(cooldownInterval > 15)
    }

    @Test("cancelling recovery during teardown does not activate a replacement")
    func cancelledRecoveryDoesNotRecreate() async {
        let app = makeApp(pid: 51003)
        let gate = RecoveryGate()
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        oldTap.invalidationGate = gate
        var factoryCalls = 0
        let engine = makeEngine(app: app) { app, uids, _ in
            factoryCalls += 1
            return RecoveryTap(app: app, deviceUIDs: uids)
        }
        engine.taps[app.id] = oldTap
        engine.appliedPIDs.insert(app.id)

        let recovery = Task { await engine.recreateTap(for: app.id) }
        await gate.waitUntilSuspended()
        recovery.cancel()
        gate.release()
        await recovery.value

        #expect(factoryCalls == 0)
        #expect(engine.taps[app.id] == nil)
        #expect(!engine.appliedPIDs.contains(app.id))
        #expect(!engine.pidsBeingRecreated.contains(app.id))
        #expect(engine.tapRecreationTokens[app.id] == nil)
    }

    @Test("shutdown during teardown cannot resurrect capture")
    func shutdownInvalidatesSuspendedRecovery() async {
        let app = makeApp(pid: 51004)
        let gate = RecoveryGate()
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        oldTap.invalidationGate = gate
        var factoryCalls = 0
        let engine = makeEngine(app: app) { app, uids, _ in
            factoryCalls += 1
            return RecoveryTap(app: app, deviceUIDs: uids)
        }
        engine.taps[app.id] = oldTap

        let recovery = Task { await engine.recreateTap(for: app.id) }
        await gate.waitUntilSuspended()
        engine.shutdown()
        gate.release()
        await recovery.value

        #expect(factoryCalls == 0)
        #expect(engine.taps.isEmpty)
        #expect(engine.pidsBeingRecreated.isEmpty)
        #expect(engine.tapRecreationTokens.isEmpty)
    }

    @Test("old recovery completion preserves a newer recovery's ownership after stop")
    func oldRecoveryCannotClearNewRecoveryToken() async {
        let app = makeApp(pid: 51005)
        let oldGate = RecoveryGate()
        let newGate = RecoveryGate()
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        oldTap.invalidationGate = oldGate
        let newTap = RecoveryTap(app: app, deviceUIDs: ["device-b"])
        newTap.invalidationGate = newGate
        var factoryCalls = 0
        let engine = makeEngine(app: app) { app, uids, _ in
            factoryCalls += 1
            return RecoveryTap(app: app, deviceUIDs: uids)
        }
        engine.taps[app.id] = oldTap

        let oldRecovery = Task { await engine.recreateTap(for: app.id) }
        await oldGate.waitUntilSuspended()
        engine.stop()
        // Model the next engine lifetime installing and recovering a new tap.
        engine.taps[app.id] = newTap
        let newRecovery = Task { await engine.recreateTap(for: app.id) }
        await newGate.waitUntilSuspended()
        let newToken = engine.tapRecreationTokens[app.id]

        oldGate.release()
        await oldRecovery.value
        #expect(factoryCalls == 0)
        #expect(engine.tapRecreationTokens[app.id] == newToken)
        #expect(engine.pidsBeingRecreated.contains(app.id))

        newGate.release()
        await newRecovery.value
        #expect(factoryCalls == 1)
        #expect(engine.taps[app.id]?.currentDeviceUIDs == ["device-b"])
        #expect(!engine.pidsBeingRecreated.contains(app.id))
        #expect(engine.tapRecreationTokens[app.id] == nil)
    }

    @Test("default change during teardown is used by the replacement tap")
    func recoveryUsesDefaultChangedDuringTeardown() async {
        let app = makeApp(pid: 51006)
        let gate = RecoveryGate()
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        oldTap.invalidationGate = gate
        let engine = makeEngine(app: app) { app, uids, sourceUID in
            let replacement = RecoveryTap(app: app, deviceUIDs: uids)
            replacement.tapSourceDeviceUID = sourceUID
            return replacement
        }
        let volume = engine.deviceVolumeMonitor as! MockDeviceVolumeProviding
        volume.defaultDeviceUID = "device-a"
        engine.followsDefault.insert(app.id)
        engine.appDeviceRouting[app.id] = "device-a"
        engine.taps[app.id] = oldTap

        let recovery = Task { await engine.recreateTap(for: app.id) }
        await gate.waitUntilSuspended()
        volume.defaultDeviceUID = "device-b"
        engine.routeFollowsDefaultApps(to: "device-b")
        gate.release()
        await recovery.value

        #expect(engine.taps[app.id]?.currentDeviceUIDs == ["device-b"])
        #expect(engine.appDeviceRouting[app.id] == "device-b")
    }

    @Test("manual rebuild waits for a tap already removed by an in-flight recovery")
    func manualRebuildWaitsForExistingRecovery() async {
        let app = makeApp(pid: 51007)
        let gate = RecoveryGate()
        let oldTap = RecoveryTap(app: app, deviceUIDs: ["device-a"])
        oldTap.invalidationGate = gate
        var factoryCalls = 0
        let engine = makeEngine(app: app) { app, uids, _ in
            factoryCalls += 1
            return RecoveryTap(app: app, deviceUIDs: uids)
        }
        engine.taps[app.id] = oldTap
        let recovery = Task { await engine.recreateTap(for: app.id) }
        await gate.waitUntilSuspended()
        let rebuild = Task { await engine.rebuildAllTaps() }
        // Longer than the old fixed settle delay: the gate must remain held
        // because this tap was removed before the manual rebuild took its snapshot.
        try? await Task.sleep(for: .milliseconds(800))
        #expect(engine.captureRebuildTask != nil)
        engine.ensureTapExists(for: app, deviceUID: "device-a")
        #expect(factoryCalls == 0)
        gate.release()
        await recovery.value
        _ = await rebuild.value
        #expect(engine.pendingTapTeardowns.isEmpty)
        #expect(engine.captureRebuildTask == nil)
    }

    private func makeEngine(
        app: AudioApp,
        tapFactory: @escaping @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling
    ) -> AudioEngine {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let permission = AudioRecordingPermission()
        permission.setStatusForTesting(.authorized)
        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        return AudioEngine(
            permission: permission,
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            processMonitor: RecoveryProcessMonitor(activeApps: [app]),
            deviceVolumeMonitor: mockVolume,
            tapFactory: tapFactory,
            startMonitorsAutomatically: false
        )
    }

    private func makeApp(pid: pid_t) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: [],
            name: "RecoveryTest",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.finetune.tests.recovery.\(pid)"
        )
    }
}
