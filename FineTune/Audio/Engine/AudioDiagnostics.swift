// FineTune/Audio/Engine/AudioDiagnostics.swift

import Foundation

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
