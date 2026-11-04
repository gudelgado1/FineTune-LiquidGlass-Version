import Foundation
import Testing
import os
@testable import FineTune

@Suite("Owned HAL jobs", .serialized)
struct OwnedHALExecutorTests {
    @Test("timeout keeps ownership until late work completes; discard happens once")
    func lateCompletionRetainsOwnership() async {
        let executor = OwnedHALExecutor(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let discarded = OSAllocatedUnfairLock(initialState: 0)
        do {
            let _: Int = try await executor.run(timeout: 0.02, work: { release.wait(); return 42 }, discard: { _ in discarded.withLock { $0 += 1 } })
            Issue.record("Expected timeout")
        } catch { #expect(error as? TapLifecycleError == .deadline) }
        #expect(executor.activeCount == 1)
        #expect(discarded.withLock { $0 } == 0)
        release.signal()
        for _ in 0..<200 {
            if executor.activeCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(discarded.withLock { $0 } == 1)
        #expect(executor.activeCount == 0)
    }

    @Test("rejection discards supplied ownership and does not start extra work")
    func saturatedRejectsWithoutLeaking() async {
        let executor = OwnedHALExecutor(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let discarded = OSAllocatedUnfairLock(initialState: 0)
        let _: Int? = try? await executor.run(timeout: 0.01, work: { release.wait(); return 1 })
        defer { release.signal() }
        do {
            let _: Int = try await executor.run(work: { Issue.record("Must not run"); return 2 }, discard: { _ in discarded.withLock { $0 += 1 } })
        } catch { #expect(error as? TapLifecycleError == .saturated) }
        #expect(discarded.withLock { $0 } == 1)
    }

    @Test("caller cancellation returns while blocked work still owns its result")
    func cancellationDiscardsLateResult() async {
        let executor = OwnedHALExecutor(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let began = OSAllocatedUnfairLock(initialState: false)
        let discarded = OSAllocatedUnfairLock(initialState: false)
        let caller = Task {
            try await executor.run(work: { began.withLock { $0 = true }; release.wait(); return 1 }, discard: { _ in discarded.withLock { $0 = true } })
        }
        while !began.withLock({ $0 }) { await Task.yield() }
        caller.cancel()
        do { _ = try await caller.value; Issue.record("Expected cancellation") } catch {}
        #expect(executor.activeCount == 1)
        release.signal()
        for _ in 0..<200 {
            if executor.activeCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(discarded.withLock { $0 })
    }
}
