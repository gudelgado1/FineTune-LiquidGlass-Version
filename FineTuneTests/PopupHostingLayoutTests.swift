import AppKit
import SwiftUI
import Testing
@testable import FineTune

/// Exercises the actual popup without starting capture, monitors or a visible UI.
@Suite("Popup hosting layout", .serialized)
@MainActor struct PopupHostingLayoutTests {
    private final class Processes: AudioProcessMonitoring {
        var activeApps: [AudioApp] = []
        var onAppsChanged: (([AudioApp]) -> Void)?
        func start() {}
        func stop() {}
    }

    private final class OffscreenPanel: NSPanel {
        var anchor: NSPoint?
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.30 }

    }

    private final class SizeSink {
        weak var panel: OffscreenPanel?
        var reports = 0
        var applications = 0
        var sizes: [CGSize] = []
        func update(_ size: CGSize) {
            reports += 1
            sizes.append(size)
            guard let panel, panel.frame.size != size else { return }
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, let anchor = panel.anchor else { return }
                self.applications += 1
                PopupFrameAnimation.apply(NSRect(x: anchor.x, y: anchor.y - size.height,
                                                  width: size.width, height: size.height),
                                          to: panel, animated: true)
            }
        }
    }

    private func directionControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl,
           control.toolTip(forSegment: 0) == "Output Devices" { return control }
        return view.subviews.lazy.compactMap { directionControl(in: $0) }.first
    }

    @Test("switching real popup directions converges without recursive window layout", arguments: [3, 12])
    func directionSwitching(outputCount: Int) async throws {
        guard #available(macOS 27.0, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsManager(directory: directory)
        let provider = MockAudioDeviceMonitor()
        for i in 0..<outputCount {
            provider.addOutputDevice(AudioDevice(id: UInt32(900_000 + i), uid: "layout-\(i)",
                name: "Fixture Output \(i)", icon: nil, supportsAutoEQ: false))
        }
        for i in 0..<2 {
            provider.addInputDevice(AudioDevice(id: UInt32(910_000 + i), uid: "layout-input-\(i)",
                name: "Fixture Input \(i)", icon: nil, supportsAutoEQ: false))
        }
        let processes = Processes()
        processes.activeApps = (0..<3).map { i in
            AudioApp(id: Int32(900_000 + i), processObjectIDs: [], name: "Fixture App \(i)",
                     icon: NSImage(size: NSSize(width: 32, height: 32)), bundleID: "layout.app.\(i)")
        }
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: provider)
        let engine = AudioEngine(settingsManager: settings, deviceProvider: provider,
            processMonitor: processes, deviceVolumeMonitor: mockVolume, startMonitorsAutomatically: false)
        let realVolume = DeviceVolumeMonitor(deviceMonitor: AudioDeviceMonitor(), settingsManager: settings)
        let permission = engine.permission
        permission.setStatusForTesting(.authorized)
        let accessibility = AccessibilityPermissionService()
        let status = MediaKeyStatus()
        let visibility = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: visibility)
        let monitor = MediaKeyMonitor(decoder: StubMediaKeyDecoder(), audioEngine: engine,
            settingsManager: settings, accessibility: accessibility, hudController: hud,
            popupVisibility: visibility, mediaKeyStatus: status)
        let sink = SizeSink()
        let root = MenuBarPopupView(audioEngine: engine, deviceVolumeMonitor: realVolume,
            updateManager: UpdateManager(), permission: permission, accessibility: accessibility,
            mediaKeyStatus: status, popupVisibility: visibility, hudController: hud, mediaKeyMonitor: monitor)
            .modifier(RootViewModifier(windowTitle: "Offscreen popup layout"))
            .onSizeUpdate { sink.update($0) }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.isVerticalContentSizeConstraintActive = false
        host.isHorizontalContentSizeConstraintActive = false
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        let screens = NSScreen.screens.map(\.frame)
        let anchor = NSPoint(x: (screens.map(\.minX).min() ?? 0) - 10000,
                             y: (screens.map(\.minY).min() ?? 0) - 10000)
        let panel = OffscreenPanel(contentRect: NSRect(x: anchor.x, y: anchor.y - 337, width: 510, height: 337),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
        panel.anchor = anchor
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.title = "Offscreen popup layout"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.contentView = host
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        sink.panel = panel
        panel.setContentSize(host.intrinsicContentSize)
        panel.setFrame(NSRect(x: anchor.x, y: anchor.y - 337, width: 510, height: 337), display: false)
        precondition(screens.allSatisfy { !$0.intersects(panel.frame) })
        panel.orderBack(nil)
        precondition(screens.allSatisfy { !$0.intersects(panel.frame) })
        defer { sink.panel = nil; panel.orderOut(nil); panel.close() }
        try await Task.sleep(for: .milliseconds(500))
        let control = try #require(directionControl(in: host))
        for i in 0..<120 {
            control.selectedSegment = i % 2 == 0 ? 1 : 0
            #expect(control.sendAction(control.action, to: control.target))
            try await Task.sleep(for: .milliseconds([8, 16, 33, 60, 120, 360][i % 6]))
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(control.selectedSegment == 0)
        #expect(sink.sizes.count > 2, "Test must actually resize across both directions")
        #expect(Set(sink.sizes.map(\.height)).count > 1)
        #expect(sink.reports < 300, "Geometry reports must converge")
        #expect(!panel.isKeyWindow && !panel.isMainWindow)
        #expect(screens.allSatisfy { !$0.intersects(panel.frame) })
        #expect(mockVolume.setVolumeCalls.isEmpty && mockVolume.setMuteCalls.isEmpty)
        print("POPUP_LAYOUT reports=\(sink.reports) applications=\(sink.applications) sizes=\(sink.sizes)")
    }
}
