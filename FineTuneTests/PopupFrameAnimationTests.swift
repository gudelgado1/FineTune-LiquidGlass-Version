import AppKit
import Testing
@testable import FineTune

@Suite("Popup frame animation responsiveness", .serialized)
@MainActor struct PopupFrameAnimationTests {
    private final class OffscreenPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.30 }
    }

    private func panel() -> OffscreenPanel {
        let frames = NSScreen.screens.map(\.frame)
        let x = (frames.map(\.minX).min() ?? 0) - 10000
        let y = (frames.map(\.minY).min() ?? 0) - 10000
        let panel = OffscreenPanel(contentRect: NSRect(x: x, y: y, width: 400, height: 300),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        precondition(frames.allSatisfy { !$0.intersects(panel.frame) })
        panel.orderBack(nil)
        precondition(frames.allSatisfy { !$0.intersects(panel.frame) })
        precondition(!panel.isKeyWindow && !panel.isMainWindow)
        return panel
    }

    @Test("an animated resize yields instead of occupying the UI thread for its duration")
    func yieldsDuringResize() async throws {
        let window = panel()
        defer { window.orderOut(nil); window.close() }
        var target = window.frame
        target.origin.y += 150
        target.size.height = 150
        let start = ContinuousClock.now
        PopupFrameAnimation.apply(target, to: window, animated: true)
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(150), "Frame update held the UI thread for \(elapsed)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.frame == target)
        #expect(!window.isKeyWindow)
    }

    @Test("a second target supersedes an in-flight resize")
    func latestTargetWins() async throws {
        let window = panel()
        defer { window.orderOut(nil); window.close() }
        var first = window.frame
        first.size.height = 180
        var second = first
        second.size.height = 260
        PopupFrameAnimation.apply(first, to: window, animated: true)
        try await Task.sleep(for: .milliseconds(30))
        PopupFrameAnimation.apply(second, to: window, animated: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.frame == second)
    }

    @Test("an immediate update cancels the previous animated destination")
    func immediateTargetWins() async throws {
        let window = panel()
        defer { window.orderOut(nil); window.close() }
        var first = window.frame
        first.size.height = 180
        var second = first
        second.size.height = 220
        PopupFrameAnimation.apply(first, to: window, animated: true)
        PopupFrameAnimation.apply(second, to: window, animated: false)
        #expect(window.frame == second)
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.frame == second)
    }
}
