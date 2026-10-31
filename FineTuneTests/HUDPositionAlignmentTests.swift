import AppKit
import Testing
@testable import FineTune

@Suite("HUD placement at the menu bar", .serialized)
@MainActor
struct HUDPositionAlignmentTests {
    @Test("AppKit must not shift the transparent compositor envelope below the menu bar")
    func menuBarDoesNotAddASecondInset() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.fullscreenProvider = { false }
        hud.observesOutsideClicks = false
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Placement test")
        let panel = try #require(hud.panel)
        let expected = HUDWindowController.computePosition(style: .tahoe, size: panel.frame.size, visibleFrame: screen.frame, suppressionDegraded: false, topObstruction: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness))
        #expect(abs(panel.frame.origin.y - expected.y) < 0.5)
    }

    @Test("a moved status button moves the visible HUD without reopening it")
    func followsAnchor() throws {
        var button = NSRect(x: -9400, y: -9130, width: 40, height: 30)
        let screen = NSRect(x: -10000, y: -10000, width: 1440, height: 900)
        var highlights: [Bool] = []
        let anchor = HUDMenuBarAnchor(geometryProvider: { .init(buttonFrame: button, screenFrame: screen) }, highlightWriter: { highlights.append($0) })
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService(), menuBarAnchor: anchor)
        hud.fullscreenProvider = { false }
        hud.observesOutsideClicks = false
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Placement")
        let panel = try #require(hud.panel)
        #expect(panel.frame.midX == button.midX)
        #expect(panel.frame.maxY - CapsuleVolumeHUD.effectMargin == button.minY - 10)
        #expect(highlights.last == true)
        button.origin.x += 100
        anchor.geometryDidChange?()
        #expect(panel.frame.midX == button.midX)
        #expect(hud.showCallCount == 1)
        hud.dismiss()
        #expect(highlights.last == false)
    }

    @Test("edge clamping works on displays with negative and vertical origins")
    func screenEdges() {
        for origin in [NSPoint.zero, NSPoint(x: -1440, y: 900), NSPoint(x: 1920, y: -900)] {
            let screen = NSRect(origin: origin, size: NSSize(width: 1440, height: 900))
            for offset: CGFloat in [0, 600, 1400] {
                let button = NSRect(x: screen.minX + offset, y: screen.maxY - 30, width: 40, height: 30)
                let origin = HUDWindowController.anchoredPosition(size: NSSize(width: 388, height: 145), anchor: .init(buttonFrame: button, screenFrame: screen), suppressionDegraded: false)
                let frame = NSRect(origin: origin, size: NSSize(width: 388, height: 145))
                #expect(frame.minX >= screen.minX && frame.maxX <= screen.maxX)
                #expect(frame.maxY - 40 == button.minY - 10)
                if offset == 600 { #expect(frame.midX == button.midX) }
            }
        }
    }

    @Test("popup and HUD each retain native highlight until both are closed")
    func highlightOwnership() {
        var last = false
        let anchor = HUDMenuBarAnchor(highlightWriter: { last = $0 })
        anchor.setHUDVisible(true)
        anchor.setPopupVisible(true)
        anchor.setHUDVisible(false)
        #expect(last)
        anchor.setPopupVisible(false)
        #expect(!last)
        anchor.setHUDVisible(true)
        anchor.setPopupVisible(false)
        #expect(last)
        anchor.setHUDVisible(false)
        #expect(!last)
    }

    @Test("a stale fade cannot clear the highlight of a newly shown HUD")
    func highlightSurvivesReshow() async throws {
        var last = false
        let anchor = HUDMenuBarAnchor(highlightWriter: { last = $0 })
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService(), menuBarAnchor: anchor)
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.fullscreenProvider = { false }
        hud.observesOutsideClicks = false
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "Placement")
        hud.hide()
        #expect(!last)
        #expect(hud.panel?.isVisible == true, "the native highlight clears while the HUD is still fading")
        hud.show(sliderFraction: 0.6, mute: false, deviceName: "Placement")
        try await Task.sleep(for: .milliseconds(650))
        #expect(last && hud.panel?.isVisible == true)
        hud.hide()
        try await Task.sleep(for: .milliseconds(650))
        #expect(!last && hud.panel?.isVisible == false)
    }
}
