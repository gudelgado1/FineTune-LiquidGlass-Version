// FineTune/Audio/Monitors/AudioProcessMonitor.swift
import AppKit
import AudioToolbox
import os

/// HAL-derived facts about one audio process, gathered off the main thread.
/// `Sendable` so it can cross the executor's thread boundary.
nonisolated struct AudioProcessFacts: Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?

    init(objectID: AudioObjectID, pid: pid_t, bundleID: String?) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Result of one off-main enumeration pass.
nonisolated struct ProcessEnumeration: Sendable {
    let facts: [AudioProcessFacts]
    /// Every process object the HAL reported, for listener bookkeeping.
    let allObjectIDs: [AudioObjectID]
    /// `false` when the process-list read itself failed (distinct from a timeout,
    /// which surfaces as a nil enumeration).
    let readSucceeded: Bool

    init(facts: [AudioProcessFacts], allObjectIDs: [AudioObjectID], readSucceeded: Bool) {
        self.facts = facts
        self.allObjectIDs = allObjectIDs
        self.readSucceeded = readSucceeded
    }
}

/// Owns one HAL listener across asynchronous registration and teardown. A stop
/// can arrive before AddPropertyListener returns, including after its deadline;
/// in that case the worker that eventually finishes also removes the listener.
nonisolated final class AudioProcessListenerRegistration: Sendable {
    private struct State: Sendable {
        var started = false
        var cancelled = false
        var registered = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let add: @Sendable () -> OSStatus
    private let remove: @Sendable () -> OSStatus

    init(add: @escaping @Sendable () -> OSStatus, remove: @escaping @Sendable () -> OSStatus) {
        self.add = add
        self.remove = remove
    }

    /// Runs on the HAL worker, never the main actor.
    func install() -> OSStatus {
        let shouldInstall = state.withLock { state in
            guard !state.cancelled, !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldInstall else { return noErr }

        let status = add()
        if status == noErr {
            let needsRemoval = state.withLock { state in
                if state.cancelled { return true }
                state.registered = true
                return false
            }
            if needsRemoval { _ = remove() }
        }
        return status
    }

    func cancel() {
        let needsRemoval = state.withLock { state in
            state.cancelled = true
            guard state.registered else { return false }
            state.registered = false
            return true
        }
        if needsRemoval {
            let remove = self.remove
            Task {
                _ = await HALExecutor.run(timeout: 4.0, remove)
            }
        }
    }
}

/// Lightweight value for detecting process list changes without comparing icons.
/// Name/bundleID are included so a late-resolving app identity (e.g. the
/// NSRunningApplication entry appearing a refresh after the HAL object) still
/// propagates to the UI even though the pid/objectIDs didn't change.
private struct AppFingerprint: Hashable {
    let pid: pid_t
    let objectIDs: [AudioObjectID]
    let name: String
    let bundleID: String?
    let helperBacked: Bool
}

@Observable
@MainActor
final class AudioProcessMonitor: AudioProcessMonitoring {
    private(set) var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioProcessMonitor")

    /// Bundle ID prefixes for system daemons that should be filtered from the apps list
    /// These produce system audio (Siri, alerts, notifications) and shouldn't appear as user apps
    private static let systemDaemonPrefixes: [String] = [
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistant",
        "com.apple.audio",
        "com.apple.coreaudio",
        "com.apple.mediaremote",
        "com.apple.accessibility.heard",
        "com.apple.hearingd",
        "com.apple.voicebankingd",
        "com.apple.systemsound",
        "com.apple.FrontBoardServices",
        "com.apple.frontboard",
        "com.apple.springboard",
        "com.apple.notificationcenter",
        "com.apple.NotificationCenter",
        "com.apple.UserNotifications",
        "com.apple.usernotifications",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",
        "com.apple.dictation",
        "com.apple.corespeech",
        "com.apple.CoreSpeech",
        "com.apple.VoiceControl",
        "com.apple.voicecontrol",
    ]

    /// Process names for system daemons (fallback when bundle ID is nil or different format)
    private static let systemDaemonNames: [String] = [
        "systemsoundserverd",
        "systemsoundserv",
        "coreaudiod",
        "audiomxd",
        "speechrecognitiond",
        "dictationd",
        "corespeech",
    ]

    /// Returns true if the bundle ID or process name indicates a system daemon that should be filtered
    private func isSystemDaemon(bundleID: String?, name: String) -> Bool {
        // Check bundle ID prefixes
        if let bundleID {
            if Self.systemDaemonPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return true
            }
        }

        // Check process name (handles nil bundleID and format variations)
        let lowercaseName = name.lowercased()
        if Self.systemDaemonNames.contains(where: { lowercaseName.hasPrefix($0) }) {
            return true
        }

        return false
    }

    // Property listeners
    private var processListRegistration: AudioProcessListenerRegistration?
    private var processRegistrations: [AudioObjectID: AudioProcessListenerRegistration] = [:]
    private var isRunning = false
    // Explicit one-shot refreshes are allowed before start(), but stop() closes
    // the current lifetime until start() opens a new one.
    private var isStopped = false
    private var lifecycleID = UUID()
    private var periodicRefreshTask: Task<Void, Never>?
    private var trailingRefreshTask: Task<Void, Never>?
    private var lastRefreshTime: Date = .distantPast
    /// Only one enumeration in flight at a time. On a wedged HAL the enumeration
    /// never returns, so without this every timer tick would strand another
    /// thread in the kernel.
    private var refreshInFlight = false
    /// A refresh requested while one was already running. Enumerating 30-odd
    /// process objects takes ~90 HAL round-trips, and the HAL fires its
    /// notifications in bursts exactly when an app starts audio — so dropping
    /// the overlapping request (rather than re-running it) left newly-audible
    /// apps missing from the list until some later refresh happened to land.
    private var refreshRequestedWhileInFlight = false

    /// Circuit breaker. While the HAL is unresponsive this monitor issues no
    /// enumerations at all — `AudioSystemHealth` owns the recovery probe.
    var health: AudioSystemHealth?

    /// How long the HAL gets to enumerate audio processes before we treat the
    /// daemon as wedged. Generous: this walk is several IPC round-trips and can
    /// legitimately be slow under heavy load.
    private let enumerationTimeout: TimeInterval = 6.0

    /// Whether to register HAL listeners. Tests inject synthetic
    /// process objects, so registering real listeners for them would be pointless
    /// IPC against IDs the HAL never issued.
    var managesHALListeners = true

    /// Performs one deadline-bounded enumeration. Returns `nil` when the HAL
    /// missed its deadline. Injectable so tests can drive the publish, coalesce,
    /// and circuit-breaker paths without a real `coreaudiod`.
    var enumerate: (_ excludingPID: pid_t, _ timeout: TimeInterval) async -> ProcessEnumeration? = { pid, timeout in
        await HALExecutor.run(timeout: timeout) {
            AudioProcessMonitor.enumerateAudioProcesses(excluding: pid)
        }
    }

    /// Function type for the private responsibility API
    private typealias ResponsibilityFunc = @convention(c) (pid_t) -> pid_t

    /// Gets the "responsible" PID for a process using Apple's private API.
    /// This is what Activity Monitor uses to show the correct parent for XPC services.
    private func getResponsiblePID(for pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsiblePID = unsafeBitCast(symbol, to: ResponsibilityFunc.self)(pid)
        return responsiblePID > 0 && responsiblePID != pid ? responsiblePID : nil
    }

    /// Finds the responsible application for a helper/XPC process.
    /// Uses Apple's responsibility API first, falls back to process tree walking.
    private func findResponsibleApp(
        for pid: pid_t,
        in runningAppsByPID: [pid_t: NSRunningApplication]
    ) -> NSRunningApplication? {
        // First try Apple's responsibility API (works for XPC services like Safari's WebKit processes)
        if let responsiblePID = getResponsiblePID(for: pid),
           let app = runningAppsByPID[responsiblePID],
           app.bundleURL?.pathExtension == "app" {
            return app
        }

        // Fall back to walking up the process tree (works for Chrome/Brave helpers)
        var currentPID = pid
        var visited = Set<pid_t>()

        while currentPID > 1 && !visited.contains(currentPID) {
            visited.insert(currentPID)

            // Check if this PID is a proper app bundle (.app, not .xpc service)
            if let app = runningAppsByPID[currentPID],
               app.bundleURL?.pathExtension == "app" {
                return app
            }

            // Get parent PID using sysctl
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, currentPID]

            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }

            let parentPID = info.kp_eproc.e_ppid
            if parentPID == currentPID { break }
            currentPID = parentPID
        }

        return nil
    }

    func start() {
        guard !isRunning else { return }

        logger.debug("Starting audio process monitor")
        isRunning = true
        isStopped = false

        if managesHALListeners {
            let generation = lifecycleID
            let registration = makeRegistration(
                objectID: .system,
                selector: kAudioHardwarePropertyProcessObjectList,
                generation: generation
            )
            processListRegistration = registration
            Task { @MainActor [weak self] in
                let status = await HALExecutor.run(timeout: 4.0) { registration.install() }
                guard let self, self.lifecycleID == generation,
                      self.processListRegistration === registration else {
                    registration.cancel()
                    return
                }
                if status != noErr {
                    registration.cancel()
                    self.processListRegistration = nil
                    self.logger.error("Failed to add process list listener: \(status.map(String.init) ?? "timeout")")
                }
            }
        }

        refresh()
        // HAL notifications can be missed during rapid process lifecycle changes.
        startPeriodicRefresh()
    }

    func stop() {
        logger.debug("Stopping audio process monitor")

        // Invalidate before teardown: old enumerations, callbacks, and listener
        // registrations must never publish into a subsequent start(). Clearing
        // these flags lets the new lifetime enumerate without waiting for old IPC.
        lifecycleID = UUID()
        isRunning = false
        isStopped = true
        refreshInFlight = false
        refreshRequestedWhileInFlight = false
        lastRefreshTime = .distantPast
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil

        processListRegistration?.cancel()
        processListRegistration = nil
        for registration in processRegistrations.values { registration.cancel() }
        processRegistrations.removeAll()
    }

    /// Coalesces bursts of HAL process notifications. The first event refreshes
    /// immediately (tap-creation latency for a newly-audible app stays at zero);
    /// events landing within the next 100 ms fold into ONE trailing refresh
    /// instead of a storm of full process-list scans (NSWorkspace + per-process
    /// HAL reads + sysctl walks, all on the main thread).
    private func scheduleCoalescedRefresh() {
        guard !isStopped else { return }
        let now = Date()
        if now.timeIntervalSince(lastRefreshTime) >= 0.1 {
            lastRefreshTime = now
            refresh()
        } else if trailingRefreshTask == nil {
            trailingRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self else { return }
                self.trailingRefreshTask = nil
                self.lastRefreshTime = Date()
                self.refresh()
            }
        }
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 10s is sufficient as a safety net — HAL listeners handle most changes.
                // Lower intervals waste CPU at idle (#176).
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    /// Forces an immediate enumeration, ignoring the notification throttle.
    /// Still honors the in-flight guard and the circuit breaker.
    func refreshNow() {
        lastRefreshTime = Date()
        refresh()
    }

    /// Enumerates audio processes with a deadline, then publishes on the main
    /// actor. **Every HAL call happens off the main thread** — this exact walk
    /// froze the whole app on 2026-07-29 when `coreaudiod` wedged and its IPC
    /// never returned (main thread blocked in `mach_msg2_trap`, 100% of samples).
    private func refresh() {
        guard !isStopped else { return }
        // Coalesce rather than drop: the caller's event (an app starting or
        // stopping audio) must still be reflected once the running pass ends.
        if refreshInFlight {
            refreshRequestedWhileInFlight = true
            return
        }
        if let health, !health.allowsPeriodicHALWork { return }
        refreshInFlight = true

        let myPID = ProcessInfo.processInfo.processIdentifier
        let generation = lifecycleID
        Task { @MainActor [weak self] in
            guard let self, self.lifecycleID == generation, !self.isStopped else { return }
            let timeout = self.enumerationTimeout
            let enumeration = await self.enumerate(myPID, timeout)
            // A completion from before stop() must not publish, report health,
            // or clear the in-flight/coalescing state of a replacement refresh.
            guard self.lifecycleID == generation, !self.isStopped else { return }
            self.refreshInFlight = false

            guard let enumeration else {
                self.logger.error("Audio process enumeration timed out after \(timeout)s — HAL not answering")
                self.health?.reportTimeout()
                // Drop any coalesced request: the HAL is not answering, and
                // re-running would strand another thread. The breaker's recovery
                // probe owns the next attempt.
                self.refreshRequestedWhileInFlight = false
                return
            }
            self.health?.reportSuccess()
            if enumeration.readSucceeded {
                self.publish(enumeration)
            }
            // Serve whatever arrived while this pass was running.
            if self.lifecycleID == generation, !self.isStopped, self.refreshRequestedWhileInFlight {
                self.refreshRequestedWhileInFlight = false
                self.refresh()
            }
        }
    }

    /// The HAL half of a refresh. Runs entirely off the main thread and touches
    /// no actor-isolated state, so it is safe to abandon on timeout.
    nonisolated static func enumerateAudioProcesses(excluding myPID: pid_t) -> ProcessEnumeration {
        guard let processIDs = try? AudioObjectID.readProcessList() else {
            return ProcessEnumeration(facts: [], allObjectIDs: [], readSucceeded: false)
        }
        var facts: [AudioProcessFacts] = []
        facts.reserveCapacity(processIDs.count)
        for objectID in processIDs {
            guard let pid = try? objectID.readProcessPID(), pid != myPID else { continue }
            guard objectID.readProcessIsRunning() else { continue }
            facts.append(
                AudioProcessFacts(
                    objectID: objectID,
                    pid: pid,
                    bundleID: objectID.readProcessBundleID()
                )
            )
        }
        return ProcessEnumeration(facts: facts, allObjectIDs: processIDs, readSucceeded: true)
    }

    /// The AppKit half: resolves owning apps, names, and icons, then publishes.
    /// Main-actor only — `NSRunningApplication.icon`/`localizedName` and the
    /// `@Observable` write both belong here.
    private func publish(_ enumeration: ProcessEnumeration) {
            let runningApps = NSWorkspace.shared.runningApplications
            let runningAppsByPID = Dictionary(
                runningApps.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { _, latest in latest }
            )

            var appsByPID: [pid_t: AudioApp] = [:]

            for facts in enumeration.facts {
                let objectID = facts.objectID
                let pid = facts.pid

                // Try to find the parent app (for helper processes like Safari Graphics and Media)
                let directApp = runningAppsByPID[pid]

                // Check if it's a real app bundle (.app), not an XPC service (.xpc)
                let isRealApp = directApp?.bundleURL?.pathExtension == "app"
                let resolvedApp = isRealApp ? directApp : findResponsibleApp(for: pid, in: runningAppsByPID)
                let parentPID = resolvedApp?.processIdentifier ?? pid
                let isHelper = parentPID != pid

                // Use resolved app's info, falling back to the bundle ID the HAL
                // reported during enumeration (already captured off-main — never
                // re-read it here, that would put IPC back on the main thread).
                let name = resolvedApp?.localizedName
                    ?? facts.bundleID?.components(separatedBy: ".").last
                    ?? "Unknown"
                let icon = resolvedApp?.icon
                    ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let bundleID = resolvedApp?.bundleIdentifier ?? facts.bundleID

                // Skip system daemons (siri, coreaudio, etc.) - they shouldn't appear in the apps list
                if isSystemDaemon(bundleID: bundleID, name: name) { continue }

                // Merge helper process objectIDs into parent app entry
                if let existing = appsByPID[parentPID] {
                    if !existing.processObjectIDs.contains(objectID) {
                        var mergedIDs = existing.processObjectIDs
                        mergedIDs.append(objectID)
                        mergedIDs.sort()
                        appsByPID[parentPID] = AudioApp(
                            id: existing.id,
                            processObjectIDs: mergedIDs,
                            name: existing.name,
                            icon: existing.icon,
                            bundleID: existing.bundleID,
                            isHelperBacked: existing.isHelperBacked || isHelper
                        )
                    }
                } else {
                    appsByPID[parentPID] = AudioApp(
                        id: parentPID,
                        processObjectIDs: [objectID],
                        name: name,
                        icon: icon,
                        bundleID: bundleID,
                        isHelperBacked: isHelper
                    )
                }
            }

            // Update per-process listeners
            updateProcessListeners(for: enumeration.allObjectIDs)

            let sorted = appsByPID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Only publish when the list actually changed. `activeApps` is
            // @Observable — an unconditional assignment invalidated every view
            // reading it (the whole popup) on each 10 s periodic refresh and each
            // HAL notification, even when nothing changed.
            let oldSet = Set(activeApps.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs, name: $0.name, bundleID: $0.bundleID, helperBacked: $0.isHelperBacked) })
            let newSet = Set(sorted.map { AppFingerprint(pid: $0.id, objectIDs: $0.processObjectIDs, name: $0.name, bundleID: $0.bundleID, helperBacked: $0.isHelperBacked) })

            if oldSet != newSet {
                activeApps = sorted
                onAppsChanged?(activeApps)
            }
    }

    /// Diffs the listener set on the main actor (it owns the block dictionary),
    /// then performs the HAL registration calls off the main thread — they are
    /// IPC too, and a wedged daemon must not be able to freeze the UI through
    /// listener churn.
    private func updateProcessListeners(for processIDs: [AudioObjectID]) {
        guard managesHALListeners, !isStopped else { return }
        let currentSet = Set(processIDs)
        let monitoredProcesses = Set(processRegistrations.keys)

        for objectID in monitoredProcesses.subtracting(currentSet) {
            processRegistrations.removeValue(forKey: objectID)?.cancel()
        }
        for objectID in currentSet.subtracting(monitoredProcesses) {
            addProcessListener(for: objectID)
        }
    }

    private func addProcessListener(for objectID: AudioObjectID) {
        let generation = lifecycleID
        let registration = makeRegistration(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunning,
            generation: generation
        )
        processRegistrations[objectID] = registration
        Task { @MainActor [weak self] in
            let status = await HALExecutor.run(timeout: 4.0) { registration.install() }
            guard let self, self.lifecycleID == generation,
                  self.processRegistrations[objectID] === registration else {
                registration.cancel()
                return
            }
            if status != noErr {
                // A timed-out add can still finish later. Cancelling its token
                // makes that worker remove the late registration itself.
                registration.cancel()
                self.processRegistrations.removeValue(forKey: objectID)
                self.logger.warning("Failed to add isRunning listener for \(objectID): \(status.map(String.init) ?? "timeout")")
            }
        }
    }

    private func makeRegistration(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        generation: UUID
    ) -> AudioProcessListenerRegistration {
        let logger = self.logger
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleID == generation, !self.isStopped else { return }
                self.scheduleCoalescedRefresh()
            }
        }
        return AudioProcessListenerRegistration(
            add: {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                return AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
            },
            remove: {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
                if status != noErr, status != OSStatus(kAudioHardwareBadObjectError) {
                    logger.warning("Failed to remove process listener for \(objectID): \(status)")
                }
                return status
            }
        )
    }
}
