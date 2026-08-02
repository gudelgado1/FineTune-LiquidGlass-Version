import Foundation
import Testing
@testable import FineTune

@Suite("HALExecutor — deadline enforcement")
struct HALExecutorTests {

    @Test("returns the value when the work finishes in time")
    func returnsValueWhenFast() async {
        let value = await HALExecutor.run(timeout: 2.0) { 42 }
        #expect(value == 42)
    }

    @Test("returns nil instead of blocking when the work outlives the deadline")
    func returnsNilOnTimeout() async {
        // Stands in for a wedged coreaudiod: work that never finishes in time.
        // The caller MUST come back anyway — that is the whole contract.
        let start = Date()
        let value: Int? = await HALExecutor.run(timeout: 0.3) {
            Thread.sleep(forTimeInterval: 5.0)
            return 7
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(value == nil)
        #expect(elapsed < 3.0, "caller waited \(elapsed)s — deadline was not enforced")
    }

    @Test("a timed-out call does not corrupt a later successful one")
    func timeoutDoesNotPoisonNextCall() async {
        let timedOut: Int? = await HALExecutor.run(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 2.0)
            return 1
        }
        #expect(timedOut == nil)

        let ok = await HALExecutor.run(timeout: 2.0) { 99 }
        #expect(ok == 99)
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
