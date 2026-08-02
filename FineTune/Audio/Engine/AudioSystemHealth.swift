// FineTune/Audio/Engine/AudioSystemHealth.swift
import Foundation
import os

// MARK: - Circuit breaker for a wedged coreaudiod
//
// When `coreaudiod` stops answering, every HAL call blocks forever (see
// `HALExecutor`). Without a breaker the app makes things worse: the health
// monitor ticks every 2 s, the process monitor refreshes every 10 s, and each
// tick spawns another thread that parks in the kernel and never comes back.
//
// This type is the single source of truth for "is the audio system answering",
// and the gate every periodic HAL caller must check first. While tripped, the
// only HAL traffic allowed is one slow recovery probe.

@MainActor
@Observable
final class AudioSystemHealth {

    enum State: Equatable {
        case responsive
        /// The HAL missed its deadline; periodic work is suspended.
        case unresponsive
    }

    private(set) var state: State = .responsive
    /// When the HAL first stopped answering, for the UI's "silent since…" copy.
    private(set) var unresponsiveSince: Date?

    /// Consecutive timeouts observed. One timeout can be a transient stall under
    /// load, so we only trip after a couple in a row.
    private var consecutiveTimeouts = 0
    private var recoveryTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "AudioSystemHealth")

    /// Number of consecutive HAL timeouts tolerated before suspending work.
    private let timeoutsBeforeTripping = 2

    /// Invoked once the HAL answers again, so the engine can rebuild state that
    /// went stale while the daemon was gone.
    var onRecovered: (() -> Void)?

    /// Whether periodic HAL work (health ticks, process refreshes, liveness
    /// queries) may run right now. Callers MUST check this before issuing HAL
    /// calls on a timer.
    var allowsPeriodicHALWork: Bool { state == .responsive }

    // MARK: Reporting

    /// Reports that a HAL call returned in time.
    func reportSuccess() {
        consecutiveTimeouts = 0
        guard state == .unresponsive else { return }
        logger.notice("Audio system is answering again — resuming periodic work")
        DiagnosticLog.log("halhealth: RECOVERED — resuming periodic HAL work")
        state = .responsive
        unresponsiveSince = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        onRecovered?()
    }

    /// Reports that a HAL call missed its deadline.
    func reportTimeout() {
        consecutiveTimeouts += 1
        guard state == .responsive, consecutiveTimeouts >= timeoutsBeforeTripping else { return }
        state = .unresponsive
        unresponsiveSince = Date()
        logger.error("Audio system stopped answering — suspending periodic HAL work")
        DiagnosticLog.log("halhealth: TRIPPED after \(consecutiveTimeouts) timeouts — suspending periodic HAL work")
        startRecoveryProbe()
    }

    /// Forces the breaker closed after an external fix (e.g. the Settings reset
    /// restarted the daemon), without waiting for the next probe.
    func forceRecoveredAfterExternalFix() {
        consecutiveTimeouts = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        guard state == .unresponsive else { return }
        state = .responsive
        unresponsiveSince = nil
        DiagnosticLog.log("halhealth: manually cleared after external fix")
    }

    // MARK: Recovery

    /// While tripped, probes on a slow cadence — the ONLY HAL traffic allowed —
    /// so the app recovers on its own if the daemon comes back (or is restarted
    /// from Settings or the Terminal).
    private func startRecoveryProbe() {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.state == .unresponsive else { return }
                if await HALExecutor.probeResponsive(timeout: 3.0) {
                    self.reportSuccess()
                    return
                }
            }
        }
    }

    func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
    }
}
