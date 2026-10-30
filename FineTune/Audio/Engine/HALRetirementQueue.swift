import Foundation
import os

nonisolated final class HALRetirementTicket: Sendable {
    private let state = OSAllocatedUnfairLock<(result: Bool?, overdue: Bool)>(initialState: (nil, false))
    var result: Bool? { state.withLock { $0.result } }
    var isOverdue: Bool { state.withLock { $0.overdue } }
    fileprivate func finish(_ success: Bool) { state.withLock { $0.result = success; if !success { $0.overdue = true } } }
    fileprivate func retry() { state.withLock { $0.result = nil } }
    func wait(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            if let result { return result }
            if Task.isCancelled { return false }
            if ContinuousClock.now >= deadline {
                state.withLock { $0.overdue = true }
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Cleanup is never dropped: the queue owns the closure (and its HAL IDs/render
/// context) until acknowledgement. Two serial queues bound blocked cleanup threads.
/// Overdue/quarantined cleanup or a backlog stops NEW capture admission.
nonisolated final class HALRetirementQueue: Sendable {
    private struct Entry: Sendable {
        let ticket: HALRetirementTicket
        let work: @Sendable () throws -> Void
    }
    private let jobs = OSAllocatedUnfairLock<[UUID: Entry]>(initialState: [:])
    private let workers = [DispatchQueue(label: "FineTune.HAL.Retire.0", qos: .userInitiated),
                           DispatchQueue(label: "FineTune.HAL.Retire.1", qos: .userInitiated)]
    private let nextWorker = OSAllocatedUnfairLock(initialState: 0)
    private let admissionLimit: Int
    init(admissionLimit: Int = 16) { self.admissionLimit = admissionLimit }
    var pendingCount: Int { jobs.withLock { $0.count } }
    var allowsCapture: Bool {
        jobs.withLock { values in values.count < admissionLimit && !values.values.contains { $0.ticket.isOverdue } }
    }
    @discardableResult
    func enqueue(_ work: @escaping @Sendable () throws -> Void) -> HALRetirementTicket {
        let id = UUID(), ticket = HALRetirementTicket()
        jobs.withLock { $0[id] = Entry(ticket: ticket, work: work) }
        schedule(id)
        return ticket
    }
    func retryFailed() {
        let ids = jobs.withLock { values in
            values.compactMap { id, entry -> UUID? in
                guard entry.ticket.result == false else { return nil }
                entry.ticket.retry()
                return id
            }
        }
        for id in ids { schedule(id) }
    }
    private func schedule(_ id: UUID) {
        let index = nextWorker.withLock { value in defer { value = (value + 1) % workers.count }; return value }
        workers[index].async { [self] in
            guard let entry = jobs.withLock({ $0[id] }) else { return }
            do {
                try entry.work()
                _ = jobs.withLock { $0.removeValue(forKey: id) }
                entry.ticket.finish(true)
            } catch {
                // Quarantine keeps the resource/context alive. Only an explicit
                // retry can release it after a successful destroy acknowledgement.
                entry.ticket.finish(false)
            }
        }
    }
}
