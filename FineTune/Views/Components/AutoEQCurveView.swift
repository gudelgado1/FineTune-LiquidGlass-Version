// FineTune/Views/Components/AutoEQCurveView.swift
import Charts
import SwiftUI

// MARK: - AutoEQ Curve View
//
// Renders the magnitude response of an AutoEQProfile as a smooth curve over
// a log-frequency X axis and a linear-dB Y axis. Drawn with SwiftUI Canvas
// for cheap repaints and no view-tree pressure.
//
// Visual language matches the EQ panel: hairline grid, dimmed reference
// label at 0 dB, accent-tinted fill below the curve, soft border around the
// plot area. Adapts automatically to light/dark via `DesignTokens`.

struct AutoEQCurveView: View {
    /// The profile to render. When `nil`, the view shows an empty state
    /// (flat baseline at 0 dB with dimmed grid).
    let profile: AutoEQProfile?

    /// Whether the correction is currently active. When false the curve is
    /// dimmed so the visual emphasizes that the user can see the profile but
    /// it isn't shaping audio right now.
    var isCorrectionEnabled: Bool = true

    // MARK: - Layout / Range Constants

    private let minFrequency: Double = 20
    private let maxFrequency: Double = 20_000
    private let dbRange: ClosedRange<Double> = -15...15
    private let sampleCount: Int = 220

    /// X-grid lines (Hz) and their labels. Major decade ticks only.
    private let xGridLines: [(value: Double, label: String)] = [
        (100, "100"),
        (1_000, "1k"),
        (10_000, "10k"),
    ]

    /// Y-grid lines (dB) and their labels.
    private let yGridLines: [(value: Double, label: String)] = [
        (10, "+10"),
        (0, "0"),
        (-10, "−10"),
    ]

    // MARK: - Computed Curve

    private var frequencies: [Double] {
        AutoEQResponseCalculator.logSpacedFrequencies(
            from: minFrequency,
            to: maxFrequency,
            count: sampleCount
        )
    }

    private var response: [Double] {
        guard let profile, !profile.filters.isEmpty else {
            return [Double](repeating: 0, count: sampleCount)
        }
        return AutoEQResponseCalculator.magnitudeDB(
            of: profile.filters,
            at: frequencies,
            sampleRate: profile.optimizedSampleRate
        )
    }

    // MARK: - Body

    private var points: [CurvePoint] {
        zip(frequencies, response).map { frequency, db in
            CurvePoint(
                frequency: frequency,
                db: min(max(db, dbRange.lowerBound), dbRange.upperBound)
            )
        }
    }

    var body: some View {
        let accent = DesignTokens.Colors.accentPrimary
        let curveOpacity = isCorrectionEnabled ? 1.0 : 0.45
        let fillOpacity = isCorrectionEnabled ? 0.20 : 0.08

        Chart {
            // Filling toward the 0-dB baseline keeps the emphasis on deviation from flat.
            ForEach(points) { point in
                AreaMark(x: .value("Frequency", point.frequency), yStart: .value("Baseline", 0), yEnd: .value("Gain", point.db))
                    .foregroundStyle(accent.opacity(fillOpacity))
                LineMark(x: .value("Frequency", point.frequency), y: .value("Gain", point.db))
                    .foregroundStyle(accent.opacity(curveOpacity))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            RuleMark(y: .value("Flat", 0))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
        }
        .chartXScale(domain: minFrequency...maxFrequency, type: .log)
        .chartYScale(domain: dbRange)
        .chartXAxis {
            AxisMarks(values: xGridLines.map(\.value)) { value in
                AxisGridLine().foregroundStyle(DesignTokens.Colors.separator)
                AxisValueLabel {
                    if let frequency = value.as(Double.self) {
                        Text(frequencyLabel(frequency))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yGridLines.map(\.value)) { value in
                AxisGridLine().foregroundStyle(DesignTokens.Colors.separator)
                AxisValueLabel {
                    if let db = value.as(Double.self) {
                        Text(dbLabel(db))
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("AutoEQ correction curve")
        .frame(height: 130)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DesignTokens.Colors.eqCardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
        }
    }

    // MARK: - Labels

    private func frequencyLabel(_ frequency: Double) -> String {
        (xGridLines.first { $0.value == frequency }?.label ?? "") + " Hz"
    }

    private func dbLabel(_ db: Double) -> String {
        yGridLines.first { $0.value == db }?.label ?? ""
    }
}

private struct CurvePoint: Identifiable {
    let frequency: Double
    let db: Double
    var id: Double { frequency }
}

// MARK: - Previews

#Preview("With profile (Sennheiser HD 600 style)") {
    AutoEQCurveView(
        profile: AutoEQProfile(
            id: "preview",
            name: "Sennheiser HD 600",
            source: .bundled,
            preampDB: -6.0,
            filters: [
                AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 2.5, q: 0.7),
                AutoEQFilter(type: .peaking, frequency: 2400, gainDB: -3.0, q: 1.5),
                AutoEQFilter(type: .peaking, frequency: 4900, gainDB: 4.0, q: 1.4),
                AutoEQFilter(type: .peaking, frequency: 6900, gainDB: -5.5, q: 4.0),
                AutoEQFilter(type: .highShelf, frequency: 10000, gainDB: 1.5, q: 0.7),
            ]
        ),
        isCorrectionEnabled: true
    )
    .padding()
    .frame(width: 360)
}

#Preview("Empty (no profile)") {
    AutoEQCurveView(profile: nil)
        .padding()
        .frame(width: 360)
}

#Preview("Disabled correction") {
    AutoEQCurveView(
        profile: AutoEQProfile(
            id: "preview-2",
            name: "AKG K712",
            source: .bundled,
            preampDB: -4.5,
            filters: [
                AutoEQFilter(type: .peaking, frequency: 80, gainDB: 3.0, q: 0.8),
                AutoEQFilter(type: .peaking, frequency: 3500, gainDB: -4.0, q: 2.0),
                AutoEQFilter(type: .peaking, frequency: 8500, gainDB: 2.5, q: 1.5),
            ]
        ),
        isCorrectionEnabled: false
    )
    .padding()
    .frame(width: 360)
}
