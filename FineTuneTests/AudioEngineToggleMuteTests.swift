// FineTuneTests/AudioEngineToggleMuteTests.swift
import Testing
import Foundation
import AppKit
@testable import FineTune

@MainActor
private final class OutputDeviceTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1.0
    var isMuted = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted = false
    var audioLevel: Float = 0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String?

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate() throws {}
    func invalidate() {}
    func invalidateAsync() async {}
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {}
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {}
    func hasRecentAudioCallback(within seconds: Double) -> Bool { true }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws {}
}

@Suite("AudioEngine.toggleMute")
@MainActor
struct AudioEngineToggleMuteTests {
    @Test("toggleMute flips an unmuted app to muted")
    func toggleUnmutedToMuted() {
        let (engine, app) = makeEngineWithApp(initiallyMuted: false)

        engine.toggleMute(for: app)

        #expect(engine.volumeState.getMute(for: app.id) == true)
    }

    @Test("toggleMute flips a muted app to unmuted")
    func toggleMutedToUnmuted() {
        let (engine, app) = makeEngineWithApp(initiallyMuted: true)

        engine.toggleMute(for: app)

        #expect(engine.volumeState.getMute(for: app.id) == false)
    }

    @Test("isAudibleNow returns false when no AudioApp matches the bundle ID")
    func isAudibleNowReturnsFalseForUnknownBundle() {
        let (engine, _) = makeEngineWithApp(initiallyMuted: false)
        #expect(engine.isAudibleNow(bundleID: "com.does.not.exist") == false)
    }

    @Test("isAudibleNow returns false when matched AudioApp has no processObjectIDs")
    func isAudibleNowReturnsFalseWhenNoProcessObjects() {
        let (engine, app) = makeEngineWithApp(initiallyMuted: false)
        #expect(engine.isAudibleNow(bundleID: app.bundleID ?? "") == false)
    }

    @Test("software output at zero silences a tap routed to multiple software devices")
    func multiDeviceSoftwareZeroSilencesTap() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let left = AudioDevice(id: 1, uid: "left", name: "Left", icon: nil, supportsAutoEQ: false)
        let right = AudioDevice(id: 2, uid: "right", name: "Right", icon: nil, supportsAutoEQ: false)
        deviceMonitor.addOutputDevice(left)
        deviceMonitor.addOutputDevice(right)
        let volume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volume.autoDetectedTiersByID[left.id] = .software
        volume.autoDetectedTiersByID[right.id] = .software
        let engine = AudioEngine(
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: volume,
            startMonitorsAutomatically: false
        )
        let app = AudioApp(
            id: 42425,
            processObjectIDs: [],
            name: "TestApp",
            icon: NSImage(),
            bundleID: "com.test.multiDeviceZero"
        )
        let tap = OutputDeviceTap(app: app, deviceUIDs: [left.uid, right.uid])
        engine.taps[app.id] = tap

        volume.setVolume(for: left.id, to: 0)
        volume.setVolume(for: right.id, to: 0)

        #expect(tap.volume == 0, "A multi-device tap must be silent when every routed software output is zero")
    }

    private func makeEngineWithApp(initiallyMuted: Bool) -> (AudioEngine, AudioApp) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        let engine = AudioEngine(
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )
        let app = AudioApp(
            id: 42424,
            processObjectIDs: [],
            name: "TestApp",
            icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage(),
            bundleID: "com.test.toggleMute"
        )
        engine.volumeState.setMute(for: app.id, to: initiallyMuted, identifier: app.persistenceIdentifier)
        return (engine, app)
    }
}
