import Foundation
import Testing
@testable import FineTune

@MainActor
private final class RecordingLoginService: LaunchAtLoginManaging {
    var isEnabled = false
    var writes: [Bool] = []
    func setEnabled(_ enabled: Bool) throws { writes.append(enabled); isEnabled = enabled }
}

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {
    private func manager(login: RecordingLoginService? = nil) -> SettingsManager {
        SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), loginService: login ?? RecordingLoginService())
    }

    @Test("Direct assignment persists and flushes the preference in a private directory")
    func directAssignmentPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let login = RecordingLoginService()
        let manager = SettingsManager(directory: directory, loginService: login)
        manager.appSettings.defaultNewAppVolume = 0.42
        manager.flushSync()
        let restored = SettingsManager(directory: directory, loginService: login)
        #expect(restored.appSettings.defaultNewAppVolume == 0.42)
        #expect(login.writes.isEmpty)
    }

    @Test("A login change reaches the injected service exactly once")
    func directAssignmentForwardsLaunchAtLogin() {
        let login = RecordingLoginService()
        let manager = manager(login: login)
        manager.appSettings.launchAtLogin = true
        #expect(login.writes == [true])
        #expect(manager.isLaunchAtLoginEnabled)
        manager.appSettings.defaultNewAppVolume = 0.7
        #expect(login.writes == [true], "An unrelated preference must not re-register login")
        manager.appSettings.launchAtLogin = false
        #expect(login.writes == [true, false])
        #expect(!manager.isLaunchAtLoginEnabled)
    }

    @Test("Direct assignment and updateAppSettings apply the same preferences")
    func directAssignmentEquivalentToUpdate() {
        let managerA = manager()
        let managerB = manager()
        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false
        managerA.appSettings = modified
        managerB.updateAppSettings(modified)
        #expect(managerA.appSettings == managerB.appSettings)
    }

    @Test("Reset unregisters through the injected service")
    func resetUsesInjectedService() {
        let login = RecordingLoginService()
        let manager = manager(login: login)
        manager.appSettings.launchAtLogin = true
        manager.resetAllSettings()
        #expect(login.writes == [true, false])
        #expect(!manager.isLaunchAtLoginEnabled)
    }
}
