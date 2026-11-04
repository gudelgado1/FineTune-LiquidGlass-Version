import Foundation
import Testing
@testable import FineTune

@Suite("AutoEQResponseCalculator — displayed curve matches the filters")
struct AutoEQResponseCalculatorTests {

    // MARK: - Frequency grid

    @Test("the grid spans the requested range with the requested resolution")
    func gridSpansRange() {
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(from: 20, to: 20_000, count: 200)
        #expect(freqs.count == 200)
        #expect(abs(freqs.first! - 20) < 0.001)
        #expect(abs(freqs.last! - 20_000) < 0.01)
    }

    @Test("the grid is logarithmic, not linear")
    func gridIsLogarithmic() {
        // Equal ratios between consecutive points is what makes the drawn curve
        // read correctly against a log frequency axis.
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(from: 20, to: 20_000, count: 50)
        let firstRatio = freqs[1] / freqs[0]
        for i in 1..<(freqs.count - 1) {
            let ratio = freqs[i + 1] / freqs[i]
            #expect(abs(ratio - firstRatio) < 0.0001, "ratio drifted at index \(i)")
        }
    }

    @Test("the grid is strictly increasing")
    func gridIsIncreasing() {
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(from: 20, to: 20_000, count: 200)
        for i in 1..<freqs.count {
            #expect(freqs[i] > freqs[i - 1])
        }
    }

    @Test("a degenerate count returns the lower bound instead of dividing by zero")
    func gridHandlesDegenerateCount() {
        #expect(AutoEQResponseCalculator.logSpacedFrequencies(count: 1) == [20.0])
        #expect(AutoEQResponseCalculator.logSpacedFrequencies(count: 0) == [20.0])
    }

    // MARK: - Magnitude response

    @Test("no filters is a flat 0 dB response")
    func emptyFilterListIsFlat() {
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(count: 32)
        let response = AutoEQResponseCalculator.magnitudeDB(of: [], at: freqs)
        #expect(response.count == freqs.count)
        #expect(response.allSatisfy { $0 == 0 })
    }

    @Test("a peaking filter puts its gain at its centre frequency")
    func peakingFilterPeaksAtCentre() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 6, q: 1.0)
        let response = AutoEQResponseCalculator.magnitudeDB(of: [filter], at: [1000])
        // The whole point of the preview: what's drawn is the actual gain.
        #expect(abs(response[0] - 6.0) < 0.15)
    }

    @Test("a peaking filter barely affects frequencies far from its centre")
    func peakingFilterIsLocal() {
        let filter = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 12, q: 2.0)
        let response = AutoEQResponseCalculator.magnitudeDB(of: [filter], at: [50, 1000, 16_000])
        #expect(abs(response[0]) < 0.5, "50 Hz should be untouched")
        #expect(abs(response[2]) < 0.5, "16 kHz should be untouched")
        #expect(response[1] > 10, "the centre should carry the boost")
    }

    @Test("a cut is negative and mirrors the equivalent boost")
    func cutMirrorsBoost() {
        let freqs = [200.0, 1000.0, 5000.0]
        let boost = AutoEQResponseCalculator.magnitudeDB(
            of: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 6, q: 1.0)], at: freqs)
        let cut = AutoEQResponseCalculator.magnitudeDB(
            of: [AutoEQFilter(type: .peaking, frequency: 1000, gainDB: -6, q: 1.0)], at: freqs)
        for i in freqs.indices {
            #expect(abs(boost[i] + cut[i]) < 0.35, "boost and cut should mirror at \(freqs[i]) Hz")
        }
    }

    @Test("a low shelf lifts the bass and leaves the treble alone")
    func lowShelfAffectsBassOnly() {
        let filter = AutoEQFilter(type: .lowShelf, frequency: 200, gainDB: 6, q: 0.7)
        let response = AutoEQResponseCalculator.magnitudeDB(of: [filter], at: [30, 10_000])
        #expect(response[0] > 4.5, "30 Hz should be near the full shelf gain")
        #expect(abs(response[1]) < 0.5, "10 kHz should be untouched")
    }

    @Test("a high shelf lifts the treble and leaves the bass alone")
    func highShelfAffectsTrebleOnly() {
        let filter = AutoEQFilter(type: .highShelf, frequency: 4000, gainDB: 6, q: 0.7)
        let response = AutoEQResponseCalculator.magnitudeDB(of: [filter], at: [50, 18_000])
        #expect(abs(response[0]) < 0.5, "50 Hz should be untouched")
        #expect(response[1] > 4.5, "18 kHz should be near the full shelf gain")
    }

    @Test("cascaded filters add in dB")
    func cascadedFiltersAddInDecibels() {
        // Cascading multiplies magnitudes, which is addition in dB — the
        // property that lets the view sum filters into one curve.
        let a = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 4, q: 1.0)
        let b = AutoEQFilter(type: .peaking, frequency: 1000, gainDB: 3, q: 1.0)
        let freqs = [500.0, 1000.0, 2000.0]

        let responseA = AutoEQResponseCalculator.magnitudeDB(of: [a], at: freqs)
        let responseB = AutoEQResponseCalculator.magnitudeDB(of: [b], at: freqs)
        let combined = AutoEQResponseCalculator.magnitudeDB(of: [a, b], at: freqs)

        for i in freqs.indices {
            #expect(abs(combined[i] - (responseA[i] + responseB[i])) < 0.001)
        }
    }

    @Test("filters at or above Nyquist are skipped instead of producing NaN")
    func aboveNyquistFiltersAreSkipped() {
        // A 44.1 kHz-authored profile can carry filters above a 48 kHz stream's
        // Nyquist; the coefficient math would go non-finite and blank the curve.
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(count: 64)
        let filters = [
            AutoEQFilter(type: .peaking, frequency: 24_000, gainDB: 6, q: 1.0),
            AutoEQFilter(type: .peaking, frequency: 30_000, gainDB: 6, q: 1.0),
            AutoEQFilter(type: .peaking, frequency: 0, gainDB: 6, q: 1.0),
            AutoEQFilter(type: .peaking, frequency: -100, gainDB: 6, q: 1.0)
        ]
        let response = AutoEQResponseCalculator.magnitudeDB(of: filters, at: freqs, sampleRate: 48_000)
        #expect(response.allSatisfy { $0.isFinite })
        #expect(response.allSatisfy { $0 == 0 }, "every filter was out of range, so the curve is flat")
    }

    @Test("the response stays finite across a realistic multi-filter profile")
    func realisticProfileStaysFinite() {
        let filters = [
            AutoEQFilter(type: .lowShelf, frequency: 105, gainDB: 5.4, q: 0.7),
            AutoEQFilter(type: .peaking, frequency: 24, gainDB: 1.2, q: 0.9),
            AutoEQFilter(type: .peaking, frequency: 1800, gainDB: -3.1, q: 2.4),
            AutoEQFilter(type: .peaking, frequency: 5600, gainDB: 4.8, q: 3.6),
            AutoEQFilter(type: .highShelf, frequency: 10_000, gainDB: -2.0, q: 0.7)
        ]
        let freqs = AutoEQResponseCalculator.logSpacedFrequencies(count: 200)
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let response = AutoEQResponseCalculator.magnitudeDB(of: filters, at: freqs, sampleRate: rate)
            #expect(response.allSatisfy { $0.isFinite }, "non-finite dB at \(rate) Hz")
            #expect(response.allSatisfy { abs($0) < 60 }, "implausible dB at \(rate) Hz")
        }
    }

    // MARK: - Peak helper

    @Test("peak magnitude reports the largest absolute deviation")
    func peakAbsoluteReportsLargestDeviation() {
        #expect(AutoEQResponseCalculator.peakAbsoluteDB([0, 3, -7, 2]) == 7)
        #expect(AutoEQResponseCalculator.peakAbsoluteDB([]) == 0)
        #expect(AutoEQResponseCalculator.peakAbsoluteDB([-1.5]) == 1.5)
    }
}
