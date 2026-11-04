import ServiceManagement

@MainActor
protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
struct SystemLaunchAtLoginService: LaunchAtLoginManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

/// The isolated unit host never registers itself as a real login item.
@MainActor
final class InMemoryLaunchAtLoginService: LaunchAtLoginManaging {
    private(set) var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}
