// FineTune/Audio/Engine/HALExecutor.swift
import AudioToolbox
import Foundation
import os

// MARK: - Deadline-bounded CoreAudio calls
//
// Every CoreAudio (HAL) call is a synchronous Mach IPC to `coreaudiod`. When
// that daemon wedges — alive but answering nobody — the call NEVER returns.
// Proven on 2026-07-29: FineTune's main thread sat in `mach_msg2_trap` in 100%
// of samples, inside a routine process-list refresh, and the app was frozen so
// hard it could only be killed with SIGKILL.
//
// The rule this type enforces: **no HAL call may ever block a thread we care
// about, and none may block indefinitely.** The call runs on a throwaway thread
// and the caller waits only until a deadline.
//
// A timed-out call leaks its thread — it is parked in the kernel and cannot be
// cancelled or killed. That is the unavoidable cost of a wedged daemon, so
// callers MUST pair this with `AudioSystemHealth`, which trips a circuit breaker
// and stops issuing new HAL work instead of spawning a thread per attempt.

enum HALExecutor {

    /// Runs a blocking HAL call off the caller's thread, returning `nil` if the
    /// HAL doesn't answer within `timeout`.
    ///
    /// - Warning: On timeout the work thread stays blocked in the kernel for the
    ///   life of the process. Never call this in an unbounded loop — gate it
    ///   behind `AudioSystemHealth`.
    static func run<T: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        // The work thread may still be blocked in the HAL when the deadline
        // expires, so the result crosses threads under a lock.
        // `OSAllocatedUnfairLock` rather than a hand-rolled generic box: a
        // custom `final class Box<T>` crashed the Swift 6.3 optimizer
        // (EarlyPerfInliner, on the box's deinit) in -O builds only.
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        let semaphore = DispatchSemaphore(value: 0)

        let thread = Thread {
            let value = work()
            box.withLock { $0 = value }
            semaphore.signal()
        }
        thread.name = "FineTune.HAL"
        thread.stackSize = 1024 * 1024
        thread.start()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let waited = semaphore.wait(timeout: .now() + timeout)
                let value = box.withLock { $0 }
                continuation.resume(returning: waited == .success ? value : nil)
            }
        }
    }

    /// One cheap round-trip that proves the daemon is answering: reading the
    /// size of the device list. Used both by the health watchdog and by the
    /// Settings reset flow.
    static func probeResponsive(timeout: TimeInterval) async -> Bool {
        let answered: Bool? = await run(timeout: timeout) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            )
            return status == noErr
        }
        return answered ?? false
    }
}
