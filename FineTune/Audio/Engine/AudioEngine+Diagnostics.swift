// FineTune/Audio/Engine/AudioEngine+Diagnostics.swift

import Foundation

extension AudioEngine {
    func diagnosticsSnapshot() -> AudioEngineDiagnostics {
        var snapshot = diagnostics
        snapshot.tapRenderDiagnostics = taps.mapValues { $0.renderDiagnostics }
        return snapshot
    }

    func resetDiagnostics() {
        diagnostics = AudioEngineDiagnostics()
    }

    func recordTapCreationFailure() {
        diagnostics.tapCreationFailures += 1
        diagnostics.markEvent()
    }

    func recordRouteFallback(reason: String, isMultiDevice: Bool = false) {
        diagnostics.routeFallbackEvents += 1
        if isMultiDevice {
            diagnostics.multiDeviceFallbackEvents += 1
        }
        diagnostics.lastFallbackReason = reason
        diagnostics.markEvent()
    }

    func recordDefaultDeviceChange() {
        diagnostics.defaultDeviceChangeEvents += 1
        diagnostics.markEvent()
    }

    func recordUnknownDefaultDevice() {
        diagnostics.unknownDefaultDeviceEvents += 1
        diagnostics.markEvent()
    }

    func recordHealthCheckMiss(pid: pid_t) {
        diagnostics.healthCheckMisses += 1
        diagnostics.lastRecoveryPID = pid
        diagnostics.markEvent()
    }

    func recordTapRecoveryAttempt(pid: pid_t) {
        diagnostics.tapRecoveryAttempts += 1
        diagnostics.lastRecoveryPID = pid
        diagnostics.markEvent()
    }

    func recordTapRecoveryResult(pid: pid_t, succeeded: Bool) {
        if succeeded {
            diagnostics.successfulTapRecoveries += 1
        } else {
            diagnostics.failedTapRecoveries += 1
        }
        diagnostics.lastRecoveryPID = pid
        diagnostics.markEvent()
    }
}
