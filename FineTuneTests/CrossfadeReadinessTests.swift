import Foundation
import Testing
@testable import FineTune

@Suite("Crossfade readiness", .serialized)
@MainActor
struct CrossfadeReadinessTests {
    @Test("elapsed time without render frames cannot authorize promotion")
    func silentSecondaryTimesOut() async throws {
        let state = CrossfadeState()
        state.beginWarmup()
        #expect(try await state.waitForWarmup(timeout: .milliseconds(15)) == false)
        #expect(!state.isWarmupComplete)
        #expect(state.phase == .warmingUp)
        #expect(state.secondaryMultiplier == 0)
    }

    @Test("warmup waits for the frame threshold, then preserves it for the fade")
    func renderFramesAuthorizeFade() async throws {
        let state = CrossfadeState()
        state.beginWarmup()
        state.totalSamples = 512
        let render = Task { @MainActor in
            _ = state.updateProgress(samples: 1024)
            await Task.yield()
            _ = state.updateProgress(samples: 1024)
        }
        #expect(try await state.waitForWarmup(timeout: .seconds(1)))
        await render.value
        state.beginCrossfading()
        #expect(state.isWarmupComplete)
        #expect(!state.isCrossfadeComplete)
        _ = state.updateProgress(samples: 512)
        #expect(state.isCrossfadeComplete)
    }

    @Test("a callback from an older phase cannot advance a new transition")
    func staleGenerationCannotCommit() {
        let state = CrossfadeState()
        state.beginWarmup()
        let oldGeneration = state.generation
        state.complete()
        state.beginWarmup()
        _ = state.updateProgress(samples: 4096, generation: oldGeneration)
        #expect(state.secondarySamplesProcessed == 0)
        #expect(!state.isWarmupComplete)
        state.totalSamples = 1000
        state.beginCrossfading()
        _ = state.updateProgress(samples: 1000, generation: oldGeneration)
        #expect(state.progress == 0)
    }

    @Test("secondary AutoEQ copy preserves preamp mode at its new sample rate", arguments: [false, true])
    func secondaryPreservesPreampBypass(enabled: Bool) {
        let primary = AutoEQProcessor(sampleRate: 48_000)
        primary.setPreampEnabled(enabled)
        primary.updateProfile(AutoEQProfile(id: "switch", name: "switch", source: .imported,
            preampDB: -6, filters: [.init(type: .peaking, frequency: 1000, gainDB: 0, q: 1)],
            measuredBy: nil, optimizedSampleRate: 48_000))
        let secondary = primary.makeCopy(sampleRate: 44_100)
        var samples = [Float](repeating: 0.25, count: 128)
        samples.withUnsafeMutableBufferPointer {
            secondary.process(input: $0.baseAddress!, output: $0.baseAddress!, frameCount: 64)
        }
        let expected: Float = enabled ? 0.25 * powf(10, -6 / 20) : 0.25
        #expect(samples.allSatisfy { abs($0 - expected) < 0.0001 })
        #expect(secondary.sampleRate == 44_100)
    }
}
