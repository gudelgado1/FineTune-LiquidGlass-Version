import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class StartupProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?
    init(_ app: AudioApp) { activeApps = [app] }
    func start() {}
    func stop() {}
}

private final class StartupTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted = false
    var audioLevel: Float = 0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String?
    var eqEnabled = false
    var levelerEnabled = false
    var eqAtActivation: Bool?
    var levelerAtActivation: Bool?
    var compensationEnabled = false
    var compensationAtActivation: Bool?
    var autoEQProfile: AutoEQProfile?
    var autoEQAtActivation: AutoEQProfile?
    var bypass = false
    var bypassAtActivation: Bool?
    var preampEnabled = true
    var preampAtActivation: Bool?
    init(app: AudioApp, devices: [String]) { self.app = app; currentDeviceUIDs = devices }
    func activate() throws {
        eqAtActivation = eqEnabled; levelerAtActivation = levelerEnabled
        compensationAtActivation = compensationEnabled; autoEQAtActivation = autoEQProfile
        bypassAtActivation = bypass; preampAtActivation = preampEnabled
    }
    func invalidate() {}
    func updateEQSettings(_ settings: EQSettings) { eqEnabled = settings.isEnabled }
    func updateAutoEQProfile(_ profile: AutoEQProfile?) { autoEQProfile = profile }
    func setAutoEQPreampEnabled(_ enabled: Bool) { preampEnabled = enabled }
    func updateLoudnessCompensation(volume: Float, enabled: Bool) { compensationEnabled = enabled }
    func setDSPBypass(_ value: Bool) { bypass = value }
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) { levelerEnabled = settings.enabled }
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws { currentDeviceUIDs = [newDeviceUID] }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws { currentDeviceUIDs = newDeviceUIDs }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }
}

@Suite("Tap startup DSP", .serialized)
@MainActor
struct TapStartupTests {
    private func harness() -> (engine: AudioEngine, tap: StartupTap, settings: SettingsManager, app: AudioApp, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finetune-qa-\(UUID().uuidString)")
        let settings = SettingsManager(directory: directory)
        let app = AudioApp(id: 99871, processObjectIDs: [], name: "QA App", icon: NSImage(), bundleID: "com.example.qa")
        let devices = MockAudioDeviceMonitor()
        devices.addOutputDevice(AudioDevice(id: 99872, uid: "qa-output", name: "QA Output", icon: nil, supportsAutoEQ: false))
        let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        volume.defaultDeviceID = 99872; volume.defaultDeviceUID = "qa-output"
        let permission = AudioRecordingPermission()
        permission.setStatusForTesting(.authorized)
        let tap = StartupTap(app: app, devices: ["qa-output"])
        let engine = AudioEngine(permission: permission, settingsManager: settings,
            deviceProvider: devices, processMonitor: StartupProcessMonitor(app), deviceVolumeMonitor: volume,
            tapFactory: { _, _, _ in tap }, isAlive: { _ in true }, startMonitorsAutomatically: false)
        return (engine, tap, settings, app, directory)
    }

    @Test("single, multi-output and recovery configure DSP before activation", arguments: [0, 1, 2])
    func persistedDSPPrecedesActivation(path: Int) async throws {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.settings.setEQSettings(EQSettings(bandGains: [3,0,0,0,0,0,0,0,0,0], isEnabled: true), for: h.app.persistenceIdentifier)
        h.settings.appSettings.loudnessEqualizationEnabled = true
        h.settings.appSettings.loudnessCompensationEnabled = true
        h.settings.autoEQPreampEnabled = false
        h.engine.isDSPLoadShed = true
        let profileID = "qa-startup-\(UUID().uuidString)"
        let cache = AppDataLocations.applicationSupport.appendingPathComponent("AutoEQ/fetched")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent(profileID + ".txt")
        try "Preamp: -6.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3.0 dB Q 1.0\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        h.settings.setAutoEQSelection(for: "qa-output", to: AutoEQSelection(profileID: profileID, isEnabled: true))
        switch path {
        case 0: h.engine.ensureTapExists(for: h.app, deviceUID: "qa-output")
        case 1: h.engine.ensureTapWithDevices(for: h.app, deviceUIDs: ["qa-output", "qa-secondary"])
        default:
            h.engine.taps[h.app.id] = h.tap
            await h.engine.recreateTap(for: h.app.id)
        }
        #expect(h.tap.eqAtActivation == true)
        #expect(h.tap.levelerAtActivation == true)
        #expect(h.tap.compensationAtActivation == true)
        #expect(h.tap.autoEQAtActivation?.id == profileID)
        #expect(h.tap.bypassAtActivation == true)
        #expect(h.tap.preampAtActivation == false)
    }

    @Test("native processor factory applies AutoEQ preamp to the first buffer")
    func nativeFirstBufferUsesSavedPreamp() {
        let profile = AutoEQProfile(id: "startup", name: "startup", source: .imported,
            preampDB: -6, filters: [.init(type: .peaking, frequency: 1000, gainDB: 0, q: 1)],
            measuredBy: nil, optimizedSampleRate: 48_000)
        var config = TapDSPConfiguration()
        config.autoEQProfile = profile
        config.loudnessEqualization.enabled = true
        config.loudnessCompensationEnabled = true
        config.loudnessVolume = 0.2
        let pipeline = config.makeProcessors(sampleRate: 48_000)
        #expect(pipeline.autoEQ.isEnabled)
        #expect(pipeline.equalizer.isEnabled)
        #expect(pipeline.compensator.isEnabled)
        var samples: [Float] = [1, 1, 1, 1]
        samples.withUnsafeMutableBufferPointer { ptr in
            pipeline.autoEQ.process(input: ptr.baseAddress!, output: ptr.baseAddress!, frameCount: 2)
        }
        let expected = powf(10, -6 / 20)
        #expect(samples.allSatisfy { abs($0 - expected) < 0.0001 })
    }
}
