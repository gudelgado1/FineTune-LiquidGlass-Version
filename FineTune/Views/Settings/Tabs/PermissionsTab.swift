// FineTune/Views/Settings/Tabs/PermissionsTab.swift
import SwiftUI

/// Settings tab listing every macOS permission FineTune relies on, with a live
/// status chip and a one-click action (Grant / Open Settings) for each.
///
/// Statuses refresh automatically: Accessibility via its distributed-notification
/// observer, Audio and Notifications when the app re-activates (i.e. when the user
/// returns from System Settings). `onAppear` forces a poll so the tab is accurate
/// the moment it's shown.
@MainActor
struct PermissionsTab: View {
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var audioPermission: AudioRecordingPermission
    @Bindable var notifications: NotificationPermission

    private var accessibilityStatus: PermissionStatus {
        accessibility.isTrustedCached ? .granted : .notDetermined
    }

    private var audioStatus: PermissionStatus {
        switch audioPermission.status {
        case .authorized: return .granted
        case .denied: return .denied
        case .unknown: return .notDetermined
        }
    }

    private var notificationStatus: PermissionStatus {
        switch notifications.state {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    private var allGranted: Bool {
        accessibilityStatus == .granted
            && audioStatus == .granted
            && notificationStatus == .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            permissionsSection

            if !allGranted {
                Button {
                    requestAll()
                } label: {
                    Label("Request All Permissions", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.horizontal, 4)
            }

            Text("FineTune only requests what it needs: Accessibility to read the media keys, Audio to control per-app sound, and Notifications to warn you when a device disconnects. Nothing leaves your Mac.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshAll() }
    }

    private var permissionsSection: some View {
        SettingsSection("Permissions", badge: allGranted ? "All granted" : nil) {
            SettingsRow(
                "Accessibility",
                description: "Lets FineTune intercept the F10–F12 media keys to control volume.",
                systemImage: "accessibility"
            ) {
                PermissionStatusControl(
                    status: accessibilityStatus,
                    onGrant: { accessibility.requestAccess() },
                    onOpenSettings: { accessibility.openSystemSettings() }
                )
            }

            SettingsRowDivider()

            SettingsRow(
                "Audio Recording",
                description: "Required to capture and control each app's volume, EQ, and loudness.",
                systemImage: "waveform"
            ) {
                PermissionStatusControl(
                    status: audioStatus,
                    onGrant: { audioPermission.request() },
                    onOpenSettings: { audioPermission.openSystemSettings() }
                )
            }

            SettingsRowDivider()

            SettingsRow(
                "Notifications",
                description: "Alerts you when a connected audio device disconnects.",
                systemImage: "bell.badge"
            ) {
                PermissionStatusControl(
                    status: notificationStatus,
                    onGrant: { notifications.request() },
                    onOpenSettings: { notifications.openSystemSettings() }
                )
            }
        }
    }

    private func refreshAll() {
        accessibility.refresh()
        audioPermission.refreshStatus()
        notifications.refresh()
    }

    /// Requests every not-yet-granted permission. Each call is a no-op if already
    /// granted, and the OS shows at most one dialog per service.
    private func requestAll() {
        if accessibilityStatus != .granted { accessibility.requestAccess() }
        if audioStatus != .granted { audioPermission.request() }
        if notificationStatus != .granted { notifications.request() }
    }
}
