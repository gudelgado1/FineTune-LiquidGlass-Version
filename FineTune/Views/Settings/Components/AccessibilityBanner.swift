// FineTune/Views/Settings/Components/AccessibilityBanner.swift
import SwiftUI

/// Persistent warning banner shown across every Settings tab whenever the
/// user hasn't granted Accessibility trust. Without trust the media-key tap
/// can't be installed, which silently disables one of FineTune's headline
/// features. The previous flow only surfaced this prompt inside Shortcuts
/// — easy to miss if the user lands on General first.
///
/// The banner self-hides once trust is granted (after a brief celebratory
/// flourish provided by the embedded `AccessibilityPromptStrip`).
@MainActor
struct AccessibilityBanner: View {
    @Bindable var accessibility: AccessibilityPermissionService

    var body: some View {
        // Render the strip in a tinted banner shell so it reads as a warning
        // even at a glance — the rounded orange-tinted card differentiates it
        // from regular settings rows below.
        AccessibilityPromptStrip(accessibility: accessibility)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .systemOrange).opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .systemOrange).opacity(0.35), lineWidth: 0.6)
            }
    }
}
