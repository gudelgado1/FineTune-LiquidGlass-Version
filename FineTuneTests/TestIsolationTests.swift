import Foundation
import Testing
@testable import FineTune

@Suite("Unit test environment isolation", .serialized)
@MainActor
struct TestIsolationTests {
    @Test("Unit runner supplies a private data root before any preferences are loaded")
    func runnerProvidesPrivateRoot() throws {
        let root = try #require(ProcessInfo.processInfo.environment["FINETUNE_TEST_DATA_ROOT"])
        #expect(root.hasPrefix("/"))
        #expect(ProcessInfo.processInfo.environment["FINETUNE_TEST_MODE"] == "unit")
    }
}

extension TestIsolationTests {
    @Test("Default settings and diagnostics stay under the runner's private root")
    func writesStayPrivate() throws {
        let root = try #require(AppDataLocations.unitTestRoot)
        #expect(AppDataLocations.applicationSupport.path.hasPrefix(root.path + "/"))
        #expect(AppDataLocations.diagnostics.path.hasPrefix(root.path + "/"))
        let manager = SettingsManager()
        let identifier = "com.finetune.tests.isolation.\(UUID().uuidString)"
        manager.setVolume(for: identifier, to: 0.42)
        manager.flushSync()
        let file = AppDataLocations.applicationSupport.appendingPathComponent("settings.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect((json?["appVolumes"] as? [String: Double])?[identifier] == 0.42)
        DiagnosticLog.log("test-isolation-marker")
        DiagnosticLog.flush()
        let log = try String(contentsOf: AppDataLocations.diagnostics.appendingPathComponent("Diagnostics.log"), encoding: .utf8)
        #expect(log.contains("test-isolation-marker"))
    }

    @Test("A default unit manager simulates login without ServiceManagement")
    func defaultLoginIsInMemory() throws {
        _ = try #require(AppDataLocations.unitTestRoot)
        let manager = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        manager.appSettings.launchAtLogin = true
        #expect(manager.isLaunchAtLoginEnabled)
        manager.appSettings.launchAtLogin = false
        #expect(!manager.isLaunchAtLoginEnabled)
    }

    @Test("The crossfade override never changes the production defaults domain")
    func defaultsStayPrivate() throws {
        _ = try #require(AppDataLocations.unitTestRoot)
        let key = "FineTune.Isolation.\(UUID().uuidString)"
        let original = UserDefaults.standard.object(forKey: key) as? Double
        AppDataLocations.preferences.set(0.123, forKey: key)
        defer { AppDataLocations.preferences.removeObject(forKey: key) }
        #expect(AppDataLocations.preferences.double(forKey: key) == 0.123)
        #expect(UserDefaults.standard.object(forKey: key) as? Double == original)
    }
}
