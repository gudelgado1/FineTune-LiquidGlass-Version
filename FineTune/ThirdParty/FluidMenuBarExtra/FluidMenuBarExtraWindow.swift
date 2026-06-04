//
//  FluidMenuBarExtraWindow.swift
//  FluidMenuBarExtra
//
//  Created by Lukas Romsicki on 2022-12-16.
//  Copyright © 2022 Lukas Romsicki.
//

import AppKit
import SwiftUI

/// A custom window configured to behave as closely to an `NSMenu` as possible.
///
/// `FluidMenuBarExtraWindow` listens for changes to the size of its content and
/// automatically adjusts its frame to match.
final class FluidMenuBarExtraWindow<Content: View>: NSPanel {
    private let content: () -> Content
    weak var statusItem: FluidMenuBarExtraStatusItem? = nil

    private var rootView: some View {
        content()
            .modifier(RootViewModifier(windowTitle: title))
            .onSizeUpdate { [weak self] size in
                self?.contentSizeDidUpdate(to: size)
            }
    }

    private lazy var hostingView: NSHostingView<some View> = {
        let view = NSHostingView(rootView: rootView)
        // Disable NSHostingView's default automatic sizing behavior.
        view.sizingOptions = []
        view.isVerticalContentSizeConstraintActive = false
        view.isHorizontalContentSizeConstraintActive = false
        // Layer-backed so we can set a clear background — same approach as the
        // custom Settings panel in FineTuneApp. Without this the hosting view
        // renders with an opaque white surface and blocks the Liquid Glass effect.
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        return view
    }()

    init(title: String,
         animation: NSWindow.AnimationBehavior = .none,
         content: @escaping () -> Content) {
        self.content = content

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = title

        isMovable = false
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        // Critical: without a clear window background the panel falls back to the
        // opaque windowBackgroundColor even when isOpaque = false, which blocks
        // any Liquid Glass effect applied by the SwiftUI content.
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        animationBehavior = animation
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Set the hosting view as the direct contentView (no NSVisualEffectView
        // in between). The transparent layer lets SwiftUI's .glassEffect() on
        // macOS 26 — or NSVisualEffectView inside the SwiftUI tree on earlier
        // releases — sample straight through to the desktop content behind the
        // window, exactly like the custom Settings panel.
        contentView = hostingView
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        setContentSize(hostingView.intrinsicContentSize)
    }

    /// Explicit deinit annotated with `@_optimize(none)` to side-step a
    /// Swift 6.3 SIL EarlyPerfInliner crash that fires when the optimizer
    /// tries to inline this generic class's implicit deinit at `-O`.
    /// The body intentionally has a single observable side-effect so the
    /// compiler doesn't decide to elide it again.
    /// Reproduces on both arm64 and x86_64 macOS Release builds.
    @_optimize(none)
    deinit {
        statusItem = nil
    }

    private func contentSizeDidUpdate(to size: CGSize) {
        guard frame.size != size else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.setWindowFrame(size: size, animate: true)
        }
    }
}
