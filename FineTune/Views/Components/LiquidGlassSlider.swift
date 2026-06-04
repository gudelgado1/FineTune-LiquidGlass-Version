// FineTune/Views/Components/LiquidGlassSlider.swift
import SwiftUI

/// Native macOS 26 slider with Liquid Glass thumb.
/// Track colour matches the system volume slider exactly:
///   • idle:    #0073F8
///   • dragging: #005ADE
struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let showUnityMarker: Bool
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isEditing = false

    /// Idle track fill — matches macOS 26 system volume slider at rest.
    private static let tintIdle    = Color(red: 0/255, green: 115/255, blue: 248/255) // #0073F8
    /// Active track fill — matches macOS 26 system volume slider while dragging.
    private static let tintActive  = Color(red: 0/255, green:  90/255, blue: 222/255) // #005ADE

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        showUnityMarker: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.showUnityMarker = showUnityMarker
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        ZStack {
            // Optional unity marker at the 50 % position (used for boost sliders).
            if showUnityMarker {
                HStack {
                    Spacer()
                    Rectangle()
                        .fill(DesignTokens.Colors.unityMarker)
                        .frame(width: 1.5, height: 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            Slider(value: $value, in: range) { editing in
                isEditing = editing
                onEditingChanged?(editing)
            }
            .controlSize(.mini)
            .tint(isEditing ? Self.tintActive : Self.tintIdle)
        }
        .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
    }
}

// MARK: - Preview

#Preview("Liquid Glass Slider") {
    struct PreviewWrapper: View {
        @State private var value: Double = 0.5

        var body: some View {
            VStack(spacing: 30) {
                LiquidGlassSlider(value: $value, showUnityMarker: true)
                    .frame(width: 200)

                Text("\(Int(value * 200))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
