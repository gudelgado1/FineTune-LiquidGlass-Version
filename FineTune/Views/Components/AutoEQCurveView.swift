// FineTune/Views/Components/AutoEQCurveView.swift
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

    var body: some View {
        Canvas(opaque: false) { context, size in
            drawGrid(context: &context, size: size)
            drawZeroLine(context: &context, size: size)
            drawCurve(context: &context, size: size)
            drawAxisLabels(context: &context, size: size)
        }
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

    // MARK: - Drawing

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let plotRect = CGRect(origin: .zero, size: size)
        let gridColor = DesignTokens.Colors.glassRowBorder.opacity(0.65)

        // Vertical grid lines (frequency)
        for line in xGridLines {
            let x = xPosition(forFrequency: line.value, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }

        // Horizontal grid lines (dB)
        for line in yGridLines where line.value != 0 {
            let y = yPosition(forDB: line.value, in: plotRect)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    private func drawZeroLine(context: inout GraphicsContext, size: CGSize) {
        let zeroY = yPosition(forDB: 0, in: CGRect(origin: .zero, size: size))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: zeroY))
        path.addLine(to: CGPoint(x: size.width, y: zeroY))
        context.stroke(
            path,
            with: .color(DesignTokens.Colors.glassRowBorder.opacity(0.9)),
            style: StrokeStyle(lineWidth: 0.75, dash: [3, 2])
        )
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        let plotRect = CGRect(origin: .zero, size: size)
        let points = curvePoints(in: plotRect)
        guard points.count > 1 else { return }

        let accent = DesignTokens.Colors.accentPrimary
        let curveOpacity = isCorrectionEnabled ? 1.0 : 0.45
        let fillOpacity = isCorrectionEnabled ? 0.20 : 0.08

        // Stroked curve path.
        var stroke = Path()
        stroke.move(to: points[0])
        for p in points.dropFirst() {
            stroke.addLine(to: p)
        }
        context.stroke(
            stroke,
            with: .color(accent.opacity(curveOpacity)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )

        // Filled area: curve down to 0 dB line, gradient toward the curve.
        // Filling toward the 0-dB baseline (rather than the bottom of the
        // canvas) keeps the visual emphasis on deviation from flat.
        let zeroY = yPosition(forDB: 0, in: plotRect)
        var fill = Path()
        fill.move(to: CGPoint(x: points.first!.x, y: zeroY))
        for p in points {
            fill.addLine(to: p)
        }
        fill.addLine(to: CGPoint(x: points.last!.x, y: zeroY))
        fill.closeSubpath()
        context.fill(fill, with: .color(accent.opacity(fillOpacity)))
    }

    private func drawAxisLabels(context: inout GraphicsContext, size: CGSize) {
        let plotRect = CGRect(origin: .zero, size: size)
        let labelColor = DesignTokens.Colors.textTertiary

        // X labels along the bottom.
        for line in xGridLines {
            let x = xPosition(forFrequency: line.value, in: plotRect)
            let text = Text(line.label + " Hz")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(labelColor)
            context.draw(
                text,
                at: CGPoint(x: x + 3, y: size.height - 8),
                anchor: .leading
            )
        }

        // Y labels along the left edge.
        for line in yGridLines {
            let y = yPosition(forDB: line.value, in: plotRect)
            let text = Text(line.label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(labelColor)
            context.draw(
                text,
                at: CGPoint(x: 4, y: y - 1),
                anchor: .leading
            )
        }
    }

    // MARK: - Geometry helpers

    private func xPosition(forFrequency f: Double, in rect: CGRect) -> CGFloat {
        let logF = log10(f)
        let logMin = log10(minFrequency)
        let logMax = log10(maxFrequency)
        let normalized = (logF - logMin) / (logMax - logMin)
        return rect.minX + CGFloat(normalized) * rect.width
    }

    private func yPosition(forDB db: Double, in rect: CGRect) -> CGFloat {
        let clamped = min(max(db, dbRange.lowerBound), dbRange.upperBound)
        let normalized = (clamped - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)
        // Flip Y: high dB at top.
        return rect.maxY - CGFloat(normalized) * rect.height
    }

    private func curvePoints(in rect: CGRect) -> [CGPoint] {
        let frequencies = self.frequencies
        let response = self.response
        guard frequencies.count == response.count else { return [] }
        return zip(frequencies, response).map { f, db in
            CGPoint(
                x: xPosition(forFrequency: f, in: rect),
                y: yPosition(forDB: db, in: rect)
            )
        }
    }
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
