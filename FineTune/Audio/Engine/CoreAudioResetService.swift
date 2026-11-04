// FineTune/Audio/Engine/CoreAudioResetService.swift
import AudioToolbox
import Foundation
import os

// MARK: - Core Audio reset
//
// `coreaudiod` can wedge: the process stays alive but stops answering HAL
// requests, so every audio device disappears system-wide and every app that
// touches CoreAudio hangs. Observed on 2026-07-29 — a fresh, unrelated HAL
// client hung on its very first query, and stayed hung after FineTune was
// killed, so nothing in user space could recover it. The only fix is restarting
// the daemon, which needs administrator rights.
//
// This service provides both halves of that recovery:
//   * `probeResponsive` — a HAL query that CANNOT hang the caller, because the
//     query runs on its own thread and the caller only waits on a deadline.
//   * `restart` — re-launches `coreaudiod` via the system's own authorization
//     dialog (`osascript` + `with administrator privileges`). The password is
//     typed into macOS's dialog; FineTune never sees or handles it.

@MainActor
@Observable
final class CoreAudioResetService {

    enum Health: Equatable {
        case unknown
        case responsive
        case unresponsive
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// Authorization dialog is up / the restart command is running.
        case restarting
        /// Daemon was restarted; waiting for it to answer again.
        case waitingForDaemon
        case rebuilding
        case succeeded
        /// User dismissed the authorization dialog.
        case cancelled
        case failed(String)
    }

    private(set) var health: Health = .unknown
    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?

    /// A wedged HAL query never returns, so its thread is lost for the life of
    /// the process. This guard keeps at most one such thread outstanding.
    private var probeInFlight = false

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "CoreAudioReset")

    var isBusy: Bool { Self.isBusy(phase) }

    /// Pure phase classification — drives the Reset button's disabled state.
    /// Static so tests exercise this exact logic rather than a copy of it.
    static func isBusy(_ phase: Phase) -> Bool {
        switch phase {
        case .checking, .restarting, .waitingForDaemon, .rebuilding: return true
        case .idle, .succeeded, .cancelled, .failed: return false
        }
    }

    /// Test hook: the privileged phases can't be reached without a real
    /// authorization dialog, so tests set them directly.
    func setPhaseForTesting(_ phase: Phase) {
        self.phase = phase
    }

    // MARK: Health probe

    /// Checks whether `coreaudiod` still answers, without ever blocking the
    /// caller. Safe to call from the UI.
    @discardableResult
    func checkHealth(timeout: TimeInterval = 4.0) async -> Health {
        guard !probeInFlight else { return health }
        probeInFlight = true
        phase = .checking
        let responsive = await Self.probeResponsive(timeout: timeout)
        probeInFlight = false
        health = responsive ? .responsive : .unresponsive
        lastCheck = Date()
        phase = .idle
        if !responsive {
            logger.warning("Core Audio probe timed out — daemon appears wedged")
            DiagnosticLog.log("coreaudio: probe TIMED OUT — daemon appears wedged")
        }
        return health
    }

    /// Runs one HAL device-list query with a deadline. If the daemon is wedged
    /// the query never returns; `HALExecutor` abandons its thread (never more
    /// than one at a time, see `probeInFlight`) and we report false.
    nonisolated static func probeResponsive(timeout: TimeInterval) async -> Bool {
        await HALExecutor.probeResponsive(timeout: timeout)
    }

    // MARK: Restart

    /// Restarts `coreaudiod` (administrator authorization required), waits for
    /// it to answer again, then asks the engine to rebuild its taps.
    ///
    /// - Parameter engine: rebuilt after the daemon returns. Every server-side
    ///   tap, aggregate device, and device ID is invalidated by the restart.
    func resetCoreAudio(engine: AudioEngine?) async {
        guard !isBusy else { return }
        logger.notice("Core Audio reset requested")
        DiagnosticLog.log("coreaudio: RESET requested by user")
        phase = .restarting

        let outcome = await Self.runPrivilegedRestart()
        switch outcome {
        case .cancelled:
            logger.info("Core Audio reset cancelled at the authorization dialog")
            DiagnosticLog.log("coreaudio: reset cancelled by user at auth dialog")
            phase = .cancelled
            return
        case .failed(let message):
            logger.error("Core Audio reset failed: \(message)")
            DiagnosticLog.log("coreaudio: reset FAILED: \(message)")
            phase = .failed(message)
            return
        case .succeeded:
            break
        }

        // launchd brings the daemon back on its own; give it time to answer.
        phase = .waitingForDaemon
        var responsive = false
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(700))
            if await Self.probeResponsive(timeout: 3.0) {
                responsive = true
                break
            }
        }

        guard responsive else {
            health = .unresponsive
            phase = .failed("Core Audio didn't come back. Restart the Mac if it stays silent.")
            DiagnosticLog.log("coreaudio: daemon did NOT answer after restart")
            return
        }

        health = .responsive
        lastCheck = Date()
        DiagnosticLog.log("coreaudio: daemon answering again — rebuilding engine")

        phase = .rebuilding
        // Clear the breaker first: it gates the periodic HAL work the rebuild
        // below (and the health monitor after it) depends on.
        engine?.audioSystemHealth.forceRecoveredAfterExternalFix()
        await engine?.resyncAfterCoreAudioRestart()

        logger.notice("Core Audio reset complete")
        DiagnosticLog.log("coreaudio: RESET complete")
        phase = .succeeded
    }

    /// Mirrors the engine's circuit breaker, which trips from background HAL
    /// timeouts. Lets an open Settings window report the outage without the user
    /// having to run a check first.
    func noteUnresponsiveFromEngine() {
        guard !isBusy else { return }
        health = .unresponsive
        lastCheck = Date()
    }

    /// Clears a terminal phase so the row returns to its resting state.
    func acknowledge() {
        switch phase {
        case .succeeded, .cancelled, .failed: phase = .idle
        default: break
        }
    }

    // MARK: Privileged command

    enum RestartOutcome: Equatable {
        case succeeded
        case cancelled
        case failed(String)
    }

    /// `launchctl kickstart -k` is the supported way to restart the service and
    /// works even when the daemon ignores SIGTERM; `killall -9` is the fallback
    /// for older systems. Spawned through `osascript` rather than in-process
    /// `NSAppleScript` — the in-process API silently fails without the
    /// apple-events entitlement (same reason the alert-volume writer shells out).
    nonisolated static func runPrivilegedRestart() async -> RestartOutcome {
        let script = "do shell script \"launchctl kickstart -k system/com.apple.audio.coreaudiod || killall -9 coreaudiod\" with administrator privileges"

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let errorPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed("Couldn't launch osascript: \(error.localizedDescription)"))
                    return
                }

                // Drain stderr BEFORE waiting: a full pipe would deadlock the child.
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded)
                    return
                }

                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // osascript reports a dismissed authorization dialog as -128.
                if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failed(message.isEmpty ? "Exit code \(process.terminationStatus)" : message))
                }
            }
        }
    }
}

