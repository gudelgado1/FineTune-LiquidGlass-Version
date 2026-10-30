import Foundation

/// Control-side owner of device transitions (never accessed by the render callback).
/// Replacements cancel, then await, their predecessor so its deferred cleanup
/// cannot destroy the replacement's resources. An obsolete request never succeeds.
@MainActor
final class DeviceTransitionCoordinator {
    private var task: Task<Void, Error>?
    private var revision: UInt64 = 0

    func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        revision &+= 1
        let token = revision
        let previous = task
        previous?.cancel()
        let next = Task {
            _ = await previous?.result
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
        }
        task = next
        defer { if revision == token { task = nil } }
        try await withTaskCancellationHandler {
            try await next.value
        } onCancel: {
            next.cancel()
        }
    }

    func cancel() { task?.cancel() }
}
