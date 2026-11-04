import SwiftUI
import AppKit

/// Native search/cancel affordances; commands belong to this field, not row volume navigation.
struct AutoEQSearchField: NSViewRepresentable {
    enum Command { case up, down, select, cancel }
    @Binding var text: String
    let onCommand: (Command) -> Void

    final class Field: NSSearchField {
        var needsInitialFocus = true
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsInitialFocus, let window = self.window, window.isKeyWindow else { return }
                self.needsInitialFocus = !window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search headphone profiles"
        field.font = .systemFont(ofSize: 13)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.recentsAutosaveName = nil
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search headphone profiles")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AutoEQSearchField
        init(_ parent: AutoEQSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            let action: Command
            switch NSStringFromSelector(command) {
            case "moveUp:": action = .up
            case "moveDown:": action = .down
            case "insertNewline:": action = .select
            case "cancelOperation:": action = .cancel
            default: return false
            }
            parent.onCommand(action)
            return true
        }
    }
}
