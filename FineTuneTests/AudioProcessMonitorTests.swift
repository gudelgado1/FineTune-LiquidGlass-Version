import AppKit
import AudioToolbox
import Foundation
import os
import Testing
@testable import FineTune

/// Coordinates a suspended enumeration so a test can hold one pass "in flight"
/// and drive what happens to requests that arrive while it runs.
@MainActor
private final class EnumerationGate {
    private var resume: (() -> Void)?
    private(set) var callCount = 0

    /// Suspends until `release()` is called.
    func wait() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            resume = { continuation.resume() }
        }
    }

    func release() {
        let r = resume
        resume = nil
        r?()
    }

    var isSuspended: Bool { resume != nil }
}

@Suite("AudioProcessMonitor — publishing, coalescing, circuit breaker", .serialized)
@MainActor
struct AudioProcessMonitorTests {

    // MARK: - Publishing

    @Test("publishes the enumerated apps and notifies once")
    func publishesEnumeratedApps() async {
        let monitor = makeMonitor()
        var notifications = 0
        monitor.onAppsChanged = { _ in notifications += 1 }
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }

        monitor.refreshNow()
        await settle()

        #expect(monitor.activeApps.count == 1)
        #expect(monitor.activeApps.first?.bundleID == "com.test.alpha")
        #expect(notifications == 1)
    }

    @Test("does not republish or notify when nothing changed")
    func skipsRepublishWhenUnchanged() async {
        // Guards the popup-churn fix: activeApps is @Observable, so an
        // unconditional assignment invalidated every view reading it on each
        // periodic refresh — 6 times a minute, for nothing.
        let monitor = makeMonitor()
        var notifications = 0
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }

        monitor.refreshNow()
        await settle()
        monitor.onAppsChanged = { _ in notifications += 1 }

        monitor.refreshNow()
        await settle()
        monitor.refreshNow()
        await settle()

        #expect(notifications == 0)
        #expect(monitor.activeApps.count == 1)
    }

    @Test("publishes when an app appears and when one disappears")
    func publishesOnMembershipChange() async {
        let monitor = makeMonitor()
        var notifications = 0
        monitor.onAppsChanged = { _ in notifications += 1 }

        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }
        monitor.refreshNow()
        await settle()
        #expect(notifications == 1)

        monitor.enumerate = { _, _ in
            Self.enumeration([(1, 100, "com.test.alpha"), (2, 200, "com.test.beta")])
        }
        monitor.refreshNow()
        await settle()
        #expect(notifications == 2)
        #expect(monitor.activeApps.count == 2)

        monitor.enumerate = { _, _ in Self.enumeration([(2, 200, "com.test.beta")]) }
        monitor.refreshNow()
        await settle()
        #expect(notifications == 3)
        #expect(monitor.activeApps.map(\.bundleID) == ["com.test.beta"])
    }

    @Test("publishes when only the identity of an existing process changes")
    func publishesOnIdentityChange() async {
        // The fingerprint includes bundleID/name precisely so a late-resolving
        // app identity still reaches the UI even though pid and object IDs are
        // unchanged — otherwise the row would keep a stale name forever.
        let monitor = makeMonitor()
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }
        monitor.refreshNow()
        await settle()

        var notifications = 0
        monitor.onAppsChanged = { _ in notifications += 1 }
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.renamed")]) }
        monitor.refreshNow()
        await settle()

        #expect(notifications == 1)
        #expect(monitor.activeApps.first?.bundleID == "com.test.renamed")
    }

    @Test("filters system daemons out of the published list")
    func filtersSystemDaemons() async {
        let monitor = makeMonitor()
        monitor.enumerate = { _, _ in
            Self.enumeration([
                (1, 100, "com.apple.siri.embeddedspeech"),
                (2, 200, "com.apple.audio.someservice"),
                (3, 300, "com.test.realapp")
            ])
        }

        monitor.refreshNow()
        await settle()

        #expect(monitor.activeApps.map(\.bundleID) == ["com.test.realapp"])
    }

    @Test("a failed process-list read leaves the previous list untouched")
    func failedReadKeepsPreviousList() async {
        let monitor = makeMonitor()
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }
        monitor.refreshNow()
        await settle()

        var notifications = 0
        monitor.onAppsChanged = { _ in notifications += 1 }
        monitor.enumerate = { _, _ in
            ProcessEnumeration(facts: [], allObjectIDs: [], readSucceeded: false)
        }
        monitor.refreshNow()
        await settle()

        // A read error must not be mistaken for "every app stopped playing" —
        // that would tear down every tap.
        #expect(notifications == 0)
        #expect(monitor.activeApps.count == 1)
    }

    // MARK: - Coalescing (regression guard)

    @Test("a refresh requested during an in-flight pass runs afterwards instead of being dropped")
    func coalescesRatherThanDropsOverlappingRefresh() async {
        // REGRESSION GUARD. The off-main refactor first returned early while a
        // pass was in flight, silently dropping the request. The HAL fires its
        // notifications in bursts exactly when an app starts audio, so a
        // newly-audible app could stay missing from the list. The second pass
        // must run and pick it up.
        let monitor = makeMonitor()
        let gate = EnumerationGate()
        var payload = [(AudioObjectID(1), pid_t(100), "com.test.alpha")]

        monitor.enumerate = { _, _ in
            let snapshot = payload
            await gate.wait()
            return Self.enumeration(snapshot)
        }

        monitor.refreshNow()
        await settle()
        #expect(gate.isSuspended, "first pass should be suspended in the enumerator")

        // An app starts audio while the first pass is still running.
        payload.append((AudioObjectID(2), pid_t(200), "com.test.beta"))
        monitor.refreshNow()   // must be remembered, not dropped

        gate.release()         // first pass completes with the OLD payload
        await settle()

        #expect(gate.isSuspended, "the coalesced request should have started a second pass")
        gate.release()         // second pass completes with the NEW payload
        await settle()

        #expect(gate.callCount == 2)
        #expect(monitor.activeApps.count == 2)
        #expect(monitor.activeApps.contains { $0.bundleID == "com.test.beta" })
    }

    @Test("many requests during one pass collapse into a single follow-up")
    func manyOverlappingRequestsCollapseToOne() async {
        let monitor = makeMonitor()
        let gate = EnumerationGate()
        monitor.enumerate = { _, _ in
            await gate.wait()
            return Self.enumeration([(1, 100, "com.test.alpha")])
        }

        monitor.refreshNow()
        await settle()
        for _ in 0..<20 { monitor.refreshNow() }

        gate.release()
        await settle()
        gate.release()
        await settle()

        // 1 original + exactly 1 coalesced follow-up — never 21 passes.
        #expect(gate.callCount == 2)
    }

    // MARK: - Lifecycle

    @Test("stop discards an in-flight result and its queued refresh")
    func stopDiscardsPendingEnumeration() async {
        let monitor = makeMonitor()
        let gate = EnumerationGate()
        var notifications = 0
        monitor.onAppsChanged = { _ in notifications += 1 }
        monitor.enumerate = { _, _ in
            await gate.wait()
            return Self.enumeration([(1, 100, "com.test.old")])
        }

        monitor.refreshNow()
        await settle()
        #expect(gate.isSuspended)
        monitor.refreshNow() // queued behind the old enumeration
        monitor.stop()
        gate.release()
        await settle()
        monitor.refreshNow() // a stopped monitor stays stopped until start()
        await settle()

        #expect(monitor.activeApps.isEmpty)
        #expect(notifications == 0)
        #expect(gate.callCount == 1)
    }

    @Test("an old timeout cannot change health after stop")
    func stoppedEnumerationDoesNotReportTimeout() async {
        let monitor = makeMonitor()
        let health = AudioSystemHealth()
        monitor.health = health
        health.reportTimeout()
        let gate = EnumerationGate()
        monitor.enumerate = { _, _ in
            await gate.wait()
            return nil
        }

        monitor.refreshNow()
        await settle()
        monitor.stop()
        gate.release()
        await settle()

        #expect(health.state == .responsive, "the stopped pass must not trip the breaker")
        health.stop()
    }

    @Test("restart begins a fresh enumeration and old results cannot clear its in-flight state")
    func restartIsolatesPendingEnumerations() async {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        let oldGate = EnumerationGate()
        let newGate = EnumerationGate()
        var calls = 0
        var published: [String] = []
        monitor.onAppsChanged = { apps in published.append(contentsOf: apps.compactMap(\.bundleID)) }
        monitor.enumerate = { _, _ in
            calls += 1
            if calls == 1 {
                await oldGate.wait()
                return Self.enumeration([(1, 100, "com.test.old")])
            }
            await newGate.wait()
            return Self.enumeration([(2, 200, "com.test.new")])
        }

        monitor.start()
        await settle()
        #expect(oldGate.isSuspended)
        monitor.stop()
        monitor.start()
        await settle()
        #expect(newGate.isSuspended, "restart must not wait for the old IPC")

        oldGate.release()
        await settle()
        #expect(monitor.activeApps.isEmpty)
        monitor.refreshNow()
        await settle()
        #expect(calls == 2, "the old completion must not clear the new in-flight guard")

        newGate.release()
        await settle()
        #expect(calls == 3, "the new generation must still serve its queued refresh")
        newGate.release()
        await settle()
        #expect(published == ["com.test.new"])
        #expect(monitor.activeApps.first?.processObjectIDs == [2])
    }

    @Test("an old result finishing after the replacement cannot overwrite it")
    func oldEnumerationCannotOverwriteRestartedMonitor() async {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        let gate = EnumerationGate()
        monitor.enumerate = { _, _ in
            await gate.wait()
            return Self.enumeration([(1, 100, "com.test.old")])
        }
        monitor.start()
        await settle()
        monitor.stop()
        monitor.enumerate = { _, _ in Self.enumeration([(2, 200, "com.test.new")]) }
        monitor.start()
        await settle()
        #expect(monitor.activeApps.first?.bundleID == "com.test.new")

        gate.release()
        await settle()
        #expect(monitor.activeApps.first?.bundleID == "com.test.new")
        #expect(monitor.activeApps.first?.processObjectIDs == [2])
    }

    @Test("a cancelled listener never starts registration")
    func cancelledListenerDoesNotRegister() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let registration = AudioProcessListenerRegistration(
            add: { calls.withLock { $0 += 1 }; return noErr },
            remove: { calls.withLock { $0 += 1 }; return noErr }
        )
        registration.cancel()
        let status = await Task.detached { registration.install() }.value

        #expect(status == noErr)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("cancelling an in-flight listener removes it after registration completes")
    func cancelledPendingListenerRemovesLateRegistration() async {
        let registered = OSAllocatedUnfairLock(initialState: false)
        let removals = OSAllocatedUnfairLock(initialState: 0)
        let addStarted = OSAllocatedUnfairLock(initialState: false)
        let releaseAdd = DispatchSemaphore(value: 0)
        let registration = AudioProcessListenerRegistration(
            add: {
                addStarted.withLock { $0 = true }
                releaseAdd.wait()
                registered.withLock { $0 = true }
                return noErr
            },
            remove: {
                registered.withLock { $0 = false }
                removals.withLock { $0 += 1 }
                return noErr
            }
        )
        let install = Task.detached { registration.install() }
        for _ in 0..<100 where !addStarted.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(addStarted.withLock { $0 })
        registration.cancel()
        registration.cancel() // teardown is idempotent even while Add is blocked
        #expect(removals.withLock { $0 } == 0, "removal must wait until Add finishes")
        releaseAdd.signal()
        let status = await install.value

        #expect(status == noErr)
        #expect(!registered.withLock { $0 })
        #expect(removals.withLock { $0 } == 1)
    }

    // MARK: - Circuit breaker

    @Test("a timed-out enumeration reports to the breaker and keeps the old list")
    func timeoutReportsToBreaker() async {
        let monitor = makeMonitor()
        let health = AudioSystemHealth()
        monitor.health = health
        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }
        monitor.refreshNow()
        await settle()

        monitor.enumerate = { _, _ in nil }   // HAL missed its deadline
        monitor.refreshNow()
        await settle()
        #expect(health.state == .responsive, "one timeout is tolerated")

        monitor.refreshNow()
        await settle()
        #expect(health.state == .unresponsive)
        #expect(monitor.activeApps.count == 1, "a wedged HAL must not empty the app list")
        health.stop()
    }

    @Test("no enumeration is attempted while the breaker is tripped")
    func breakerSuppressesEnumeration() async {
        // Continuing to poll a wedged daemon strands one thread per attempt in
        // the kernel; the breaker's own probe owns recovery.
        let monitor = makeMonitor()
        let health = AudioSystemHealth()
        monitor.health = health
        health.reportTimeout()
        health.reportTimeout()
        #expect(health.state == .unresponsive)

        var calls = 0
        monitor.enumerate = { _, _ in
            calls += 1
            return Self.enumeration([(1, 100, "com.test.alpha")])
        }
        monitor.refreshNow()
        await settle()

        #expect(calls == 0)
        health.stop()
    }

    @Test("a successful pass clears a partial timeout streak")
    func successResetsTimeoutStreak() async {
        let monitor = makeMonitor()
        let health = AudioSystemHealth()
        monitor.health = health

        monitor.enumerate = { _, _ in nil }
        monitor.refreshNow()
        await settle()

        monitor.enumerate = { _, _ in Self.enumeration([(1, 100, "com.test.alpha")]) }
        monitor.refreshNow()
        await settle()

        monitor.enumerate = { _, _ in nil }
        monitor.refreshNow()
        await settle()

        // Timeout, success, timeout — never two in a row, so work continues.
        #expect(health.state == .responsive)
        health.stop()
    }

    @Test("a coalesced request is abandoned after a timeout")
    func timeoutDropsCoalescedRequest() async {
        // Re-running straight into a wedged HAL would strand another thread.
        let monitor = makeMonitor()
        let health = AudioSystemHealth()
        monitor.health = health
        let gate = EnumerationGate()
        monitor.enumerate = { _, _ in
            await gate.wait()
            return nil
        }

        monitor.refreshNow()
        await settle()
        monitor.refreshNow()   // arrives while the first pass hangs
        gate.release()
        await settle()

        #expect(gate.callCount == 1, "the coalesced request must not re-enter a wedged HAL")
        health.stop()
    }

    // MARK: - Helpers

    private func makeMonitor() -> AudioProcessMonitor {
        let monitor = AudioProcessMonitor()
        // Never touch the real HAL: the object IDs below are synthetic.
        monitor.managesHALListeners = false
        return monitor
    }

    /// Builds an enumeration from (objectID, pid, bundleID) triples.
    private static func enumeration(_ entries: [(AudioObjectID, pid_t, String)]) -> ProcessEnumeration {
        ProcessEnumeration(
            facts: entries.map { AudioProcessFacts(objectID: $0.0, pid: $0.1, bundleID: $0.2) },
            allObjectIDs: entries.map(\.0),
            readSucceeded: true
        )
    }

    /// Lets the monitor's internal Task hop through the main actor.
    private func settle() async {
        for _ in 0..<6 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<6 { await Task.yield() }
    }
}
