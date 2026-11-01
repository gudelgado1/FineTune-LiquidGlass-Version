import AppKit
import SwiftUI
import Testing
@testable import FineTune

/// Regression for the "more Layout Window passes than there are views" crash: a
/// frame change during `layoutIfNeeded` re-marks the window while AppKit is
/// counting passes, so it must wait until the layout pass has finished.
@Suite("Popup window layout guard", .serialized)
@MainActor struct PopupWindowLayoutGuardTests {
    @Test("a frame change during a layout pass is applied after the pass")
    func frameChangeWaitsForLayoutPass() async {
        let window = FluidMenuBarExtraWindow(title: "Layout guard") { Color.clear.frame(width: 100, height: 100) }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }
        let start = window.frame
        var requested = start
        requested.size.height += 40
        var heightInsideLayout: CGFloat?
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidLayoutNotification"), object: window, queue: nil
        ) { [requested] _ in
            MainActor.assumeIsolated {
                guard heightInsideLayout == nil else { return }
                window.setFrame(requested, display: false)
                heightInsideLayout = window.frame.height
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        window.contentView?.needsLayout = true
        window.layoutIfNeeded()

        #expect(heightInsideLayout == start.height)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(window.frame.height == requested.height)
    }
}
