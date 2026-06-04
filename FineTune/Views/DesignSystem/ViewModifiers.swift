// FineTune/Views/DesignSystem/ViewModifiers.swift
import SwiftUI

// MARK: - Hoverable Row Modifier (flat-rest, hover-active per System Settings pattern)

struct HoverableRowModifier: ViewModifier {
    let isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 6)
            // Flat at rest; hover or keyboard focus reveals hoverSurface only.
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(isHovered || isFocused ? DesignTokens.Colors.hoverSurface : Color.clear)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.hover, value: isFocused)
    }
}

// MARK: - Section Header Style Modifier

struct SectionHeaderStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(DesignTokens.Typography.sectionHeader)
            .foregroundStyle(DesignTokens.Colors.sectionHeaderText)
            .tracking(DesignTokens.Typography.sectionHeaderTracking)
            .textCase(.uppercase)
    }
}

// MARK: - Icon Button Style Modifier (Vibrancy-aware)

struct IconButtonStyleModifier: ViewModifier {
    let isActive: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foregroundColor)
            .symbolRenderingMode(.hierarchical)  // Better vibrancy support
            .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                   minHeight: DesignTokens.Dimensions.minTouchTarget)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
    }

    private var foregroundColor: Color {
        if isActive {
            return DesignTokens.Colors.mutedIndicator
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

// MARK: - Glass Button Style Modifier

/// Button styling for glass aesthetic with vibrancy
struct GlassButtonStyleModifier: ViewModifier {
    @State private var isHovered = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .glassChip(in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                        lineWidth: 0.5
                    )
            }
            .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.quick, value: isPressed)
    }
}

// MARK: - View Extensions

extension View {
    /// Applies hoverable row styling (forwards to floatingGlassRow)
    func hoverableRow(isFocused: Bool = false) -> some View {
        modifier(HoverableRowModifier(isFocused: isFocused))
    }

    /// Applies section header text styling (uppercase, spaced, tertiary color)
    func sectionHeaderStyle() -> some View {
        modifier(SectionHeaderStyleModifier())
    }

    /// Applies icon button styling with hover state (vibrancy-aware)
    func iconButtonStyle(isActive: Bool = false) -> some View {
        modifier(IconButtonStyleModifier(isActive: isActive))
    }

    /// Applies glass button styling
    func glassButtonStyle() -> some View {
        modifier(GlassButtonStyleModifier())
    }
}

// MARK: - Previews

#Preview("Floating Glass Row") {
    VStack(spacing: 8) {
        HStack {
            Image(systemName: "music.note")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Spotify")
            Spacer()
            Text("75%")
                .foregroundStyle(.secondary)
        }
        .hoverableRow()

        HStack {
            Image(systemName: "video")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Zoom")
            Spacer()
            Text("100%")
                .foregroundStyle(.secondary)
        }
        .hoverableRow()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Section Header") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Output Devices")
            .sectionHeaderStyle()

        Text("Apps")
            .sectionHeaderStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Icon Button Styles") {
    HStack(spacing: 16) {
        Button { } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .iconButtonStyle(isActive: false)

        Button { } label: {
            Image(systemName: "speaker.slash.fill")
        }
        .iconButtonStyle(isActive: true)

        Button { } label: {
            Image(systemName: "slider.vertical.3")
        }
        .iconButtonStyle(isActive: false)
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

#Preview("Glass Button") {
    HStack(spacing: 16) {
        Button { } label: {
            Label("Settings", systemImage: "gear")
        }
        .glassButtonStyle()

        Button { } label: {
            Label("Quit", systemImage: "power")
        }
        .glassButtonStyle()
    }
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}

