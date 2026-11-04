import AppKit
import Testing
@testable import FineTune

@Suite("Capsule style keeps the selected geometry", .serialized)
@MainActor
struct CapsuleHUDRegressionTests {
    @Test("saved Tahoe preference presents the capsule instead of delegating to OSDManager")
    func selectedCapsuleOwnsItsRendering() throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(settings.appSettings.hudStyle == .tahoe)
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.fullscreenProvider = { false }
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.observesOutsideClicks = false
        defer { hud.shutdown() }
        hud.show(sliderFraction: 7.0 / 16, mute: false, deviceName: "Output")
        let panel = try #require(hud.panel)
        #expect(panel.isVisible)
        #expect(panel.contentView?.frame.size == NSSize(width: 388, height: 145))
    }

    @Test("explicit Classic selection keeps the square indicator")
    func classicRemainsAnExplicitChoice() throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var options = settings.appSettings
        options.hudStyle = .classic
        settings.updateAppSettings(options)
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.fullscreenProvider = { false }
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.observesOutsideClicks = false
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Output")
        let panel = try #require(hud.panel)
        #expect(panel.isVisible)
        #expect(panel.contentView?.frame.size == NSSize(width: 200, height: 200))
    }
}
