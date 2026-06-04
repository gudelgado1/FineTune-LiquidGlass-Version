// FineTune/Audio/Permission/NotificationPermission.swift
import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "NotificationPermission")

/// Tracks the macOS notification authorization for FineTune's device-disconnect
/// alerts. Mirrors the shape of `AudioRecordingPermission` /
/// `AccessibilityPermissionService` so the Permissions settings section can treat
/// all three uniformly: a published `state`, a `refresh()` that polls without
/// prompting, a `request()` that triggers the system dialog, and an
/// `openSystemSettings()` deep link for the "denied" recovery path.
@Observable
@MainActor
final class NotificationPermission {
    enum State {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var state: State = .notDetermined

    init() {
        registerForActivation()
        refresh()
    }

    /// Polls the current authorization status without prompting. Safe to call
    /// repeatedly (e.g. on app activation or when the settings tab appears).
    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                self?.apply(status)
            }
        }
    }

    /// Triggers the system authorization dialog. Only shows once per app; if the
    /// status is already determined the OS returns the existing decision without a
    /// dialog, so calling this on a denied app is a silent no-op (use
    /// `openSystemSettings()` for the recovery path).
    func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    private func apply(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            state = .authorized
        case .denied:
            state = .denied
        case .notDetermined:
            state = .notDetermined
        @unknown default:
            state = .notDetermined
        }
    }

    private func registerForActivation() {
        // Re-poll when the user returns from System Settings so a grant/revoke
        // reflects without restarting the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }
}
