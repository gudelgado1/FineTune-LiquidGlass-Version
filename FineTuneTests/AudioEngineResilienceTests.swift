import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class ResilienceProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?

    init(activeApps: [AudioApp]) {
        self.activeApps = activeApps
    }

    func start() {}
    func stop() {}
}

private final class ResilienceTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var currentDeviceUIDs: [String]
    var tapSourceDeviceUID: String?

    private(set) var switchDeviceCalls: [(uid: String, sourceUID: String?, sourceDeviceDead: Bool)] = []
    private(set) var updateDevicesCalls: [(uids: [String], sourceUID: String?, sourceDeviceDead: Bool)] = []
    private(set) var refreshSourceCalls: [String?] = []

    init(app: AudioApp, deviceUIDs: [String], sourceUID: String? = nil) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
        self.tapSourceDeviceUID = sourceUID
    }

    func activate() throws {}
    func invalidate() {}
    func invalidateAsync() async {}
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        switchDeviceCalls.append((newDeviceUID, preferredTapSourceDeviceUID, sourceDeviceDead))
        currentDeviceUIDs = [newDeviceUID]
        tapSourceDeviceUID = preferredTapSourceDeviceUID
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        updateDevicesCalls.append((newDeviceUIDs, preferredTapSourceDeviceUID, sourceDeviceDead))
        currentDeviceUIDs = newDeviceUIDs
        tapSourceDeviceUID = preferredTapSourceDeviceUID
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { true }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        refreshSourceCalls.append(preferredDeviceUID)
        tapSourceDeviceUID = preferredDeviceUID
    }
}

@Suite("AudioEngine — device resilience", .serialized)
@MainActor
struct AudioEngineResilienceTests {
    @Test("default-device disconnect falls back and preserves app volume/mute state")
    func defaultDisconnectFallsBackWithoutLosingState() async {
        let app = makeApp(pid: 61001)
        let primary = makeDevice(id: 101, uid: "primary", name: "Primary")
        let fallback = makeDevice(id: 102, uid: "fallback", name: "Fallback")
        let harness = makeHarness(app: app, devices: [primary, fallback], defaultUID: primary.uid)
        let tap = ResilienceTap(app: app, deviceUIDs: [primary.uid], sourceUID: primary.uid)
        harness.engine.taps[app.id] = tap
        harness.engine.followsDefault.insert(app.id)
        harness.engine.appDeviceRouting[app.id] = primary.uid
        harness.engine.setVolume(for: app, to: 0.42)
        harness.engine.setMute(for: app, to: true)

        harness.deviceMonitor.removeOutputDevice(uid: primary.uid)
        harness.engine.handleDeviceDisconnected(primary.uid, name: primary.name)
        await drainMainActorTasks()

        #expect(harness.engine.getDeviceUID(for: app) == fallback.uid)
        #expect(harness.engine.isFollowingDefault(for: app))
        #expect(tap.currentDeviceUIDs == [fallback.uid])
        #expect(tap.switchDeviceCalls.last?.sourceDeviceDead == true)
        #expect(abs(tap.volume - 0.42) < 0.0001)
        #expect(tap.isMuted)
        #expect(harness.engine.diagnosticsSnapshot().routeFallbackEvents == 1)
        #expect(harness.engine.diagnosticsSnapshot().lastFallbackReason == "deviceDisconnected:\(primary.uid)")
    }

    @Test("multi-device disconnect removes only the dead device and keeps the remaining route")
    func multiDeviceDisconnectKeepsRemainingDevices() async {
        let app = makeApp(pid: 61002)
        let left = makeDevice(id: 201, uid: "left", name: "Left")
        let right = makeDevice(id: 202, uid: "right", name: "Right")
        let harness = makeHarness(app: app, devices: [left, right], defaultUID: left.uid)
        let tap = ResilienceTap(app: app, deviceUIDs: [left.uid, right.uid])
        harness.engine.taps[app.id] = tap
        harness.engine.volumeState.setDeviceSelectionMode(for: app.id, to: .multi, identifier: app.persistenceIdentifier)
        harness.engine.volumeState.setSelectedDeviceUIDs(for: app.id, to: [left.uid, right.uid], identifier: app.persistenceIdentifier)

        harness.deviceMonitor.removeOutputDevice(uid: left.uid)
        harness.engine.handleDeviceDisconnected(left.uid, name: left.name)
        await drainMainActorTasks()

        #expect(tap.currentDeviceUIDs == [right.uid])
        #expect(tap.updateDevicesCalls.last?.sourceDeviceDead == true)
        #expect(harness.engine.getSelectedDeviceUIDs(for: app) == [right.uid])
        #expect(harness.engine.getDeviceSelectionMode(for: app) == .multi)
        #expect(harness.engine.diagnosticsSnapshot().multiDeviceFallbackEvents == 1)
    }

    @Test("reconnected explicit device restores persisted route after fallback")
    func reconnectRestoresExplicitPersistedRoute() async {
        let app = makeApp(pid: 61003)
        let preferred = makeDevice(id: 301, uid: "preferred", name: "Preferred")
        let fallback = makeDevice(id: 302, uid: "fallback", name: "Fallback")
        let harness = makeHarness(app: app, devices: [fallback, preferred], defaultUID: fallback.uid)
        let tap = ResilienceTap(app: app, deviceUIDs: [fallback.uid])
        harness.engine.taps[app.id] = tap
        harness.engine.settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: preferred.uid)
        harness.engine.appDeviceRouting[app.id] = fallback.uid
        harness.engine.followsDefault.insert(app.id)

        harness.engine.handleDeviceConnected(preferred.uid, name: preferred.name)
        await drainMainActorTasks()

        #expect(harness.engine.getDeviceUID(for: app) == preferred.uid)
        #expect(!harness.engine.isFollowingDefault(for: app))
        #expect(tap.currentDeviceUIDs == [preferred.uid])
        #expect(tap.switchDeviceCalls.last?.sourceDeviceDead == false)
    }

    @Test("external default-device change reroutes follows-default taps with stream-specific source")
    func externalDefaultChangeRoutesFollowsDefaultApps() async {
        let app = makeApp(pid: 61004)
        let oldDefault = makeDevice(id: 401, uid: "old-default", name: "Old Default")
        let newDefault = makeDevice(id: 402, uid: "new-default", name: "New Default")
        let harness = makeHarness(app: app, devices: [oldDefault, newDefault], defaultUID: oldDefault.uid)
        let tap = ResilienceTap(app: app, deviceUIDs: [oldDefault.uid], sourceUID: oldDefault.uid)
        harness.engine.taps[app.id] = tap
        harness.engine.followsDefault.insert(app.id)
        harness.engine.appDeviceRouting[app.id] = oldDefault.uid

        harness.volume.defaultDeviceID = newDefault.id
        harness.volume.defaultDeviceUID = newDefault.uid
        harness.engine.handleDefaultDeviceChanged(newDefault.uid)
        await drainMainActorTasks()

        #expect(harness.engine.getDeviceUID(for: app) == newDefault.uid)
        #expect(harness.engine.lastConfirmedDefaultUID == newDefault.uid)
        #expect(tap.currentDeviceUIDs == [newDefault.uid])
        #expect(tap.tapSourceDeviceUID == newDefault.uid)
        #expect(harness.engine.diagnosticsSnapshot().defaultDeviceChangeEvents == 1)
    }

    private func makeHarness(
        app: AudioApp,
        devices: [AudioDevice],
        defaultUID: String
    ) -> (engine: AudioEngine, deviceMonitor: MockAudioDeviceMonitor, volume: MockDeviceVolumeProviding) {
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
        if let defaultDevice = devices.first(where: { $0.uid == defaultUID }) {
            _ = volume.setDefaultDevice(defaultDevice.id)
        }
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            processMonitor: ResilienceProcessMonitor(activeApps: [app]),
            deviceVolumeMonitor: volume,
            tapFactory: { app, deviceUIDs, sourceUID in
                ResilienceTap(app: app, deviceUIDs: deviceUIDs, sourceUID: sourceUID)
            },
            isAlive: { _ in true },
            startMonitorsAutomatically: false
        )
        return (engine, deviceMonitor, volume)
    }

    private func makeApp(pid: pid_t) -> AudioApp {
        AudioApp(
            id: pid,
            processObjectIDs: [],
            name: "ResilienceTest",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.finetune.tests.resilience.\(pid)"
        )
    }

    private func makeDevice(id: AudioDeviceID, uid: String, name: String) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: name, icon: nil, supportsAutoEQ: false)
    }

    private func drainMainActorTasks() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
