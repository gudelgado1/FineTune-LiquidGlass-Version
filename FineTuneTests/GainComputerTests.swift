// FineTuneTests/GainComputerTests.swift
import Testing
@testable import FineTune

struct GainComputerTests {

    // Default settings: targetLoudnessDb = -12, maxBoostDb = 15, maxCutDb = 4,
    // compressionThresholdOffsetDb = 6, compressionRatio = 1.6, compressionKneeDb = 8,
    // noiseFloorThresholdDb = -48, lowLevelMaxBoostDb = 1.5

    private func makeComputer(
        targetLoudnessDb: Float = -12,
        maxBoostDb: Float = 15,
        maxCutDb: Float = 4,
        compressionThresholdOffsetDb: Float = 6,
        compressionRatio: Float = 1.6,
        compressionKneeDb: Float = 8,
        noiseFloorThresholdDb: Float = -48,
        lowLevelMaxBoostDb: Float = 1.5
    ) -> GainComputer {
        var settings = LoudnessEqualizerSettings()
        settings.targetLoudnessDb = targetLoudnessDb
        settings.maxBoostDb = maxBoostDb
        settings.maxCutDb = maxCutDb
        settings.compressionThresholdOffsetDb = compressionThresholdOffsetDb
        settings.compressionRatio = compressionRatio
        settings.compressionKneeDb = compressionKneeDb
        settings.noiseFloorThresholdDb = noiseFloorThresholdDb
        settings.lowLevelMaxBoostDb = lowLevelMaxBoostDb
        return GainComputer(settings: settings)
    }

    // MARK: - Boost Tests

    @Test("Signal at target level produces zero boost")
    func atTargetLevel_zeroGain() {
        let computer = makeComputer()
        // level = -12 == target, compression threshold = -12 + 6 = -6 → -12 is below threshold
        let gain = computer.desiredGainDb(forLevelDb: -12)
        #expect(abs(gain) < 0.01, "At target level, gain should be ~0 dB, got \(gain)")
    }

    @Test("Signal well below target boosts up to maxBoostDb")
    func belowTarget_boostsCappedAtMax() {
        let computer = makeComputer() // target = -12, maxBoost = 15
        // raw = -12 - (-40) = 28 → clamped to min(28, 15) = 15
        let gain = computer.desiredGainDb(forLevelDb: -40)
        #expect(abs(gain - 15) < 0.01, "Should boost to maxBoostDb=15, got \(gain)")
    }

    @Test("Signal above compression threshold produces cut")
    func aboveCompressionThreshold_producesCut() {
        let computer = makeComputer() // threshold = -12 + 6 = -6
        // level = 0 > -6 → compression applies, no boost
        let gain = computer.desiredGainDb(forLevelDb: 0)
        #expect(gain < 0, "Signal above compression threshold should produce a cut, got \(gain)")
        #expect(gain >= -4, "Cut should not exceed maxCutDb=4, got \(gain)")
    }

    @Test("No cut when maxCutDb is zero")
    func maxCutDbZero_noCut() {
        let computer = makeComputer(maxCutDb: 0)
        // level = 0, well above target, but maxCutDb=0 → no cut applied
        let gain = computer.desiredGainDb(forLevelDb: 0)
        #expect(gain >= 0, "With maxCutDb=0, gain should be non-negative, got \(gain)")
    }

    @Test("Noise floor protection caps boost for very quiet signals")
    func noiseFloor_capsBoost() {
        let computer = makeComputer() // noiseFloorThreshold = -48, lowLevelMaxBoost = 1.5
        // level = -55 < -48 → boost capped at 1.5
        let gain = computer.desiredGainDb(forLevelDb: -55)
        #expect(abs(gain - 1.5) < 0.01, "Noise floor protection should cap boost at 1.5 dB, got \(gain)")
    }

    @Test("Signal slightly below target gets partial boost")
    func slightlyBelowTarget_partialBoost() {
        let computer = makeComputer() // target = -12, maxBoost = 15
        // level = -17, raw = -12 - (-17) = 5, clamped = 5, above noiseFloor (-48)
        let gain = computer.desiredGainDb(forLevelDb: -17)
        #expect(abs(gain - 5) < 0.5, "Should boost by ~5 dB, got \(gain)")
    }

    @Test("Signal inside soft knee gets partial compression")
    func inSoftKnee_partialCompression() {
        // threshold = -12 + 6 = -6, knee = 8, kneeStart = -10, kneeEnd = -2
        // level = -6 is at threshold center → partial compression
        let computer = makeComputer()
        let gain = computer.desiredGainDb(forLevelDb: -6)
        // At threshold center, compression is partial — gain should be a small negative value
        #expect(gain <= 0, "At compression threshold, gain should be <= 0, got \(gain)")
    }

    @Test("Higher compression ratio produces larger cut")
    func higherRatio_largerCut() {
        let lightComputer = makeComputer(compressionRatio: 1.2)
        let heavyComputer = makeComputer(compressionRatio: 4.0)
        let lightGain = lightComputer.desiredGainDb(forLevelDb: 0)
        let heavyGain = heavyComputer.desiredGainDb(forLevelDb: 0)
        #expect(heavyGain < lightGain, "Higher ratio should produce more cut: heavy=\(heavyGain) vs light=\(lightGain)")
    }

    @Test("Ratio of 1.0 produces no cut")
    func ratioOne_noCut() {
        let computer = makeComputer(compressionRatio: 1.0)
        // ratio == 1 → no compression
        let gain = computer.desiredGainDb(forLevelDb: 0)
        #expect(gain >= 0, "Ratio=1.0 means no compression, gain should be >=0, got \(gain)")
    }

    @Test("Custom target loudness shifts the operating point")
    func customTargetLoudness_shiftsPoint() {
        let standard = makeComputer(targetLoudnessDb: -12)
        let louder = makeComputer(targetLoudnessDb: -6)
        // At level = -12: standard sees it as "at target", louder sees it as 6 dB below target
        let standardGain = standard.desiredGainDb(forLevelDb: -12)
        let louderGain = louder.desiredGainDb(forLevelDb: -12)
        #expect(louderGain > standardGain, "Higher target should produce more boost at same level")
    }
}
