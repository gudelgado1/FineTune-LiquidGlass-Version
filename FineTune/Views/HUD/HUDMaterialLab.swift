#if DEBUG
import AppKit
import SwiftUI

/// Compositor QA only. Entered before audio/permission/login services start.
/// Changes only these test windows; never changes macOS appearance or wallpaper.
@MainActor
enum HUDMaterialLab {
    static func trace(_ event: String) {
        guard ProcessInfo.processInfo.arguments.contains("--hud-session-lab"),
              let root = ProcessInfo.processInfo.environment["FINETUNE_TEST_DATA_ROOT"] else { return }
        let directory = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.log")
        let data = Data("\(Date().timeIntervalSinceReferenceDate) \(event)\n".utf8)
        if !FileManager.default.fileExists(atPath: file.path) { try? data.write(to: file) }
        else if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = State()
        let motionLab = ProcessInfo.processInfo.arguments.contains("--hud-motion-lab")
        let sessionLab = ProcessInfo.processInfo.arguments.contains("--hud-session-lab")
        let placementLab = sessionLab || ProcessInfo.processInfo.arguments.contains("--hud-placement-lab")
        if placementLab { state.backdrop = "Dark" }
        let placementItem = placementLab && !sessionLab ? NSStatusBar.system.statusItem(withLength: 40) : nil
        placementItem?.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "FineTune placement QA")
        placementItem?.button?.setAccessibilityTitle("FineTune placement QA")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 680),
                              styleMask: placementLab ? [.borderless] : [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "FineTune HUD Material Lab"
        window.isReleasedWhenClosed = false
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent("FineTune-HUD-Lab-\(UUID().uuidString)"))
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: MediaKeyStatus(), popupVisibility: PopupVisibilityService())
        if placementLab { hud.menuBarAnchor.bind(to: placementItem) }
        var popupItem: FluidMenuBarExtraStatusItem?
        if sessionLab {
            let popup = FluidMenuBarExtraWindow(title: "FineTune Popup Session QA") {
                VStack(spacing: 16) {
                    Text("FineTune popup session QA")
                    Text("Production popup and status-item lifecycle; no audio")
                    Button("Close QA popup") { popupItem?.dismissWindow() }
                }.padding(30).frame(width: 360).background(.regularMaterial)
            }
            popupItem = FluidMenuBarExtraStatusItem(title: "FineTune session QA", image: .systemNamed("hammer.fill"), window: popup)
            popupItem?.hudAnchor = hud.menuBarAnchor
        }
        hud.hideDelayOverride = motionLab ? .milliseconds(1100) : .seconds(120)
        hud.observesOutsideClicks = sessionLab
        hud.fullscreenProvider = { false }
        if !placementLab { hud.frameProvider = { [weak window] in window?.frame.insetBy(dx: 30, dy: 40) } }
        let present: () -> Void = {
            var options = settings.appSettings
            options.appearance = state.dark ? .dark : .light
            options.hudStyle = .tahoe
            settings.updateAppSettings(options)
            window.appearance = NSAppearance(named: state.dark ? .darkAqua : .aqua)
            hud.show(sliderFraction: 7.0 / 16, mute: state.mute, deviceName: "Material Lab")
            // REA's selected-window screenshot provider admits layer-zero windows.
            // Material/focus remain the real HUD; production z-order is tested separately.
            if !placementLab { hud.panel?.level = .normal }
            hud.panel?.title = "FineTune Volume HUD — Material Capture"
            hud.panel?.orderFrontRegardless()
            if placementLab {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let panel = hud.panel, let view = panel.contentView {
                        print("HUD-PLACEMENT-LAB frame=\(panel.frame) view=\(view.frame) safeArea=\(view.safeAreaInsets) statusBar=\(NSStatusBar.system.thickness)")
                        if let root = ProcessInfo.processInfo.environment["FINETUNE_TEST_DATA_ROOT"] {
                            let directory = URL(fileURLWithPath: root)
                            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            var record: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "panelFrame": NSStringFromRect(panel.frame), "panelLevel": panel.level.rawValue]
                            if let geometry = hud.menuBarAnchor.geometry {
                                record["buttonFrame"] = NSStringFromRect(geometry.buttonFrame)
                                record["screenFrame"] = NSStringFromRect(geometry.screenFrame)
                                record["buttonWindowID"] = placementItem?.button?.window?.windowNumber
                                record["statusWindowFrame"] = placementItem?.button?.window.map { NSStringFromRect($0.frame) }
                                record["buttonHighlighted"] = placementItem?.button?.cell?.isHighlighted
                            }
                            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                                try? data.write(to: directory.appendingPathComponent("placement.json"))
                            }
                        }
                    }
                }
            }
        }
        let replay: () -> Void = {
            hud.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: present)
        }
        let fixture = NSHostingView(rootView: Fixture(state: state, present: present, replay: replay,
                                                     togglePopup: sessionLab ? { _ = hud.menuBarAnchor.togglePopupPresentation() } : nil))
        if placementLab { fixture.safeAreaRegions = [] }
        window.contentView = fixture
        if placementLab, let screen = NSScreen.main { window.setFrame(screen.frame, display: true) }
        else { window.center() }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let fixtureClicks = sessionLab ? NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.window === window {
                let point = window.convertPoint(toScreen: event.locationInWindow)
                trace("fixture.pointer \(point.x),\(point.y)")
            }
            return event
        } : nil
        // The scene-based status item must finish registering before a session
        // request. Production starts these requests later, from media-key input.
        DispatchQueue.main.async(execute: present)
        let sessionTimer = sessionLab ? Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let path = ProcessInfo.processInfo.environment["FINETUNE_TEST_DATA_ROOT"] else { return }
                let directory = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var record: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                                            "hudOwner": hud.menuBarAnchor.isHUDVisible,
                                            "popupOwner": hud.menuBarAnchor.isPopupVisible,
                                            "panelVisible": hud.panel?.isVisible ?? false,
                                            "popupVisible": popupItem?.window.isVisible ?? false,
                                            "popupKey": popupItem?.window.isKeyWindow ?? false,
                                            "nativeRequestSupported": hud.menuBarAnchor.labNativeRequestSupported,
                                            "sessionPhase": hud.menuBarAnchor.labSessionPhase]
                record["nativeSession"] = hud.menuBarAnchor.labSessionIdentifier
                if let geometry = hud.menuBarAnchor.geometry { record["buttonFrame"] = NSStringFromRect(geometry.buttonFrame) }
                if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
                }
            }
        } : nil
        print("HUD-MATERIAL-LAB: no audio services; compositor QA windows only")
        app.run()
        if let fixtureClicks { NSEvent.removeMonitor(fixtureClicks) }
        sessionTimer?.invalidate()
        hud.shutdown()
        popupItem?.dismissWindow(animated: false)
        if let placementItem { NSStatusBar.system.removeStatusItem(placementItem) }
        exit(0)
    }

    @Observable @MainActor final class State {
        var backdrop = "Detail"
        var dark = true
        var mute = false
        var phase = false
    }

    private struct Fixture: View {
        @Bindable var state: State
        let present: () -> Void
        let replay: () -> Void
        let togglePopup: (() -> Void)?

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                Canvas { context, size in
                    let base: Color = switch state.backdrop {
                    case "Dark": .black
                    case "Light": .white
                    case "Red": state.phase ? Color(red: 0.08, green: 0.12, blue: 0.9) : Color(red: 0.85, green: 0.08, blue: 0.08)
                    case "Blue": Color(red: 0.08, green: 0.12, blue: 0.9)
                    default: .gray
                    }
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
                    if state.backdrop == "Detail" || state.backdrop == "Stripes" {
                        let step: CGFloat = state.backdrop == "Stripes" ? 4 : 48
                        for i in 0..<Int(size.width / step) + 2 {
                            let x = CGFloat(i) * step + (state.phase ? step / 2 : 0)
                            context.fill(Path(CGRect(x: x, y: 0, width: step / 2, height: size.height)),
                                         with: .color(i.isMultiple(of: 2) ? .white : .black))
                        }
                        if state.backdrop == "Detail" {
                            for y in stride(from: CGFloat(40), to: size.height, by: 100) {
                                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 6)), with: .color(.red))
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Live HUD compositor QA").font(.headline)
                    HStack {
                        ForEach(["Dark", "Light", "Red", "Blue", "Detail", "Stripes"], id: \.self) { name in
                            Button("Background: \(name)") { state.backdrop = name; state.phase = false; present() }
                        }
                    }
                    HStack {
                        Button("Theme: Light") { state.dark = false; present() }
                        Button("Theme: Dark") { state.dark = true; present() }
                        Button("Shift background") { state.phase.toggle() }
                        Button("Toggle mute") { state.mute.toggle(); present() }
                        Button("Show HUD") { present() }.keyboardShortcut("h", modifiers: [.command, .shift])
                        Button("Replay motion") { replay() }
                        if let togglePopup {
                            Button("Toggle QA popup") { togglePopup() }.keyboardShortcut("o", modifiers: [.command, .shift])
                        }
                        Button("Quit Lab") { NSApp.terminate(nil) }
                    }
                    Text("308 × 65 pt capsule • 40 pt margin • layer-zero material capture • " + backend)
                    Text("Volume never changes. No capture, media keys or permission prompts.")
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(20)
            }
            .frame(minWidth: 1000, minHeight: 600)
        }

        private var backend: String {
            if ProcessInfo.processInfo.arguments.contains("--hud-material-opaque-control") { return "Opaque negative control" }
            if ProcessInfo.processInfo.arguments.contains("--hud-material-legacy-control") { return "Previous regular-glass control" }
            if #available(macOS 26.0, *) { return HUDGlassMaterial.backendDescription }
            return "Legacy visual effect"
        }
    }
}
#endif
