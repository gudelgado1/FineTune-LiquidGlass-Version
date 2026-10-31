import AppKit
import Testing
@testable import FineTune

@Suite("HUD compositor envelope and pointer behavior", .serialized)
@MainActor
struct HUDMaterialInteractionTests {
    private func makeHUD() -> HUDWindowController {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.fullscreenProvider = { false }
        hud.observesOutsideClicks = false
        return hud
    }

    @Test("transparent compositor margins pass mouse input while the capsule remains interactive")
    func marginsAreNotControls() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Output")
        let panel = try #require(hud.panel)
        #expect(panel.frame.size == NSSize(width: 388, height: 145))
        hud.updatePointerInteractivity(at: NSPoint(x: panel.frame.minX + 8, y: panel.frame.midY))
        #expect(panel.ignoresMouseEvents)
        hud.updatePointerInteractivity(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        #expect(!panel.ignoresMouseEvents)
    }

    @Test("active material appearance does not make the HUD a key or main window")
    func activeWithoutFocus() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Output")
        let panel = try #require(hud.panel)
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        for name in ["_hasActiveAppearance", "_hasKeyAppearance", "hasKeyAppearance"] {
            let selector = NSSelectorFromString(name)
            #expect(panel.responds(to: selector))
            let getter = unsafeBitCast(panel.method(for: selector), to: Getter.self)
            #expect(getter(panel, selector))
        }
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isKeyWindow)
        #expect(panel.level.rawValue == NSWindow.Level.mainMenu.rawValue - 1)
    }

    @Test("a stationary cursor at presentation cannot pin the HUD open")
    func initialHoverDoesNotPin() async throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        let origin = HUDWindowController.computePosition(style: .tahoe, size: NSSize(width: 388, height: 145), visibleFrame: NSRect(x: -10000, y: -10000, width: 1440, height: 900), suppressionDegraded: false)
        let cursor = NSPoint(x: origin.x + 100, y: origin.y + 70)
        hud.mousePositionProvider = { cursor }
        hud.hideDelayOverride = .milliseconds(20)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Output")
        hud.handleHoverChange(true)
        try await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == false)
    }

    @Test("per-app notifications keep their usable-screen inset after a capsule")
    func perAppPlacementRemainsIndependent() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Output")
        hud.showPerAppNotControlledHUD(displayName: "Test", bundleID: nil, icon: nil)
        let panel = try #require(hud.panel)
        #expect(panel.frame.size == NSSize(width: 316, height: 88))
        #expect(panel.frame.origin == NSPoint(x: -8884, y: -9196))
    }
}
