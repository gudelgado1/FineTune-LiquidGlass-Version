import Foundation
import os

nonisolated enum TapLifecycleError: Error, Equatable, LocalizedError {
    case deadline, saturated, retirementFailed, asynchronousRequired
    var errorDescription: String? {
        switch self {
        case .deadline: return "Core Audio did not answer before the deadline. Pending work still owns its resources."
        case .saturated: return "Audio worker capacity is busy. Capture can retry when capacity is available."
        case .retirementFailed: return "Audio resource cleanup has not been acknowledged. New capture is paused."
        case .asynchronousRequired: return "Native capture requires asynchronous activation."
        }
    }
}

/// Bounded synchronous work outside MainActor. Ownership transfers at submission:
/// discard runs exactly once for every result not delivered successfully, including
/// rejection, cancellation and late completion. A slot remains held through discard.
nonisolated final class OwnedHALExecutor: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let limit: Int
    init(limit: Int = 4) { precondition(limit > 0); self.limit = limit }
    var hasCapacity: Bool { count.withLock { $0 < limit } }
    var activeCount: Int { count.withLock { $0 } }

    func run<T: Sendable>(timeout: TimeInterval = 4,
                          work: @escaping @Sendable () throws -> T,
                          discard: @escaping @Sendable (Result<T, Error>) -> Void = { _ in }) async throws -> T {
        let state = OSAllocatedUnfairLock<(finished: Bool, continuation: CheckedContinuation<T, Error>?)>(initialState: (false, nil))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { value -> Bool in
                    if value.finished { return true }
                    value.continuation = continuation
                    return false
                }
                if cancelled {
                    discard(.failure(CancellationError()))
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let admitted = count.withLock { value in
                    guard value < limit else { return false }; value += 1; return true
                }
                guard admitted else {
                    discard(.failure(TapLifecycleError.saturated))
                    let waiter = state.withLock { value in
                        value.finished = true; defer { value.continuation = nil }; return value.continuation
                    }
                    waiter?.resume(throwing: TapLifecycleError.saturated)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, timeout)) {
                    let waiter = state.withLock { value in
                        value.finished = true; defer { value.continuation = nil }; return value.continuation
                    }
                    waiter?.resume(throwing: TapLifecycleError.deadline)
                }
                let thread = Thread { [self] in
                    let result = Result { try work() }
                    let waiter = state.withLock { value in
                        value.finished = true; defer { value.continuation = nil }; return value.continuation
                    }
                    if case .failure = result { discard(result) }
                    else if waiter == nil { discard(result) }
                    count.withLock { $0 -= 1 }
                    waiter?.resume(with: result)
                }
                thread.name = "FineTune.HAL.Lifecycle"
                thread.stackSize = 1024 * 1024
                thread.start()
            }
        } onCancel: {
            let waiter = state.withLock { value in
                value.finished = true; defer { value.continuation = nil }; return value.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
