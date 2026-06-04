// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A frosted glass background using NSVisualEffectView, Apple's documented
/// translucent material primitive. The default `.popover` material renders
/// as proper light/dark glass and matches the platform Control Center and
/// Notification Center surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    /// Apple's documented material for popover and menu-bar panels. Renders
    /// vibrant translucency in both appearances. The previous `.hudWindow`
    /// default was designed for dark floating overlays and washed out badly
    /// in light mode.
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Colors

extension Color {
    /// Popup background overlay - uses theme-aware color from DesignTokens
    /// Darker than before for more contrast with floating glass rows
    static var popupBackgroundOverlay: Color { DesignTokens.Colors.popupOverlay }
}

// MARK: - View Extensions

extension View {
    /// Applies the popup's Liquid Glass background.
    ///
    /// On **macOS 26+** this uses SwiftUI's native `.glassEffect(in:)` API —
    /// the documented way to adopt Liquid Glass on custom views. The system
    /// handles blur, reflections, color sampling, and accessibility adaptations
    /// (Reduce Transparency, etc.) automatically.
    ///
    /// On **macOS 14/15** it falls back to the traditional `NSVisualEffectView`
    /// approach via `VisualEffectBackground(.sidebar, .behindWindow)`.
    ///
    /// Apple's own guidance: "Reduce your use of custom backgrounds in controls
    /// and navigation elements — any custom backgrounds might overlay or interfere
    /// with Liquid Glass." So on macOS 26 we let the system do everything and
    /// add no tint overlay.
    func darkGlassBackground(cornerRadius: CGFloat = DesignTokens.Dimensions.cornerRadius) -> some View {
        self.modifier(GlassBackgroundModifier(cornerRadius: cornerRadius))
    }

    /// Applies the lifted-card background used by the EQ panel.
    /// Light reads as a white card on the popup glass; dark reads as a
    /// translucent surface on the dark glass. Replaces the prior recessed
    /// treatment which read as a heavy gray block on whiter light glass.
    func eqCardBackground() -> some View {
        modifier(LiftedCardBackgroundModifier())
    }

    /// Small Liquid Glass chip background — for capsules, pills, badges,
    /// floating controls. macOS 26 uses `.glassEffect(.regular, in: shape)`;
    /// older releases fall back to `.regularMaterial`. Call this instead of
    /// hand-rolling `.background(.regularMaterial, in: shape)` everywhere.
    func glassChip<S: Shape>(in shape: S = Capsule()) -> some View {
        modifier(GlassChipModifier(shape: AnyShape(shape)))
    }

    /// Liquid Glass panel background for free-floating surfaces like the on-screen
    /// volume HUD. macOS 26 uses native `.glassEffect(in: .rect(cornerRadius:))`
    /// — the system supplies blur, refraction, edge highlight, and accessibility
    /// adaptations, so no custom border is layered (Apple advises against custom
    /// backgrounds that interfere with Liquid Glass). macOS 14/15 falls back to
    /// the prior `.regularMaterial` fill plus a hairline `hudBorder`.
    func glassPanel(cornerRadius: CGFloat) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass Background Modifier

/// Applies the popup glass background, choosing the best implementation for
/// the running OS version.
///
/// macOS 26+: `.glassEffect(in: .rect(cornerRadius:))` — the documented
/// SwiftUI API for Liquid Glass on custom views. The system handles blur,
/// vibrancy, color sampling, and accessibility settings automatically. We add
/// no custom tint overlay; Apple's own guidance warns against custom
/// backgrounds that can interfere with Liquid Glass.
///
/// macOS 14/15: `VisualEffectBackground(.sidebar, .behindWindow)` + the
/// `popupOverlay` tint — the pre-26 NSVisualEffectView approach.
struct GlassBackgroundModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // `.regular` — the standard Liquid Glass variant. The earlier
            // darkness-over-light-desktop concern was actually the HUD rendering
            // dimmed as a non-key window; now that the HUD is a key window it's
            // vibrant, so we keep the default (more defined) glass everywhere.
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(Color.popupBackgroundOverlay)
                .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
        }
    }
}

// MARK: - Glass Chip Modifier

/// Small reusable Liquid Glass background for chips/capsules/badges.
/// Centralizes the previously scattered material fills so every small floating
/// surface adopts Liquid Glass uniformly on macOS 26 and degrades on 14/15.
/// Uses the standard `.regular` variant; the caller's `shape` is kept.
struct GlassChipModifier: ViewModifier {
    let shape: AnyShape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

// MARK: - Glass Panel Modifier (HUD)

/// Liquid Glass background for floating panels (the volume HUD). See
/// `View.glassPanel(cornerRadius:)`.
struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // `.regular` to match the popup. The HUD panel is a key window, so this
            // renders vibrant (not the dimmed inactive look) just like the popup.
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(DesignTokens.Colors.hudBorder, lineWidth: 1)
                }
        }
    }
}

// MARK: - Lifted Card Background Modifier (EQ panel)

/// Lifted-card background used by the EQ panel.
/// Light: opaque-ish white card on the popup glass with a hairline edge
/// and a soft shadow that lifts the card off the surface. Dark: translucent
/// white on the dark glass with a slightly stronger hairline. Tokens come
/// from `DesignTokens.Colors.eqCardBackground` and `eqCardBorder`.
///
/// The shadow uses a literal `Color.black.opacity(0.06)`. Shadows are a
/// depth cue, not a chromatic surface, and remain readable in both modes
/// without an appearance-aware token.
struct LiftedCardBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .fill(DesignTokens.Colors.eqCardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(0.06),
                radius: 1.5,
                x: 0,
                y: 0.5
            )
    }
}

// MARK: - Previews

#Preview("Dark Glass Popup Background") {
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES")
            .sectionHeaderStyle()
        Text("Dark frosted glass background")
            .foregroundStyle(.primary)
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
    .environment(\.colorScheme, .dark)
}

#Preview("EQ Card - Lifted") {
    VStack(spacing: 8) {
        Text("EQ Card - Lifted")
            .foregroundStyle(.secondary)
        HStack {
            ForEach(0..<5) { _ in
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 20, height: 60)
            }
        }
    }
    .padding()
    .eqCardBackground()
    .padding()
    .darkGlassBackground()
}
