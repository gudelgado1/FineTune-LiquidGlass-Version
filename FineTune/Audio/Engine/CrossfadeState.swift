import Atomics
import Foundation

enum CrossfadePhase: Int, Equatable {
    case idle = 0, warmingUp = 1, crossfading = 2
}

/// Control + one secondary render writer, any number of readers. One atomic
/// double-word publishes phase/progress/counters together. Transitions advance
/// a generation so a preempted callback cannot commit into a newer phase.
/// No allocations/locks in updateProgress or multiplier reads. Counter storage
/// saturates at UInt32.max (~24h at 48kHz); crossfades use milliseconds.
nonisolated final class CrossfadeState: Sendable {
    // first: progress Float bits (32), phase (2), generation (30).
    // second: total secondary frames (32), crossfade frames (32).
    private let state = ManagedAtomic(DoubleWord(first: 0, second: 0))
    private let duration = ManagedAtomic<Int64>(0)
    private static let mask: UInt = 0xffff_ffff
    private static let generationMask: UInt = 0x3fff_ffff
    static let minimumWarmupSamples = 2048

    var generation: UInt { state.load(ordering: .acquiring).first >> 34 }
    var phase: CrossfadePhase { Self.phase(of: state.load(ordering: .acquiring)) }
    var isActive: Bool { phase != .idle }
    var secondarySamplesProcessed: Int { Int(state.load(ordering: .acquiring).second & Self.mask) }
    var secondarySampleCount: Int64 { Int64(state.load(ordering: .acquiring).second >> 32) }
    var totalSamples: Int64 {
        get { duration.load(ordering: .relaxed) }
        set { duration.store(max(0, min(Int64(UInt32.max), newValue)), ordering: .relaxed) }
    }
    var progress: Float {
        get { Self.progress(of: state.load(ordering: .acquiring)) }
        set {
            let value = newValue.isFinite ? max(0, min(1, newValue)) : 0
            mutate { old in
                DoubleWord(first: Self.header(progress: value, phase: Self.phase(of: old), generation: (old.first >> 34) &+ 1), second: old.second)
            }
        }
    }

    func beginWarmup() {
        transition(to: .warmingUp, preserveWarmup: false)
        totalSamples = 0 // no fade calculation while warming up
    }
    func beginCrossfading() { transition(to: .crossfading, preserveWarmup: true) }
    func complete() {
        transition(to: .idle, preserveWarmup: false)
        totalSamples = 0
    }
    private func transition(to phase: CrossfadePhase, preserveWarmup: Bool) {
        mutate { old in
            DoubleWord(first: Self.header(progress: 0, phase: phase, generation: (old.first >> 34) &+ 1),
                       second: preserveWarmup ? old.second & Self.mask : 0)
        }
    }

    @inline(__always)
    func updateProgress(samples: Int, generation expectedGeneration: UInt? = nil) -> Float {
        var old = state.load(ordering: .acquiring)
        let epoch = expectedGeneration ?? (old.first >> 34)
        guard samples > 0 else { return Self.progress(of: old) }
        while true {
            guard old.first >> 34 == epoch else { return Self.progress(of: old) }
            let warm = min(Self.mask, (old.second & Self.mask) + UInt(min(samples, Int(UInt32.max))))
            var count = old.second >> 32
            var progress = Self.progress(of: old)
            if Self.phase(of: old) == .crossfading {
                count = min(Self.mask, count + UInt(min(samples, Int(UInt32.max))))
                progress = max(progress, min(1, Float(count) / Float(max(1, totalSamples))))
            }
            let next = DoubleWord(first: Self.header(progress: progress, phase: Self.phase(of: old), generation: epoch),
                                  second: warm | (count << 32))
            let result = state.compareExchange(expected: old, desired: next, ordering: .acquiringAndReleasing)
            if result.exchanged { return progress }
            old = result.original
        }
    }
    var isWarmupComplete: Bool { secondarySamplesProcessed >= Self.minimumWarmupSamples }
    var isCrossfadeComplete: Bool { progress >= 1 }

    /// Uses actual rendered frames, not elapsed sleep, as readiness evidence.
    @MainActor
    func waitForWarmup(timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isWarmupComplete {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        return true
    }

    var primaryMultiplier: Float {
        let value = state.load(ordering: .acquiring)
        let progress = Self.progress(of: value)
        switch Self.phase(of: value) {
        case .idle: return progress >= 1 ? 0 : 1
        case .warmingUp: return 1
        case .crossfading: return progress >= 1 ? 0 : cos(progress * .pi / 2)
        }
    }
    var secondaryMultiplier: Float {
        let value = state.load(ordering: .acquiring)
        switch Self.phase(of: value) {
        case .idle: return 1
        case .warmingUp: return 0
        case .crossfading: return sin(Self.progress(of: value) * .pi / 2)
        }
    }
    private func mutate(_ transform: (DoubleWord) -> DoubleWord) {
        var old = state.load(ordering: .acquiring)
        while true {
            let result = state.compareExchange(expected: old, desired: transform(old), ordering: .acquiringAndReleasing)
            if result.exchanged { return }
            old = result.original
        }
    }
    private static func header(progress: Float, phase: CrossfadePhase, generation: UInt) -> UInt {
        UInt(progress.bitPattern) | UInt(phase.rawValue) << 32 | (generation & generationMask) << 34
    }
    private static func progress(of value: DoubleWord) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: value.first)) }
    private static func phase(of value: DoubleWord) -> CrossfadePhase { CrossfadePhase(rawValue: Int((value.first >> 32) & 3)) ?? .idle }
}
