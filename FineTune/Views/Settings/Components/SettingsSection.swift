// FineTune/Views/Settings/Components/SettingsSection.swift
import SwiftUI

/// A grouped card of related settings with an optional header title and a
/// status badge that surfaces context without spending a full row.
///
/// Examples:
///   SettingsSection("Hotkeys", badge: "3 configured") { ... }
///   SettingsSection("Software Updates", badge: "Up to date · 2h ago") { ... }
///
/// The badge is rendered as secondary text on the trailing edge of the
/// title row. Pass `nil` (or omit) to keep the original title-only look.
@MainActor
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let badge: String?
    @ViewBuilder private let content: () -> Content

    init(
        _ title: String? = nil,
        badge: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || badge != nil {
                HStack(spacing: 8) {
                    if let title {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.textPrimary)
                    }
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                content()
            }
            .modifier(SettingsCardSurface())
        }
    }
}
