// FineTune/Views/Settings/Components/SettingsRow.swift
import SwiftUI

@MainActor
struct SettingsRow<Trailing: View>: View {
    private let title: String
    private let description: String?
    private let systemImage: String?
    @ViewBuilder private let trailing: () -> Trailing

    init(
        _ title: String,
        description: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(.title2, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                if let description {
                    Text(description)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Hairline divider sized to fit between `SettingsRow`s inside a
/// `SettingsSection`. Inset from the leading edge so it doesn't touch the
/// container border.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}
