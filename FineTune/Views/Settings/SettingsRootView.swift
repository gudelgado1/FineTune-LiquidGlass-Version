// FineTune/Views/Settings/SettingsRootView.swift
import AppKit
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

    @State private var selection: SettingsPage = .general
    @AppStorage("settings.showHelp") private var showHelp = true

    var body: some View {
        SettingsLayout(selection: $selection, showHelp: $showHelp, attentionPages: attentionPages) {
            VStack(alignment: .leading, spacing: 22) {
                if !accessibility.isTrustedCached {
                    AccessibilityBanner(accessibility: accessibility)
                }
                selectedContent
            }
        }
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .environment(\.appearancePreference, settings.appSettings.appearance)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
    }

    private var attentionPages: Set<SettingsPage> {
        var pages: Set<SettingsPage> = []
        if !accessibility.isTrustedCached || mediaKeyStatus.isOffline { pages.insert(.shortcuts) }
        if !accessibility.isTrustedCached || audioEngine.permission.status != .authorized
            || notifications.state != .authorized { pages.insert(.permissions) }
        return pages
    }

    @ViewBuilder private var selectedContent: some View {
        switch selection {
        case .general:
            GeneralTab(settings: settings, onResetAll: {
                audioEngine.handleSettingsReset()
                deviceVolumeMonitor.setSystemFollowDefault()
            })
        case .appearance:
            AppearanceTab(settings: settings)
        case .audio:
            AudioTab(settings: settings, audioEngine: audioEngine, deviceVolumeMonitor: deviceVolumeMonitor)
        case .shortcuts:
            ShortcutsTab(settings: settings, accessibility: accessibility, mediaKeyStatus: mediaKeyStatus,
                         mediaKeyMonitor: mediaKeyMonitor, shortcutsRegistry: shortcutsRegistry)
        case .permissions:
            PermissionsTab(accessibility: accessibility, audioPermission: audioEngine.permission, notifications: notifications)
        case .updates:
            UpdatesTab(updateManager: updateManager)
        case .about:
            AboutTab()
        }
    }
}

// The layout is independent of the audio services so previews use the same UI.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, audio, shortcuts, permissions, updates, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Application"
        case .appearance: "Appearance"
        case .audio: "Audio"
        case .shortcuts: "Keyboard"
        case .permissions: "Permissions"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .appearance: "macwindow"
        case .audio: "speaker.wave.2"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .updates: "arrow.down.circle"
        case .about: "tag"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, notifications and your saved preferences"
        case .appearance: "Make FineTune feel at home on your Mac"
        case .audio: "Volume, devices and audio processing"
        case .shortcuts: "Media keys and shortcuts for everyday control"
        case .permissions: "Manage FineTune’s access to macOS features"
        case .updates: "Your installed version and software updates"
        case .about: "FineTune for macOS"
        }
    }
}

@MainActor
struct SettingsLayout<Content: View>: View {
    @Binding var selection: SettingsPage
    @Binding var showHelp: Bool
    var attentionPages: Set<SettingsPage> = []
    @ViewBuilder var content: () -> Content
    @FocusState private var focusedPage: SettingsPage?

    var body: some View {
        SettingsGlassContainer {
            settingsColumns
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(SettingsStyle.header)
        .tint(.blue)
        .environment(\.settingsShowsHelp, showHelp)
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowChromeBridge())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
    }

    private var settingsColumns: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .padding(10)
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    content()
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(26)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .id(selection)
                .scrollIndicators(.automatic)
                .contentMargins(.vertical, 16, for: .scrollIndicators)
                .background(SettingsStyle.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(SettingsStyle.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Space for the actual macOS close/minimize/zoom controls.
            WindowDragStrip().frame(height: 56)
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        selection = page
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.blue)
                                .frame(width: 26)
                            Text(page.title)
                                .font(.system(size: 14, weight: selection == page ? .medium : .regular))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if attentionPages.contains(page) {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                                    .accessibilityLabel("Needs attention")
                            }
                        }
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background(selection == page ? SettingsStyle.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 11))
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .focused($focusedPage, equals: page)
                    .accessibilityIdentifier("settings.sidebar.\(page.rawValue)")
                    .accessibilityAddTraits(selection == page ? .isSelected : [])
                }
            }
            .onMoveCommand { direction in
                let pages = SettingsPage.allCases
                guard let index = pages.firstIndex(of: focusedPage ?? selection) else { return }
                let next: Int
                switch direction {
                case .up: next = max(0, index - 1)
                case .down: next = min(pages.count - 1, index + 1)
                default: return
                }
                selection = pages[next]
                focusedPage = pages[next]
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 30)
            Toggle("Show help", isOn: $showHelp)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                .accessibilityIdentifier("settings.showHelp")
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.blue)
                Text("FineTune").fontWeight(.medium)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(18)
        }
        .modifier(SettingsNavigationSurface(cornerRadius: 22, fallback: SettingsStyle.sidebar))
    }

    private var pageHeader: some View {
        WindowDragStrip()
            // Keep the 136 pt header allocation while insetting its glass surface.
            .frame(height: 116)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: selection.symbol)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.blue)
                    Text(selection.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(selection.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
                .allowsHitTesting(false)
            }
            .modifier(SettingsNavigationSurface(cornerRadius: 22, fallback: SettingsStyle.sidebar))
            .padding(.vertical, 10)
            .padding(.trailing, 10)
    }
}

private struct SettingsWindowChromeBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowChromeView { SettingsWindowChromeView() }
    func updateNSView(_ nsView: SettingsWindowChromeView, context: Context) { nsView.apply() }
}

private final class SettingsWindowChromeView: NSView {
    private var trafficLights: [NSButton] = []
    private var trafficLightLayoutScheduled = false

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            NotificationCenter.default.removeObserver(self)
            trafficLights.removeAll()
        }
        apply()
    }

    override func layout() {
        super.layout()
        positionTrafficLights()
    }

    func apply() {
        guard let window else { return }
        window.title = "FineTune Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarSeparatorStyle = .none
        // Reserve a native titlebar tall enough for the inset traffic lights.
        let toolbarID = NSToolbar.Identifier("FineTune.Settings")
        if window.toolbar?.identifier != toolbarID {
            let toolbar = NSToolbar(identifier: toolbarID)
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }
        if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("settings.close")
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        observeTrafficLights(in: window)
        scheduleTrafficLightLayout()
    }

    private func observeTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard trafficLights.count != buttons.count
                || !zip(trafficLights, buttons).allSatisfy({ $0 === $1 }) else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        trafficLights = buttons
        for button in buttons {
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scheduleTrafficLightLayout),
                name: NSView.frameDidChangeNotification, object: button
            )
        }
    }

    @objc private func scheduleTrafficLightLayout() {
        guard !trafficLightLayoutScheduled else { return }
        trafficLightLayoutScheduled = true
        // AppKit can reset the standard frames during titlebar layout. Reapply
        // after that pass, without changing button targets or moving view parents.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trafficLightLayoutScheduled = false
            self.positionTrafficLights()
        }
    }

    private func positionTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let frameView = window.contentView?.superview else { return }
        // The sidebar starts 10 pt inside the window. Leave another 14 pt of
        // space inside its curved edge, matching the reference's inset controls.
        let inset: CGFloat = 24
        for (index, button) in trafficLights.enumerated() {
            guard let parent = button.superview else { continue }
            let rect = NSRect(x: inset + CGFloat(index) * 23,
                              y: frameView.bounds.maxY - inset - button.frame.height,
                              width: button.frame.width, height: button.frame.height)
            let target = parent.convert(rect, from: frameView)
            if button.frame.origin != target.origin { button.setFrameOrigin(target.origin) }
        }
    }
}

private final class SettingsDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsDragView { SettingsDragView() }
    func updateNSView(_ nsView: SettingsDragView, context: Context) {}
}
