import AppKit
import QuartzCore

/// One frame-animation entry point for the popup's geometry owner.
enum PopupFrameAnimation {
    static func apply(_ frame: NSRect, to window: NSWindow, animated: Bool) {
        let shouldAnimate = animated && window.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // setFrame(..., animate: true) occupies the UI thread until the resize
        // finishes, delaying native control feedback. The animator proxy yields
        // immediately and retargets the same frame property on rapid changes.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? window.animationResizeTime(frame) : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}
