import Testing
@testable import FineTune

/// The channel that carries a typed digit from the popup's key handler to the
/// focused row's percentage editor.
@Suite("PopupTextEntryCoordinator — keyboard percentage entry")
@MainActor
struct PopupTextEntryCoordinatorTests {

    @Test("starts empty so no row begins in edit mode")
    func startsEmpty() {
        let c = PopupTextEntryCoordinator()
        #expect(c.pendingDigit == nil)
        #expect(c.nonce == 0)
    }

    @Test("sending a digit publishes it and advances the nonce")
    func sendPublishesDigit() {
        let c = PopupTextEntryCoordinator()
        c.send(digit: "4")
        #expect(c.pendingDigit == "4")
        #expect(c.nonce == 1)
    }

    @Test("the same digit twice still registers as two deliveries")
    func repeatedDigitAdvancesNonce() {
        // Typing "55" delivers "5" twice. Rows observe the nonce precisely because
        // comparing the value alone would swallow the second keystroke.
        let c = PopupTextEntryCoordinator()
        c.send(digit: "5")
        let first = c.nonce
        c.send(digit: "5")
        #expect(c.nonce == first + 1)
        #expect(c.pendingDigit == "5")
    }

    @Test("clearing removes the digit but never rewinds the nonce")
    func clearKeepsNonceMonotonic() {
        // A rewound nonce could make the next delivery look like a repeat of an
        // already-consumed one, and the row would ignore it.
        let c = PopupTextEntryCoordinator()
        c.send(digit: "7")
        let afterSend = c.nonce
        c.clear()
        #expect(c.pendingDigit == nil)
        #expect(c.nonce == afterSend)

        c.send(digit: "8")
        #expect(c.nonce == afterSend + 1)
        #expect(c.pendingDigit == "8")
    }
}
