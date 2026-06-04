// FineTune/Views/Settings/Components/HUDStyleSegmentedControl.swift
import SwiftUI

/// Native segmented picker for HUD style. Adopts Liquid Glass automatically
/// on macOS 26 via `NSSegmentedControl`.
@MainActor
struct HUDStyleSegmentedControl: View {
    @Binding var selection: HUDStyle

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(HUDStyle.allCases) { style in
                Text(style.id.capitalized).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minWidth: 140)
    }
}
