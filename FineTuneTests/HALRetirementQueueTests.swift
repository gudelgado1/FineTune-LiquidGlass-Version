import Foundation
import os
import Testing
@testable import FineTune

@Suite("HAL retirement ownership", .serialized)
struct HALRetirementQueueTests {
    @Test("timeout blocks new admission but retains cleanup until acknowledgement")
    func timeoutRetainsCleanup() async {
        let queue = HALRetirementQueue()
        let release = DispatchSemaphore(value: 0)
        let cleaned = OSAllocatedUnfairLock(initialState: false)
        let ticket = queue.enqueue { release.wait(); cleaned.withLock { $0 = true } }
        #expect(await ticket.wait(timeout: 0.02) == false)
        #expect(queue.pendingCount == 1)
        #expect(!queue.allowsCapture)
        #expect(!cleaned.withLock { $0 })
        release.signal()
        #expect(await ticket.wait(timeout: 1))
        #expect(queue.pendingCount == 0)
        #expect(queue.allowsCapture)
    }
    @Test("failed destroy is quarantined and can be retried without dropping ownership")
    func failedDestroyRetainedForRetry() async {
        let queue = HALRetirementQueue()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let ticket = queue.enqueue {
            let value = attempts.withLock { $0 += 1; return $0 }
            if value == 1 { throw TapLifecycleError.retirementFailed }
        }
        #expect(await ticket.wait(timeout: 1) == false)
        #expect(queue.pendingCount == 1)
        #expect(!queue.allowsCapture)
        queue.retryFailed()
        #expect(await ticket.wait(timeout: 1))
        #expect(attempts.withLock { $0 } == 2)
        #expect(queue.pendingCount == 0)
    }
    @Test("backlog limits capture, never drops a shutdown cleanup")
    func backlogKeepsAllOwners() async {
        let queue = HALRetirementQueue(admissionLimit: 1)
        let release = DispatchSemaphore(value: 0)
        let first = queue.enqueue { release.wait() }
        #expect(!queue.allowsCapture)
        let second = queue.enqueue {}
        #expect(await second.wait(timeout: 1))
        #expect(queue.pendingCount == 1)
        release.signal()
        #expect(await first.wait(timeout: 1))
        #expect(queue.pendingCount == 0)
    }
}
