import AppKit
import ObjectiveC.runtime
import Testing
@testable import FineTune

@MainActor
private final class FakeHUDStatusItemSessionDriver: HUDStatusItemSessionDriving {
    var supportsNativeSessions = true
    var currentSessionID: ObjectIdentifier?
    var requestSucceeds = true
    var requests = 0
    var cancelled: [ObjectIdentifier] = []
    var legacyStates: [Bool] = []
    func requestSession() -> Bool { requests += 1; return requestSucceeds }
    func cancelSession(matching identifier: ObjectIdentifier) {
        guard currentSessionID == identifier else { return }
        cancelled.append(identifier)
        currentSessionID = nil // AppKit clears the property before didEnd.
    }
    func setLegacyHighlighted(_ highlighted: Bool) { legacyStates.append(highlighted) }
}

private final class HUDRequestSignatureFixture: NSObject {
    @objc nonisolated func correctRequest() {}
    @objc nonisolated func wrongArgument(_ object: NSObject?) {}
    @objc nonisolated func wrongResult() -> Bool { false }
}

@Suite("Native status item expanded session", .serialized)
@MainActor
struct HUDStatusItemSessionTests {
    @Test("volume repeats reuse one pending and active native request")
    func repeatsShareOneSession() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        session.setHUDVisible(true)
        session.setHUDVisible(true)
        #expect(driver.requests == 1)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        session.setHUDVisible(true)
        #expect(driver.requests == 1)
        #expect(driver.cancelled.isEmpty)
        #expect(driver.legacyStates.last == false)
    }

    @Test("late programmatic begin after hide cancels without opening a popup")
    func lateBeginCannotResurrectUI() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var popupRequests = 0
        session.onPopupRequested = { popupRequests += 1 }
        session.setHUDVisible(true)
        session.setHUDVisible(false)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        #expect(driver.cancelled == [ObjectIdentifier(token)])
        #expect(popupRequests == 0)
        #expect(!session.hudVisible && !session.popupVisible)
    }

    @Test("a re-show waits for the old cancellation and ignores a stale end after new begin")
    func cancellationThenReshow() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var hudEnds = 0
        session.onHUDSessionEnded = { hudEnds += 1 }
        session.setHUDVisible(true)
        let old = NSObject()
        driver.currentSessionID = ObjectIdentifier(old)
        session.nativeSessionBegan(ObjectIdentifier(old))
        session.setHUDVisible(false)
        session.setHUDVisible(true)
        #expect(driver.requests == 1)
        session.nativeSessionEnded(animated: true)
        #expect(driver.requests == 2)
        let current = NSObject()
        driver.currentSessionID = ObjectIdentifier(current)
        session.nativeSessionBegan(ObjectIdentifier(current))
        session.nativeSessionEnded(animated: true) // queued old end; new native session exists.
        #expect(session.hudVisible)
        #expect(hudEnds == 0)
    }

    @Test("native user cancellation closes the HUD exactly once")
    func userEndDismissesHUD() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var hudEnds = 0
        session.onHUDSessionEnded = { hudEnds += 1 }
        session.setHUDVisible(true)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        driver.currentSessionID = nil
        session.nativeSessionEnded(animated: true)
        session.nativeSessionEnded(animated: true)
        #expect(hudEnds == 1)
        #expect(!session.hudVisible)
    }

    @Test("popup promotion reserves ownership before hiding the HUD and retains the session")
    func popupPromotionKeepsHighlight() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var hudEnds = 0
        var popupRequests = 0
        session.onHUDSessionEnded = { hudEnds += 1; session.setHUDVisible(false) }
        defer { session.onHUDSessionEnded = nil }
        session.onPopupRequested = { popupRequests += 1 }
        session.setHUDVisible(true)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        session.requestPopup()
        #expect(hudEnds == 1 && popupRequests == 1)
        #expect(session.popupVisible && !session.hudVisible)
        #expect(driver.requests == 1 && driver.cancelled.isEmpty)
        session.setHUDVisible(false)
        #expect(driver.cancelled.isEmpty)
        session.setPopupVisible(false)
        #expect(driver.cancelled == [ObjectIdentifier(token)])
    }

    @Test("native user begin opens the normal popup and end preserves its animation intent")
    func userPopupLifecycle() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var popupRequests = 0
        var popupEnds: [Bool] = []
        session.onPopupRequested = { popupRequests += 1 }
        session.onPopupEnded = { popupEnds.append($0) }
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        #expect(popupRequests == 1 && session.popupVisible)
        driver.currentSessionID = nil
        session.nativeSessionEnded(animated: false)
        #expect(popupEnds == [false])
        #expect(!session.popupVisible)
    }

    @Test("programmatic popup begin does not request the popup twice")
    func popupHotkeyAndBeginShareOneOpen() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var popupRequests = 0
        session.onPopupRequested = { popupRequests += 1 }
        session.requestPopup()
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        #expect(popupRequests == 1 && driver.requests == 1)
        #expect(session.popupVisible)
    }

    @Test("direct popup toggle opens and closes without a synthetic mouse event")
    func popupToggleUsesOwnedCallbacks() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var opens = 0
        var closes: [Bool] = []
        session.onPopupRequested = { opens += 1 }
        session.onPopupEnded = { closes.append($0) }
        session.togglePopup()
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        session.togglePopup()
        #expect(opens == 1 && closes == [true])
        #expect(!session.popupVisible)
        #expect(driver.requests == 1 && driver.cancelled == [ObjectIdentifier(token)])
    }

    @Test("unavailable and rejected requests use the legacy fallback without retrying each key")
    func unavailableAndRejectedRequestsFallBack() {
        let missing = FakeHUDStatusItemSessionDriver()
        missing.supportsNativeSessions = false
        let legacy = HUDStatusItemSessionCoordinator(driver: missing)
        legacy.setHUDVisible(true)
        #expect(missing.requests == 0 && missing.legacyStates.last == true)
        legacy.setHUDVisible(false)
        #expect(missing.legacyStates.last == false)

        let rejected = FakeHUDStatusItemSessionDriver()
        rejected.requestSucceeds = false
        let failed = HUDStatusItemSessionCoordinator(driver: rejected)
        failed.setHUDVisible(true)
        failed.setHUDVisible(true)
        #expect(rejected.requests == 1 && rejected.legacyStates.last == true)
        failed.setHUDVisible(false)
        #expect(rejected.legacyStates.last == false)
    }

    @Test("acknowledgement timeout falls back but a late hidden begin is still cancelled")
    func timedOutBeginRemainsIdentified() async throws {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver, acknowledgementDelay: .milliseconds(5))
        var popupRequests = 0
        session.onPopupRequested = { popupRequests += 1 }
        session.setHUDVisible(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(driver.legacyStates.last == true)
        session.setHUDVisible(false)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        #expect(driver.cancelled == [ObjectIdentifier(token)])
        #expect(popupRequests == 0)
    }

    @Test("private request validation rejects an argument or nonvoid return without calling it")
    func exactSignatureGuard() throws {
        let exact = try #require(class_getInstanceMethod(HUDRequestSignatureFixture.self, #selector(HUDRequestSignatureFixture.correctRequest)))
        let argument = try #require(class_getInstanceMethod(HUDRequestSignatureFixture.self, #selector(HUDRequestSignatureFixture.wrongArgument(_:))))
        let result = try #require(class_getInstanceMethod(HUDRequestSignatureFixture.self, #selector(HUDRequestSignatureFixture.wrongResult)))
        #expect(NativeHUDStatusItemSessionDriver.requestSignatureMatches(exact))
        #expect(!NativeHUDStatusItemSessionDriver.requestSignatureMatches(argument))
        #expect(!NativeHUDStatusItemSessionDriver.requestSignatureMatches(result))
    }

    @Test("an unacknowledged startup request can recover on the next presentation without retrying volume repeats")
    func timedOutRequestRecoversOnNextPresentation() async throws {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver, acknowledgementDelay: .milliseconds(5))
        session.setHUDVisible(true)
        try await Task.sleep(for: .milliseconds(30))
        session.setHUDVisible(true)
        #expect(driver.requests == 1)
        session.setHUDVisible(false)
        session.setHUDVisible(true)
        #expect(driver.requests == 2)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        #expect(session.hudVisible && !session.popupVisible)
        #expect(driver.legacyStates.last == false)
    }

    @Test("a new popup intent survives an old native end already queued by an outside click")
    func popupPromotionWhileNativeEndIsQueued() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var closes = 0
        session.onPopupEnded = { _ in closes += 1 }
        session.setHUDVisible(true)
        let token = NSObject()
        driver.currentSessionID = ObjectIdentifier(token)
        session.nativeSessionBegan(ObjectIdentifier(token))
        driver.currentSessionID = nil // Native cancellation precedes its delegate callback.
        session.requestPopup()
        session.nativeSessionEnded(animated: true)
        #expect(session.popupVisible && closes == 0)
        #expect(driver.requests == 2)
    }
}


extension HUDStatusItemSessionTests {
    @Test("status click retires the HUD session and rearms without closing the requested popup")
    func statusClickRetiresOldSession() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var opens = 0, closes = 0
        session.onPopupRequested = { opens += 1 }
        session.onPopupEnded = { _ in closes += 1 }
        session.setHUDVisible(true)
        let old = NSObject()
        driver.currentSessionID = ObjectIdentifier(old)
        session.nativeSessionBegan(ObjectIdentifier(old))
        session.requestPopupFromStatusItemClick()
        session.requestPopupFromStatusItemClick()
        #expect(driver.cancelled == [ObjectIdentifier(old)])
        #expect(session.popupVisible && !session.hudVisible && opens == 1)
        session.nativeSessionEnded(animated: true)
        #expect(driver.requests == 2 && closes == 0)
        let new = NSObject()
        driver.currentSessionID = ObjectIdentifier(new)
        session.nativeSessionBegan(ObjectIdentifier(new))
        session.nativeSessionEnded(animated: true) // Queued end for the previous native presentation.
        #expect(session.popupVisible && opens == 1 && closes == 0)
    }

    @Test("a click after native HUD cancellation still opens the popup")
    func statusClickAfterNativeEnd() {
        let driver = FakeHUDStatusItemSessionDriver()
        let session = HUDStatusItemSessionCoordinator(driver: driver)
        var opens = 0
        session.onPopupRequested = { opens += 1 }
        session.setHUDVisible(true)
        let old = NSObject()
        driver.currentSessionID = ObjectIdentifier(old)
        session.nativeSessionBegan(ObjectIdentifier(old))
        driver.currentSessionID = nil
        session.nativeSessionEnded(animated: true)
        session.requestPopupFromStatusItemClick()
        #expect(session.popupVisible && !session.hudVisible && opens == 1)
        #expect(driver.requests == 2)
    }
}
