// FineTune/Audio/AutoEQ/AutoEQResponseCalculator.swift
import Foundation

// MARK: - AutoEQ Frequency Response Calculator
//
// Computes the magnitude response (in dB) of an AutoEQ profile's filter chain
// at a set of log-spaced frequencies. Used by `AutoEQCurveView` to draw the
// curve in the expanded inspector — same coefficients the audio engine uses,
// so what you see is exactly what you hear.

enum AutoEQResponseCalculator {
    /// Standard log-spaced frequency grid (20 Hz to 20 kHz) at the chosen
    /// resolution. 200 points gives a visually smooth curve without burning
    /// CPU on the main thread; the math is cheap per point.
    static func logSpacedFrequencies(
        from minHz: Double = 20.0,
        to maxHz: Double = 20_000.0,
        count: Int = 200
    ) -> [Double] {
        guard count > 1 else { return [minHz] }
        let minLog = log10(minHz)
        let maxLog = log10(maxHz)
        let step = (maxLog - minLog) / Double(count - 1)
        return (0..<count).map { i in pow(10, minLog + Double(i) * step) }
    }

    /// Computes the total magnitude response in dB at each frequency for a
    /// cascade of AutoEQ filters.
    ///
    /// Math: for each filter we use the same RBJ-cookbook coefficients the
    /// runtime processor uses (`BiquadMath`), then evaluate the digital
    /// transfer function `H(e^jω)` directly:
    ///
    ///     H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
    ///     |H(e^jω)|² = |num(ω)|² / |den(ω)|²
    ///     dB(ω) = 10·log₁₀(|H|²)
    ///
    /// Cascaded biquads multiply in magnitude — equivalently, their dBs add.
    /// Preamp is NOT applied here; callers add it as a flat offset if needed.
    ///
    /// - Parameters:
    ///   - filters: The profile's filter list.
    ///   - frequencies: Frequencies in Hz at which to evaluate the response.
    ///   - sampleRate: Sample rate the response is computed for. 48 kHz is a
    ///     reasonable visual default; the curve shape barely changes between
    ///     44.1k and 96k for the audible band, so this isn't critical for display.
    /// - Returns: dB values, parallel to `frequencies`.
    static func magnitudeDB(
        of filters: [AutoEQFilter],
        at frequencies: [Double],
        sampleRate: Double = 48_000
    ) -> [Double] {
        var totalDB = [Double](repeating: 0, count: frequencies.count)
        guard !filters.isEmpty else { return totalDB }

        for filter in filters {
            // Above-Nyquist filters can't reasonably contribute — skip them
            // rather than producing NaN from the coefficient math.
            guard filter.frequency > 0, filter.frequency < sampleRate / 2.0 else { continue }

            let coeffs: [Double]
            switch filter.type {
            case .peaking:
                coeffs = BiquadMath.peakingEQCoefficients(
                    frequency: filter.frequency,
                    gainDB: filter.gainDB,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .lowShelf:
                coeffs = BiquadMath.lowShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: filter.gainDB,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            case .highShelf:
                coeffs = BiquadMath.highShelfCoefficients(
                    frequency: filter.frequency,
                    gainDB: filter.gainDB,
                    q: filter.q,
                    sampleRate: sampleRate
                )
            }

            let b0 = coeffs[0]
            let b1 = coeffs[1]
            let b2 = coeffs[2]
            let a1 = coeffs[3]
            let a2 = coeffs[4]

            for (i, f) in frequencies.enumerated() {
                let omega = 2.0 * .pi * f / sampleRate
                let cosW = cos(omega)
                let sinW = sin(omega)
                let cos2W = cos(2 * omega)
                let sin2W = sin(2 * omega)

                // H(e^jω) = sum_k c_k · e^(-j·k·ω)
                // For the numerator with coefficients b0,b1,b2:
                let numRe = b0 + b1 * cosW + b2 * cos2W
                let numIm = -b1 * sinW - b2 * sin2W
                // Denominator with a0=1, a1, a2:
                let denRe = 1.0 + a1 * cosW + a2 * cos2W
                let denIm = -a1 * sinW - a2 * sin2W

                let numMag2 = numRe * numRe + numIm * numIm
                let denMag2 = denRe * denRe + denIm * denIm

                // Guard against division by zero (shouldn't happen with valid filters).
                guard denMag2 > 0 else { continue }
                totalDB[i] += 10.0 * log10(numMag2 / denMag2)
            }
        }

        return totalDB
    }

    /// Convenience: peak absolute dB across the response. Used to scale the
    /// curve preview when no fixed dB range is required.
    static func peakAbsoluteDB(_ response: [Double]) -> Double {
        response.reduce(0) { max($0, abs($1)) }
    }
}
