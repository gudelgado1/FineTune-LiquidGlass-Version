// FineTune/Views/Settings/Components/PermissionStatusControl.swift
import SwiftUI

/// Unified state for the three macOS permissions FineTune surfaces. Each backing
/// service (Accessibility, Audio, Notifications) maps its own status onto this.
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

/// Trailing-slot control for a permission `SettingsRow`: a colored status chip
/// plus a context-appropriate action button.
///
/// - `.granted` → green chip, no button.
/// - `.notDetermined` → amber chip + "Grant" (triggers the system request).
/// - `.denied` → red chip + "Open Settings" (the request dialog won't re-prompt
///   once the user has decided, so the only recovery is System Settings).
@MainActor
struct PermissionStatusControl: View {
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusChip
            actionButton
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch status {
        case .granted:
            chip("Granted", systemImage: "checkmark.circle.fill", color: DesignTokens.Colors.vuGreen)
        case .denied:
            chip("Denied", systemImage: "xmark.circle.fill", color: DesignTokens.Colors.mutedIndicator)
        case .notDetermined:
            chip("Not requested", systemImage: "questionmark.circle.fill", color: DesignTokens.Colors.vuOrange)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Grant", action: onGrant)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .denied:
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassChip(in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
    }
}
