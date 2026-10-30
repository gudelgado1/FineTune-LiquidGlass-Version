import AudioToolbox
import Foundation
import os

/// MainActor owns route intent and HAL leases. An IO proc captures only its own
/// TapRenderContext; no callback reads controller fields or adopts another proc's history.
@MainActor
final class ProcessTapController: ProcessTapControlling {
    let app: AudioApp
    private let adapter: any TapHALAdapting
    private let executor: OwnedHALExecutor
    private let retirements: HALRetirementQueue
    private let timeout: TimeInterval
    private let transition = DeviceTransitionCoordinator()
    private let crossfade = CrossfadeState()
    private var activation: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var nextID: UInt32 = 0
    private var activated = false
    private var switching = false
    private var activationTick: UInt64 = 0
    private var dsp = TapDSPConfiguration()
    private var targetDeviceUIDs: [String]
    private var preferredSource: String?
    private(set) var currentDeviceUIDs: [String]
    private var tickets: [HALRetirementTicket] = []
    private var primary: LiveTap?
    private var secondary: LiveTap?
    private var pending: TapRenderContext?
    // Test callback seam has no HAL resources, but uses the same production context.
    private var testContext: TapRenderContext?
    nonisolated private final class LiveTap: Sendable {
        let resource: PreparedTap
        let context: TapRenderContext
        private let adapter: any TapHALAdapting
        private let queue: HALRetirementQueue
        init(resource: PreparedTap, context: TapRenderContext, adapter: any TapHALAdapting, queue: HALRetirementQueue) {
            self.resource = resource; self.context = context; self.adapter = adapter; self.queue = queue
        }
        deinit {
            context.setRole(.retired)
            resource.retire(adapter: adapter, queue: queue)
        }
    }
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "ProcessTapController")

    var renderClock: TapRenderClock? { primary.map { TapRenderClock(aggregateDeviceID: $0.resource.aggregateID, sampleRate: $0.resource.sampleRate) } }
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? { preferredSource }
    var volume: Float = 1 { didSet { updateParameters() } }
    var isMuted = false { didSet { updateParameters() } }
    var currentDeviceVolume: Float = 1
    var isDeviceMuted = false
    var audioLevel: Float { contexts.map(\.audioLevel).max() ?? 0 }
    var renderDiagnostics: TapRenderDiagnostics {
        let values = contexts.map(\.diagnostics)
        return TapRenderDiagnostics(callbackCount: values.reduce(0) { $0 &+ $1.callbackCount },
                                    longGapCount: values.reduce(0) { $0 &+ $1.longGapCount })
    }
    private var contexts: [TapRenderContext] { [primary?.context, secondary?.context, pending, testContext].compactMap { $0 } }
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom))
    }()
    init(app: AudioApp, targetDeviceUIDs: [String], deviceMonitor: AudioDeviceMonitor? = nil,
         preferredTapSourceDeviceUID: String? = nil,
         adapter: (any TapHALAdapting)? = nil, executor: OwnedHALExecutor? = nil,
         retirements: HALRetirementQueue? = nil, timeout: TimeInterval = 4) {
        precondition(!targetDeviceUIDs.isEmpty)
        self.app = app; self.targetDeviceUIDs = targetDeviceUIDs; self.currentDeviceUIDs = targetDeviceUIDs
        self.preferredSource = preferredTapSourceDeviceUID
        self.adapter = adapter ?? NativeTapHALAdapter.shared
        self.executor = executor ?? NativeTapHALAdapter.executor
        self.retirements = retirements ?? NativeTapHALAdapter.retirements
        self.timeout = timeout
    }
    convenience init(app: AudioApp, targetDeviceUID: String, deviceMonitor: AudioDeviceMonitor? = nil,
                     preferredTapSourceDeviceUID: String? = nil) {
        self.init(app: app, targetDeviceUIDs: [targetDeviceUID], deviceMonitor: deviceMonitor,
                  preferredTapSourceDeviceUID: preferredTapSourceDeviceUID)
    }

    // Legacy synchronous adapter interface is only for mocks. Native lifecycle never blocks control.
    func activate() throws { throw TapLifecycleError.asynchronousRequired }
    func activate(initialDSP: TapDSPConfiguration) throws { throw TapLifecycleError.asynchronousRequired }
    func beginActivation(initialDSP: TapDSPConfiguration, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        // Register initial configuration before yielding, so immediate UI/DSP
        // edits to the pending placeholder cannot be overwritten by the task.
        dsp = initialDSP
        activation = Task { [self] in
            do { try await activateCurrentConfiguration(); completion(.success(())) }
            catch { completion(.failure(error)) }
        }
    }
    func activateAwaiting(initialDSP: TapDSPConfiguration) async throws {
        dsp = initialDSP
        try await activateCurrentConfiguration()
    }
    private func activateCurrentConfiguration() async throws {
        try await transition.run { [self] in
            guard !activated else { return }
            let epoch = generation
            let live = try await makeLiveTap(uids: targetDeviceUIDs, role: .primary, initialVolume: nil)
            guard epoch == generation, !Task.isCancelled else { retire(live); throw CancellationError() }
            primary = live; pending = nil; activated = true; activationTick = mach_absolute_time()
        }
    }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { contexts.contains { $0.isRecent(within: seconds) } }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool {
        activationTick != 0 && contexts.contains { $0.lastRenderTick != 0 && $0.role != .retired }
            && Double(mach_absolute_time() &- activationTick) * Self.nanosPerTick >= minActiveSeconds * 1_000_000_000
    }
    func checkResourceLiveness(timeout: TimeInterval) async -> Bool? {
        guard activated, !switching, let resource = primary?.resource else { return true }
        let id = resource.aggregateID
        return await HALExecutor.run(timeout: timeout) { id.deviceLiveness() != .dead }
    }
    func setDSPBypass(_ bypass: Bool) { dsp.bypass = bypass; updateParameters() }
    private func updateParameters() {
        for context in contexts { context.update(volume: volume, muted: isMuted, bypass: dsp.bypass) }
    }
    func updateEQSettings(_ settings: EQSettings) { dsp.eq = settings; for context in contexts { context.eq.updateSettings(settings) } }
    func updateAutoEQProfile(_ profile: AutoEQProfile?) { dsp.autoEQProfile = profile; for context in contexts { context.autoEQ.updateProfile(profile) } }
    func setAutoEQPreampEnabled(_ enabled: Bool) { dsp.autoEQPreampEnabled = enabled; for context in contexts { context.autoEQ.setPreampEnabled(enabled) } }
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        dsp.loudnessVolume = volume; dsp.loudnessCompensationEnabled = enabled
        for context in contexts {
            if enabled { context.compensator.updateForVolume(volume) } else { context.compensator.setEnabled(false) }
        }
    }
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        dsp.loudnessEqualization = settings
        for context in contexts { context.updateEqualizer(settings) }
    }

    private func makeLiveTap(uids: [String], role: TapRenderContext.Role, initialVolume: Float?) async throws -> LiveTap {
        try await TapLifecycleAdmission.shared.acquire(executor: executor, timeout: timeout)
        defer { TapLifecycleAdmission.shared.release() }
        retirements.retryFailed()
        guard retirements.allowsCapture else { throw TapLifecycleError.retirementFailed }
        let plan = TapHALPlan(pid: app.id, processObjectIDs: app.processObjectIDs,
                              outputUIDs: uids, preferredSourceUID: preferredSource)
        let adapter = self.adapter, queue = retirements
        let resource = try await executor.run(timeout: timeout, work: { try adapter.prepare(plan) }, discard: { result in
            if case .success(let resource) = result { resource.retire(adapter: adapter, queue: queue) }
        })
        var startSubmitted = false
        var startReturned = false
        var context: TapRenderContext?
        do {
            try Task.checkCancellation()
            nextID &+= 1; if nextID == 0 { nextID = 1 }
            let render = TapRenderContext(id: nextID, sampleRate: resource.sampleRate,
                stereoLeft: resource.stereoLeft, stereoRight: resource.stereoRight,
                role: role, crossfade: crossfade, dsp: dsp, volume: initialVolume ?? volume, muted: isMuted)
            context = render
            pending = render
            render.update(volume: volume, muted: isMuted, bypass: dsp.bypass)
            startSubmitted = true
            let _: PreparedTap = try await executor.run(timeout: timeout, work: {
                guard render.role != .retired else { throw CancellationError() }
                try adapter.start(resource, context: render)
                return resource
            }, discard: { _ in
                render.setRole(.retired)
                resource.retire(adapter: adapter, queue: queue)
            })
            startReturned = true
            try Task.checkCancellation()
            return LiveTap(resource: resource, context: render, adapter: adapter, queue: queue)
        } catch {
            context?.setRole(.retired)
            if let context, pending === context { pending = nil }
            // While start is still blocked the WORKER owns the resource. Its
            // discard hook retires it later; never race destroy against start.
            if !startSubmitted || startReturned { resource.retire(adapter: adapter, queue: queue) }
            throw error
        }
    }
    private func retire(_ live: LiveTap) {
        live.context.setRole(.retired)
        if pending === live.context { pending = nil }
        tickets.append(live.resource.retire(adapter: adapter, queue: retirements))
        tickets.removeAll { $0.result == true }
    }
    func switchDevice(to uid: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        try await updateDevices(to: [uid], preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: sourceDeviceDead)
    }
    func updateDevices(to uids: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        precondition(!uids.isEmpty)
        try await transition.run { [self] in
            guard activated else { targetDeviceUIDs = uids; currentDeviceUIDs = uids; preferredSource = preferredTapSourceDeviceUID; return }
            preferredSource = preferredTapSourceDeviceUID
            guard uids != currentDeviceUIDs else { return }
            try await replace(uids: uids, sourceDead: sourceDeviceDead)
        }
    }
    func refreshTapSource(_ uid: String?) async throws {
        try await transition.run { [self] in
            guard preferredSource != uid else { return }
            preferredSource = uid
            guard activated else { return }
            try await replace(uids: currentDeviceUIDs, sourceDead: false)
        }
    }
    private func replace(uids: [String], sourceDead: Bool) async throws {
        switching = true; defer { switching = false }
        let epoch = generation
        if !sourceDead {
            do {
                crossfade.beginWarmup()
                let live = try await makeLiveTap(uids: uids, role: .secondary, initialVolume: nil)
                guard generation == epoch, activated, !Task.isCancelled else { retire(live); throw CancellationError() }
                secondary = live; pending = nil
                var promoted = false
                defer {
                    if !promoted { retire(live); secondary = nil; crossfade.complete() }
                }
                let profile = live.resource.profile
                crossfade.totalSamples = CrossfadeConfig.totalSamples(at: live.resource.sampleRate, for: profile)
                try await Task.sleep(for: .milliseconds(profile.warmupMs))
                guard try await crossfade.waitForWarmup(timeout: .milliseconds(profile.timeoutExtraMs)) else { throw CrossfadeError.secondaryTapFailed }
                crossfade.beginCrossfading()
                let deadline = ContinuousClock.now.advanced(by: .seconds(CrossfadeConfig.duration(for: profile) + Double(profile.timeoutExtraMs) / 1000))
                while !crossfade.isCrossfadeComplete, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try Task.checkCancellation()
                guard crossfade.isCrossfadeComplete, generation == epoch, activated else { throw CrossfadeError.secondaryTapFailed }
                if let primary { retire(primary) }
                live.context.setRole(.primary)
                primary = live; secondary = nil; promoted = true; crossfade.complete()
                targetDeviceUIDs = uids; currentDeviceUIDs = uids
                return
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                crossfade.complete()
                logger.warning("Crossfade failed, attempting prepared replacement: \(error.localizedDescription)")
            }
        }
        if let primary { primary.context.update(volume: volume, muted: isMuted, bypass: dsp.bypass, silent: true) }
        defer { updateParameters() }
        let live = try await makeLiveTap(uids: uids, role: .primary, initialVolume: 0)
        guard generation == epoch, activated, !Task.isCancelled else { retire(live); throw CancellationError() }
        if let primary { retire(primary) }
        primary = live; pending = nil
        targetDeviceUIDs = uids; currentDeviceUIDs = uids
    }
    func invalidate() {
        generation &+= 1; activated = false; activationTick = 0
        activation?.cancel(); transition.cancel()
        pending?.setRole(.retired) // start worker retains ownership until it returns
        pending = nil
        if let primary { retire(primary) }; primary = nil
        if let secondary { retire(secondary) }; secondary = nil
        testContext?.setRole(.retired); testContext = nil
        crossfade.complete()
    }
    func invalidateAndWait() async throws {
        invalidate()
        for ticket in tickets { guard await ticket.wait(timeout: timeout) else { throw TapLifecycleError.retirementFailed } }
        tickets.removeAll { $0.result == true }
    }
    func invalidateAsync() async { try? await invalidateAndWait() }

    /// Used by callback regressions without opening a CoreAudio resource.
    func reservePrimaryCallbackID() -> UInt32 {
        testContext?.setRole(.retired)
        nextID &+= 1; if nextID == 0 { nextID = 1 }
        testContext = TapRenderContext(id: nextID, sampleRate: 48_000, role: .primary,
            crossfade: crossfade, dsp: dsp, volume: volume, muted: isMuted)
        return nextID
    }
    func renderContextForTesting() -> TapRenderContext? { testContext }
    func processAudioCallback(_ input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, callbackID: UInt32, timing: RenderTimingState? = nil) {
        if let context = testContext, context.id == callbackID, callbackID != 0 { context.process(input, to: output) }
        else { for buffer in UnsafeMutableAudioBufferListPointer(output) { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } } }
    }
}
