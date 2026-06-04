// FineTune/Views/Settings/Components/IconStyleSegmentedControl.swift
import SwiftUI

/// Compact segmented selector for `MenuBarIconStyle`. Lifted out of the
/// previous `SettingsIconPickerRow` so it can drop into a `CardRow`'s
/// trailing slot without dragging row chrome along with it.
@MainActor
struct IconStyleSegmentedControl: View {
    @Binding var selection: MenuBarIconStyle

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(MenuBarIconStyle.allCases) { style in
                Group {
                    if style.isSystemSymbol {
                        Image(systemName: style.iconName)
                    } else {
                        Image(style.iconName)
                    }
                }
                .tag(style)
                .accessibilityLabel(style.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 160)
    }
}

// MARK: - Previews

#Preview("Icon Style Segmented Control") {
    VStack(spacing: 16) {
        IconStyleSegmentedControl(selection: .constant(.default))
        IconStyleSegmentedControl(selection: .constant(.speaker))
        IconStyleSegmentedControl(selection: .constant(.equalizer))
    }
    .padding()
    .frame(width: 300)
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
