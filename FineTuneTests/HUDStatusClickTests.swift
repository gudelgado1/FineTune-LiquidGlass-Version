import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("HUD to popup through status-item mouse monitors", .serialized)
@MainActor struct HUDStatusClickTests {
    @Test("reopening during a popup fade remains visible after old completions",
          arguments: [false, true])
    func reopenDuringFade(duringDismissal: Bool) async throws {
        let title = "FineTune-fade-QA-\(UUID().uuidString)"
        let popup = FluidMenuBarExtraWindow(title: title) { Text("Popup QA").padding(20) }
        let item = FluidMenuBarExtraStatusItem(title: title, image: .systemNamed("speaker.fill"), window: popup)
        defer { item.dismissWindow(animated: false) }
        // Other async suites may take key focus. This test owns only fade
        // completion/reopening; first-click tests below cover delegate routing.
        popup.delegate = nil
        item.showWindow()
        try await Task.sleep(for: .milliseconds(duringDismissal ? 250 : 60))
        item.dismissWindow()
        item.showWindow()
        try await Task.sleep(for: .milliseconds(500))
        #expect(popup.isVisible)
        #expect(popup.alphaValue == 1)
        item.dismissWindow(animated: false)
        #expect(!popup.isVisible)
    }

    @Test("one status-item click opens popup with either monitor ordering", arguments: ["hud-first", "fluid-first", "global"])
    func firstClickPromotes(route: String) throws {
        let title = "FineTune-click-QA-\(UUID().uuidString)"
        let popup = FluidMenuBarExtraWindow(title: title) { Text("Popup QA").padding(20) }
        let item = FluidMenuBarExtraStatusItem(title: title, image: .systemNamed("speaker.fill"), window: popup)
        // The inert test host has no active menu bar; inject the remote source
        // rectangle for the global-event case rather than asserting visibility.
        var remoteGeometry: HUDMenuBarAnchor.Geometry?
        let anchor = HUDMenuBarAnchor(geometryProvider: route == "global" ? { remoteGeometry } : nil)
        item.hudAnchor = anchor
        let native = try #require(MenuBarPopupController(accessibilityTitle: title).findStatusItem())
        let button = try #require(native.button), buttonWindow = try #require(button.window)
        remoteGeometry = .init(buttonFrame: NSRect(x: -9400, y: -9130, width: 40, height: 30), screenFrame: NSRect(x: -10000, y: -10000, width: 1440, height: 900))
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService(), menuBarAnchor: anchor)
        hud.fullscreenProvider = { false }; hud.observesOutsideClicks = false
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.mousePositionProvider = { route == "global" ? NSPoint(x: -9380, y: -9115) : NSPoint(x: buttonWindow.frame.midX, y: buttonWindow.frame.midY) }
        defer { hud.shutdown(); item.dismissWindow(animated: false); item.hudAnchor = nil }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "QA")
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                      location: NSPoint(x: button.bounds.midX, y: button.bounds.midY), modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: route == "global" ? 0 : buttonWindow.windowNumber,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        if route != "global" { #expect(event.window === buttonWindow) }
        // Same handlers and ordering as the production local monitors.
        if route == "global" { hud.handleGlobalMouseDown(event) }
        else {
            if route == "hud-first" { _ = hud.handleOutsideMouseDown(event) }
            #expect(item.handleStatusItemMouseDown(event) == nil)
            if route == "fluid-first" { _ = hud.handleOutsideMouseDown(event) }
        }
        #expect(anchor.isPopupVisible)
        #expect(popup.isVisible)
    }
}

@Suite("Remote menu-bar mouse routing", .serialized)
@MainActor struct HUDRemoteClickTests {
    @Test("only an ordinary left click inside our status item requests a popup",
          arguments: ["inside", "outside", "command", "control", "right"])
    func routesOwnButtonOnly(route: String) throws {
        let button = NSRect(x: -9400, y: -9130, width: 40, height: 30)
        let screen = NSRect(x: -10000, y: -10000, width: 1440, height: 900)
        let anchor = HUDMenuBarAnchor(geometryProvider: { .init(buttonFrame: button, screenFrame: screen) })
        var opens = 0
        anchor.onPopupRequested = { opens += 1 }
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService(), menuBarAnchor: anchor)
        hud.fullscreenProvider = { false }; hud.observesOutsideClicks = false
        hud.mousePositionProvider = { route == "outside" ? .zero : NSPoint(x: button.midX, y: button.midY) }
        defer { hud.shutdown(); anchor.setPopupVisible(false) }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "QA")
        let flags: NSEvent.ModifierFlags = route == "command" ? .command : (route == "control" ? .control : [])
        let event = try #require(NSEvent.mouseEvent(with: route == "right" ? .rightMouseDown : .leftMouseDown,
                    location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        hud.handleGlobalMouseDown(event)
        #expect(opens == (route == "inside" ? 1 : 0))
        #expect(anchor.isPopupVisible == (route == "inside"))
    }

    @Test("an outside click closes a visible popup that lost key to its popover")
    func outsideClickClosesPopupWithoutKey() async {
        let window = FluidMenuBarExtraWindow(title: "Outside click") { Color.clear }
        let item = FluidMenuBarExtraStatusItem(title: "Outside click", image: .systemNamed("speaker"), window: window)
        defer { item.isVisible = false; window.close() }
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        #expect(window.isVisible && !window.isKeyWindow)

        item.handleOutsideMouseDown()

        try? await Task.sleep(for: .milliseconds(400))
        #expect(!window.isVisible)
    }
}
