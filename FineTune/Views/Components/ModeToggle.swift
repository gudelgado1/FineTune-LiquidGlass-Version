// FineTune/Views/Components/ModeToggle.swift
import SwiftUI

/// A native segmented control for switching between single and multi device modes
struct ModeToggle: View {
    @Binding var mode: DeviceSelectionMode

    var body: some View {
        Picker("Selection Mode", selection: $mode.animation(.spring(response: 0.25, dampingFraction: 0.8))) {
            Text("Single").tag(DeviceSelectionMode.single)
            Text("Multi").tag(DeviceSelectionMode.multi)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - Previews

#Preview("Mode Toggle - Single Selected") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.lg) {
            ModeToggle(mode: .constant(.single))
            ModeToggle(mode: .constant(.multi))
        }
        .frame(width: 180)
    }
}

#Preview("Mode Toggle Interactive") {
    struct InteractivePreview: View {
        @State private var mode: DeviceSelectionMode = .single

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.md) {
                    ModeToggle(mode: $mode)
                        .frame(width: 180)

                    Text("Current: \(mode == .single ? "Single" : "Multi")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    return InteractivePreview()
}
