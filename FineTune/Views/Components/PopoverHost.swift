// FineTune/Views/Components/PopoverHost.swift
import SwiftUI
import AppKit

/// Borderless panels return `canBecomeKey == false` by default,
/// which prevents text fields from receiving focus/keyboard input.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Entrance animation

/// Transparent margin added around the dropdown content so the spring
/// overshoot can render without being clipped by the panel boundary.
/// Must match the `.padding` applied inside `PopoverEntrance`.
private let popoverOverflowInset: CGFloat = 12

/// Shared state between showPanel and updateContent so the zoom animation
/// plays only once — on initial show — and not on every content refresh.
private final class PopoverAnimController {
    var appeared = false
    /// SwiftUI anchor for the scale: top-trailing when opening below the
    /// trigger, bottom-trailing when opening above.
    let anchor: UnitPoint

    init(anchor: UnitPoint) {
        self.anchor = anchor
    }
}

/// Wraps the dropdown content with a zoom-from-corner entrance animation.
/// Initialises `appeared` from the controller so that content refreshes via
/// `updateContent` start at scale 1.0 and skip the animation entirely.
private struct PopoverEntrance<Content: View>: View {
    let controller: PopoverAnimController
    @ViewBuilder let content: () -> Content
    @State private var appeared: Bool

    init(controller: PopoverAnimController, @ViewBuilder content: @escaping () -> Content) {
        self.controller = controller
        self.content = content
        // If the controller already fired (updateContent path), start at 1.0
        // so no animation plays on the refreshed view.
        self._appeared = State(initialValue: controller.appeared)
    }

    var body: some View {
        content()
            .scaleEffect(appeared ? 1.0 : 0.05, anchor: controller.anchor)
            .animation(
                .spring(response: 0.30, dampingFraction: 0.74),
                value: appeared
            )
            // Transparent buffer so the spring overshoot renders inside the
            // panel frame instead of being clipped at the boundary.
            .padding(popoverOverflowInset)
            .onAppear {
                guard !controller.appeared else { return }
                controller.appeared = true
                appeared = true   // triggers the spring from 0.05 → 1.0
            }
    }
}

// MARK: - PopoverHost

/// A dropdown panel without arrow using NSPanel
/// Uses child window relationship for proper dismissal behavior
struct PopoverHost<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// SwiftUI color-scheme override applied to the hosted root view. `nil`
    /// means "follow environment" (System mode).
    let preferredColorScheme: ColorScheme?
    /// AppKit appearance applied to the panel itself. `nil` inherits from the
    /// application's effective appearance (System mode).
    let nsAppearance: NSAppearance?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    // Clean up when view is removed from hierarchy (e.g., app row disappears)
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismissPanel()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isPresented {
            if context.coordinator.panel == nil {
                context.coordinator.showPanel(
                    from: nsView,
                    content: content,
                    preferredColorScheme: preferredColorScheme,
                    nsAppearance: nsAppearance
                )
            } else {
                // Update content when state changes while panel is open
                context.coordinator.updateContent(
                    content,
                    preferredColorScheme: preferredColorScheme,
                    nsAppearance: nsAppearance
                )
            }
        } else {
            context.coordinator.dismissPanel()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    class Coordinator: NSObject {
        @Binding var isPresented: Bool
        var panel: NSPanel?
        var hostingView: NSHostingView<AnyView>?
        var localEventMonitor: Any?
        var globalEventMonitor: Any?
        var appDeactivateObserver: NSObjectProtocol?
        weak var parentWindow: NSWindow?
        /// Retained so updateContent can pass the same controller (already
        /// marked appeared = true) and avoid replaying the entrance animation.
        fileprivate var animController: PopoverAnimController?

        init(isPresented: Binding<Bool>) {
            self._isPresented = isPresented
        }

        func showPanel<V: View>(
            from parentView: NSView,
            content: () -> V,
            preferredColorScheme: ColorScheme?,
            nsAppearance: NSAppearance?
        ) {
            guard let parentWindow = parentView.window else { return }
            self.parentWindow = parentWindow

            // Create borderless panel that can become key for text field input
            let panel = KeyablePanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .popUpMenu
            panel.hasShadow = true
            panel.collectionBehavior = [.fullScreenAuxiliary]
            // Apply appearance before any drawing so NSVisualEffectView picks
            // it up on first render. `nil` inherits from the application.
            panel.appearance = nsAppearance

            panel.becomesKeyOnlyIfNeeded = false

            // Position relative to trigger with screen-boundary clamping.
            // Right-align the panel to the trigger's right edge so it doesn't
            // overflow the popup's right boundary when the trigger is on the
            // trailing side of a row. Flip above when there's not enough space
            // below.
            let parentFrame = parentView.convert(parentView.bounds, to: nil)
            let screenFrame = parentWindow.convertToScreen(parentFrame)

            let screen = parentWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let visibleFrame = screen.visibleFrame

            // Build content once for size measurement (content is non-escaping
            // so we materialise the View value before any closure capture).
            let builtForSize = content()
            let sizer: NSHostingView<AnyView> = NSHostingView(
                rootView: AnyView(builtForSize.preferredColorScheme(preferredColorScheme))
            )
            let pw = sizer.fittingSize.width
            let ph = sizer.fittingSize.height

            // X: right-align panel to trigger right edge, clamped within screen.
            var panelX = screenFrame.maxX - pw
            panelX = max(panelX, visibleFrame.minX)
            panelX = min(panelX, visibleFrame.maxX - pw)

            // Y: prefer below trigger; flip above when space is tight.
            let yBelow = screenFrame.minY - ph - 4
            let yAbove = screenFrame.maxY + 4
            let panelY = yBelow >= visibleFrame.minY ? yBelow : yAbove
            let opensAbove = panelY == yAbove

            // Entrance animation: zoom from the corner closest to the trigger icon.
            // .topTrailing  = below the trigger (panel opens downward)
            // .bottomTrailing = above the trigger (panel opens upward)
            let animAnchor: UnitPoint = opensAbove ? .bottomTrailing : .topTrailing
            let ctrl = PopoverAnimController(anchor: animAnchor)
            self.animController = ctrl

            // Build content a second time for the actual hosting view
            // (separate call so the sizer and the live view are independent).
            let builtForHosting = content()
            let hosting: NSHostingView<AnyView> = NSHostingView(
                rootView: AnyView(
                    PopoverEntrance(controller: ctrl) {
                        builtForHosting.preferredColorScheme(preferredColorScheme)
                    }
                )
            )
            hosting.frame.size = hosting.fittingSize
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            self.hostingView = hosting

            // Offset origin by the overflow inset so the visible content is
            // positioned at panelX/panelY while the transparent margin extends
            // beyond, giving room for the spring overshoot to render cleanly.
            panel.setFrameOrigin(NSPoint(x: panelX - popoverOverflowInset,
                                         y: panelY - popoverOverflowInset))

            // Add as child window - links to parent's event stream
            parentWindow.addChildWindow(panel, ordered: .above)

            // Make panel key so text fields can receive focus.
            // Temporarily suppress the parent's delegate to prevent
            // FluidMenuBarExtra from dismissing the popup on resign-key.
            let savedDelegate = parentWindow.delegate
            parentWindow.delegate = nil
            panel.makeKeyAndOrderFront(nil)
            parentWindow.delegate = savedDelegate

            self.panel = panel

            // Get trigger button frame in screen coordinates
            let triggerFrame = parentWindow.convertToScreen(parentView.convert(parentView.bounds, to: nil))

            // Local monitor: clicks within our app (outside panel AND outside trigger)
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.panel else { return event }
                let mouseLocation = NSEvent.mouseLocation
                let isInPanel = panel.frame.contains(mouseLocation)
                let isInTrigger = triggerFrame.contains(mouseLocation)
                // Only dismiss if click is outside both panel and trigger button
                // Let the trigger button handle its own clicks (toggle behavior)
                if !isInPanel && !isInTrigger {
                    self.dismissPanel()
                }
                return event  // Don't consume
            }

            // Global monitor: clicks in OTHER apps (dismisses panel + parent)
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissPanel(reKeyParent: false)
            }

            // Dismiss when app loses focus (Command-Tab, click other app, quit, etc.)
            appDeactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.dismissPanel(reKeyParent: false)
            }
        }

        func updateContent<V: View>(
            _ content: () -> V,
            preferredColorScheme: ColorScheme?,
            nsAppearance: NSAppearance?
        ) {
            guard let hostingView = hostingView, let ctrl = animController else { return }
            // Re-apply appearance in case the preference changed while the
            // panel is open. Setting to the same value is a no-op.
            panel?.appearance = nsAppearance
            // Materialise the view value before the escaping @ViewBuilder closure.
            let built = content()
            // Pass the same controller (appeared = true) so the entrance
            // animation doesn't replay on content refreshes.
            hostingView.rootView = AnyView(
                PopoverEntrance(controller: ctrl) {
                    built.preferredColorScheme(preferredColorScheme)
                }
            )
            // Resize panel if content size changed
            let newSize = hostingView.fittingSize
            if let panel = panel, panel.frame.size != newSize {
                panel.setContentSize(newSize)
            }
        }

        /// - Parameter reKeyParent: When `true`, restores key status to the parent
        ///   window (normal dismiss, e.g. user selected a profile). When `false`,
        ///   re-keys then resigns the parent so FluidMenuBarExtra dismisses it too
        ///   (external click or app deactivation).
        func dismissPanel(reKeyParent: Bool = true) {
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
                localEventMonitor = nil
            }
            if let monitor = globalEventMonitor {
                NSEvent.removeMonitor(monitor)
                globalEventMonitor = nil
            }
            if let observer = appDeactivateObserver {
                NotificationCenter.default.removeObserver(observer)
                appDeactivateObserver = nil
            }
            // Remove child window relationship
            if let panel = panel, let parent = panel.parent {
                parent.removeChildWindow(panel)
            }
            panel?.orderOut(nil)
            panel = nil
            hostingView = nil
            animController = nil

            if let parentWindow = parentWindow {
                if reKeyParent {
                    // Restore key status — parent popup stays visible
                    parentWindow.makeKey()
                } else {
                    // External dismiss — re-key then resign so FluidMenuBarExtra
                    // runs its standard dismiss animation
                    parentWindow.makeKey()
                    parentWindow.resignKey()
                }
            }
            parentWindow = nil

            if isPresented {
                isPresented = false
            }
        }

        deinit {
            if let monitor = localEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = globalEventMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let observer = appDeactivateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
