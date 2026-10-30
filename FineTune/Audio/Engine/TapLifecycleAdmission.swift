import Foundation

/// Bounds prepare/configure/start transactions as well as individual workers.
/// This avoids treating a normal burst of app activation as an unresponsive HAL.
@MainActor
final class TapLifecycleAdmission {
    static let shared = TapLifecycleAdmission()
    private let limit: Int
    private var active = 0
    init(limit: Int = 4) { self.limit = limit }
    func acquire(executor: OwnedHALExecutor, timeout: TimeInterval) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while active >= limit || !executor.hasCapacity {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TapLifecycleError.saturated }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        active += 1
    }
    func release() { precondition(active > 0); active -= 1 }
}
