// FineTune/Audio/Engine/AudioDiagnostics.swift

import Foundation

/// Render-thread-only timing state. A pause or a single scheduling hiccup does
/// not itself request recovery; the control-thread detector evaluates deltas.
nonisolated struct RenderGapTracker {
    private var previousTime: Double?
    private var generation: UInt32 = 0

    mutating func record(time: Double, callbackID: UInt32, bufferDuration: Double) -> Bool {
        defer { previousTime = time; generation = callbackID }
        guard generation == callbackID, let previousTime else { return false }
        return time - previousTime > max(0.050, bufferDuration * 4)
    }
}

/// Allocated when installing an IO proc, never in the callback. Each proc owns
/// its timing history, including while two procs overlap during a crossfade.
nonisolated final class RenderTimingState: @unchecked Sendable {
    var tracker = RenderGapTracker()
}

/// Evaluated every two seconds. Require multiple gaps in two consecutive
/// windows so a resume, one overload burst, or a quiet period does not thrash IO.
nonisolated struct RenderStutterDetector {
    private var previousCount: UInt64?
    private var badWindows = 0

    mutating func observe(longGapCount: UInt64) -> Bool {
        defer { previousCount = longGapCount }
        guard let previousCount, longGapCount >= previousCount else {
            badWindows = 0
            return false
        }
        badWindows = longGapCount - previousCount >= 3 ? badWindows + 1 : 0
        return badWindows >= 2
    }
}

nonisolated struct TapRenderDiagnostics: Equatable {
    var callbackCount: UInt64 = 0
    var staleCallbackCount: UInt64 = 0
    var longGapCount: UInt64 = 0
    var maxCallbackGapMilliseconds: Double = 0
    var lastCallbackAgeMilliseconds: Double?
}

nonisolated struct AudioEngineDiagnostics: Equatable {
    var healthCheckMisses: Int = 0
    var tapRecoveryAttempts: Int = 0
    var successfulTapRecoveries: Int = 0
    var failedTapRecoveries: Int = 0
    var routeFallbackEvents: Int = 0
    var multiDeviceFallbackEvents: Int = 0
    var defaultDeviceChangeEvents: Int = 0
    var unknownDefaultDeviceEvents: Int = 0
    var tapCreationFailures: Int = 0

    var lastEventAt: Date?
    var lastRecoveryPID: pid_t?
    var lastFallbackReason: String?
    var tapRenderDiagnostics: [pid_t: TapRenderDiagnostics] = [:]

    var totalTapRecoveries: Int {
        successfulTapRecoveries + failedTapRecoveries
    }

    mutating func markEvent() {
        lastEventAt = Date()
    }
}
