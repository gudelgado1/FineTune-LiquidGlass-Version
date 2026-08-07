import Foundation
import Testing
@testable import FineTune

/// Thread-safe boolean for observing whether abandoned work completed.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("HALExecutor — deadline enforcement")
struct HALExecutorTests {

    @Test("returns the value when the work finishes in time")
    func returnsValueWhenFast() async {
        let value = await HALExecutor.run(timeout: 2.0) { 42 }
        #expect(value == 42)
    }

    @Test("returns nil instead of waiting for work that never finishes")
    func returnsNilOnTimeout() async {
        // Stands in for a wedged coreaudiod. The work blocks on a semaphore the
        // test owns, so it CANNOT complete — no wall-clock threshold is involved
        // and the result can't change under CI load.
        let gate = DispatchSemaphore(value: 0)
        let finished = Flag()

        let value: Int? = await HALExecutor.run(timeout: 0.2) {
            gate.wait()
            finished.set()
            return 7
        }

        #expect(value == nil, "a call that outlived its deadline must report nil")
        #expect(finished.isSet == false, "the caller returned without waiting for the work")

        gate.signal()  // let the abandoned thread exit
    }

    @Test("a timed-out call does not corrupt a later successful one")
    func timeoutDoesNotPoisonNextCall() async {
        let gate = DispatchSemaphore(value: 0)
        let timedOut: Int? = await HALExecutor.run(timeout: 0.2) {
            gate.wait()
            return 1
        }
        #expect(timedOut == nil)

        // The executor holds no shared state across calls, so a wedged HAL must
        // not stop the app from working the moment the daemon answers again.
        let ok = await HALExecutor.run(timeout: 5.0) { 99 }
        #expect(ok == 99)

        gate.signal()
    }
}

@Suite("AudioSystemHealth — circuit breaker")
@MainActor
struct AudioSystemHealthTests {

    @Test("starts closed so periodic HAL work is allowed")
    func startsResponsive() {
        let health = AudioSystemHealth()
        #expect(health.state == .responsive)
        #expect(health.allowsPeriodicHALWork == true)
        #expect(health.unresponsiveSince == nil)
    }

    @Test("one timeout is tolerated — a single stall under load must not suspend audio work")
    func singleTimeoutDoesNotTrip() {
        let health = AudioSystemHealth()
        health.reportTimeout()
        #expect(health.state == .responsive)
        #expect(health.allowsPeriodicHALWork == true)
    }

    @Test("two consecutive timeouts trip the breaker and suspend periodic work")
    func consecutiveTimeoutsTrip() {
        let health = AudioSystemHealth()
        health.reportTimeout()
        health.reportTimeout()
        #expect(health.state == .unresponsive)
        #expect(health.allowsPeriodicHALWork == false)
        #expect(health.unresponsiveSince != nil)
        health.stop()
    }

    @Test("a success between timeouts resets the streak")
    func successResetsStreak() {
        let health = AudioSystemHealth()
        health.reportTimeout()
        health.reportSuccess()
        health.reportTimeout()
        // Only one timeout since the last success — must still be closed.
        #expect(health.state == .responsive)
    }

    @Test("recovery fires onRecovered exactly once and re-allows work")
    func recoveryNotifiesOnce() {
        let health = AudioSystemHealth()
        var recoveredCount = 0
        health.onRecovered = { recoveredCount += 1 }

        health.reportTimeout()
        health.reportTimeout()
        #expect(health.allowsPeriodicHALWork == false)

        health.reportSuccess()
        #expect(health.state == .responsive)
        #expect(health.allowsPeriodicHALWork == true)
        #expect(recoveredCount == 1)

        // Further successes while already closed must not re-notify — the
        // callback triggers a full engine resync, which is expensive.
        health.reportSuccess()
        #expect(recoveredCount == 1)
    }

    @Test("external fix clears the breaker without firing the resync callback")
    func externalFixClearsWithoutCallback() {
        // The Settings reset already rebuilds the engine itself; firing
        // onRecovered too would run a second, redundant resync.
        let health = AudioSystemHealth()
        var recoveredCount = 0
        health.onRecovered = { recoveredCount += 1 }

        health.reportTimeout()
        health.reportTimeout()
        #expect(health.state == .unresponsive)

        health.forceRecoveredAfterExternalFix()
        #expect(health.state == .responsive)
        #expect(health.allowsPeriodicHALWork == true)
        #expect(recoveredCount == 0)
    }
}
