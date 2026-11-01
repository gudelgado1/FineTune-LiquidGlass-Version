// FineTune/Views/Settings/Components/SettingsRow.swift
import SwiftUI

@MainActor
struct SettingsRow<Trailing: View>: View {
    @Environment(\.settingsShowsHelp) private var showHelp
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 16) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing()
                    .fixedSize(horizontal: true, vertical: false)
            }
            if showHelp, let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// Hairline divider sized to fit between `SettingsRow`s inside a
/// `SettingsSection`. Inset from the leading edge so it doesn't touch the
/// container border.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
    }
}
