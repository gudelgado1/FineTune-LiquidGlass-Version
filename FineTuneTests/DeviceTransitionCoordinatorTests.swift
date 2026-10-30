import Foundation
import Testing
@testable import FineTune

@Suite("Device transition ownership", .serialized)
@MainActor
struct DeviceTransitionCoordinatorTests {
    @Test("replacement waits for cancelled predecessor cleanup")
    func replacementWaitsForCleanup() async throws {
        let coordinator = DeviceTransitionCoordinator()
        var started = false
        var cleaned = false
        var beganAfterCleanup = false
        let first = Task {
            try await coordinator.run {
                started = true
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    // Cleanup can suspend (e.g. waiting for an IO proc to stop).
                    await Task.yield()
                    await Task.yield()
                    cleaned = true
                    throw error
                }
            }
        }
        while !started { await Task.yield() }
        try await coordinator.run { beganAfterCleanup = cleaned }
        _ = await first.result
        #expect(cleaned)
        #expect(beganAfterCleanup)
    }

    @Test("a superseded request throws cancellation even if work ignores it")
    func obsoleteWorkCannotReportSuccess() async throws {
        let coordinator = DeviceTransitionCoordinator()
        var started = false
        var obsoleteSucceeded = false
        let first = Task {
            do {
                try await coordinator.run {
                    started = true
                    try? await Task.sleep(for: .seconds(30))
                }
                obsoleteSucceeded = true
            } catch {}
        }
        while !started { await Task.yield() }
        try await coordinator.run {}
        await first.value
        #expect(!obsoleteSucceeded)
    }
    @Test("caller cancellation cancels the operation and finishes cleanup")
    func callerCancellationPropagates() async {
        let coordinator = DeviceTransitionCoordinator()
        var started = false
        var cleaned = false
        var succeeded = false
        let caller = Task {
            do {
                try await coordinator.run {
                    started = true
                    defer { cleaned = true }
                    try await Task.sleep(for: .seconds(30))
                }
                succeeded = true
            } catch {}
        }
        while !started { await Task.yield() }
        caller.cancel()
        await caller.value
        #expect(cleaned)
        #expect(!succeeded)
    }

}
