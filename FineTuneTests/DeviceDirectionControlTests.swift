import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Native device-direction control", .serialized)
@MainActor struct DeviceDirectionControlTests {
    @Test("native capsule keeps the tab role, selected direction and named symbols",
          arguments: [false, true])
    func nativeConfiguration(input: Bool) throws {
        guard #available(macOS 27.0, *) else { return }
        let coordinator = DeviceDirectionControl.Coordinator(selection: .constant(input))
        let control = DeviceDirectionControl.makeControl(coordinator: coordinator)
        #expect(control.window == nil)
        #expect(control.borderShape == .capsule)
        #expect(control.role == .tabs)
        #expect(control.trackingMode == .selectOne)
        #expect(control.selectedSegment == (input ? 1 : 0))
        #expect(control.image(forSegment: 0)?.accessibilityDescription == "Output Devices")
        #expect(control.image(forSegment: 1)?.accessibilityDescription == "Input Devices")
        #expect(try #require(control.image(forSegment: 0)).size.width > 0)
        #expect(try #require(control.image(forSegment: 1)).size.width > 0)
    }

    @Test("native actions use the latest binding and external updates restore the selection")
    func bindingLifecycle() {
        guard #available(macOS 27.0, *) else { return }
        var first = false
        var second = true
        let coordinator = DeviceDirectionControl.Coordinator(
            selection: Binding(get: { first }, set: { first = $0 }))
        let control = DeviceDirectionControl.makeControl(coordinator: coordinator)
        control.selectedSegment = 1
        #expect(control.sendAction(control.action, to: control.target))
        #expect(first)
        coordinator.synchronize(control)
        let inputImage = control.image(forSegment: 1)
        coordinator.synchronize(control)
        #expect(control.image(forSegment: 1) === inputImage)

        coordinator.selection = Binding(get: { second }, set: { second = $0 })
        coordinator.synchronize(control)
        control.selectedSegment = 0
        #expect(control.sendAction(control.action, to: control.target))
        #expect(!second)
        #expect(first)
        second = true
        coordinator.synchronize(control)
        #expect(control.selectedSegment == 1)
    }

    @Test("an invalid deselection cannot overwrite the current direction")
    func invalidSelection() {
        guard #available(macOS 27.0, *) else { return }
        var input = true
        let coordinator = DeviceDirectionControl.Coordinator(
            selection: Binding(get: { input }, set: { input = $0 }))
        let control = DeviceDirectionControl.makeControl(coordinator: coordinator)
        control.selectedSegment = -1
        #expect(control.sendAction(control.action, to: control.target))
        #expect(input)
        coordinator.synchronize(control)
        #expect(control.selectedSegment == 1)
    }
}
