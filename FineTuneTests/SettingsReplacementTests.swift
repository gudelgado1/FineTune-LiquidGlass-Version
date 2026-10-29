import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class ReplacementProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?
    init(_ app: AudioApp) { activeApps = [app] }
    func start() {}
    func stop() {}
}

private final class ReplacementTap: ProcessTapControlling {
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
    var invalidated = false
    func invalidate() { invalidated = true }
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

@Suite("Settings replacement", .serialized)
@MainActor
struct SettingsReplacementTests {
    private func harness(loginService: (any LaunchAtLoginManaging)? = nil) -> (engine: AudioEngine, tap: ReplacementTap, settings: SettingsManager, app: AudioApp, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finetune-qa-\(UUID().uuidString)")
        let settings = SettingsManager(directory: directory, loginService: loginService)
        let app = AudioApp(id: 99871, processObjectIDs: [], name: "QA App", icon: NSImage(), bundleID: "com.example.qa")
        let devices = MockAudioDeviceMonitor()
        devices.addOutputDevice(AudioDevice(id: 99872, uid: "qa-output", name: "QA Output", icon: nil, supportsAutoEQ: false))
        let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        volume.defaultDeviceID = 99872; volume.defaultDeviceUID = "qa-output"
        let permission = AudioRecordingPermission()
        permission.setStatusForTesting(.authorized)
        let tap = ReplacementTap(app: app, devices: ["qa-output"])
        let engine = AudioEngine(permission: permission, settingsManager: settings,
            deviceProvider: devices, processMonitor: ReplacementProcessMonitor(app), deviceVolumeMonitor: volume,
            tapFactory: { _, _, _ in tap }, isAlive: { _ in true }, startMonitorsAutomatically: false)
        return (engine, tap, settings, app, directory)
    }

    @Test("Backup restore must update the running engine volume")
    func importedVolumeReachesEngine() throws {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        h.engine.setVolume(for: h.app, to: 0.2)
        var backup = SettingsManager.Settings()
        backup.appVolumes[h.app.persistenceIdentifier] = 0.8
        try h.settings.importData(JSONEncoder().encode(backup))
        #expect(h.settings.getVolume(for: h.app.persistenceIdentifier) == 0.8)
        #expect(h.engine.getVolume(for: h.app) == 0.8)
        #expect(h.tap.volume == 0.8)
    }

    @Test("Reset all settings must disable a running loudness leveler")
    func resetDisablesLeveler() {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        h.engine.appDeviceRouting[h.app.id] = "qa-output"
        h.settings.appSettings.loudnessEqualizationEnabled = true
        h.tap.levelerEnabled = true
        h.engine.handleSettingsReset()
        #expect(!h.settings.appSettings.loudnessEqualizationEnabled)
        #expect(!h.tap.levelerEnabled)
    }

    @Test("import replaces cached mute/boost/DSP, including defaults absent from backup", arguments: [true, false])
    func replacesEntireLiveState(enabled: Bool) throws {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        h.engine.setVolume(for: h.app, to: 0.2)
        h.engine.setMute(for: h.app, to: !enabled)
        h.engine.setBoost(for: h.app, to: .x4)
        h.tap.eqEnabled = !enabled; h.tap.levelerEnabled = !enabled
        h.tap.compensationEnabled = !enabled; h.tap.preampEnabled = !enabled
        var backup = SettingsManager.Settings()
        if enabled {
            backup.appVolumes[h.app.persistenceIdentifier] = 0.3
            backup.appBoosts[h.app.persistenceIdentifier] = 2
            backup.appMutes[h.app.persistenceIdentifier] = true
            backup.appEQSettings[h.app.persistenceIdentifier] = EQSettings(bandGains: [3], isEnabled: true)
            backup.appSettings.loudnessEqualizationEnabled = true
            backup.appSettings.loudnessCompensationEnabled = true
            backup.autoEQPreampEnabled = false
        }
        try h.settings.importData(JSONEncoder().encode(backup))
        #expect(abs(h.tap.volume - (enabled ? 0.6 : 1)) < 0.0001)
        #expect(h.tap.isMuted == enabled)
        #expect(h.tap.eqEnabled == enabled)
        #expect(h.tap.levelerEnabled == enabled)
        #expect(h.tap.compensationEnabled == enabled)
        #expect(h.tap.preampEnabled == !enabled)
        #expect(h.engine.getBoost(for: h.app) == (enabled ? .x2 : .x1))
    }

    @Test("paused warm tap is updated and rerouted on import", arguments: [false, true])
    func pausedTapRoutesOnImport(multi: Bool) async throws {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        (h.engine.processMonitor as? ReplacementProcessMonitor)?.activeApps = []
        (h.engine.deviceMonitor as? MockAudioDeviceMonitor)?.addOutputDevice(
            AudioDevice(id: 99873, uid: "second", name: "Second", icon: nil, supportsAutoEQ: false))
        h.engine.taps[h.app.id] = h.tap
        h.engine.setVolume(for: h.app, to: 0.2)
        var backup = SettingsManager.Settings()
        backup.appVolumes[h.app.persistenceIdentifier] = 0.7
        backup.appDeviceRouting[h.app.persistenceIdentifier] = "second"
        if multi {
            backup.appDeviceSelectionMode[h.app.persistenceIdentifier] = .multi
            backup.appSelectedDeviceUIDs[h.app.persistenceIdentifier] = ["qa-output", "second"]
        }
        try h.settings.importData(JSONEncoder().encode(backup))
        let expected = multi ? ["qa-output", "second"] : ["second"]
        for _ in 0..<100 {
            if h.tap.currentDeviceUIDs == expected { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.tap.currentDeviceUIDs == expected)
        #expect(abs(h.tap.volume - 0.7) < 0.0001)
        #expect(h.engine.getDeviceSelectionMode(for: h.app) == (multi ? .multi : .single))
    }

    @Test("malformed import leaves persisted and live state intact")
    func failedImportIsAtomic() {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        h.engine.setVolume(for: h.app, to: 0.2)
        #expect(throws: (any Error).self) { try h.settings.importData(Data("invalid JSON".utf8)) }
        #expect(h.settings.getVolume(for: h.app.persistenceIdentifier) == 0.2)
        #expect(h.engine.getVolume(for: h.app) == 0.2)
        #expect(h.tap.volume == 0.2)
    }

    @Test("import updates login adapter and drops newly ignored taps")
    func loginAndIgnoreFollowImport() throws {
        let login = InMemoryLaunchAtLoginService()
        let h = harness(loginService: login)
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        var backup = SettingsManager.Settings()
        backup.appSettings.launchAtLogin = true
        backup.ignoredApps.insert(h.app.persistenceIdentifier)
        try h.settings.importData(JSONEncoder().encode(backup))
        #expect(login.isEnabled)
        #expect(h.engine.taps[h.app.id] == nil)
        #expect(h.tap.invalidated)
        h.engine.handleSettingsReset()
        #expect(!login.isEnabled)
    }

    @Test("reset restores all live defaults including preamp")
    func resetAllLiveDefaults() {
        let h = harness()
        defer { h.settings.flushSync(); try? FileManager.default.removeItem(at: h.directory) }
        h.engine.taps[h.app.id] = h.tap
        h.engine.setVolume(for: h.app, to: 0.2)
        h.engine.setMute(for: h.app, to: true)
        h.engine.setBoost(for: h.app, to: .x4)
        h.tap.eqEnabled = true; h.tap.levelerEnabled = true
        h.tap.compensationEnabled = true; h.tap.preampEnabled = false
        h.engine.handleSettingsReset()
        #expect(h.tap.volume == 1)
        #expect(!h.tap.isMuted)
        #expect(h.engine.getBoost(for: h.app) == .x1)
        #expect(!h.tap.eqEnabled && !h.tap.levelerEnabled && !h.tap.compensationEnabled)
        #expect(h.tap.preampEnabled)
        #expect(h.tap.autoEQProfile == nil)
    }

}
