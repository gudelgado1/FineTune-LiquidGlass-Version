// FineTune/Audio/Engine/AudioTaskScheduler.swift
import Foundation

// MARK: - AudioTaskScheduler
//
// Centralizes the dozens of ad-hoc `Task { try? await Task.sleep(...); ... }`
// patterns scattered across the audio engine (tap recovery cooldowns, health
// monitor ticks, BT settle timers, debounced device-list refreshes, etc.).
//
// **Problem before this scheduler:**
//   * Each call site stored its own `Task<Void, Never>?` property.
//   * Cancellation logic was duplicated (and sometimes forgotten on deinit).
//   * Hot-reload and Settings reset paths leaked orphaned Tasks that re-fired
//     after their owner thought they were gone.
//   * Hard to mock for tests — every site that polled was untestable in unit
//     tests without sleeping for real time.
//
// **What the scheduler provides:**
//   * A single owner that holds all in-flight tasks keyed by `TaskID`.
//   * `schedule` overwrites any prior task with the same ID (debounce semantics).
//   * `cancel(id:)` and `cancelAll()` are O(1) / O(n) respectively.
//   * Deterministic teardown in `deinit` — no orphan Tasks survive.
//
// **What it intentionally does NOT do:**
//   * It does NOT run on a separate actor — every task is `@MainActor` so the
//     work can mutate UI state freely. Audio-thread work has its own
//     mechanisms (RT-safe vars + GCD queues) and never goes through here.

/// Identifier for a scheduled task. Subsystems define their own static
/// instances; ad-hoc string keys are also allowed for one-off cases.
struct AudioTaskID: Hashable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

// Pre-defined IDs for the call sites we know about today. New subsystems
// should add their own constants here so each ID has a single source of truth.
extension AudioTaskID {
    /// Health-monitor heartbeat. Wakes every 2 s to check for stalled taps.
    static let healthMonitor = AudioTaskID("audio.healthMonitor")

    /// Per-PID stale-tap cleanup (one task per PID; the PID is appended).
    static func pendingCleanup(pid: pid_t) -> AudioTaskID {
        AudioTaskID("audio.pendingCleanup.\(pid)")
    }

    /// Debounced default-device-list refresh after device add/remove.
    static let deviceListDebounce = AudioTaskID("audio.deviceListDebounce")

    /// Input-lock acquisition timeout.
    static let inputLockTimeout = AudioTaskID("audio.inputLockTimeout")

    /// Device-priority arbitration timeout.
    static let devicePriorityTimeout = AudioTaskID("audio.devicePriorityTimeout")

    /// Stale-cleanup periodic check.
    static let staleCleanup = AudioTaskID("audio.staleCleanup")

    /// Debounced tap-liveness revalidation. Coalesces bursts of triggers
    /// (memory-pressure storms, device-list churn, wake/foreground) into one
    /// pass so we don't hammer the HAL — and the engine — under load.
    static let livenessRevalidate = AudioTaskID("audio.livenessRevalidate")

    /// Post-wake settle + full rebuild of active taps. Aggregate devices can
    /// survive standby as "zombies" (alive but not delivering audio), which no
    /// cheap check detects, so we rebuild them after a settle delay.
    static let wakeRebuild = AudioTaskID("audio.wakeRebuild")

    /// Bluetooth confirmation timeout (one per device MAC).
    static func bluetoothConfirm(mac: String) -> AudioTaskID {
        AudioTaskID("audio.bluetoothConfirm.\(mac)")
    }

    /// Bluetooth error-flag auto-clear (one per device MAC).
    static func bluetoothErrorClear(mac: String) -> AudioTaskID {
        AudioTaskID("audio.bluetoothErrorClear.\(mac)")
    }
}

@MainActor
final class AudioTaskScheduler {
    private var tasks: [AudioTaskID: Task<Void, Never>] = [:]

    init() {}

    /// Schedules `work` to run after `delay`. Any task with the same ID is
    /// cancelled first — so this also serves as a "debounced fire after N ms"
    /// primitive when called repeatedly with the same ID.
    ///
    /// - Parameters:
    ///   - id: Unique ID for this task slot.
    ///   - delay: Wall-clock delay before `work` runs. Use `.zero` for
    ///     "schedule for the next tick" semantics.
    ///   - work: The async closure to run. Captured weakly via the task itself.
    /// - Returns: The created task, in case the caller wants to await it.
    @discardableResult
    func schedule(
        _ id: AudioTaskID,
        after delay: Duration,
        _ work: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        // Replace-by-cancel: any pending task with this ID is invalidated
        // before the new one is registered. This is intentional debounce
        // semantics — callers who want to chain should use distinct IDs.
        tasks[id]?.cancel()

        let task = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await work()
        }
        tasks[id] = task
        return task
    }

    /// Schedules a repeating loop. The loop calls `work` then sleeps `interval`
    /// before the next iteration, exiting cleanly when cancelled.
    @discardableResult
    func scheduleRepeating(
        _ id: AudioTaskID,
        every interval: Duration,
        _ work: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        tasks[id]?.cancel()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await work()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: interval)
            }
        }
        tasks[id] = task
        return task
    }

    /// Cancels and removes the task with the given ID. No-op if absent.
    func cancel(_ id: AudioTaskID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// Cancels every in-flight task. Call from `deinit` or any teardown path
    /// that wants a clean slate (e.g. settings reset, hot reload, sign-out).
    func cancelAll() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
    }

    /// Diagnostic — how many tasks are currently in flight. Useful in tests.
    var activeCount: Int { tasks.count }

    /// Diagnostic — set of currently-active IDs. Useful in tests to assert
    /// "exactly these tasks are pending".
    var activeIDs: Set<AudioTaskID> { Set(tasks.keys) }

    deinit {
        // Cancel all so any Task observing Task.isCancelled exits cleanly.
        // We can't reach the actor-isolated dictionary from a non-isolated
        // deinit, so we read it via the unsafe trick: tasks is captured
        // by-value here because the deinit runs synchronously on the last
        // owner's release thread.
        for task in tasks.values { task.cancel() }
    }
}
