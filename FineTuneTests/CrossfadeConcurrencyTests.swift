import Foundation
import os
import Testing
@testable import FineTune

nonisolated private final class SharedCrossfade: @unchecked Sendable {
    var state = CrossfadeState()
}

@Suite("Crossfade control and render concurrency", .serialized)
@MainActor
struct CrossfadeConcurrencyTests {
    @Test("secondary render overlaps phase resets and primary reads")
    func concurrentPhaseChanges() {
        let shared = SharedCrossfade()
        let running = OSAllocatedUnfairLock(initialState: true)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            while running.withLock({ $0 }) {
                _ = shared.state.updateProgress(samples: 64)
                _ = shared.state.secondaryMultiplier
            }
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 3) == .success)
        for _ in 0..<5_000 {
            shared.state.beginWarmup()
            shared.state.totalSamples = 4_800
            shared.state.beginCrossfading()
            _ = shared.state.primaryMultiplier
            _ = shared.state.isWarmupComplete
            shared.state.complete()
        }
        running.withLock { $0 = false }
        #expect(finished.wait(timeout: .now() + 5) == .success)
        shared.state.complete()
        #expect(shared.state.phase == .idle)
        #expect(shared.state.progress == 0)
    }
}
