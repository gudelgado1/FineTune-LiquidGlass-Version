import AppKit

/// Shares our own status item's geometry and expanded-session lifecycle.
/// The native session draws the capsule on27; older/unsupported systems retain
/// the legacy button highlight. The popup and HUD remain independent owners.
@MainActor
final class HUDMenuBarAnchor: NSObject {
    struct Geometry {
        let buttonFrame: NSRect
        let screenFrame: NSRect
    }

    private weak var statusItem: NSStatusItem?
    private let nativeDriver: NativeHUDStatusItemSessionDriver
    private let sessions: HUDStatusItemSessionCoordinator
    private var observers: [NSObjectProtocol] = []
    private let geometryProvider: (() -> Geometry?)?
    private let highlightWriter: ((Bool) -> Void)?
    var geometryDidChange: (() -> Void)?
    var onHUDSessionEnded: (() -> Void)?
    var onPopupRequested: (() -> Void)?
    var onPopupEnded: ((Bool) -> Void)?
    var hudPresentationIsVisible: (() -> Bool)?

    init(geometryProvider: (() -> Geometry?)? = nil, highlightWriter: ((Bool) -> Void)? = nil) {
        let driver = NativeHUDStatusItemSessionDriver()
        nativeDriver = driver
        sessions = HUDStatusItemSessionCoordinator(driver: driver)
        self.geometryProvider = geometryProvider
        self.highlightWriter = highlightWriter
        super.init()
        sessions.onHighlightChanged = { [weak self] in self?.highlightWriter?($0) }
        sessions.onHUDSessionEnded = { [weak self] in self?.onHUDSessionEnded?() }
        sessions.onPopupRequested = { [weak self] in self?.onPopupRequested?() }
        sessions.onPopupEnded = { [weak self] in self?.onPopupEnded?($0) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = note.object as? NSWindow, window === self.statusItem?.button?.window else { return }
                    self.geometryDidChange?()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.geometryDidChange?() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var geometry: Geometry? {
        if let geometryProvider { return geometryProvider() }
        guard let button = statusItem?.button, !button.isHiddenOrHasHiddenAncestor,
              let window = button.window, window.isVisible, let screen = window.screen else { return nil }
        // Its drawing bounds are optically inset; the status window spans the row.
        return Geometry(buttonFrame: window.frame, screenFrame: screen.frame)
    }

    var isHUDVisible: Bool { sessions.hudVisible }
    var isPopupVisible: Bool { sessions.popupVisible }
    var canPromoteHUD: Bool { isHUDVisible || hudPresentationIsVisible?() == true }
    func ownsStatusItemEvent(_ event: NSEvent) -> Bool {
        guard let window = statusItem?.button?.window else { return false }
        return event.window === window
    }
    #if DEBUG
    var labSessionIdentifier: String? { nativeDriver.currentSessionID.map { String(describing: $0) } }
    var labNativeRequestSupported: Bool { nativeDriver.supportsNativeSessions }
    var labSessionPhase: String { sessions.labPhaseDescription }
    #endif
    var handlesNativeInteraction: Bool {
        guard #available(macOS 27.0, *), let statusItem else { return false }
        return statusItem.expandedInterfaceDelegate === self
    }

    func bind(to item: NSStatusItem?) {
        guard statusItem !== item else { return }
        if let old = statusItem {
            if #available(macOS 27.0, *) {
                if old.expandedInterfaceDelegate === self { old.expandedInterfaceDelegate = nil }
                old.expandedInterfaceSession?.cancel()
            }
            old.button?.highlight(false)
        }
        statusItem = item
        nativeDriver.item = item
        if #available(macOS 27.0, *) { item?.expandedInterfaceDelegate = self }
        sessions.bindingChanged()
        geometryDidChange?()
    }

    func setHUDVisible(_ visible: Bool) { sessions.setHUDVisible(visible) }
    func setPopupVisible(_ visible: Bool) { sessions.setPopupVisible(visible) }
    func requestPopupPresentation() { sessions.requestPopup() }
    func requestPopupFromStatusItemClick() { sessions.requestPopupFromStatusItemClick() }

    @discardableResult
    func togglePopupPresentation() -> Bool {
        guard statusItem != nil, onPopupRequested != nil else { return false }
        sessions.togglePopup()
        return true
    }
}

@available(macOS 27.0, *)
extension HUDMenuBarAnchor: NSStatusItemExpandedInterfaceDelegate {
    nonisolated func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        let itemID = ObjectIdentifier(statusItem)
        let sessionID = ObjectIdentifier(expandedInterfaceSession)
        Task { @MainActor [weak self] in
            guard let self, let ownItem = self.statusItem,
                  ObjectIdentifier(ownItem) == itemID,
                  self.nativeDriver.currentSessionID == sessionID else { return }
            self.sessions.nativeSessionBegan(sessionID)
        }
    }

    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        let itemID = ObjectIdentifier(statusItem)
        Task { @MainActor [weak self] in
            guard let self, let ownItem = self.statusItem,
                  ObjectIdentifier(ownItem) == itemID else { return }
            self.sessions.nativeSessionEnded(animated: animated)
        }
    }
}
