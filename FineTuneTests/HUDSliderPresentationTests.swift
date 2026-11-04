import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Native HUD pointer presentation", .serialized)
@MainActor struct HUDSliderPresentationTests {
    private func bitmap(interactive: Bool, level: Double = 0.5) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: HUDVolumeSlider(level: level, interactive: interactive, dragging: false).frame(width: 214, height: 28))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }
    @Test("hover closes the gaps and reveals a14pt thumb without changing the envelope")
    func continuousOnHover() throws {
        let rest = try bitmap(interactive: false), active = try bitmap(interactive: true)
        #expect(rest.pixelsWide == active.pixelsWide && rest.pixelsHigh == active.pixelsHigh)
        func alpha(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat { image.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        // First segment gap, and the top of the thumb at50%.
        #expect(alpha(rest, 25, 28) < 0.5)
        #expect(alpha(active, 25, 28) > 0.9)
        #expect(alpha(rest, 214, 17) < 0.1)
        #expect(alpha(active, 214, 17) > 0.9)
    }
    @Test("the interactive thumb follows both volume limits")
    func thumbAtEndpoints() throws {
        for level in [0.0, 1.0] {
            let image = try bitmap(interactive: true, level: level)
            let x = level == 0 ? 2 : image.pixelsWide - 3
            #expect((image.colorAt(x: x, y: 17)?.alphaComponent ?? 0) > 0.9)
        }
    }
    @Test("drag holds across pointer exit and resumes the timer after release")
    func dragHold() async throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.observesOutsideClicks = false; hud.fullscreenProvider = { false }
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.hideDelayOverride = .milliseconds(20)
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "QA")
        hud.handleDragChange(true)
        hud.handleHoverChange(false)
        hud.updatePointerInteractivity(at: .zero)
        try await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == true && hud.panel?.ignoresMouseEvents == false)
        hud.handleDragChange(false)
        try await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == false)
    }
}

extension HUDSliderPresentationTests {
    @Test("drag release resolves hover against the capsule including its rounded ends")
    func releasePosition() {
        #expect(CapsuleVolumeHUD.containsDragEnd(CGPoint(x: 107, y: 14)))
        #expect(CapsuleVolumeHUD.containsDragEnd(CGPoint(x: -40, y: 14)))
        #expect(!CapsuleVolumeHUD.containsDragEnd(CGPoint(x: -70, y: 14)))
        #expect(!CapsuleVolumeHUD.containsDragEnd(CGPoint(x: 107, y: 100)))
        #expect(!CapsuleVolumeHUD.containsDragEnd(CGPoint(x: -62, y: -18)))
    }
}

extension HUDSliderPresentationTests {
    @Test("endpoint feedback fires on arrivals but not middle steps or repeated clamping")
    func endpointArrivals() {
        var feedback = HUDEndpointFeedback()
        feedback.update(level: 0.5, muted: false, reduceMotion: false)
        feedback.update(level: 0.9, muted: false, reduceMotion: false)
        #expect(feedback.generation == 0)
        feedback.update(level: 1, muted: false, reduceMotion: false)
        #expect(feedback.generation == 1)
        feedback.update(level: 1, muted: false, reduceMotion: false)
        #expect(feedback.generation == 1)
        feedback.update(level: 0, muted: false, reduceMotion: false)
        #expect(feedback.generation == 2)
        feedback.update(level: 0, muted: false, reduceMotion: false)
        #expect(feedback.generation == 2)
        feedback.update(level: 0.5, muted: false, reduceMotion: false)
        feedback.update(level: 0, muted: false, reduceMotion: false)
        #expect(feedback.generation == 3)
    }

    @Test("Reduce Motion and muted maximum do not trigger the endpoint bounce")
    func endpointSuppression() {
        var feedback = HUDEndpointFeedback()
        feedback.update(level: 1, muted: true, reduceMotion: false)
        feedback.update(level: 0, muted: true, reduceMotion: true)
        #expect(feedback.generation == 0)
        feedback.update(level: 0.5, muted: false, reduceMotion: false)
        feedback.update(level: 1, muted: false, reduceMotion: false)
        #expect(feedback.generation == 1)
    }

    @Test("switching to a per-app notification releases an old system-slider drag hold")
    func dragDoesNotPinPerAppHUD() async throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        hud.observesOutsideClicks = false; hud.fullscreenProvider = { false }
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        hud.hideDelayOverride = .milliseconds(20)
        defer { hud.shutdown() }
        hud.show(sliderFraction: 0.5, mute: false, deviceName: "QA")
        hud.handleDragChange(true)
        hud.showPerAppNotControlledHUD(displayName: "QA", bundleID: nil, icon: nil)
        try await Task.sleep(for: .milliseconds(650))
        #expect(hud.panel?.isVisible == false)
    }
}
