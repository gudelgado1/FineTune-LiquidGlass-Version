import Foundation

/// The isolated unit runner supplies this environment before loading the app library.
/// Production continues to use its existing directories and defaults domain.
nonisolated enum AppDataLocations {
    static let unitTestRoot: URL? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FINETUNE_TEST_MODE"] == "unit" else { return nil }
        guard let path = environment["FINETUNE_TEST_DATA_ROOT"], path.hasPrefix("/") else {
            preconditionFailure("Unit tests require an absolute FINETUNE_TEST_DATA_ROOT; use scripts/run-tests.py")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var isUnitTesting: Bool { unitTestRoot != nil }

    static let applicationSupport: URL = {
        if let root = unitTestRoot { return root.appendingPathComponent("Application Support/FineTune", isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FineTune", isDirectory: true)
    }()

    static let diagnostics: URL = {
        if let root = unitTestRoot { return root.appendingPathComponent("Logs/FineTune", isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FineTune", isDirectory: true)
    }()

    // A fresh domain per run prevents the crossfade tests from changing the
    // installed app's preferences. The existing production domain is preserved.
    static let preferences: UserDefaults = {
        guard unitTestRoot != nil else { return .standard }
        return UserDefaults(suiteName: "com.finetune.tests.\(UUID().uuidString)")!
    }()
}
