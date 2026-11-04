import SwiftUI

/// The popup delegates Escape to its current inline editor before closing itself.
@Observable @MainActor
final class PopupInlineEditorContext {
    private(set) var isPresented = false
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var dismissHandler: (() -> Void)?

    func register(owner: UUID, dismiss: @escaping () -> Void) {
        if self.owner != owner { _ = dismissCurrent() }
        self.owner = owner
        dismissHandler = dismiss
        isPresented = true
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        dismissHandler = nil
        isPresented = false
    }

    @discardableResult func dismissCurrent() -> Bool {
        guard let handler = dismissHandler else { return false }
        owner = nil
        dismissHandler = nil
        isPresented = false
        handler()
        return true
    }
}

private struct PopupInlineEditorKey: EnvironmentKey {
    nonisolated static let defaultValue: PopupInlineEditorContext? = nil
}

extension EnvironmentValues {
    var popupInlineEditor: PopupInlineEditorContext? {
        get { self[PopupInlineEditorKey.self] }
        set { self[PopupInlineEditorKey.self] = newValue }
    }
}
