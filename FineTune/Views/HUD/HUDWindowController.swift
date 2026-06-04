// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// Borderless panels return `canBecomeKey == false` by default, which would
/// leave the HUD non-key and its Liquid Glass rendered in the dimmed/frosted
/// inactive state. Overriding this lets `makeKeyAndOrderFront` make the HUD key
/// (without activating the app, thanks to `.nonactivatingPanel`) so `glassEffect`
/// renders vibrant — identical to the key popup.
private final class KeyableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let popupVisibility: PopupVisibilityService
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "HUDWindowController")

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var styleAtLastShow: HUDStyle = .tahoe

    /// Slider fraction in [0, 1]. The wiring site converts to gain using the current device's tier.
    var volumeWriter: ((Double) -> Void)?

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var frameProvider: () -> NSRect? = { NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame }
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        subscribeToSettingsChangedNotification()
    }

    deinit {
        if let observer = settingsChangedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // `deinit` is nonisolated; `shutdown()` is preferred for synchronous teardown.
        if let panel {
            DispatchQueue.main.async { panel.orderOut(nil) }
        }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
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

        guard !isForegroundAppFullscreen() else {
            logger.debug("Skipping HUD show: foreground app is fullscreen")
            return
        }
        guard !popupVisibility.isVisible else {
            logger.debug("Skipping HUD show: popup is visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = style
        let panel = ensurePanel()
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
                TahoeStyleHUD(
                    sliderFraction: displayFraction,
                    mute: mute,
                    deviceName: deviceName,
                    onSliderChange: { [weak self] newFraction in
                        self?.volumeWriter?(Double(newFraction))
                    },
                    onHoverChange: { [weak self] hovering in
                        self?.handleHoverChange(hovering)
                    }
                )
                .preferredColorScheme(scheme)
            )
            size = NSSize(width: 300, height: 72)
        case .classic:
            root = AnyView(
                ClassicStyleHUD(sliderFraction: displayFraction, mute: mute)
                    .preferredColorScheme(scheme)
            )
            size = NSSize(width: 200, height: 200)
        }

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            // Clear the hosting view's backing so the panel is truly transparent.
            // Without this, NSHostingView's opaque default backing sits behind the
            // SwiftUI `.glassEffect`, leaving nothing for Liquid Glass to sample —
            // it renders solid dark. Mirrors the popup window's hosting-view patch.
            hv.wantsLayer = true
            hv.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: style, size: size))

        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            // Key (not just ordered front) so Liquid Glass renders vibrant like the
            // popup. `.nonactivatingPanel` keeps the user's app frontmost; only the
            // key-window status moves here for the HUD's brief lifetime.
            panel.makeKeyAndOrderFront(nil)
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

        styleAtLastShow = .tahoe
        let panel = ensurePanel()
        panel.appearance = settingsManager.appSettings.appearance.nsAppearance ?? NSApp.effectiveAppearance
        panel.ignoresMouseEvents = true

        let scheme = settingsManager.appSettings.appearance.swiftUIColorScheme
        let root = AnyView(
            PerAppHUD(icon: icon, title: title, content: content)
                .preferredColorScheme(scheme)
        )
        let size = NSSize(width: 300, height: 72)

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            // Clear the hosting view's backing so the panel is truly transparent.
            // Without this, NSHostingView's opaque default backing sits behind the
            // SwiftUI `.glassEffect`, leaving nothing for Liquid Glass to sample —
            // it renders solid dark. Mirrors the popup window's hosting-view patch.
            hv.wantsLayer = true
            hv.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        panel.setFrameOrigin(position(for: .tahoe, size: size))

        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            // Key (not just ordered front) so Liquid Glass renders vibrant like the
            // popup. `.nonactivatingPanel` keeps the user's app frontmost; only the
            // key-window status moves here for the HUD's brief lifetime.
            panel.makeKeyAndOrderFront(nil)
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
        guard let panel, panel.isVisible else { return }
        let duration = reduceMotionEnabled() ? 0.08 : 0.11
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Position Math

    /// Tahoe: top-right. Classic: bottom-center. Under suppression-degraded,
    /// Tahoe shifts left so it doesn't overlap the native top-right HUD.
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        suppressionDegraded: Bool
    ) -> NSPoint {
        switch style {
        case .tahoe:
            if suppressionDegraded {
                let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            } else {
                let x = visibleFrame.maxX - size.width - 8
                let y = visibleFrame.maxY - size.height - 8
                return NSPoint(x: x, y: y)
            }
        case .classic:
            let x = visibleFrame.midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
    }

    private func position(for style: HUDStyle, size: NSSize) -> NSPoint {
        let frame = frameProvider() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.computePosition(
            style: style,
            size: size,
            visibleFrame: frame,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded
        )
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        // KeyableHUDPanel so `makeKeyAndOrderFront` can make the HUD key → its
        // Liquid Glass renders vibrant, identical to the popup.
        let p = KeyableHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
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

    /// Strips the opaque backing from the panel's whole view stack so the more
    /// transparent `.clear` Liquid Glass shows the desktop, not a black slab.
    /// Clearing only the hosting view isn't enough: AppKit's window frame view
    /// (the hosting view's superview) keeps its own opaque backing, which the
    /// previous `.regular` glass hid but `.clear` reveals. We re-apply on the next
    /// runloop because AppKit can reset the frame view's color after the window
    /// finishes ordering in. Mirrors the popup window's chrome clearing.
    private func clearPanelBacking(_ panel: NSPanel) {
        // Belt-and-suspenders: keep the window's own drop shadow off (it can be
        // re-enabled when the borderless panel becomes key), so no shadow renders
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
        let delay = hideDelay(for: style)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow)
        }
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

    private func isForegroundAppFullscreen() -> Bool {
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
                    .font(TahoeStyleHUD.nameFont)
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
        // Liquid Glass — vibrant now that the HUD panel is a key window (matches
        // the popup). Plus the popup's hairline border.
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
