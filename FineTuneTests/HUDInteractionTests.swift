import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("HUD — focus, dismissal and timers", .serialized)
@MainActor
struct HUDInteractionTests {
    private func makeHUD(style: HUDStyle = .tahoe) -> HUDWindowController {
        _ = NSApplication.shared
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var options = settings.appSettings
        options.hudStyle = style
        settings.updateAppSettings(options)
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        // Keep test panels away from the user's windows and physical mouse.
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.fullscreenProvider = { false }
        hud.observesOutsideClicks = false
        hud.hideDelayOverride = .seconds(5)
        return hud
    }

    @Test("system HUD never becomes key or main, including repeated volume presses", arguments: [HUDStyle.tahoe, .classic])
    func preservesKeyWindow(style: HUDStyle) throws {
        let hud = makeHUD(style: style)
        let editor = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        editor.isReleasedWhenClosed = false
        defer { hud.shutdown(); editor.close() }
        editor.makeKeyAndOrderFront(nil)
        let previousKey = NSApp.keyWindow

        hud.show(sliderFraction: 0.4, mute: false, deviceName: "Display")
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        let panel = try #require(hud.panel)
        #expect(panel.isVisible)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isKeyWindow)
        #expect(NSApp.keyWindow === previousKey)
        #expect(panel.ignoresMouseEvents == (style == .classic))
        #expect(panel.contentView?.acceptsFirstMouse(for: nil) == true)
    }

    @Test("per-app HUD also stays non-key and offers mouse dismissal")
    func perAppPreservesFocus() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        let previousKey = NSApp.keyWindow
        hud.showPerAppNotControlledHUD(displayName: "Test App", bundleID: nil, icon: nil)
        let panel = try #require(hud.panel)
        #expect(panel.isVisible)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.ignoresMouseEvents)
        #expect(NSApp.keyWindow === previousKey)
        hud.dismiss()
        #expect(!panel.isVisible)
    }

    @Test("outside clicks dismiss the HUD and return the original event for window dragging")
    func outsideClickPassesThrough() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(hud.handleOutsideMouseDown(event) === event)
        #expect(hud.panel?.isVisible == false)
    }

    @Test("clicks inside the HUD reach its controls without dismissing it")
    func insideClickRemainsInteractive() throws {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        let panel = try #require(hud.panel)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 30), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(hud.handleOutsideMouseDown(event) === event)
        #expect(panel.isVisible)
    }

    @Test("the actual hide timer dismisses the panel")
    func autoHideTimerFires() async {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.hideDelayOverride = .milliseconds(40)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        try? await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == false)
    }

    @Test("hover holds the HUD across volume updates, then leaving starts dismissal")
    func hoverSurvivesVolumeUpdate() async {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.hideDelayOverride = .milliseconds(40)
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        hud.handleHoverChange(true)
        hud.show(sliderFraction: 0.6, mute: false, deviceName: "Display")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(hud.panel?.isVisible == true)
        hud.handleHoverChange(false)
        try? await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == false)
    }

    @Test("a stale fade completion cannot hide a HUD shown again after dismissal")
    func staleFadeDoesNotHideNewPresentation() async {
        let hud = makeHUD()
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Display")
        hud.hide()
        hud.dismiss()
        hud.show(sliderFraction: 0.6, mute: false, deviceName: "Display")
        try? await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == true)
        #expect(hud.panel?.alphaValue == 1)
    }
}
