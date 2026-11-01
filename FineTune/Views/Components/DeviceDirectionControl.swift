import AppKit
import SwiftUI

/// Own the native control so its public border shape can be configured without
/// reaching into a SwiftUI Picker's implementation or replacing its material.
@available(macOS 27.0, *)
struct DeviceDirectionControl: NSViewRepresentable {
    @Binding var showingInput: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $showingInput)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        Self.makeControl(coordinator: context.coordinator)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $showingInput
        context.coordinator.synchronize(control)
    }

    static func makeControl(coordinator: Coordinator) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.role = .tabs
        control.borderShape = .capsule
        control.segmentDistribution = .fillEqually
        control.target = coordinator
        control.action = #selector(Coordinator.selectDirection(_:))
        control.setToolTip("Output Devices", forSegment: 0)
        control.setToolTip("Input Devices", forSegment: 1)
        control.setAccessibilityLabel("Device Direction")
        control.setAccessibilityIdentifier("devices.direction.picker")
        coordinator.synchronize(control)
        control.sizeToFit()
        return control
    }

    final class Coordinator: NSObject {
        var selection: Binding<Bool>
        private var renderedInput: Bool?

        init(selection: Binding<Bool>) {
            self.selection = selection
        }

        func synchronize(_ control: NSSegmentedControl) {
            let input = selection.wrappedValue
            // Keep native artwork untouched on unrelated parent updates, including
            // updates arriving while the user is tracking a segment.
            if renderedInput != input || control.image(forSegment: 0) == nil {
                let configuration = NSImage.SymbolConfiguration(textStyle: .body, scale: .medium)
                    .applying(.preferringMonochrome())
                let symbols = [
                    (input ? "speaker.wave.2" : "speaker.wave.2.fill", "Output Devices"),
                    (input ? "mic.fill" : "mic", "Input Devices"),
                ]
                for (index, symbol) in symbols.enumerated() {
                    let image = NSImage(systemSymbolName: symbol.0, accessibilityDescription: symbol.1)
                    let configured = image?.withSymbolConfiguration(configuration) ?? image
                    configured?.accessibilityDescription = symbol.1
                    control.setImage(configured, forSegment: index)
                }
                renderedInput = input
            }
            let index = input ? 1 : 0
            if control.selectedSegment != index { control.selectedSegment = index }
        }

        @objc func selectDirection(_ control: NSSegmentedControl) {
            guard (0..<2).contains(control.selectedSegment) else { return }
            let input = control.selectedSegment == 1
            guard selection.wrappedValue != input else { return }
            selection.wrappedValue = input
        }
    }
}
