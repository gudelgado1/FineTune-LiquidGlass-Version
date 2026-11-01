//
//  FluidMenuBarExtraStatusItem.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-17.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// An individual element displayed in the system menu bar that displays a window
/// when triggered.
final class FluidMenuBarExtraStatusItem: NSObject, NSWindowDelegate {
    let window: NSWindow
    var menu: NSMenu?
    @objc private let statusItem: NSStatusItem
    weak var hudAnchor: HUDMenuBarAnchor? {
        didSet {
            guard oldValue !== hudAnchor else { return }
            oldValue?.onPopupRequested = nil
            oldValue?.onPopupEnded = nil
            oldValue?.setPopupVisible(false)
            oldValue?.bind(to: nil)
            hudAnchor?.onPopupRequested = { [weak self] in self?.presentPopupWindow() }
            hudAnchor?.onPopupEnded = { [weak self] animated in self?.dismissWindow(animated: animated) }
            hudAnchor?.bind(to: statusItem)
            hudAnchor?.setPopupVisible(window.isVisible && !popupIsDismissing)
        }
    }
    private var statusItemVisibilityObservation: NSKeyValueObservation? = nil

    private var localEventMonitor: EventMonitor?
    private var globalEventMonitor: EventMonitor?
    private var popupDismissalGeneration = 0
    private var popupIsDismissing = false
    private var postedLegacyMenuTracking = false

    var alignment: PopUpAlignment
    var screenClippingBehaviour: ScreenClippingBehaviour {
        didSet {
            setWindowFrame(animate: true)
        }
    }

    @Binding private var isInserted: Bool

    enum Image {
        case named(String)
        case systemNamed(String)
        case direct(NSImage)
        case none

        func asNSImage(accessibilityDescription: String) -> NSImage? {
            switch self {
            case .named(let name):
                return NSImage(named: name)
            case .systemNamed(let name):
                return NSImage(systemSymbolName: name,
                               accessibilityDescription: accessibilityDescription)
            case .direct(let image):
                return image
            case .none:
                return nil
            }
        }
    }

    init<Content: View>(title: String,
                        image: Image = .none,
                        isInserted foo: Binding<Bool> = .constant(true),
                        window: FluidMenuBarExtraWindow<Content>,
                        menu: NSMenu? = nil,
                        alignment: PopUpAlignment = .left,
                        screenClippingBehaviour: ScreenClippingBehaviour = .reverseAlignment) {
        self._isInserted = foo
        self.window = window
        self.menu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = foo.wrappedValue
        statusItem.button?.setAccessibilityTitle(title)

        if let image = image.asNSImage(accessibilityDescription: title) {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = title
        }

        self.alignment = alignment
        self.screenClippingBehaviour = screenClippingBehaviour
        
        super.init()

        assert(nil == window.statusItem)
        window.statusItem = self

        statusItemVisibilityObservation = observe(\.statusItem.isVisible, options: .new) {
            [weak self] _, change in
            guard let newValue = change.newValue else { return }
            self?.isInserted = newValue
        }

        localEventMonitor = LocalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleStatusItemMouseDown(event)
        }

        globalEventMonitor = GlobalEventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let window = self?.window, window.isKeyWindow {
                // Resign key window status if a external non-activating event is triggered,
                // such as other system status bar menus.
                window.resignKey()
            }
            // An open popover holds key, so the popup never receives its own resign.
            else if let self, self.window.childWindows?.contains(where: \.isKeyWindow) == true {
                self.dismissWindow()
            }
        }

        window.delegate = self
        localEventMonitor?.start()
    }

    deinit {
        statusItemVisibilityObservation?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Shared by the actual local event monitor and the event-chain regression.
    func handleStatusItemMouseDown(_ event: NSEvent) -> NSEvent? {
        if let button = self.statusItem.button,
           event.window == button.window
        {
            // Command-drag remains owned by the menu bar.
            if event.type == .leftMouseDown && event.modifierFlags.contains(.command) { return event }
            let contextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            if contextClick, let menu = self.menu {
                menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY + 5), in: button)
                return nil
            }
            if !contextClick, self.hudAnchor?.handlesNativeInteraction == true {
                if self.hudAnchor?.canPromoteHUD == true {
                    // Promote the already-expanded HUD session instead of
                    // letting the same click toggle that session closed.
                    self.hudAnchor?.requestPopupFromStatusItemClick()
                    return nil
                }
                // The public27 delegate owns ordinary left-click activation.
                // Do not run the old mouse toggle as well.
                return event
            }
            // Older systems and right/control-click without a context menu
            // preserve the existing toggle behavior.
            self.didPressStatusBarButton(button)
            return nil
        }

        return event
    }

    private func didPressStatusBarButton(_ sender: NSStatusBarButton) {
        if window.isVisible && !popupIsDismissing {
            dismissWindow()
        } else if let hudAnchor {
            hudAnchor.requestPopupPresentation()
        } else {
            presentPopupWindow()
        }
    }

    private func presentPopupWindow() {
        guard !window.isVisible || popupIsDismissing else { return }
        popupDismissalGeneration += 1
        popupIsDismissing = false
        let fadeIn = !window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A previous fade must not order out a newly reopened popup.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = fadeIn ? 0 : 1
        }
        setWindowFrame()
        if hudAnchor?.handlesNativeInteraction != true {
            DistributedNotificationCenter.default().post(name: .beginMenuTracking, object: nil)
            postedLegacyMenuTracking = true
        }
        window.makeKeyAndOrderFront(nil)
        hudAnchor?.setPopupVisible(true)
        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    var isVisible: Bool {
        get {
            statusItem.isVisible
        }
        set {
            statusItem.isVisible = newValue
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        globalEventMonitor?.start()
        setPopupHighlightOwnership(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A popover opened from the popup takes key; keep the popup behind it.
        if NSApp.isActive, window.childWindows?.contains(where: \.isVisible) == true { return }
        globalEventMonitor?.stop()
        dismissWindow()
    }
    
    func showWindow() {
        guard !window.isVisible || popupIsDismissing else { return }
        if let hudAnchor { hudAnchor.requestPopupPresentation() }
        else { presentPopupWindow() }
    }

    func dismissWindow(animated: Bool = true) {
        // Release this owner before its fade; a HUD owner can retain the session.
        setPopupHighlightOwnership(false)
        guard window.isVisible, !popupIsDismissing else { return }
        popupIsDismissing = true
        popupDismissalGeneration += 1
        let generation = popupDismissalGeneration
        if postedLegacyMenuTracking {
            DistributedNotificationCenter.default().post(name: .endMenuTracking, object: nil)
            postedLegacyMenuTracking = false
        }
        let finish: () -> Void = { [weak self] in
            guard let self, self.popupDismissalGeneration == generation else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.popupIsDismissing = false
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    private func setPopupHighlightOwnership(_ visible: Bool) {
        if let hudAnchor { hudAnchor.setPopupVisible(visible) }
        else { statusItem.button?.highlight(visible) }
    }

    func setWindowFrame(size: CGSize? = nil,
                        animate: Bool = false) {
        guard let statusItemWindow = statusItem.button?.window else {
            // If we don't know where the status item is, just place the window in the center.
            if let size {
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true, animate: false)
            }

            window.center()
            return
        }

        let statusItemFrame = statusItemWindow.frame
        var newFrame = CGRect(origin: statusItemFrame.origin, size: size ?? window.frame.size)

        newFrame.origin.y -= newFrame.height

        switch alignment {
        case .left:
            // Note: Offset by window border size to align with highlighted button.
            newFrame.origin.x -= Metrics.windowBorderSize
        case .centre:
            newFrame.origin.x += (statusItemFrame.width / 2) - (newFrame.width / 2)
        case .right:
            // Note: Offset by window border size to align with highlighted button.
            newFrame.origin.x += statusItemFrame.width - newFrame.width + Metrics.windowBorderSize
        }

        if let screen = statusItemWindow.screen {
            if newFrame.maxX > screen.visibleFrame.maxX {
                switch (alignment, screenClippingBehaviour) {
                case (.left, .reverseAlignment):
                    newFrame.origin.x = statusItemFrame.maxX - newFrame.width + Metrics.windowBorderSize
                default:
                    newFrame.origin.x = screen.visibleFrame.maxX - newFrame.width - Metrics.windowBorderSize
                }
            }

            if newFrame.minX < screen.visibleFrame.minX {
                switch (alignment, screenClippingBehaviour) {
                case (.right, .reverseAlignment):
                    newFrame.origin.x = statusItemFrame.minX - Metrics.windowBorderSize

                    if newFrame.maxX > screen.visibleFrame.maxX {
                        fallthrough
                    }
                default:
                    newFrame.origin.x = screen.visibleFrame.minX + Metrics.windowBorderSize
                }
            }
        }

        guard newFrame != window.frame else {
            return
        }

        PopupFrameAnimation.apply(newFrame, to: window, animated: animate)
    }
}

private extension Notification.Name {
    static let beginMenuTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
    static let endMenuTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")
}

private enum Metrics {
    static let windowBorderSize: CGFloat = 2
}
