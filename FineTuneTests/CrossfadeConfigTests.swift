// FineTuneTests/CrossfadeConfigTests.swift
import Foundation
import Testing
@testable import FineTune

// Serialized: tests that read/write UserDefaults.standard share global mutable state
// and must not run concurrently (Swift Testing defaults to parallel execution).
@Suite(.serialized)
struct CrossfadeConfigTests {

    // MARK: - Default Duration

    @Test("Default crossfade duration is 50ms")
    func defaultDuration_is50ms() {
        // Ensure no override is set
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        #expect(abs(CrossfadeConfig.defaultDuration - 0.050) < 0.001)
    }

    @Test("duration returns default when no UserDefaults override is set")
    func duration_returnsDefaultWithoutOverride() {
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        #expect(abs(CrossfadeConfig.duration - 0.050) < 0.001)
    }

    @Test("duration respects UserDefaults override")
    func duration_respectsOverride() {
        let key = "FineTuneCrossfadeDuration"
        UserDefaults.standard.set(0.1, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(abs(CrossfadeConfig.duration - 0.1) < 0.001)
    }

    @Test("Zero or negative UserDefaults override falls back to default")
    func duration_zeroOverride_fallsBackToDefault() {
        let key = "FineTuneCrossfadeDuration"
        UserDefaults.standard.set(0.0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(abs(CrossfadeConfig.duration - 0.050) < 0.001)
    }

    // MARK: - totalSamples

    @Test("totalSamples at 44100 Hz is at least 1")
    func totalSamples_at44100_atLeastOne() {
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        let samples = CrossfadeConfig.totalSamples(at: 44100)
        #expect(samples >= 1)
    }

    @Test("totalSamples at 48000 Hz matches expected 50ms count")
    func totalSamples_at48000_correct() {
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        let samples = CrossfadeConfig.totalSamples(at: 48000)
        // 0.050 * 48000 = 2400
        #expect(samples == 2400)
    }

    @Test("totalSamples at 44100 Hz matches expected 50ms count")
    func totalSamples_at44100_correct() {
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        let samples = CrossfadeConfig.totalSamples(at: 44100)
        // 0.050 * 44100 = 2205
        #expect(samples == 2205)
    }

    @Test("totalSamples at 96000 Hz is twice that of 48000")
    func totalSamples_96kHzIsTwice48kHz() {
        UserDefaults.standard.removeObject(forKey: "FineTuneCrossfadeDuration")
        let samples48 = CrossfadeConfig.totalSamples(at: 48000)
        let samples96 = CrossfadeConfig.totalSamples(at: 96000)
        #expect(samples96 == samples48 * 2)
    }

    @Test("totalSamples scales correctly with custom duration override")
    func totalSamples_customDuration_scales() {
        let key = "FineTuneCrossfadeDuration"
        UserDefaults.standard.set(0.1, forKey: key) // 100ms
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let samples = CrossfadeConfig.totalSamples(at: 48000)
        // 0.1 * 48000 = 4800
        #expect(samples == 4800)
    }

    // MARK: - CrossfadeError Descriptions

    @Test("tapCreationFailed error has non-empty description")
    func tapCreationFailed_hasDescription() {
        let error = CrossfadeError.tapCreationFailed(-1)
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.errorDescription?.contains("-1") == true)
    }

    @Test("aggregateCreationFailed error has non-empty description")
    func aggregateCreationFailed_hasDescription() {
        let error = CrossfadeError.aggregateCreationFailed(-50)
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.errorDescription?.contains("-50") == true)
    }

    @Test("deviceNotReady error has non-empty description")
    func deviceNotReady_hasDescription() {
        let error = CrossfadeError.deviceNotReady
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("secondaryTapFailed error has non-empty description")
    func secondaryTapFailed_hasDescription() {
        let error = CrossfadeError.secondaryTapFailed
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("noTapDescription error has non-empty description")
    func noTapDescription_hasDescription() {
        let error = CrossfadeError.noTapDescription
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("All CrossfadeError cases produce distinct descriptions")
    func allErrors_distinctDescriptions() {
        let errors: [CrossfadeError] = [
            .tapCreationFailed(0),
            .aggregateCreationFailed(0),
            .deviceNotReady,
            .secondaryTapFailed,
            .noTapDescription
        ]
        let descriptions = errors.compactMap(\.errorDescription)
        let unique = Set(descriptions)
        #expect(unique.count == errors.count, "Each error type should have a unique description")
    }
}
