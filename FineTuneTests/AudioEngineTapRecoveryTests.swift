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
