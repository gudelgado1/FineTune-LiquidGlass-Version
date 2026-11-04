import Foundation
import os
import Testing
@testable import FineTune

@Suite("HAL worker admission", .serialized)
struct HALWorkerPoolTests {
    @Test("timed-out work retains its slot until it actually exits")
    func timeoutDoesNotReleaseWorkerSlot() async {
        let pool = HALWorkerPool(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let value: Int? = await pool.run(timeout: 0.05) {
            release.wait()
            return 1
        }
        defer { release.signal() }
        #expect(value == nil)
        #expect(pool.activeWorkerCount == 1)
        for _ in 0..<100 {
            let rejected = await pool.run(timeout: 0.05) {
                calls.withLock { $0 += 1 }
                return 2
            }
            #expect(rejected == nil)
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(pool.activeWorkerCount == 1)
        release.signal()
        for _ in 0..<200 {
            if pool.activeWorkerCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let recovered = await pool.run(timeout: 1) { 42 }
        #expect(recovered == 42)
        #expect(pool.activeWorkerCount == 0)
    }

    @Test("HAL work runs off main and does not block MainActor progress")
    @MainActor
    func mainActorRemainsResponsive() async {
        let pool = HALWorkerPool(limit: 1)
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            await pool.run(timeout: 1) {
                started.withLock { $0 = true }
                release.wait()
                return Thread.isMainThread
            }
        }
        for _ in 0..<100 {
            if started.withLock({ $0 }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.withLock { $0 })
        // This code executes on MainActor while HAL's worker is still blocked.
        #expect(pool.activeWorkerCount == 1)
        release.signal()
        #expect(await task.value == false)
    }
}
