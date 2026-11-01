import Testing
@testable import FineTune

@Suite("Compact popup output presentation")
@MainActor struct PopupOutputLayoutTests {
    private func device(_ uid: String, id: UInt32) -> AudioDevice {
        AudioDevice(id: id, uid: uid, name: uid, icon: nil, supportsAutoEQ: true)
    }

    @Test("the real active output leads even when priority order differs")
    func activeOutputLeads() {
        let devices = [device("speakers", id: 1), device("usb", id: 2), device("dell", id: 3)]
        let layout = PopupOutputLayout(devices: devices, defaultUID: "usb")
        #expect(layout.active?.uid == "usb")
        #expect(layout.alternatives.map(\.uid) == ["speakers", "dell"])
        #expect(layout.visibleDevices(showingAlternatives: false).map(\.uid) == ["usb"])
        #expect(layout.visibleDevices(showingAlternatives: true).map(\.uid) == ["usb", "speakers", "dell"])
    }

    @Test("an unavailable default exposes choices without pretending one is active",
          arguments: [Optional<String>.none, Optional("disconnected")])
    func unavailableDefault(uid: String?) {
        let devices = [device("speakers", id: 1), device("usb", id: 2)]
        let layout = PopupOutputLayout(devices: devices, defaultUID: uid)
        #expect(layout.active == nil)
        #expect(layout.visibleDevices(showingAlternatives: false).map(\.uid) == ["speakers", "usb"])
    }

    @Test("no devices produces an empty choice state")
    func emptyOutputs() {
        let layout = PopupOutputLayout(devices: [], defaultUID: "disconnected")
        #expect(layout.active == nil)
        #expect(layout.alternatives.isEmpty)
        #expect(layout.visibleDevices(showingAlternatives: false).isEmpty)
    }

    @Test("reconnected hardware uses its current CoreAudio ID for the same UID")
    func reconnectedOutput() {
        let before = PopupOutputLayout(devices: [device("usb", id: 2)], defaultUID: "usb")
        let after = PopupOutputLayout(devices: [device("usb", id: 98)], defaultUID: "usb")
        #expect(before.active?.id == 2)
        #expect(after.visibleDevices(showingAlternatives: false).first?.id == 98)
    }

    @Test("keyboard order skips collapsed devices and includes disclosed alternatives")
    func visibleKeyboardTargets() {
        let devices = [device("speakers", id: 1), device("usb", id: 2), device("dell", id: 3)]
        let layout = PopupOutputLayout(devices: devices, defaultUID: "usb")
        let nav = PopupKeyboardNavModel()
        nav.syncOrder(activeDevices: layout.visibleDevices(showingAlternatives: false), appPersistenceIDs: ["firefox"], isEditingPriority: false)
        #expect(nav.orderedRowIDs == [.device(uid: "usb"), .app(persistenceID: "firefox")])
        nav.syncOrder(activeDevices: layout.visibleDevices(showingAlternatives: true), appPersistenceIDs: ["firefox"], isEditingPriority: false)
        #expect(nav.next(after: .device(uid: "usb")) == .device(uid: "speakers"))
        nav.syncOrder(activeDevices: layout.visibleDevices(showingAlternatives: false), appPersistenceIDs: ["firefox"], isEditingPriority: false)
        #expect(nav.next(after: .device(uid: "usb")) == .app(persistenceID: "firefox"))
    }

    @Test("a new default moves to the primary control after a route change")
    func changedDefault() {
        let devices = [device("speakers", id: 1), device("usb", id: 2)]
        let layout = PopupOutputLayout(devices: devices, defaultUID: "speakers")
        #expect(layout.visibleDevices(showingAlternatives: false).map(\.uid) == ["speakers"])
        #expect(layout.alternatives.map(\.uid) == ["usb"])
    }
}
