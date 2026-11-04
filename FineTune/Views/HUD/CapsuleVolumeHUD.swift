import SwiftUI

/// Rounded GlassOSD reconstruction. Geometry comes from BetterDisplay 5.2.1;
/// the glass samples the live compositor, never a cached desktop image.
struct CapsuleVolumeHUD: View {
    let sliderFraction: Float
    let mute: Bool
    let deviceName: String
    var onSliderChange: ((Float) -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil
    var onDragChange: ((Bool) -> Void)? = nil

    static let nameFont = DesignTokens.Typography.rowNameBold
    static let capsuleSize = CGSize(width: 308, height: 65)
    static let effectMargin: CGFloat = 40
    static let cornerRadius: CGFloat = 32.5
    private static let trackWidth: CGFloat = 214
    @State private var dragValue: Double?
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var endpointFeedback = HUDEndpointFeedback()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func normalizedFraction(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0
    }
    static func containsDragEnd(_ location: CGPoint) -> Bool {
        let point = CGPoint(x: location.x + 62, y: location.y + (capsuleSize.height - 28) / 2)
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: CGRect(origin: .zero, size: capsuleSize)).contains(point)
    }
    private var value: Double { Self.normalizedFraction(dragValue ?? Double(sliderFraction)) }
    private var isMuted: Bool { dragValue.map { Self.normalizedFraction($0) == 0 } ?? mute }
    private var symbol: String {
        if isMuted { return "speaker.slash.fill" }
        switch value {
        case ...0: return "speaker.slash.fill"
        case ...0.33: return "speaker.wave.1.fill"
        case ...0.66: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
    private var binding: Binding<Double> { Binding(get: { value }, set: write) }
    // The supplied system/BetterDisplay references use the white OSD foreground.
    // GlassOSD has a force-white presentation branch separate from its theme.
    // Keep that presentation here; the material still inherits the app theme.
    private var ink: Color { .white }
    private func write(_ proposed: Double) {
        let next = Self.normalizedFraction(proposed)
        dragValue = next
        onSliderChange?(Float(next))
    }
    private var accessibleValue: String {
        let name = deviceName.isEmpty ? "Unknown device" : deviceName
        return isMuted ? "\(name), muted, volume at \(Int((value * 100).rounded())) percent"
                       : "\(name), volume \(Int((value * 100).rounded())) percent"
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 22)
            Image(systemName: symbol)
                .font(.system(size: 27))
                .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: endpointFeedback.generation)
                .symbolEffectsRemoved(reduceMotion)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Spacer().frame(width: 12)
            track
                .frame(width: Self.trackWidth, height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged {
                        if !isDragging { isDragging = true; onDragChange?(true) }
                        write($0.location.x / Self.trackWidth)
                    }
                    .onEnded {
                        // Pointer capture can suppress hover events during a
                        // drag. Resolve its final position before releasing the
                        // hold, including clicks delivered without mouseMoved.
                        isHovered = Self.containsDragEnd($0.location)
                        isDragging = false
                        onHoverChange?(isHovered)
                        onDragChange?(false)
                    })
                .scrollWheelStep(binding, in: 0...1)
            Spacer().frame(width: 32)
        }
        .foregroundStyle(ink)
        .frame(width: Self.capsuleSize.width, height: Self.capsuleSize.height)
        .modifier(HUDGlassSurface(cornerRadius: Self.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: isHovered = true; onHoverChange?(true)
            case .ended: isHovered = false; onHoverChange?(false)
            }
        }
        .onChange(of: sliderFraction) { _, _ in dragValue = nil }
        .onChange(of: mute) { _, _ in dragValue = nil }
        .onAppear { endpointFeedback.update(level: value, muted: isMuted, reduceMotion: reduceMotion) }
        .onChange(of: value) { _, level in
            endpointFeedback.update(level: level, muted: isMuted, reduceMotion: reduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: write(value + 1.0 / 16)
            case .decrement: write(value - 1.0 / 16)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        HUDVolumeSlider(level: isMuted ? 0 : value, interactive: isHovered || isDragging, dragging: isDragging)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isHovered || isDragging)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isDragging)
            .animation(!isDragging && dragValue == nil && !mute ? .easeOut(duration: HUDMotionProfile.levelDuration) : nil,
                       value: isMuted ? 0 : value)
    }
}

/// An endpoint arrival is distinct from an ordinary glyph/volume update.
/// Remaining at a bound does not restart a bounce on every auto-repeat.
struct HUDEndpointFeedback {
    private var previousLevel: Double?
    private(set) var generation = 0

    mutating func update(level: Double, muted: Bool, reduceMotion: Bool) {
        let next = CapsuleVolumeHUD.normalizedFraction(level)
        defer { previousLevel = next }
        guard !reduceMotion, previousLevel != next,
              next == 0 || (next == 1 && !muted) else { return }
        generation &+= 1
    }
}

/// Rest: sixteen segments. Pointer entry: continuous track and18×14pt thumb.
/// The larger pressed glass thumb follows the supplied native recording; the
/// capsule and its hit target never resize during this transition.
struct HUDVolumeSlider: View {
    let level: Double
    let interactive: Bool
    let dragging: Bool
    private var fraction: Double { CapsuleVolumeHUD.normalizedFraction(level) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                HUDVolumeTrack(level: fraction, ink: .white)
                    .frame(height: 4).clipShape(Capsule())
                    .opacity(interactive ? 0 : 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(.white).frame(width: geometry.size.width * fraction)
                }
                .frame(height: 4)
                .opacity(interactive ? 1 : 0)
                thumb
                    .frame(width: dragging ? 24 : 18, height: dragging ? 18 : 14)
                    .position(x: geometry.size.width * fraction, y: geometry.size.height / 2)
                    .opacity(interactive ? 1 : 0)
            }
            .frame(height: geometry.size.height)
        }
    }

    @ViewBuilder private var thumb: some View {
        if dragging {
            if #available(macOS 26.0, *) {
                Capsule().fill(.white.opacity(0.08))
                    .glassEffect(.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(.black.opacity(0.7), lineWidth: 0.6))
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.7), lineWidth: 0.6))
            }
        } else {
            Capsule().fill(.white).shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
    }
}

/// Animatable canvas input lets keyboard steps move through fractional segments.
/// Pointer drags and mute use the parent view's immediate transaction.
nonisolated struct HUDVolumeTrack: View, Animatable {
    var level: Double
    let ink: Color
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    @MainActor var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1
            let segment = (size.width - 15 * gap) / 16
            let level = level.isFinite ? max(0, min(1, level)) : 0
            for index in 0..<16 {
                let rect = CGRect(x: CGFloat(index) * (segment + gap), y: 0, width: segment, height: size.height)
                context.fill(Path(rect), with: .color(ink.opacity(0.1)))
                let fill = max(0, min(1, level * 16 - Double(index)))
                if fill > 0 {
                    context.fill(Path(CGRect(x: rect.minX, y: 0, width: segment * fill, height: size.height)), with: .color(ink))
                }
            }
        }
    }
}
