// FineTune/Audio/Engine/HALExecutor.swift
import AudioToolbox
import Foundation
import os

// A timeout cannot cancel a synchronous HAL call. Keep its worker slot occupied
// until the call really returns, so repeated outages cannot leak unlimited threads.
nonisolated final class HALWorkerPool: Sendable {
    private let limit: Int
    private let inFlight = OSAllocatedUnfairLock(initialState: 0)

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    var activeWorkerCount: Int { inFlight.withLock { $0 } }

    func run<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        guard !Task.isCancelled else { return nil }
        let admitted = inFlight.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard admitted else { return nil }
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let value = work()
            box.withLock { $0 = value }
            inFlight.withLock { $0 -= 1 }
            semaphore.signal()
        }
        thread.name = "FineTune.HAL"
        thread.stackSize = 1024 * 1024
        thread.start()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let waited = semaphore.wait(timeout: .now() + max(0, timeout))
                let value = box.withLock { $0 }
                continuation.resume(returning: waited == .success ? value : nil)
            }
        }
    }
}

/// Deadline-bounded HAL reads. Four general workers plus one reserved health
/// probe; saturation fails closed, leaving the circuit breaker to handle recovery.
enum HALExecutor {
    private static let workers = HALWorkerPool(limit: 4)
    private static let probeWorker = HALWorkerPool(limit: 1)

    static func run<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
        await workers.run(timeout: timeout, work)
    }

    /// One cheap round-trip that proves the daemon is answering: reading the
    /// size of the device list. Used both by the health watchdog and by the
    /// Settings reset flow.
    static func probeResponsive(timeout: TimeInterval) async -> Bool {
        let answered: Bool? = await probeWorker.run(timeout: timeout) {
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
