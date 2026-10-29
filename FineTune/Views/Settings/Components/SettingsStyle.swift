import AppKit
import SwiftUI

/// Glass belongs to Settings navigation; preferences keep solid, legible cards.
enum SettingsStyle {
    static let canvas = DesignTokens.dynamicColor(name: "settings.canvas", light: .white, dark: NSColor(white: 0.10, alpha: 1))
    static let sidebar = DesignTokens.dynamicColor(name: "settings.sidebar", light: NSColor(white: 0.975, alpha: 1), dark: NSColor(white: 0.16, alpha: 1))
    static let header = DesignTokens.dynamicColor(name: "settings.header", light: NSColor(white: 0.89, alpha: 1), dark: NSColor(white: 0.19, alpha: 1))
    static let card = DesignTokens.dynamicColor(name: "settings.card", light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.145, alpha: 1))
    static let border = DesignTokens.dynamicColor(name: "settings.border", light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.white.withAlphaComponent(0.11))
    static let selection = DesignTokens.dynamicColor(name: "settings.selection", light: NSColor.black.withAlphaComponent(0.13), dark: NSColor.white.withAlphaComponent(0.13))
}

private struct SettingsHelpVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var settingsShowsHelp: Bool {
        get { self[SettingsHelpVisibilityKey.self] }
        set { self[SettingsHelpVisibilityKey.self] = newValue }
    }
}

struct SettingsCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SettingsStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsStyle.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Render the two navigation surfaces together without merging across the sidebar gap.
struct SettingsGlassContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }
}

struct SettingsNavigationSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let fallback: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            // Apply after layout; the panel itself is not an interactive control.
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(fallback, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
