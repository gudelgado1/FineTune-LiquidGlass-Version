// FineTune/Views/Settings/SettingsRootView.swift
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var notifications: NotificationPermission
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry
    @ObservedObject var updateManager: UpdateManager

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, audio, shortcuts, permissions, updates, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .audio: "Audio"
            case .shortcuts: "Shortcuts"
            case .permissions: "Permissions"
            case .updates: "Updates"
            case .about: "About"
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .audio: "speaker.wave.2"
            case .shortcuts: "command"
            case .permissions: "lock.shield"
            case .updates: "arrow.triangle.2.circlepath"
            case .about: "info.circle"
            }
        }

        var accessibilityIdentifier: String {
            "settings.sidebar.\(rawValue)"
        }
    }

    @State private var selection: Section = .general
    @State private var isCloseButtonHovered = false
    /// `NavigationSplitView.List(selection:)` requires an optional binding.
    /// We bridge to the non-optional `selection` so the sidebar never falls
    /// into a "nothing selected" state — selecting `nil` is silently ignored.
    private var selectionBinding: Binding<Section?> {
        Binding(
            get: { selection },
            set: { newValue in
                if let new = newValue { selection = new }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            navigationSplitView
                // Dedicated 24 pt drag handle at the very top, reserved via
                // safeAreaInset so it doesn't overlap the sidebar List rows.
                // Without this strip the borderless panel can't be dragged
                // (window.isMovableByWindowBackground is intentionally false).
                .safeAreaInset(edge: .top, spacing: 0) {
                    WindowDragStrip()
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)
                }

            closeButton
                .padding(.trailing, 22)
                .padding(.bottom, 16)
        }
        .frame(minWidth: 860, minHeight: 580)
        // Liquid Glass stays the front surface (full vibrancy / reflections).
        // A faint behind-window blur sits *under* the glass to deepen the
        // backdrop just a touch — kept at low opacity so the glass look is
        // preserved rather than flattened into an opaque frosted panel. Glass is
        // applied first so it layers in front of this blur; tune `opacity`
        // (and/or the material) for more/less blur. Both sit before `.clipShape`
        // so they inherit the 22 pt rounded corners.
        .darkGlassBackground(cornerRadius: 22)
        .background {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .opacity(0.2)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.8)
        }
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .environment(\.appearancePreference, settings.appSettings.appearance)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(SettingsWindowChromeBridge())
        .overlay(alignment: .topLeading) {
            uiTestAccessibilityAnchors
        }
    }

    // MARK: - NavigationSplitView

    /// Native two-column navigation. On macOS 26 the sidebar inherits Liquid
    /// Glass automatically; on macOS 14/15 it falls back to the conventional
    /// vibrant sidebar material. Either way the system handles selection
    /// styling, hover states, and Reduce-Transparency accessibility for us —
    /// the previous hand-rolled `Button` sidebar reimplemented all of that.
    private var navigationSplitView: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    /// Native `List` with sidebar style. macOS provides the row backgrounds,
    /// selection highlight, hover state, keyboard navigation (↑↓ + Return),
    /// and Liquid Glass material on macOS 26. Each row uses `Label` so the
    /// icon + text alignment matches every other macOS sidebar — plus an
    /// optional trailing **status dot** that surfaces "this tab needs your
    /// attention" cues at a glance (currently used for the Shortcuts tab
    /// when Accessibility isn't granted or the media-key tap is offline).
    private var sidebarList: some View {
        List(selection: selectionBinding) {
            ForEach(Section.allCases) { section in
                sidebarRow(for: section)
                    .tag(Section?.some(section))
                    .accessibilityIdentifier(section.accessibilityIdentifier)
            }
        }
        // Hide the inner scroll background so our outer `darkGlassBackground`
        // is what reads through — the native sidebar material is then layered
        // by the system on top of our glass, which is the Apple pattern.
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
    }

    /// One sidebar row: native Label + a 6 pt trailing status dot whenever
    /// the section reports a non-`nil` status color. The dot's accessibility
    /// label is announced alongside the row title so VoiceOver users hear
    /// "Shortcuts, needs attention".
    @ViewBuilder
    private func sidebarRow(for section: Section) -> some View {
        HStack(spacing: 6) {
            Label(section.title, systemImage: section.symbolName)
            Spacer(minLength: 0)
            if let dotColor = statusDotColor(for: section) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Needs attention")
            }
        }
    }

    /// Returns a non-nil color when the given section has a state worth
    /// flagging. Keeps badge logic centralized so future sections can opt-in
    /// by adding a case here.
    private func statusDotColor(for section: Section) -> Color? {
        switch section {
        case .shortcuts:
            // Two failure modes for the media-key feature: missing trust, or
            // the CGEventTap has gone offline. Both block keys from working,
            // so both deserve the same orange "your attention is needed" cue.
            if !accessibility.isTrustedCached || mediaKeyStatus.isOffline {
                return .orange
            }
            return nil
        case .permissions:
            // Flag whenever any required permission isn't granted yet.
            return anyPermissionMissing ? .orange : nil
        case .general, .audio, .updates, .about:
            return nil
        }
    }

    /// True if any of the three macOS permissions FineTune relies on is not granted.
    private var anyPermissionMissing: Bool {
        !accessibility.isTrustedCached
            || audioEngine.permission.status != .authorized
            || notifications.state != .authorized
    }

    // MARK: - Detail (selected tab content)

    /// Detail column with the active tab's content. We deliberately do NOT
    /// apply `backgroundExtensionEffect()` here: that modifier is designed
    /// for media-rich hero content (images extending under a toolbar/sidebar
    /// for continuity), and on text-heavy settings pages it produces a bug
    /// where section headers like "Appearance" or "Danger Zone" bleed
    /// through the sidebar — exactly the artifact the inspector is meant
    /// to *prevent*.
    ///
    /// When Accessibility trust is missing, a persistent banner is pinned
    /// above the scroll view so the prompt reaches the user on every tab,
    /// not only Shortcuts. The banner removes itself once trust is granted.
    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if !accessibility.isTrustedCached {
                AccessibilityBanner(accessibility: accessibility)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            scrollContent
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: accessibility.isTrustedCached)
    }

    private var scrollContent: some View {
        ScrollView {
            Group {
                switch selection {
                case .general:
                    GeneralTab(
                        settings: settings,
                        onResetAll: {
                            audioEngine.handleSettingsReset()
                            deviceVolumeMonitor.setSystemFollowDefault()
                        }
                    )
                case .audio:
                    AudioTab(
                        settings: settings,
                        audioEngine: audioEngine,
                        deviceVolumeMonitor: deviceVolumeMonitor
                    )
                case .shortcuts:
                    ShortcutsTab(
                        settings: settings,
                        accessibility: accessibility,
                        mediaKeyStatus: mediaKeyStatus,
                        mediaKeyMonitor: mediaKeyMonitor,
                        shortcutsRegistry: shortcutsRegistry
                    )
                case .permissions:
                    PermissionsTab(
                        accessibility: accessibility,
                        audioPermission: audioEngine.permission,
                        notifications: notifications
                    )
                case .updates:
                    UpdatesTab(updateManager: updateManager)
                case .about:
                    AboutTab()
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            // Bottom padding leaves room for the floating close button so the
            // last row in any tab is never clipped by it.
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Close button (overlay, bottom-right)

    private var closeButton: some View {
        Button {
            NSApp.keyWindow?.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCloseButtonHovered ? Color.primary : DesignTokens.Colors.textSecondary)
        .modifier(CloseButtonGlassModifier(isHovered: isCloseButtonHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isCloseButtonHovered = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("settings.close")
        .accessibilityLabel("Close Settings")
    }

    // MARK: - UI test anchors

    /// Invisible 1 pt anchors exposing the section identifiers at predictable
    /// locations for UI tests. The native sidebar rows also carry their own
    /// `.accessibilityIdentifier`, but these anchors guarantee a stable hook
    /// even if SwiftUI's accessibility tree shifts between OS releases.
    private var uiTestAccessibilityAnchors: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("settings.root")
                .accessibilityIdentifier("settings.root")
            Text("settings.sidebar.general")
                .accessibilityIdentifier("settings.sidebar.general")
            Text("settings.sidebar.audio")
                .accessibilityIdentifier("settings.sidebar.audio")
            Text("settings.sidebar.shortcuts")
                .accessibilityIdentifier("settings.sidebar.shortcuts")
        }
        .font(.system(size: 1))
        .foregroundStyle(.clear)
        .frame(width: 1, height: 1, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Close button glass modifier

/// macOS 26 uses native interactive Liquid Glass (scales/bounces on press,
/// shimmers on hover). On macOS 14/15 we keep the prior ultraThinMaterial
/// + hover-scale fallback so the button still feels lifted.
private struct CloseButtonGlassModifier: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(
                            isHovered
                                ? DesignTokens.Colors.glassRowBorderHover.opacity(0.9)
                                : DesignTokens.Colors.glassRowBorderHover,
                            lineWidth: 0.7
                        )
                }
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
    }
}

// MARK: - Window chrome bridge

private struct SettingsWindowChromeBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowChromeView {
        SettingsWindowChromeView()
    }

    func updateNSView(_ nsView: SettingsWindowChromeView, context: Context) {
        nsView.apply()
    }
}

private final class SettingsWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.toolbar = nil
        window.titlebarSeparatorStyle = .none
        // Disabled so that clicks on toggles/buttons are NOT swallowed by the
        // window-drag gesture. The SwiftUI WindowDragStrip at the top of the
        // view hierarchy provides a dedicated drag handle instead.
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        clearAppKitChrome(window)

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.clearAppKitChrome(window)
        }
    }

    private func clearAppKitChrome(_ window: NSWindow) {
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView?.superview?.wantsLayer = true
        window.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Window Drag Strip

/// Transparent NSView that initiates window dragging on mouse-down.
/// Used in place of `isMovableByWindowBackground = true` so that interactive
/// controls (Toggle, Button, Picker) respond normally to clicks — the drag
/// behavior is confined to this dedicated strip at the top of the window.
private final class _DragStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> _DragStripView { _DragStripView() }
    func updateNSView(_ nsView: _DragStripView, context: Context) {}
}
