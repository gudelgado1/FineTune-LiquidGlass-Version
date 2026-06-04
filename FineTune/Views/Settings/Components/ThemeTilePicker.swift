// FineTune/Views/Settings/Components/ThemeTilePicker.swift
import SwiftUI

// MARK: - Theme Tile Picker
//
// Three side-by-side tiles, each rendering a mini-mockup of how the popup will
// look in the matching appearance. Clicking selects; the selected tile gets an
// accent-tinted ring and bold caption. This replaces a flat text-only
// `Picker(.segmented)` so the user sees what they're choosing.
//
// The mockups are static — they don't reflect the user's actual EQ/devices —
// they're just enough chrome (window bar + 3 rows) to convey "light" vs "dark"
// vs "split (system follows macOS)" at a glance.

@MainActor
struct ThemeTilePicker: View {
    @Binding var selection: AppearancePreference

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppearancePreference.allCases) { preference in
                ThemeTile(
                    preference: preference,
                    isSelected: selection == preference
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = preference
                    }
                }
            }
        }
    }
}

// MARK: - Tile

private struct ThemeTile: View {
    let preference: AppearancePreference
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 7) {
            ThemePreviewMockup(preference: preference)
                .frame(width: 84, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? DesignTokens.Colors.accentPrimary : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                }
                .shadow(
                    color: .black.opacity(isHovered ? 0.10 : 0.04),
                    radius: isHovered ? 4 : 2,
                    y: isHovered ? 2 : 1
                )
                .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)

            Text(preference.description)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(preference.description))
    }
}

// MARK: - Mockup

private struct ThemePreviewMockup: View {
    let preference: AppearancePreference

    var body: some View {
        switch preference {
        case .system:
            // Split window — left half light, right half dark. Reads as
            // "follows the system" without needing an OS-symbol overlay.
            HStack(spacing: 0) {
                MockPopupWindow(scheme: .light)
                MockPopupWindow(scheme: .dark)
            }
        case .light:
            MockPopupWindow(scheme: .light)
        case .dark:
            MockPopupWindow(scheme: .dark)
        }
    }
}

/// Static mini-popup mockup: title bar with 3 traffic lights at top, then
/// 3 stacked rows with a leading badge and trailing slider line. Just enough
/// to read as "the FineTune popup" at thumbnail size.
private struct MockPopupWindow: View {
    enum Scheme { case light, dark }
    let scheme: Scheme

    private var background: Color {
        scheme == .light ? Color(white: 0.95) : Color(white: 0.13)
    }
    private var titleBar: Color {
        scheme == .light ? Color(white: 0.97) : Color(white: 0.19)
    }
    private var rowColor: Color {
        scheme == .light ? Color(white: 0.80) : Color(white: 0.38)
    }
    private var badgeColor: Color {
        Color.accentColor.opacity(scheme == .light ? 0.85 : 0.95)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with traffic lights
            ZStack(alignment: .leading) {
                titleBar
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 1.00, green: 0.37, blue: 0.36)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 1.00, green: 0.79, blue: 0.27)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.24, green: 0.80, blue: 0.34)).frame(width: 3, height: 3)
                }
                .padding(.leading, 4)
            }
            .frame(height: 9)

            // Three "rows" with a colored badge + slider line
            VStack(alignment: .leading, spacing: 4) {
                MockRow(badge: badgeColor, line: rowColor)
                MockRow(badge: rowColor.opacity(0.7), line: rowColor.opacity(0.7))
                MockRow(badge: rowColor.opacity(0.5), line: rowColor.opacity(0.5))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
        }
    }
}

private struct MockRow: View {
    let badge: Color
    let line: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(badge)
                .frame(width: 5, height: 5)

            Capsule()
                .fill(line)
                .frame(width: 12, height: 1.5)

            Spacer(minLength: 1)

            // Slider track + knob — fakes the row's volume slider
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(line.opacity(0.5))
                    .frame(width: 26, height: 1.5)
                Circle()
                    .fill(line)
                    .frame(width: 3, height: 3)
                    .offset(x: -4)
            }
        }
    }
}

// MARK: - Popup Width / Density Tile Pickers

/// Three tiles for the popup **width** presets. Each mockup keeps the same row
/// breathing room and only changes how wide the mock popup is, so the choice
/// reads as "width, independent of density".
@MainActor
struct PopupWidthTilePicker: View {
    @Binding var selection: MenuBarPopupWidth

    /// Mock popup width relative to the 84pt tile.
    private func mockWidth(_ w: MenuBarPopupWidth) -> CGFloat {
        switch w {
        case .narrow: return 52
        case .medium: return 64
        case .wide:   return 76
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MenuBarPopupWidth.allCases) { width in
                PopupLayoutTile(
                    label: width.description,
                    isSelected: selection == width,
                    mockup: PopupLayoutMockup(
                        popupWidth: mockWidth(width),
                        rowSpacing: 4,
                        verticalPadding: 4.5
                    )
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = width
                    }
                }
            }
        }
    }
}

/// Three tiles for the popup **density** presets. Each mockup keeps the same
/// width and only changes the row spacing + padding, so the choice reads as
/// "breathing room, independent of width".
@MainActor
struct PopupDensityTilePicker: View {
    @Binding var selection: MenuBarPopupDensity

    private func rowSpacing(_ d: MenuBarPopupDensity) -> CGFloat {
        switch d {
        case .compact:     return 2.5
        case .comfortable: return 4
        case .spacious:    return 5.5
        }
    }

    private func verticalPadding(_ d: MenuBarPopupDensity) -> CGFloat {
        switch d {
        case .compact:     return 3
        case .comfortable: return 4.5
        case .spacious:    return 6
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MenuBarPopupDensity.allCases) { density in
                PopupLayoutTile(
                    label: density.description,
                    isSelected: selection == density,
                    mockup: PopupLayoutMockup(
                        popupWidth: 64,
                        rowSpacing: rowSpacing(density),
                        verticalPadding: verticalPadding(density)
                    )
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = density
                    }
                }
            }
        }
    }
}

/// Shared tile chrome for the width/density pickers: a framed mockup with the
/// selection ring + hover lift, and a caption underneath.
private struct PopupLayoutTile<Mockup: View>: View {
    let label: String
    let isSelected: Bool
    let mockup: Mockup
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 7) {
            mockup
                .frame(width: 84, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? DesignTokens.Colors.accentPrimary : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 0.5
                        )
                }
                .shadow(
                    color: .black.opacity(isHovered ? 0.10 : 0.04),
                    radius: isHovered ? 4 : 2,
                    y: isHovered ? 2 : 1
                )
                .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)

            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(label))
    }
}

/// Parametric mock popup: a framed card with three rows. Width, row spacing,
/// and vertical padding are supplied so the same view can illustrate either a
/// width change (vary `popupWidth`) or a density change (vary spacing/padding).
private struct PopupLayoutMockup: View {
    let popupWidth: CGFloat
    let rowSpacing: CGFloat
    let verticalPadding: CGFloat

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .frame(width: popupWidth)
                .overlay {
                    VStack(spacing: rowSpacing) {
                        MockRow(badge: Color.accentColor.opacity(0.7),
                                line: Color.primary.opacity(0.45))
                        MockRow(badge: Color.primary.opacity(0.4),
                                line: Color.primary.opacity(0.35))
                        MockRow(badge: Color.primary.opacity(0.3),
                                line: Color.primary.opacity(0.25))
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, verticalPadding)
                    .frame(width: popupWidth)
                }
        }
    }
}

// MARK: - Previews

#Preview("Theme tiles - Light") {
    @Previewable @State var pref: AppearancePreference = .system
    return VStack(alignment: .leading, spacing: 12) {
        Text("Theme").font(.headline)
        ThemeTilePicker(selection: $pref)
    }
    .padding(20)
    .frame(width: 380)
    .preferredColorScheme(.light)
}

#Preview("Theme tiles - Dark") {
    @Previewable @State var pref: AppearancePreference = .dark
    return VStack(alignment: .leading, spacing: 12) {
        Text("Theme").font(.headline).foregroundStyle(.primary)
        ThemeTilePicker(selection: $pref)
    }
    .padding(20)
    .frame(width: 380)
    .background(Color(white: 0.12))
    .preferredColorScheme(.dark)
}

#Preview("Popup Width + Density tiles") {
    @Previewable @State var width: MenuBarPopupWidth = .medium
    @Previewable @State var density: MenuBarPopupDensity = .comfortable
    return VStack(alignment: .leading, spacing: 16) {
        Text("Popup Width").font(.headline)
        PopupWidthTilePicker(selection: $width)
        Text("Popup Density").font(.headline)
        PopupDensityTilePicker(selection: $density)
    }
    .padding(20)
    .frame(width: 380)
}
