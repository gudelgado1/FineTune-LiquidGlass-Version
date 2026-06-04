// FineTune/Views/Settings/Tabs/AboutTab.swift
import AppKit
import SwiftUI

@MainActor
struct AboutTab: View {
    /// Hover state on the app icon enables a subtle bounce — small visual
    /// reward for poking around. Cheap, charming, and accessibility-friendly
    /// (no auto-animation; user-triggered only).
    @State private var iconHovered = false

    /// Acknowledgments section is collapsed by default so the page stays
    /// visually quiet at first glance. Curious users can expand it.
    @State private var showAcknowledgments = false

    private var versionShort: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var yearText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: .now)
        return startYear == currentYear ? "\(startYear)" : "\(startYear)-\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            heroSection
            Spacer()
            actionChips
            acknowledgmentsSection
                .padding(.top, 18)
                .padding(.horizontal, 24)
            footer
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                // Subtle scale + drop-shadow lift on hover. Triggered on the
                // user's intent (mouse-over) rather than animating constantly,
                // so it stays compliant with Reduce Motion automatically.
                .scaleEffect(iconHovered ? 1.06 : 1.0)
                .shadow(
                    color: .black.opacity(iconHovered ? 0.18 : 0.08),
                    radius: iconHovered ? 12 : 4,
                    y: iconHovered ? 6 : 2
                )
                .onHover { iconHovered = $0 }
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: iconHovered)

            Text("FineTune")
                .font(.system(.title, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Text("Version \(versionShort) (\(buildNumber))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Per-app audio control for macOS")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }

    // MARK: - Action Chips

    private var actionChips: some View {
        HStack(spacing: 8) {
            AboutLinkChip(
                label: "Donate",
                icon: "heart.fill",
                hoverIcon: "heart.fill",
                hoverColor: .pink,
                url: DesignTokens.Links.support,
                isPrimary: true
            )
            AboutLinkChip(
                label: "Star on GitHub",
                icon: "star",
                hoverIcon: "star.fill",
                hoverColor: .yellow,
                url: URL(string: "https://github.com/gudelgado1/FineTune-LiquidGlass-Version")!
            )
        }
    }

    // MARK: - Acknowledgments

    /// Inline credits for the open-source packages FineTune depends on.
    /// Collapsible so it doesn't crowd the page; clicking the header reveals
    /// a tidy list with each project's name + a one-line role description.
    /// Each entry is a button that opens the upstream repo in the browser.
    private var acknowledgmentsSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    showAcknowledgments.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAcknowledgments ? 90 : 0))
                    Text("Built with")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAcknowledgments {
                VStack(spacing: 6) {
                    ForEach(Self.acknowledgments) { ack in
                        acknowledgmentRow(ack)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func acknowledgmentRow(_ ack: Acknowledgment) -> some View {
        Button {
            NSWorkspace.shared.open(ack.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: ack.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text(ack.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(ack.role)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(ack.name) on GitHub")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                NSWorkspace.shared.open(DesignTokens.Links.license)
            } label: {
                Text("GPL-3.0")
            }
            .buttonStyle(.plain)

            Text("·")
            Text("© \(yearText) Ronit Singh")
            Text("·")
            Text("Made with ❤️ for macOS")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Acknowledgment Model

private struct Acknowledgment: Identifiable {
    let name: String
    let role: String
    let icon: String
    let url: URL
    var id: String { name }
}

extension AboutTab {
    /// Static acknowledgments list. Adding a new dependency? Append here so
    /// it shows up in the About panel automatically.
    fileprivate static let acknowledgments: [Acknowledgment] = [
        .init(
            name: "FluidMenuBarExtra",
            role: "menu bar window behaviour",
            icon: "menubar.rectangle",
            url: URL(string: "https://github.com/wadetregaskis/FluidMenuBarExtra")!
        ),
        .init(
            name: "KeyboardShortcuts",
            role: "global hotkey registration",
            icon: "command",
            url: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!
        ),
        .init(
            name: "Sparkle",
            role: "app auto-updates",
            icon: "arrow.down.circle",
            url: URL(string: "https://github.com/sparkle-project/Sparkle")!
        ),
    ]
}
