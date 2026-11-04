import AppKit
import ObjectiveC.runtime

/// A native session is observable independently of the button cell's highlight.
/// Tests supply an inert driver; production drives only its own status item.
@MainActor
protocol HUDStatusItemSessionDriving: AnyObject {
    var supportsNativeSessions: Bool { get }
    var currentSessionID: ObjectIdentifier? { get }
    @discardableResult func requestSession() -> Bool
    func cancelSession(matching identifier: ObjectIdentifier)
    func setLegacyHighlighted(_ highlighted: Bool)
}

@MainActor
final class NativeHUDStatusItemSessionDriver: HUDStatusItemSessionDriving {
    weak var item: NSStatusItem?

    var supportsNativeSessions: Bool {
        guard #available(macOS 27.0, *), let item else { return false }
        return Self.requestMethod(on: item) != nil
    }

    var currentSessionID: ObjectIdentifier? {
        guard #available(macOS 27.0, *), let session = item?.expandedInterfaceSession else { return nil }
        return ObjectIdentifier(session)
    }

    @discardableResult
    func requestSession() -> Bool {
        guard #available(macOS 27.0, *), let item,
              let method = Self.requestMethod(on: item) else { return false }
        typealias Request = @convention(c) (AnyObject, Selector) -> Void
        let selector = NSSelectorFromString("_requestExpandedInterfaceSession")
        unsafeBitCast(method_getImplementation(method), to: Request.self)(item, selector)
        return true // Submitted, not visually acknowledged.
    }

    func cancelSession(matching identifier: ObjectIdentifier) {
        guard #available(macOS 27.0, *), let session = item?.expandedInterfaceSession,
              ObjectIdentifier(session) == identifier else { return }
        session.cancel()
    }

    func setLegacyHighlighted(_ highlighted: Bool) { item?.button?.highlight(highlighted) }

    private static func requestMethod(on item: NSStatusItem) -> Method? {
        let selector = NSSelectorFromString("_requestExpandedInterfaceSession")
        guard let cls = object_getClass(item), let method = class_getInstanceMethod(cls, selector),
              requestSignatureMatches(method) else { return nil }
        return method
    }

    /// The sole private invocation is a void instance method with no user args.
    /// Do not infer a new ABI merely because a selector survives an OS update.
    static func requestSignatureMatches(_ method: Method) -> Bool {
        guard method_getNumberOfArguments(method) == 2,
              copiedType(method_copyReturnType(method)) == "v",
              copiedType(method_copyArgumentType(method, 0)) == "@",
              copiedType(method_copyArgumentType(method, 1)) == ":" else { return false }
        return true
    }

    private static func copiedType(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// Coordinates two UI owners with one asynchronous AppKit expanded session.
/// A programmatic end waits for its end callback before rearming; a user end
/// dismisses owners. Late begin callbacks cannot resurrect hidden UI.
@MainActor
final class HUDStatusItemSessionCoordinator {
    private enum Phase {
        case idle
        case awaitingBegin(generation: Int, legacyFallback: Bool)
        case active(ObjectIdentifier)
        case ending(ObjectIdentifier)
    }

    private let driver: any HUDStatusItemSessionDriving
    private let acknowledgementDelay: Duration
    private var phase: Phase = .idle
    private var generation = 0
    private var nativeRequestFailed = false
    private var acknowledgementTask: Task<Void, Never>?
    private(set) var hudVisible = false
    private(set) var popupVisible = false

    var onHighlightChanged: ((Bool) -> Void)?
    var onHUDSessionEnded: (() -> Void)?
    var onPopupRequested: (() -> Void)?
    var onPopupEnded: ((Bool) -> Void)?

    init(driver: any HUDStatusItemSessionDriving, acknowledgementDelay: Duration = .milliseconds(500)) {
        self.driver = driver
        self.acknowledgementDelay = acknowledgementDelay
    }

    deinit { acknowledgementTask?.cancel() }

    func bindingChanged() {
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        generation += 1
        phase = .idle
        nativeRequestFailed = false
        reconcile()
    }

    func setHUDVisible(_ visible: Bool) {
        let startingPresentation = visible && !hasOwner
        hudVisible = visible
        if startingPresentation { retryUnacknowledgedRequest() }
        reconcile()
    }

    func setPopupVisible(_ visible: Bool) {
        let closingHUD = visible && hudVisible
        popupVisible = visible
        if visible { hudVisible = false }
        reconcile() // Reserve popup ownership before the HUD's dismiss callback.
        if closingHUD { onHUDSessionEnded?() }
    }

    /// Used by popup hotkeys and by an icon click that promotes an existing HUD.
    /// The popup callback opens the normal key window, never the HUD path.
    func requestPopup() {
        let alreadyRequested = popupVisible
        let closingHUD = hudVisible
        popupVisible = true
        hudVisible = false
        if !alreadyRequested { retryUnacknowledgedRequest() }
        reconcile()
        if closingHUD { onHUDSessionEnded?() }
        if !alreadyRequested { onPopupRequested?() }
    }

    /// A click on an already expanded native item also toggles its old session
    /// closed. Retire that session deliberately after reserving popup ownership,
    /// so its later didEnd cannot discard the user's request for the popup.
    func requestPopupFromStatusItemClick() {
        guard !popupVisible else { return }
        let closingHUD = hudVisible
        popupVisible = true
        hudVisible = false
        if closingHUD, let identifier = driver.currentSessionID { beginEnding(identifier) }
        else {
            retryUnacknowledgedRequest()
            reconcile()
        }
        if closingHUD { onHUDSessionEnded?() }
        onPopupRequested?()
    }

    /// Direct hotkey route; native interaction does not consume synthetic clicks.
    func togglePopup() {
        guard popupVisible else { requestPopup(); return }
        popupVisible = false
        reconcile()
        onPopupEnded?(true)
    }

    func nativeSessionBegan(_ identifier: ObjectIdentifier) {
        guard driver.currentSessionID == identifier else { return }
        let programmatic: Bool
        switch phase {
        case .awaitingBegin:
            programmatic = true
        case .active(let existing) where existing == identifier:
            return
        case .ending(let existing) where existing == identifier:
            // Its cancellation is already in flight; do not reopen any owner.
            return
        default:
            programmatic = false
        }
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        phase = .active(identifier)
        if programmatic {
            reconcile() // If all owners hid before begin, cancel immediately.
        } else {
            // A native user activation is the ordinary popup, not a new HUD.
            requestPopup()
        }
    }

    func nativeSessionEnded(animated: Bool) {
        // A queued old end must not close a more recent native session.
        guard driver.currentSessionID == nil else { return }
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        switch phase {
        case .ending:
            phase = .idle
            reconcile() // A new show during cancellation is rearmed here.
        case .active, .awaitingBegin:
            phase = .idle
            let closeHUD = hudVisible
            let closePopup = popupVisible
            hudVisible = false
            popupVisible = false
            publishHighlight()
            if closeHUD { onHUDSessionEnded?() }
            if closePopup { onPopupEnded?(animated) }
        case .idle:
            break
        }
    }

    private var hasOwner: Bool { hudVisible || popupVisible }

    #if DEBUG
    var labPhaseDescription: String { String(describing: phase) }
    #endif

    /// A slow startup must not permanently disable the native presentation.
    /// Retry only at an explicit new presentation, never on volume repeats.
    /// Keep the awaiting origin until here so a late begin remains programmatic.
    private func retryUnacknowledgedRequest() {
        guard case .awaitingBegin(_, legacyFallback: true) = phase else { return }
        phase = .idle
        nativeRequestFailed = false
    }

    private func reconcile() {
        if !hasOwner {
            switch phase {
            case .active(let identifier):
                beginEnding(identifier)
            case .awaitingBegin:
                if let identifier = driver.currentSessionID { beginEnding(identifier) }
            case .idle, .ending:
                break
            }
            publishHighlight()
            return
        }

        switch phase {
        case .idle:
            if let existing = driver.currentSessionID {
                phase = .active(existing)
            } else if driver.supportsNativeSessions && !nativeRequestFailed {
                generation += 1
                let requestGeneration = generation
                phase = .awaitingBegin(generation: requestGeneration, legacyFallback: false)
                publishHighlight()
                if driver.requestSession() {
                    if case .awaitingBegin(let current, _) = phase, current == requestGeneration {
                        startAcknowledgementTimeout(generation: requestGeneration)
                    }
                } else {
                    phase = .idle
                    nativeRequestFailed = true
                }
            }
        case .active(let identifier):
            if let current = driver.currentSessionID {
                phase = .active(current)
            } else {
                // AppKit can clear the native session before delivering didEnd.
                // A new explicit UI intent belongs to the next presentation;
                // the queued end must rearm it rather than close its popup.
                phase = .ending(identifier)
            }
        case .awaitingBegin, .ending:
            break
        }
        publishHighlight()
    }

    private func beginEnding(_ identifier: ObjectIdentifier) {
        acknowledgementTask?.cancel()
        acknowledgementTask = nil
        phase = .ending(identifier) // Set before cancel can synchronously call back.
        driver.cancelSession(matching: identifier)
    }

    private func publishHighlight() {
        let useLegacy: Bool
        switch phase {
        case .active, .ending:
            useLegacy = false
        case .awaitingBegin(_, let fallback):
            useLegacy = fallback
        case .idle:
            useLegacy = !driver.supportsNativeSessions || nativeRequestFailed
        }
        driver.setLegacyHighlighted(hasOwner && useLegacy)
        onHighlightChanged?(hasOwner)
    }

    private func startAcknowledgementTimeout(generation requestGeneration: Int) {
        acknowledgementTask?.cancel()
        let delay = acknowledgementDelay
        acknowledgementTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self,
                  case .awaitingBegin(let current, _) = self.phase,
                  current == requestGeneration else { return }
            // Keep the pending origin so a late begin is not mistaken for a click.
            self.phase = .awaitingBegin(generation: current, legacyFallback: true)
            self.nativeRequestFailed = true
            self.acknowledgementTask = nil
            self.publishHighlight()
        }
    }
}
