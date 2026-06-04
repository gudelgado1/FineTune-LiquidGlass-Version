// FineTune/Views/Settings/Tabs/UpdatesTab.swift
import AppKit
import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var updateManager: UpdateManager

    /// Visible release notes is collapsed by default. Most users hit this tab
    /// to check for updates, not to read change history — but power users like
    /// to scan what changed without leaving the app, so the link is always
    /// one click away.
    @State private var showReleaseLinks = false

    // MARK: - Versioning helpers

    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var releaseNotesURL: URL {
        URL(string: "https://github.com/gudelgado1/FineTune-LiquidGlass-Version/releases/tag/v\(versionShort)")!
    }

    private var allReleasesURL: URL {
        URL(string: "https://github.com/gudelgado1/FineTune-LiquidGlass-Version/releases")!
    }

    // MARK: - Status helpers

    private var lastCheckDescription: String {
        guard let date = updateManager.lastUpdateCheckDate else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    /// Compact summary for the section header: shows the freshness state at
    /// a glance ("Up to date · 2h ago" or "Auto · 5d ago" or "Never checked").
    private var updatesBadge: String {
        let prefix = updateManager.automaticallyChecksForUpdates ? "Auto" : "Manual"
        return "\(prefix) · \(lastCheckDescription)"
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.automaticallyChecksForUpdates = $0 }
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                currentVersionCard
                softwareUpdatesSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Current Version Card
    //
    // Prominent hero card at the top with the running version. The "What's
    // new" affordance opens the corresponding GitHub release page in the
    // user's browser — no inline release notes (which would require either
    // shipping them in the appcast or making a runtime network fetch).
    // Keeps the tab self-contained while still giving immediate access.

    private var currentVersionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("FineTune \(versionShort)")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Text("Build \(buildNumber) · Last checked \(lastCheckDescription)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(releaseNotesURL)
                } label: {
                    Label("What's new in \(versionShort)", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.open(allReleasesURL)
                } label: {
                    Label("Release history", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Colors.eqCardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.6)
        }
    }

    // MARK: - Software Updates section

    private var softwareUpdatesSection: some View {
        SettingsSection("Software Updates", badge: updatesBadge) {
            SettingsRow(
                "Automatic updates",
                description: "Check for new versions in the background"
            ) {
                Toggle("", isOn: automaticallyChecksBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "Check Now",
                description: "Fetch the latest version manually"
            ) {
                Button("Check") {
                    updateManager.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
