// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// A volume notification must never replace the user's key/main window.
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Placement already accounts for the menu bar. AppKit must not move the
    // transparent effect margin below it and add a second menu-bar-height inset.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Recovered OSDPanel appearance selectors. They affect material activity,
    // never keyboard focus; canBecomeKey/canBecomeMain stay false.
    @objc(_hasActiveAppearance) dynamic func hudHasActiveAppearance() -> Bool { true }
    @objc(_hasKeyAppearance) dynamic func hudHasKeyAppearance() -> Bool { true }
    @objc(hasKeyAppearance) dynamic func hudKeyAppearance() -> Bool { true }
}

/// Mouse controls still respond on the first click while another app has focus.
private final class HUDHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

/// Reveal the close control near the top-left corner, like a notification.
/// The hover region stays in place while the button fades in and out.
private struct DismissibleHUD<Content: View>: View {
    let content: Content
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCloseHovered = false

    var body: some View {
        content
            .padding(8)
            .overlay(alignment: .topLeading) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Dismiss volume notification")
                .accessibilityLabel("Dismiss volume notification")
                .accessibilityIdentifier("hud.dismiss")
                .opacity(isCloseHovered ? 1 : 0)
                .allowsHitTesting(isCloseHovered)
                .accessibilityHidden(!isCloseHovered)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isCloseHovered)
                // Track a generous corner region even while the button is hidden.
                // Fading this wrapper would also make the hover target disappear.
                .frame(width: 36, height: 36, alignment: .topLeading)
                .contentShape(Rectangle())
                .onHover { isCloseHovered = $0 }
            }
            .onHover { hovering in
                if !hovering { isCloseHovered = false }
                onHover(hovering)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Dismiss volume notification")) {
                onDismiss()
            }
    }
}

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let popupVisibility: PopupVisibilityService
    let menuBarAnchor: HUDMenuBarAnchor
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "HUDWindowController")

    private(set) var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var isHovering = false
    private var isDragging = false
    private var ignoresInitialHover = false
    private var mouseAtPresentation = NSPoint.zero
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var isSystemCapsule = false
    private let motionState = HUDMotionState()
    private var styleAtLastShow: HUDStyle = .tahoe
    /// Invalidates in-flight fade-out completions. A `show()` that arrives during
    /// the ~110 ms fade-out bumps this; the stale fade's completion handler then
    /// must NOT `orderOut` the panel it just re-presented (the panel would vanish
    /// mid-interaction and ignore further volume keys until the next show).
    private var hideAnimationGeneration = 0

    /// Slider fraction in [0, 1]. The wiring site converts to gain using the current device's tier.
    var volumeWriter: ((Double) -> Void)?

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var observesOutsideClicks = true
    var mousePositionProvider: () -> NSPoint = { NSEvent.mouseLocation }
    var fullscreenProvider: () -> Bool = HUDWindowController.foregroundAppIsFullscreen
    /// Optional virtual screen for tests/lab. Production uses NSScreen geometry.
    var frameProvider: (() -> NSRect?)?
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService,
        menuBarAnchor: HUDMenuBarAnchor? = nil
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        self.menuBarAnchor = menuBarAnchor ?? HUDMenuBarAnchor()
        self.menuBarAnchor.geometryDidChange = { [weak self] in self?.repositionForMenuBarAnchor() }
        self.menuBarAnchor.onHUDSessionEnded = { [weak self] in self?.hide() }
        self.menuBarAnchor.hudPresentationIsVisible = { [weak self] in
            self?.isSystemCapsule == true && self?.panel?.isVisible == true
        }
        subscribeToSettingsChangedNotification()
    }

    deinit {
        if let observer = settingsChangedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        let monitors = [localDismissMonitor, globalDismissMonitor, localPointerMonitor, globalPointerMonitor].compactMap { $0 }
        DispatchQueue.main.async { monitors.forEach(NSEvent.removeMonitor) }
        // `deinit` is nonisolated; `shutdown()` is preferred for synchronous teardown.
        if let panel {
            DispatchQueue.main.async { panel.orderOut(nil) }
        }
        let anchor = menuBarAnchor
        DispatchQueue.main.async { anchor.setHUDVisible(false) }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        dismiss()
    }

    /// Explicit dismissal is immediate so the next click can reach other windows.
    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        hideAnimationGeneration += 1
        isHovering = false
        isDragging = false
        ignoresInitialHover = false
        isSystemCapsule = false
        removePointerMonitors()
        removeDismissMonitors()
        panel?.orderOut(nil)
        menuBarAnchor.setHUDVisible(false)
    }

    // MARK: - Style-indexed hide delay

    func hideDelay(for style: HUDStyle) -> Duration {
        if let override = hideDelayOverride { return override }
        return .milliseconds(1100)
    }

    // MARK: - Public API

    /// Displays the HUD. Skipped when the foreground app is fullscreen or the popup is visible.
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        showCallCount += 1
        showDidUpdatePanel = false

        guard !fullscreenProvider() else {
            logger.debug("Skipping HUD show: foreground app is fullscreen")
            return
        }
        guard !popupVisibility.isVisible else {
            logger.debug("Skipping HUD show: popup is visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        isSystemCapsule = style == .tahoe
        removePointerMonitors()
        let appearance = settingsManager.appSettings.appearance
        if styleAtLastShow != style || panel?.isVisible != true { isHovering = false; isDragging = false }
        styleAtLastShow = style
        let panel = ensurePanel()
        let newPresentation = !panel.isVisible
        let reducedMotion = reduceMotionEnabled()
        if isSystemCapsule && newPresentation {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { motionState.progress = reducedMotion ? 1 : 0 }
        }
        // Follow the app theme (matches the popup), refreshed each show. System
        // mode resolves to the concrete effective appearance so the panel never
        // renders stale.
        panel.appearance = appearance.nsAppearance ?? NSApp.effectiveAppearance

        // Classic is click-through; Tahoe takes mouse events for drag + hover.
        panel.ignoresMouseEvents = (style == .classic)

        let scheme = appearance.swiftUIColorScheme
        let displayFraction = Float(max(0, min(1, sliderFraction)))
        let root: AnyView
        let size: NSSize
        switch style {
        case .tahoe:
            root = AnyView(
                CapsuleVolumeHUD(
                        sliderFraction: displayFraction,
                        mute: mute,
                        deviceName: deviceName,
                        onSliderChange: { [weak self] newFraction in
                            self?.volumeWriter?(Double(newFraction))
                        },
                        onHoverChange: { [weak self] in self?.handleHoverChange($0) },
                        onDragChange: { [weak self] in self?.handleDragChange($0) }
                )
                .padding(CapsuleVolumeHUD.effectMargin)
                .accessibilityAction(named: Text("Dismiss volume notification")) { [weak self] in self?.dismiss() }
                .environment(\.controlActiveState, .active)
                .preferredColorScheme(scheme)
            )
            size = NSSize(width: CapsuleVolumeHUD.capsuleSize.width + 80,
                          height: CapsuleVolumeHUD.capsuleSize.height + 80)
        case .classic:
            root = AnyView(
                ClassicStyleHUD(sliderFraction: displayFraction, mute: mute)
                    .preferredColorScheme(scheme)
            )
            size = NSSize(width: 200, height: 200)
        }

        let presentedRoot = isSystemCapsule
            ? AnyView(HUDMotionRoot(content: root, state: motionState, reduceMotion: reducedMotion))
            : root
        if let existing = hostingView {
            existing.rootView = presentedRoot
        } else {
            let hv = HUDHostingView(rootView: presentedRoot)
            hv.frame = NSRect(origin: .zero, size: size)
            // Keep any layer backing transparent so the compositor can sample
            // windows behind the HUD. NSHostingView itself is already nonopaque.
            hv.wantsLayer = true
            hv.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: style, size: size))
        updateMotionAnchor(for: panel)
        // Begin the native status-item presentation before the HUD enters.
        menuBarAnchor.setHUDVisible(isSystemCapsule)
        if !panel.isVisible && isSystemCapsule {
            mouseAtPresentation = mousePositionProvider()
            ignoresInitialHover = panel.frame.insetBy(dx: 40, dy: 40).contains(mouseAtPresentation)
        }

        if panel.isVisible {
            // Possibly mid fade-out: neutralize it or the panel gets ordered out
            // (and left at alpha ~0) right after this show.
            cancelHideAnimation(for: panel)
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            // Present without moving keyboard focus away from the user's app.
            panel.orderFrontRegardless()
            let duration = reducedMotion ? HUDMotionProfile.reducedFadeDuration : (isSystemCapsule ? HUDMotionProfile.entryDuration : 0.12)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = isSystemCapsule && !reducedMotion
                    ? HUDMotionProfile.timingFunction(appearing: true)
                    : CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        if isSystemCapsule {
            hostingView?.layoutSubtreeIfNeeded()
            let generation = hideAnimationGeneration
            // Let the first graph render the initial scale before targeting rest.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isSystemCapsule, self.panel?.isVisible == true,
                      self.hideAnimationGeneration == generation else { return }
                withAnimation(reducedMotion ? nil : HUDMotionProfile.animation(appearing: true)) {
                    self.motionState.progress = 1
                }
            }
        }

        // Strip any opaque window backing now that the panel is on screen, so the
        // `.clear` glass shows the desktop instead of a black layer.
        clearPanelBacking(panel)

        startDismissMonitors()
        if isSystemCapsule { startPointerMonitors() }
        scheduleHide(for: style)
        postAccessibilityAnnouncement(panel: panel, sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
    }

    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .volume(sliderFraction: max(0, min(1, sliderFraction)))
        )
    }

    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .mute(isMuted: isMuted)
        )
    }

    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
        let title = displayName?.nilIfEmpty
            ?? bundleID?.nilIfEmpty
            ?? "FineTune isn't controlling this app yet"
        presentPerApp(
            icon: icon,
            title: title,
            content: .notControlled
        )
    }

    /// Hotkey-triggered per-app HUDs bypass the fullscreen guard because the user explicitly invoked them.
    private func presentPerApp(icon: NSImage?, title: String, content: PerAppHUDContent) {
        showCallCount += 1
        showDidUpdatePanel = false

        guard !popupVisibility.isVisible else {
            logger.debug("Skipping per-app HUD: popup is visible")
            return
        }
        isSystemCapsule = false
        isDragging = false
        menuBarAnchor.setHUDVisible(false)
        ignoresInitialHover = false
        removePointerMonitors()

        if styleAtLastShow != .tahoe || panel?.isVisible != true { isHovering = false }
        styleAtLastShow = .tahoe
        let panel = ensurePanel()
        panel.appearance = settingsManager.appSettings.appearance.nsAppearance ?? NSApp.effectiveAppearance
        panel.ignoresMouseEvents = false

        let scheme = settingsManager.appSettings.appearance.swiftUIColorScheme
        let root = AnyView(
            DismissibleHUD(
                content: PerAppHUD(icon: icon, title: title, content: content),
                onDismiss: { [weak self] in self?.dismiss() },
                onHover: { [weak self] in self?.handleHoverChange($0) }
            )
            .environment(\.controlActiveState, .active)
            .preferredColorScheme(scheme)
        )
        let size = NSSize(width: 316, height: 88)

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = HUDHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            // Keep any layer backing transparent for the compositor.
            hv.wantsLayer = true
            hv.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: .tahoe, size: size))

        if panel.isVisible {
            // Possibly mid fade-out: neutralize it or the panel gets ordered out
            // (and left at alpha ~0) right after this show.
            cancelHideAnimation(for: panel)
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            // Present without moving keyboard focus away from the user's app.
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        // Strip any opaque window backing now that the panel is on screen, so the
        // `.clear` glass shows the desktop instead of a black layer.
        clearPanelBacking(panel)

        startDismissMonitors()
        scheduleHide(for: .tahoe)
        postPerAppAccessibilityAnnouncement(panel: panel, title: title, content: content)
    }

    /// Called when the monitor swallows a keypress; used to detect if the native HUD still fired.
    func swallowObserved() {
        lastSwallowedKeyTime = DispatchTime.now()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        removeDismissMonitors()
        isHovering = false
        isDragging = false
        // The reference clears the menu-bar capsule at the start of the fade.
        // Session cancellation is independent of the fading panel's lifetime.
        menuBarAnchor.setHUDVisible(false)
        guard let panel, panel.isVisible else { menuBarAnchor.setHUDVisible(false); return }
        hideAnimationGeneration += 1
        let generation = hideAnimationGeneration
        let reducedMotion = reduceMotionEnabled()
        let duration = reducedMotion ? HUDMotionProfile.reducedFadeDuration : (isSystemCapsule ? HUDMotionProfile.exitDuration : 0.11)
        if isSystemCapsule {
            withAnimation(reducedMotion ? nil : HUDMotionProfile.animation(appearing: false)) {
                motionState.progress = reducedMotion ? 1 : 0
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = isSystemCapsule && !reducedMotion
                ? HUDMotionProfile.timingFunction(appearing: false)
                : CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            // AppKit runs this on the main thread, but the closure isn't typed
            // as main-actor — assume the isolation rather than hopping, so the
            // check and the orderOut stay in the same runloop turn as the fade.
            MainActor.assumeIsolated {
                // A show() during the fade bumps the generation — this fade is
                // stale and must not order out the panel show() just re-presented.
                guard let self, self.hideAnimationGeneration == generation else { return }
                panel.orderOut(nil)
                self.removePointerMonitors()
            }
        })
    }

    /// Cancels any in-flight fade-out so a re-show doesn't get ordered out from
    /// under it: bumps the generation (stale completions become no-ops) and
    /// retargets the alpha animation to 1 immediately (a plain property write
    /// would be overwritten by the still-running animator ticks).
    private func cancelHideAnimation(for panel: NSPanel) {
        hideAnimationGeneration += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            panel.animator().alphaValue = 1.0
        }
    }

    // MARK: - Position Math

    /// Tahoe: top-right. Classic: bottom-center. Under suppression-degraded,
    /// Tahoe shifts left so it doesn't overlap the native top-right HUD.
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        suppressionDegraded: Bool,
        topObstruction: CGFloat = 0
    ) -> NSPoint {
        switch style {
        case .tahoe:
            if suppressionDegraded {
                let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
                let y = visibleFrame.maxY - size.height - max(0, topObstruction + 10 - 40)
                return NSPoint(x: x, y: y)
            } else {
                let x = visibleFrame.maxX - size.width
                let y = visibleFrame.maxY - size.height - max(0, topObstruction + 10 - 40)
                return NSPoint(x: x, y: y)
            }
        case .classic:
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
    }

    private func position(for style: HUDStyle, size: NSSize) -> NSPoint {
        if style == .tahoe, isSystemCapsule, let anchor = menuBarAnchor.geometry {
            return Self.anchoredPosition(size: size, anchor: anchor, suppressionDegraded: mediaKeyStatus.suppressionDegraded)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let override = frameProvider?()
        // Per-app notifications retain their smaller envelope and eight-point
        // inset from the usable screen; only the system capsule needs 40 points.
        if style == .tahoe && !isSystemCapsule {
            let frame = override ?? screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = mediaKeyStatus.suppressionDegraded
                ? frame.minX + frame.width * 0.25 - size.width / 2
                : frame.maxX - size.width - 8
            return NSPoint(x: x, y: frame.maxY - size.height - 8)
        }
        let frame = override ?? (style == .tahoe ? screen?.frame : screen?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.computePosition(
            style: style,
            size: size,
            visibleFrame: frame,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded,
            topObstruction: override == nil ? max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness) : 0
        )
    }

    /// Center the visible capsule under the status button, ten points below it.
    /// The symmetric compositor margin affects the panel origin, not the gap.
    static func anchoredPosition(size: NSSize, anchor: HUDMenuBarAnchor.Geometry, suppressionDegraded: Bool) -> NSPoint {
        let screen = anchor.screenFrame
        let proposedX = suppressionDegraded
            ? screen.minX + screen.width * 0.25 - size.width / 2
            : anchor.buttonFrame.midX - size.width / 2
        let x = min(max(proposedX, screen.minX), max(screen.minX, screen.maxX - size.width))
        return NSPoint(x: x, y: anchor.buttonFrame.minY - 10 - size.height + CapsuleVolumeHUD.effectMargin)
    }

    private func repositionForMenuBarAnchor() {
        guard isSystemCapsule, let panel, panel.isVisible else { return }
        panel.setFrameOrigin(position(for: .tahoe, size: panel.frame.size))
        updateMotionAnchor(for: panel)
        updatePointerInteractivity(at: mousePositionProvider())
    }

    private func updateMotionAnchor(for panel: NSPanel) {
        guard isSystemCapsule else { return }
        let size = panel.frame.size
        let source = menuBarAnchor.geometry?.buttonFrame
        motionState.anchor = UnitPoint(
            x: source.map { ($0.midX - panel.frame.minX) / size.width } ?? 0.5,
            y: source.map { (panel.frame.maxY - $0.minY) / size.height } ?? ((CapsuleVolumeHUD.effectMargin - 10) / size.height)
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Recovered GlassOSD level: immediately below the main menu (24 - 1).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Needed for Tahoe hover/drag on a non-activating panel.
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        // Follow the app theme (matches the popup), refreshed on every show().
        // System mode (nsAppearance nil) resolves to the concrete effective
        // appearance so the panel never renders stale.
        p.appearance = settingsManager.appSettings.appearance.nsAppearance ?? NSApp.effectiveAppearance

        panel = p
        return p
    }

    /// Keep native panel chrome transparent, including after AppKit orders it in.
    /// The material supplies its own edge and ambient effect inside the margin.
    private func clearPanelBacking(_ panel: NSPanel) {
        // Belt-and-suspenders: keep the window's own drop shadow off (it can be
        // re-enabled when the panel is ordered in), so no shadow renders
        // around the HUD on light backdrops.
        panel.hasShadow = false
        panel.invalidateShadow()
        Self.clearBacking(panel.contentView)
        Self.clearBacking(panel.contentView?.superview)
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.hasShadow = false
            panel.invalidateShadow()
            Self.clearBacking(panel.contentView)
            Self.clearBacking(panel.contentView?.superview)
        }
    }

    private static func clearBacking(_ view: NSView?) {
        guard let view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
    }

    private func scheduleHide(for style: HUDStyle) {
        hideTask?.cancel()
        guard !isHovering && !isDragging else { hideTask = nil; return }
        let delay = hideDelay(for: style)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func handleHoverChange(_ hovering: Bool) {
        // Do not pin a newly shown HUD under a stationary cursor. Actual entry
        // or movement can still keep an interactive indicator available.
        if hovering && isSystemCapsule && ignoresInitialHover && mousePositionProvider() == mouseAtPresentation { return }
        ignoresInitialHover = false
        isHovering = hovering
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow)
        }
    }

    func handleDragChange(_ dragging: Bool) {
        isDragging = dragging
        ignoresInitialHover = false
        if dragging {
            hideTask?.cancel()
            hideTask = nil
            panel?.ignoresMouseEvents = false
        } else {
            scheduleHide(for: styleAtLastShow)
        }
    }

    /// The forty-point compositor envelope must not swallow clicks outside the pill.
    func updatePointerInteractivity(at point: NSPoint) {
        guard isSystemCapsule, let panel, panel.isVisible else { return }
        if isDragging { panel.ignoresMouseEvents = false; return }
        panel.ignoresMouseEvents = !panel.frame.insetBy(dx: 40, dy: 40).contains(point)
    }

    private func startPointerMonitors() {
        guard observesOutsideClicks else { return }
        updatePointerInteractivity(at: mousePositionProvider())
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointerInteractivity(at: self?.mousePositionProvider() ?? .zero) }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerInteractivity(at: self?.mousePositionProvider() ?? .zero) }
        }
    }

    private func removePointerMonitors() {
        if let monitor = localPointerMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalPointerMonitor { NSEvent.removeMonitor(monitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
    }

    // Observe outside clicks; never consume or resend the user's mouse event.
    private func startDismissMonitors() {
        guard observesOutsideClicks, localDismissMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleOutsideMouseDown(event) }
            return event
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalMouseDown(event) }
        }
    }

    func handleGlobalMouseDown(_ event: NSEvent) {
        guard isSystemCapsule, panel?.isVisible == true else { dismiss(); return }
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           let geometry = menuBarAnchor.geometry,
           geometry.buttonFrame.contains(mousePositionProvider()) {
            menuBarAnchor.requestPopupFromStatusItemClick()
            return
        }
        dismiss()
    }

    @discardableResult
    func handleOutsideMouseDown(_ event: NSEvent) -> NSEvent {
        // The item's own monitor must see the still-visible HUD so it can
        // promote it to the popup. Monitor invocation order is not guaranteed.
        if isSystemCapsule && menuBarAnchor.ownsStatusItemEvent(event) { return event }
        if let panel, panel.isVisible, event.window !== panel { dismiss() }
        return event
    }

    private func removeDismissMonitors() {
        if let monitor = localDismissMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalDismissMonitor { NSEvent.removeMonitor(monitor) }
        localDismissMonitor = nil
        globalDismissMonitor = nil
    }

    // MARK: - Accessibility

    private func postAccessibilityAnnouncement(panel: NSPanel, sliderFraction: Double, mute: Bool, deviceName: String) {
        let description = accessibilityDescription(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func accessibilityDescription(sliderFraction: Double, mute: Bool, deviceName: String) -> String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        if mute { return "\(device), muted" }
        let clamped = max(0, min(1, sliderFraction))
        return "\(device), volume \(Int((clamped * 100).rounded())) percent"
    }

    private func postPerAppAccessibilityAnnouncement(panel: NSPanel, title: String, content: PerAppHUDContent) {
        let description: String
        switch content {
        case .volume(let sliderFraction):
            description = "\(title), volume \(Int((sliderFraction * 100).rounded())) percent"
        case .mute(let isMuted):
            description = isMuted ? "\(title), muted" : "\(title), unmuted"
        case .notControlled:
            description = "\(title), not controlled by FineTune"
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func reduceMotionEnabled() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Fullscreen guard

    private static func foregroundAppIsFullscreen() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmostApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if boundsRect.width >= screenFrame.width && boundsRect.height >= screenFrame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Suppression-degraded detection

    private func subscribeToSettingsChangedNotification() {
        settingsChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSettingsChangedNotification()
            }
        }
    }

    private func handleSettingsChangedNotification() {
        guard let lastSwallow = lastSwallowedKeyTime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSwallow.uptimeNanoseconds
        let elapsedMs = elapsed / 1_000_000
        if elapsedMs <= 500 && !mediaKeyStatus.suppressionDegraded {
            mediaKeyStatus.suppressionDegraded = true
            logger.warning("Suppression degraded: native sound handler fired within \(elapsedMs)ms of our swallow")
        }
    }
}

// MARK: - Per-app HUD content

private enum PerAppHUDContent {
    case volume(sliderFraction: Double)
    case mute(isMuted: Bool)
    case notControlled
}

private struct PerAppHUD: View {
    let icon: NSImage?
    let title: String
    let content: PerAppHUDContent

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 22
    private static let percentageWidth: CGFloat = 36
    private static let iconSize: CGFloat = 28
    private static let barHeight: CGFloat = 4

    private var subtitleText: String? {
        if case .notControlled = content { return "Not controlled by FineTune" }
        return nil
    }

    private var displayLevel: Double {
        switch content {
        case .volume(let sliderFraction): return max(0, min(1, sliderFraction))
        case .mute(let isMuted): return isMuted ? 0 : 1
        case .notControlled: return 0
        }
    }

    private var displayedPercent: Int {
        Int((displayLevel * 100).rounded())
    }

    private var isMutedDisplay: Bool {
        switch content {
        case .mute(let isMuted): return isMuted
        case .volume: return displayedPercent == 0
        case .notControlled: return false
        }
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private var percentageText: String {
        "\(displayedPercent)%"
    }

    private var accessibilityDescription: String {
        switch content {
        case .volume:
            return "\(title), volume \(Int((displayLevel * 100).rounded())) percent"
        case .mute(let isMuted):
            return isMuted ? "\(title), muted" : "\(title), unmuted"
        case .notControlled:
            return "\(title), not controlled by FineTune"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(CapsuleVolumeHUD.nameFont)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        // Per-app notifications retain their existing material and border.
        .glassPanel(cornerRadius: Self.cornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.popupBorder, lineWidth: 0.5)
        }
        // Hard-clip to the rounded shape so the Liquid Glass ambient shadow can't
        // leak outside the HUD as a gray box on light backdrops.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }

    @ViewBuilder
    private var trailingRow: some View {
        switch content {
        case .volume:
            HStack(spacing: 8) {
                Image(systemName: isMutedDisplay ? "speaker.slash.fill" : waveIconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMutedDisplay
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)

                progressBar
                    .opacity(isMutedDisplay ? 0.5 : 1.0)

                Text(percentageText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: Self.percentageWidth, alignment: .trailing)
            }
        case .mute(let isMuted):
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMuted
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)
                Text(isMuted ? "Muted" : "Unmuted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        case .notControlled:
            if let subtitleText {
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Colors.textSecondary.opacity(0.25))
                    .frame(height: Self.barHeight)
                Capsule()
                    .fill(DesignTokens.Colors.hudTileActive)
                    .frame(width: geo.size.width * CGFloat(displayLevel), height: Self.barHeight)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.barHeight + 8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
