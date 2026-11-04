// FineTune/Views/MenuBar/PopupTextEntryCoordinator.swift
import Observation

/// Carries a typed digit from the popup's key handler to whichever row is the
/// current keyboard selection, so the user can just type "45" on a focused row
/// to set it to 45%.
///
/// Only the focused row reads this, and the popup guarantees exactly one row is
/// focused, so the digit needs no row identity of its own. `nonce` exists because
/// the same digit typed twice in a row must still register — comparing values
/// alone would swallow the second "5" of "55".
///
/// Upstream solves this with a popup-owned text buffer that avoids a `TextField`
/// entirely, because moving first responder broke their navigation. This fork
/// already keeps navigation working while a field is focused (see
/// `MenuBarPopupView.isEditingText`), so the digit simply opens the row's normal
/// editor and every existing behaviour — caret, commit on Return, click-outside,
/// range clamping — comes along unchanged.
@MainActor
@Observable
final class PopupTextEntryCoordinator {
    /// The digit that should start (or continue) an edit on the focused row.
    private(set) var pendingDigit: String?
    /// Bumped on every delivery so repeats of the same digit are distinguishable.
    private(set) var nonce: Int = 0

    /// Called by the popup when a digit key is pressed with a row selected.
    func send(digit: String) {
        pendingDigit = digit
        nonce += 1
    }

    /// Called by the row once it has consumed the digit.
    func clear() {
        pendingDigit = nil
    }
}
