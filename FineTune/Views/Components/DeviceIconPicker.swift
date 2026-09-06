// FineTune/Views/Components/DeviceIconPicker.swift
import AppKit
import AudioToolbox
import SwiftUI

/// Popover grid for choosing a device's menu-bar / row icon.
///
/// The automatic icon is derived from the device's name and transport, which
/// guesses wrong for anything generic ("USB Audio CODEC") — this lets the user
/// pin the right glyph per device. "Automatic" clears the override rather than
/// storing today's guess, so the device keeps following the derived icon if the
/// heuristics improve later.
struct DeviceIconPicker: View {
    let deviceName: String
    let transport: TransportType
    /// Currently stored override, or nil while the device uses its automatic icon.
    let currentOverride: String?
    /// `nil` clears the override.
    let onSelect: (String?) -> Void

    @State private var query = ""
    @State private var hoveredSymbol: String?
    @Environment(\.dismiss) private var dismiss

    private static let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 7)

    private var automaticSymbol: String {
        AudioDeviceID.iconSymbol(forName: deviceName, transport: transport)
    }

    private var suggested: [String] {
        DeviceIconCatalog.suggested(forName: deviceName, transport: transport)
    }

    private var results: [String] {
        DeviceIconCatalog.matching(query).map(\.symbol)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !isSearching {
                        section("Suggested", symbols: suggested)
                    }
                    section(isSearching ? "Results" : "All Icons", symbols: results)
                    if results.isEmpty {
                        Text("No icons match “\(query)”.")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 240)
            .scrollIndicators(.never)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text(deviceName)
                .font(DesignTokens.Typography.rowNameBold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Automatic") {
                onSelect(nil)
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(currentOverride == nil
                             ? DesignTokens.Colors.textSecondary
                             : DesignTokens.Colors.accentPrimary)
            .disabled(currentOverride == nil)
            .help("Use the icon derived from the device name and connection")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            TextField("Search icons", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DesignTokens.Colors.deviceBadgeMonoFill)
        )
    }

    @ViewBuilder
    private func section(_ title: String, symbols: [String]) -> some View {
        if !symbols.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    ForEach(symbols, id: \.self) { symbol in
                        cell(symbol)
                    }
                }
            }
        }
    }

    private func cell(_ symbol: String) -> some View {
        // The override wins; with none, the automatic symbol reads as current.
        let isCurrent = currentOverride == symbol || (currentOverride == nil && symbol == automaticSymbol)
        return Button {
            onSelect(symbol)
            dismiss()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(cellFill(isCurrent: isCurrent, isHovered: hoveredSymbol == symbol))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent
                                      ? DesignTokens.Colors.accentPrimary.opacity(0.7)
                                      : Color.clear,
                                      lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredSymbol = $0 ? symbol : (hoveredSymbol == symbol ? nil : hoveredSymbol) }
        .help(symbol)
        .accessibilityLabel(symbol)
    }

    /// Hover reads as a hint, the current selection as a statement — so the
    /// selected cell keeps its stronger fill even while hovered.
    private func cellFill(isCurrent: Bool, isHovered: Bool) -> Color {
        if isCurrent { return DesignTokens.Colors.accentPrimary.opacity(0.22) }
        if isHovered { return DesignTokens.Colors.deviceBadgeMonoFill }
        return .clear
    }
}
