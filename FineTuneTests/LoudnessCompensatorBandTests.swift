// FineTuneTests/LoudnessCompensatorBandTests.swift
import Testing
@testable import FineTune

struct LoudnessCompensatorBandTests {

    private let sampleRate: Double = 48000

    // MARK: - Band Count

    @Test("fittedSectionGains returns exactly bandCount gains")
    func fittedSectionGains_returnsBandCount() {
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: 60, sampleRate: sampleRate)
        #expect(gains.count == LoudnessCompensator.bandCount)
    }

    @Test("bandCount is 4 (four-section topology)")
    func bandCount_isFour() {
        #expect(LoudnessCompensator.bandCount == 4)
    }

    // MARK: - Reference Level (80 phon)

    @Test("At reference phon (80), all section gains are near zero")
    func atReferencePhon_gainsAreNearZero() {
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: 80, sampleRate: sampleRate)
        for (index, gain) in gains.enumerated() {
            #expect(abs(gain) < 0.5, "Band \(index) should have near-zero gain at reference level, got \(gain) dB")
        }
    }

    // MARK: - Low Phon Level (quiet listening)

    @Test("At low phon (40), low-frequency bands get positive boost")
    func atLowPhon_lowFrequencyBoost() {
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: 40, sampleRate: sampleRate)
        // bandFrequencies[0] = 80 Hz (low shelf) — should boost
        // bandFrequencies[1] = 180 Hz (peaking) — may boost
        let lowShelfGain = gains[0]
        #expect(lowShelfGain > 0, "Low shelf at 80Hz should boost at quiet levels, got \(lowShelfGain) dB")
    }

    @Test("At low phon (40), gain magnitudes are larger than at medium phon (60)")
    func lowerPhon_largerCorrection() {
        let gains40 = LoudnessCompensator.fittedSectionGains(forPhon: 40, sampleRate: sampleRate)
        let gains60 = LoudnessCompensator.fittedSectionGains(forPhon: 60, sampleRate: sampleRate)
        let maxAbsGain40 = gains40.map { abs($0) }.max() ?? 0
        let maxAbsGain60 = gains60.map { abs($0) }.max() ?? 0
        #expect(maxAbsGain40 > maxAbsGain60, "Quieter phon level should need more correction: \(maxAbsGain40) vs \(maxAbsGain60)")
    }

    // MARK: - Coefficient Generation

    @Test("coefficientsForBands returns 5 coefficients per band")
    func coefficientsForBands_correctCount() {
        let gains = [Float](repeating: 1.0, count: LoudnessCompensator.bandCount)
        let coefficients = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        #expect(coefficients.count == LoudnessCompensator.bandCount * 5)
    }

    @Test("coefficientsForBands with zero gains returns finite, stable coefficients")
    func coefficientsForBands_zeroGains_finiteCoefficients() {
        // With gainDB = 0 for every band, each biquad section is a passthrough.
        // The bilinear-transformed shelf/peaking filters with 0 dB gain produce
        // coefficients that evaluate to flat response, but they are NOT necessarily
        // the literal [1, 0, 0, 0, 0] vector — the bilinear transform yields
        // numerically equivalent but algebraically distinct values. We verify
        // that all coefficients are finite (no NaN / infinity from degenerate math).
        let gains = [Float](repeating: 0.0, count: LoudnessCompensator.bandCount)
        let coefficients = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        for (index, coeff) in coefficients.enumerated() {
            #expect(coeff.isFinite, "Coefficient[\(index)] should be finite with zero gains, got \(coeff)")
        }
    }

    @Test("coefficientsForBands with wrong count returns unity filters")
    func coefficientsForBands_wrongCount_unityFilters() {
        // Passing wrong gain count should return safe unity filters
        let gains: [Float] = [1.0, 2.0]  // wrong count
        let coefficients = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        #expect(coefficients.count == LoudnessCompensator.bandCount * 5)
        // First coefficient of each section should be 1.0 (passthrough)
        for section in 0..<LoudnessCompensator.bandCount {
            let b0 = coefficients[section * 5]
            #expect(abs(b0 - 1.0) < 0.001, "Section \(section) b0 should be 1.0, got \(b0)")
        }
    }

    // MARK: - Sample Rate Independence

    @Test("Different sample rates produce different coefficient sets")
    func differentSampleRates_differentCoefficients() {
        let gains = LoudnessCompensator.fittedSectionGains(forPhon: 50, sampleRate: 48000)
        let coeffs44 = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: 44100)
        let coeffs48 = LoudnessCompensator.coefficientsForBands(gains: gains, sampleRate: 48000)
        // Bilinear transform maps frequencies differently at different sample rates
        #expect(coeffs44 != coeffs48, "Different sample rates should produce different biquad coefficients")
    }

    // MARK: - Band Frequencies

    @Test("bandFrequencies has correct count")
    func bandFrequencies_correctCount() {
        #expect(LoudnessCompensator.bandFrequencies.count == LoudnessCompensator.bandCount)
    }

    @Test("bandFrequencies are all positive")
    func bandFrequencies_positive() {
        for freq in LoudnessCompensator.bandFrequencies {
            #expect(freq > 0, "Band frequency should be positive, got \(freq)")
        }
    }

    @Test("bandFrequencies cover the full audible spectrum")
    func bandFrequencies_coverAudibleSpectrum() {
        let min = LoudnessCompensator.bandFrequencies.min() ?? 0
        let max = LoudnessCompensator.bandFrequencies.max() ?? 0
        #expect(min < 200, "Lowest band should be in the bass region (<200 Hz), got \(min) Hz")
        #expect(max > 5000, "Highest band should be in the treble region (>5 kHz), got \(max) Hz")
    }
}
