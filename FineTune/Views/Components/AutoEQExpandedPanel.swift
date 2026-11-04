// FineTune/Views/Components/AutoEQExpandedPanel.swift
import SwiftUI

// MARK: - AutoEQ Expanded Panel
//
// Inline expansion panel for the AutoEQ Correction section of a DeviceRow.
// Replaces the equalizer-slider real estate of the per-app EQ panel with a
// graphical representation of the correction curve, while keeping the
// import action and presenting the profile browser inline via "Browse".
//
// Layout:
//   ┌──────────────────────────────────────────────┐
//   │ Graphical response curve (AutoEQCurveView)   │
//   ├──────────────────────────────────────────────┤
//   │ Profile name + measurement source + preamp   │
//   ├──────────────────────────────────────────────┤
//   │ [Enable] [Preamp]   [Browse…] [Import file]  │
//   └──────────────────────────────────────────────┘

struct AutoEQExpandedPanel: View {
    let profileManager: AutoEQProfileManager
    let selection: AutoEQSelection?
    let favoriteIDs: Set<String>
    let isCorrectionEnabled: Bool
    let preampEnabled: Bool
    let importErrorMessage: String?

    let onCorrectionToggle: (Bool) -> Void
    let onPreampToggle: () -> Void
    let onSelectProfile: (AutoEQProfile?) -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void

    @State private var isBrowsing = false

    // MARK: - Resolved profile (for graph + name)

    /// Fully resolved profile — only present if filters are loaded for the
    /// selected ID. Catalog-only entries (no filter data yet) fall back to a
    /// minimal info row without a curve.
    private var resolvedProfile: AutoEQProfile? {
        guard let id = selection?.profileID else { return nil }
        return profileManager.profile(for: id)
    }

    private var profileDisplayName: String? {
        if let resolvedProfile { return resolvedProfile.name }
        guard let id = selection?.profileID else { return nil }
        return profileManager.catalogEntry(for: id)?.name
    }

    private var measurementLabel: String? {
        if let resolvedProfile {
            switch resolvedProfile.source {
            case .imported: return "Imported"
            case .bundled, .fetched: return resolvedProfile.measuredBy.map { "measured by \($0)" }
            }
        }
        guard let id = selection?.profileID else { return nil }
        if let entry = profileManager.catalogEntry(for: id) {
            return "measured by \(entry.measuredBy)"
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if isBrowsing {
                AutoEQSearchPanel(
                    profileManager: profileManager,
                    favoriteIDs: favoriteIDs,
                    selectedProfileID: selection?.profileID,
                    onSelect: onSelectProfile,
                    onDismiss: { isBrowsing = false },
                    onImport: onImport,
                    onToggleFavorite: onToggleFavorite,
                    importErrorMessage: importErrorMessage
                )
                .transition(.identity)
            } else {
                AutoEQCurveView(
                    profile: resolvedProfile,
                    isCorrectionEnabled: isCorrectionEnabled && selection != nil
                )
                profileInfoRow
                controlsRow
            }

            if let error = importErrorMessage, !isBrowsing {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // A cross-fade retains the outgoing white curve behind the native search
        // field. Replace the content atomically; the popup owns its size animation.
        .animation(nil, value: isBrowsing)
    }

    // MARK: - Profile Info Row

    @ViewBuilder
    private var profileInfoRow: some View {
        if let name = profileDisplayName {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isCorrectionEnabled
                            ? DesignTokens.Colors.accentPrimary
                            : DesignTokens.Colors.textTertiary
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    if let measurement = measurementLabel {
                        Text(measurement)
                            .font(.system(size: 9))
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let resolvedProfile, preampEnabled {
                    Text("Preamp \(String(format: "%+.1f", resolvedProfile.preampDB)) dB")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassChip(in: Capsule())
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No correction profile selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
        }
    }

    // MARK: - Controls Row

    @ViewBuilder
    private var controlsRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            // Enable / Disable correction
            toggleChip(
                title: "On",
                systemImage: isCorrectionEnabled ? "checkmark.circle.fill" : "circle",
                isActive: isCorrectionEnabled,
                isEnabled: selection != nil,
                action: { onCorrectionToggle(!isCorrectionEnabled) }
            )

            // Toggle preamp scaling
            toggleChip(
                title: "Preamp",
                systemImage: preampEnabled ? "speaker.wave.2.fill" : "speaker.wave.1",
                isActive: preampEnabled,
                isEnabled: selection != nil,
                action: onPreampToggle
            )

            Spacer(minLength: 0)

            actionChip(
                title: "Browse",
                systemImage: "magnifyingglass",
                action: { isBrowsing = true }
            )

            // Import file — direct shortcut for the support file format.
            actionChip(
                title: "Import",
                systemImage: "square.and.arrow.down",
                action: onImport
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }

    // MARK: - Chip Builders

    private func toggleChip(
        title: String,
        systemImage: String,
        isActive: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(
                isActive ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassChip(in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? DesignTokens.Colors.accentPrimary.opacity(0.5)
                                 : DesignTokens.Colors.glassRowBorder,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func actionChip(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassChip(in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
