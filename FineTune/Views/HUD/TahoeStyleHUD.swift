// FineTune/Views/HUD/TahoeStyleHUD.swift
import SwiftUI

/// 300×72 interactive volume pill matching the macOS Tahoe volume HUD: the
/// device name on top, then a min-speaker icon, a dotted segmented track with a
/// white knob, and a max-speaker icon. No percentage readout (matches macOS).
struct TahoeStyleHUD: View {
    let sliderFraction: Float
    let mute: Bool
    let deviceName: String
    var onSliderChange: ((Float) -> Void)? = nil
    var onHoverChange: ((Bool) -> Void)? = nil

    // MARK: - Constants

    static let nameFont: Font = DesignTokens.Typography.rowNameBold

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 22

    // MARK: - State

    @State private var dragValue: Double? = nil

    // MARK: - Derived state

    private var displayFloat: Float {
        if let dragValue { return Float(max(0, min(1, dragValue))) }
        return max(0, min(1, sliderFraction))
    }

    private var displayMute: Bool {
        if let dragValue { return Int((dragValue * 100).rounded()) == 0 }
        return mute
    }

    /// macOS flanks the track with a fixed min/max speaker pair rather than a
    /// level-dependent glyph; the only state the left icon reflects is mute.
    private var minIconName: String {
        displayMute ? "speaker.slash.fill" : "speaker.fill"
    }

    private var accessibilityDescription: String {
        let device = deviceName.isEmpty ? "Unknown device" : deviceName
        let percent = Int((displayFloat * 100).rounded())
        if displayMute { return "\(device), muted, volume at \(percent) percent" }
        return "\(device), volume \(percent) percent"
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(displayFloat) },
            set: { newValue in
                dragValue = newValue
                onSliderChange?(Float(newValue))
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceName.isEmpty ? " " : deviceName)
                .font(Self.nameFont)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Image(systemName: minIconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(displayMute
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 16, height: 16, alignment: .center)

                // Native macOS 26 slider. `.primary` (not a fixed white) keeps the
                // filled track visible under BOTH HUD themes: near-white in Dark
                // (matching the system volume HUD) and near-black in Light, where a
                // hardcoded white fill vanished against the light glass.
                Slider(value: sliderBinding, in: 0...1)
                    .controlSize(.regular)
                    .tint(.primary)
                    .opacity(displayMute ? 0.55 : 1.0)
                    .scrollWheelStep(sliderBinding, in: 0.0...1.0)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.hudTileActive)
                    .frame(width: 20, height: 16, alignment: .center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        // Liquid Glass, vibrant now that the HUD panel is a key window — identical
        // to the popup, which is also `.glassEffect(.clear)` in a key window.
        .glassPanel(cornerRadius: Self.cornerRadius)
        // Crisp hairline edge to match the popup.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.popupBorder, lineWidth: 0.5)
        }
        // Hard-clip to the HUD's rounded shape so NOTHING renders outside it — in
        // particular the Liquid Glass ambient shadow, which otherwise leaks into the
        // panel's rectangular corners as a gray box on light backdrops.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onHover { hovering in
            onHoverChange?(hovering)
        }
        .onChange(of: sliderFraction) { _, _ in
            // External source pushed a value; drop the sticky drag snapshot.
            dragValue = nil
        }
        .onChange(of: mute) { _, _ in
            dragValue = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }
}

#Preview("Tahoe — mid volume") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — muted") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: true, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — long name") {
    TahoeStyleHUD(sliderFraction: 0.75, mute: false,
                  deviceName: "Ronit's MacBook Pro Speakers (Built-in Audio Output)")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — empty name") {
    TahoeStyleHUD(sliderFraction: 0.25, mute: false, deviceName: "")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — max volume") {
    TahoeStyleHUD(sliderFraction: 1.0, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — zero volume") {
    TahoeStyleHUD(sliderFraction: 0.0, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.black)
}

#Preview("Tahoe — light washout") {
    TahoeStyleHUD(sliderFraction: 0.5, mute: false, deviceName: "Ronit's AirPods Pro")
        .padding()
        .background(Color.white)
}
