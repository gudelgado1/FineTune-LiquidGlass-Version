import SwiftUI
import Darwin

/// Recovered material boundary, independent of the OSDManager presentation API.
/// This creates our own SwiftUI glass; it cannot launch the classic system HUD.
@available(macOS 26.0, *)
@MainActor
enum HUDGlassMaterial {
    static let controlCenter: Glass? = {
        // BetterDisplay 5.2.1 checks this layout before using the private getter.
        // Do not reinterpret a future Glass representation after an OS update.
        guard MemoryLayout<Glass>.size == 40,
              MemoryLayout<Glass>.stride == 40,
              MemoryLayout<Glass>.alignment == 8,
              let handle = dlopen("/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(handle, "$s7SwiftUI6_GlassV13controlCenterACvgZ") else { return nil }
        // The framework stays loaded while the material's native storage is alive.
        typealias Getter = @convention(thin) () -> Glass
        return unsafeBitCast(symbol, to: Getter.self)()
    }()

    static var backendDescription: String { controlCenter == nil ? "Clear (public fallback)" : "Control Center" }

    static func material(for scheme: ColorScheme) -> Glass {
        if let controlCenter { return controlCenter }
        // These are material tints, not opaque layers between glass and desktop.
        return .clear.tint(scheme == .dark ? .black.opacity(0.4) : .white.opacity(0.8))
    }
}

struct HUDGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if DEBUG
        let lab = ProcessInfo.processInfo.arguments.contains("--hud-material-lab")
        if lab && ProcessInfo.processInfo.arguments.contains("--hud-material-opaque-control") {
            content.background(.black, in: shape)
        } else if lab && ProcessInfo.processInfo.arguments.contains("--hud-material-legacy-control") {
            if #available(macOS 26.0, *) {
                content.background(.black.opacity(0.55), in: shape).glassEffect(.regular, in: shape)
            } else { content.background(.black.opacity(0.55), in: shape) }
        } else {
            surface(content, shape: shape)
        }
        #else
        surface(content, shape: shape)
        #endif
    }

    @ViewBuilder private func surface(_ content: Content, shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(HUDGlassMaterial.material(for: colorScheme), in: shape)
        } else {
            content.background {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow).clipShape(shape)
            }
        }
    }
}
