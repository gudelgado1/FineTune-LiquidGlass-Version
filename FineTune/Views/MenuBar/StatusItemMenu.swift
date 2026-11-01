// FineTune/Views/MenuBar/StatusItemMenu.swift
import AppKit

/// Short native menu for a secondary click on the menu bar item: default devices,
/// mute, Settings and Quit. Rebuilt on each open so it always shows live state;
/// per-app controls stay in the popup.
final class StatusItemMenu: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private var audioEngine: AudioEngine?
    private var openSettings: (() -> Void)?

    func configured(audioEngine: AudioEngine, openSettings: @escaping () -> Void) -> NSMenu {
        self.audioEngine = audioEngine
        self.openSettings = openSettings
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let audioEngine, let monitor = audioEngine.deviceVolumeMonitor as? DeviceVolumeMonitor else { return }

        addSection("Output", to: menu)
        for device in audioEngine.prioritySortedOutputDevices {
            let item = addItem(device.name, to: menu) { audioEngine.setDefaultOutputDevice(device.id) }
            item.state = device.id == monitor.defaultDeviceID ? .on : .off
        }
        addSection("Input", to: menu)
        for device in audioEngine.prioritySortedInputDevices {
            let item = addItem(device.name, to: menu) { audioEngine.setLockedInputDevice(device) }
            item.state = device.id == monitor.defaultInputDeviceID ? .on : .off
        }

        menu.addItem(.separator())
        let outputID = monitor.defaultDeviceID
        let isMuted = monitor.muteStates[outputID] ?? false
        let mute = addItem(isMuted ? "Unmute Output" : "Mute Output", to: menu) {
            monitor.setMute(for: outputID, to: !isMuted)
        }
        mute.isEnabled = outputID != .unknown

        menu.addItem(.separator())
        let settings = addItem("Settings…", to: menu) { [weak self] in self?.openSettings?() }
        settings.keyEquivalent = ","
        let quit = addItem("Quit FineTune", to: menu) { NSApplication.shared.terminate(nil) }
        quit.keyEquivalent = "q"
    }

    private func addSection(_ title: String, to menu: NSMenu) {
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(.sectionHeader(title: title))
    }

    @discardableResult
    private func addItem(_ title: String, to menu: NSMenu, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        menu.addItem(item)
        return item
    }

    @objc private func runAction(_ item: NSMenuItem) {
        (item.representedObject as? () -> Void)?()
    }
}
