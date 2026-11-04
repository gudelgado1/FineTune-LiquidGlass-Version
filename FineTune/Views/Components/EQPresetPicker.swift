// FineTune/Views/Components/EQPresetPicker.swift
import SwiftUI

// MARK: - Unified Picker Types

/// Sections for the EQ preset picker — "My Presets" at top, then built-in categories.
enum EQPickerSection: Identifiable, Hashable {
    case myPresets
    case builtIn(EQPreset.Category)

    var id: String {
        switch self {
        case .myPresets: return "my-presets"
        case .builtIn(let cat): return cat.rawValue
        }
    }

    var title: String {
        switch self {
        case .myPresets: return "My Presets"
        case .builtIn(let cat): return cat.rawValue
        }
    }
}

/// A single item in the picker — wraps either a built-in or user preset.
struct EQPickerItem: Identifiable, Hashable {
    let id: String
    let name: String
    let builtInPreset: EQPreset?
    let userPresetID: UUID?

    init(builtIn preset: EQPreset) {
        self.id = "builtin-\(preset.id)"
        self.name = preset.name
        self.builtInPreset = preset
        self.userPresetID = nil
    }

    init(user preset: UserEQPreset) {
        self.id = "user-\(preset.id.uuidString)"
        self.name = preset.name
        self.builtInPreset = nil
        self.userPresetID = preset.id
    }

    var isUserPreset: Bool { userPresetID != nil }

    static func == (lhs: EQPickerItem, rhs: EQPickerItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - EQ Preset Picker

struct EQPresetPicker: View {
    let selectedItem: EQPickerItem?
    let userPresets: [UserEQPreset]
    let onBuiltInSelected: (EQPreset) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    private var sections: [EQPickerSection] {
        var result: [EQPickerSection] = []
        if !userPresets.isEmpty {
            result.append(.myPresets)
        }
        result.append(contentsOf: EQPreset.Category.allCases.map { .builtIn($0) })
        return result
    }

    private func items(for section: EQPickerSection) -> [EQPickerItem] {
        switch section {
        case .myPresets:
            return userPresets.map { EQPickerItem(user: $0) }
        case .builtIn(let category):
            return EQPreset.presets(for: category).map { EQPickerItem(builtIn: $0) }
        }
    }

    private func handleSelect(_ item: EQPickerItem) {
        if let preset = item.builtInPreset {
            onBuiltInSelected(preset)
        } else if let userID = item.userPresetID,
                  let userPreset = userPresets.first(where: { $0.id == userID }) {
            onUserPresetSelected(userPreset)
        }
    }

    /// A preset selects a curve; the app keeps ownership of the EQ enable state.
    private var selection: Binding<String?> {
        Binding(
            get: { selectedItem?.id },
            set: { id in
                guard let id,
                      let item = sections.flatMap({ items(for: $0) }).first(where: { $0.id == id }) else { return }
                handleSelect(item)
            }
        )
    }

    var body: some View {
        // Native menu tracking preserves the parent panel's key status. A custom
        // keyable child panel made the parent's glass switch to its inactive
        // backdrop every time the preset list opened.
        Menu {
            Picker("Preset", selection: selection) {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(items(for: section)) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if !userPresets.isEmpty {
                Divider()
                Menu("Delete User Preset") {
                    ForEach(userPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            onDeleteUserPreset(preset.id)
                        }
                    }
                }
            }
        } label: {
            Text(selectedItem?.name ?? "Custom")
        }
        .menuStyle(.borderedButton)
        .menuActionDismissBehavior(.enabled)
        .controlSize(.small)
        .frame(width: 100)
        .help("Choose an EQ preset")
        .accessibilityLabel("EQ preset")
        .accessibilityValue(selectedItem?.name ?? "Custom")
    }
}

// MARK: - Previews

#Preview("With User Presets") {
    let sampleUser = [
        UserEQPreset(name: "My Bass Boost", settings: EQSettings(bandGains: [6, 5, 4, 0, 0, 0, 0, 0, 0, 0])),
        UserEQPreset(name: "Studio Monitor", settings: EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 1, 2, 2, 2]))
    ]
    VStack(spacing: 20) {
        EQPresetPicker(
            selectedItem: EQPickerItem(builtIn: .rock),
            userPresets: sampleUser,
            onBuiltInSelected: { _ in },
            onUserPresetSelected: { _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
        EQPresetPicker(
            selectedItem: nil,
            userPresets: [],
            onBuiltInSelected: { _ in },
            onUserPresetSelected: { _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding()
    .background(Color.black)
}
