// FineTune/Views/Components/MediaTargetToggle.swift
import SwiftUI

/// Small per-app toggle marking which app the media-transport shortcuts
/// (Play/Pause, Next, Previous) control.
///
/// Visibility rules keep the row quiet: it's persistent and accent-tinted when
/// this app *is* the current target, and otherwise only appears while the row is
/// hovered (so it's discoverable without adding permanent clutter). When hidden
/// it collapses to zero width, so the flexible app-name column absorbs the change
/// and the trailing controls don't shift.
struct MediaTargetToggle: View {
    let isTarget: Bool
    let isRowHovered: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var isVisible: Bool { isTarget || isRowHovered }

    var body: some View {
        Button(action: action) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background {
                    // Active: solid accent circle + white glyph — high contrast in
                    // BOTH light and dark (the previous faint accent tint vanished
                    // on the dark glass). Mirrors the selected DeviceBadge.
                    if isTarget {
                        Circle().fill(DesignTokens.Colors.accentPrimary)
                    } else if isHovered {
                        Circle().fill(Color.primary.opacity(0.10))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isTarget
              ? "Media shortcuts control this app — click to clear"
              : "Set as the target for media shortcuts (Play/Pause, Next, Previous)")
        .accessibilityLabel(isTarget ? "Media shortcut target, on" : "Set as media shortcut target")
        .opacity(isVisible ? 1 : 0)
        .frame(width: isVisible ? 22 : 0)
        .clipped()
        .animation(DesignTokens.Animation.hover, value: isVisible)
    }

    private var iconColor: Color {
        if isTarget { return .white }
        // Reveal-on-hover state: use secondary/primary (adapts to light & dark)
        // instead of tertiary, which was too faint on the dark glass.
        return isHovered ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
    }
}
