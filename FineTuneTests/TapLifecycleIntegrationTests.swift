import AppKit
import AudioToolbox
import Foundation
import os
import Testing
@testable import FineTune

nonisolated private final class ControlledTapHAL: TapHALAdapting {
    struct State { var prepare = 0; var start = 0; var destroy = 0; var offMain = true; var render: TapRenderContext?; var contexts: [AudioDeviceID: TapRenderContext] = [:] }
    let state = OSAllocatedUnfairLock(initialState: State())
    let prepareGate: DispatchSemaphore?
    let startGate: DispatchSemaphore?
    let destroyGate: DispatchSemaphore?
    init(prepareGate: DispatchSemaphore? = nil, startGate: DispatchSemaphore? = nil, destroyGate: DispatchSemaphore? = nil) {
        self.prepareGate = prepareGate; self.startGate = startGate; self.destroyGate = destroyGate
    }
    func prepare(_ plan: TapHALPlan) throws -> PreparedTap {
        let id = state.withLock { $0.prepare += 1; $0.offMain = $0.offMain && !Thread.isMainThread; return $0.prepare }
        prepareGate?.wait()
        return PreparedTap(aggregateID: AudioDeviceID(99000 + id), sampleRate: 44_100, storage: NSObject())
    }
    func start(_ tap: PreparedTap, context: TapRenderContext) throws {
        state.withLock { $0.start += 1; $0.offMain = $0.offMain && !Thread.isMainThread }
        startGate?.wait()
        state.withLock { $0.render = context; $0.contexts[tap.aggregateID] = context }
    }
    func destroy(_ tap: PreparedTap) throws {
        destroyGate?.wait()
        state.withLock { $0.destroy += 1; $0.offMain = $0.offMain && !Thread.isMainThread; let removed = $0.contexts.removeValue(forKey: tap.aggregateID); if $0.render === removed { $0.render = nil } }
    }
}

@Suite("Native controller async lifecycle", .serialized)
@MainActor
struct TapLifecycleIntegrationTests {
    private func controller(_ adapter: ControlledTapHAL, queue: HALRetirementQueue = HALRetirementQueue(), timeout: TimeInterval = 0.08) -> ProcessTapController {
        ProcessTapController(app: AudioApp(id: 99100, processObjectIDs: [], name: "Lifecycle", icon: NSImage(), bundleID: "test.lifecycle"),
            targetDeviceUIDs: ["test"], adapter: adapter, executor: OwnedHALExecutor(limit: 2), retirements: queue, timeout: timeout)
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test("prepare suspends MainActor; initial render uses the latest gain")
    func prepareDoesNotBlockUIOrUseStaleGain() async throws {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(prepareGate: gate)
        let tap = controller(adapter, timeout: 1)
        let job = Task { try await tap.activateAwaiting(initialDSP: TapDSPConfiguration()) }
        await waitUntil { adapter.state.withLock { $0.prepare == 1 } }
        tap.volume = 0.2 // MainActor is free while HAL prepare is blocked
        gate.signal()
        try await job.value
        #expect(tap.renderClock?.sampleRate == 44_100)
        let render = adapter.state.withLock { $0.render! }
        #expect(process(render).allSatisfy { abs($0 - 0.05) < 0.0001 })
        try await tap.invalidateAndWait()
        #expect(adapter.state.withLock { $0.offMain && $0.destroy == 1 })
    }
    @Test("cancelled prepare cleans late result without starting or publishing it")
    func cancelPrepareRetiresLateResource() async {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(prepareGate: gate)
        let tap = controller(adapter, timeout: 1)
        let job = Task { try await tap.activateAwaiting(initialDSP: TapDSPConfiguration()) }
        await waitUntil { adapter.state.withLock { $0.prepare == 1 } }
        tap.invalidate()
        do { try await job.value; Issue.record("Expected cancellation") } catch {}
        #expect(tap.renderClock == nil)
        #expect(adapter.state.withLock { $0.destroy == 0 && $0.start == 0 })
        gate.signal()
        await waitUntil { adapter.state.withLock { $0.destroy == 1 } }
        #expect(tap.renderClock == nil)
        #expect(adapter.state.withLock { $0.start == 0 })
    }
    @Test("start timeout must not race destroy against a still-blocked start")
    func timeoutStartRetainsWorkerOwnership() async {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(startGate: gate)
        let tap = controller(adapter)
        do { try await tap.activateAwaiting(initialDSP: TapDSPConfiguration()); Issue.record("Expected timeout") }
        catch { #expect(error as? TapLifecycleError == .deadline) }
        tap.invalidate()
        #expect(adapter.state.withLock { $0.destroy == 0 })
        gate.signal()
        await waitUntil { adapter.state.withLock { $0.destroy == 1 } }
        #expect(tap.renderClock == nil)
    }
    @Test("teardown deadline blocks replacement until actual acknowledgement")
    func teardownDeadlineStopsNewCapture() async throws {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(destroyGate: gate)
        let queue = HALRetirementQueue()
        let tap = controller(adapter, queue: queue)
        try await tap.activateAwaiting(initialDSP: TapDSPConfiguration())
        do { try await tap.invalidateAndWait(); Issue.record("Expected retirement timeout") }
        catch { #expect(error as? TapLifecycleError == .retirementFailed) }
        #expect(queue.pendingCount == 1 && !queue.allowsCapture)
        let replacement = controller(adapter, queue: queue)
        do { try await replacement.activateAwaiting(initialDSP: TapDSPConfiguration()); Issue.record("Must reject") }
        catch { #expect(error as? TapLifecycleError == .retirementFailed) }
        #expect(adapter.state.withLock { $0.prepare == 1 })
        gate.signal()
        await waitUntil { queue.pendingCount == 0 }
        try await replacement.activateAwaiting(initialDSP: TapDSPConfiguration())
        gate.signal()
        try await replacement.invalidateAndWait()
        #expect(adapter.state.withLock { $0.prepare == 2 && $0.destroy == 2 })
    }
    @Test("promotion preserves the secondary context and never transfers mutable history")
    func promotionKeepsContextIdentity() async throws {
        let adapter = ControlledTapHAL(), queue = HALRetirementQueue()
        let tap = controller(adapter, queue: queue, timeout: 1)
        try await tap.activateAwaiting(initialDSP: TapDSPConfiguration())
        let first = adapter.state.withLock { $0.render! }
        var done = false
        let change = Task {
            defer { done = true }
            try await tap.switchDevice(to: "second", preferredTapSourceDeviceUID: nil, sourceDeviceDead: false)
        }
        var secondary: TapRenderContext?
        for _ in 0..<300 {
            if done { break }
            let contexts = adapter.state.withLock { Array($0.contexts.values) }
            for context in contexts {
                if context.role == .secondary { secondary = context }
                _ = process(context, frames: 1024)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await change.value
        let promoted = adapter.state.withLock { $0.render! }
        #expect(promoted === secondary)
        #expect(promoted !== first)
        #expect(promoted.eq !== first.eq)
        #expect(promoted.role == .primary && first.role == .retired)
        #expect(tap.currentDeviceUIDs == ["second"])
        #expect(process(first).allSatisfy { $0 == 0 })
        try await tap.invalidateAndWait()
    }

    @Test("dropping the controller still retires its owned IO resource")
    func ownerDeinitRetiresResource() async throws {
        let adapter = ControlledTapHAL(), queue = HALRetirementQueue()
        var tap: ProcessTapController? = controller(adapter, queue: queue, timeout: 1)
        try await tap!.activateAwaiting(initialDSP: TapDSPConfiguration())
        tap = nil
        await waitUntil { adapter.state.withLock { $0.destroy == 1 } }
        #expect(queue.pendingCount == 0)
    }

    @Test("activation bursts queue asynchronously instead of exhausting workers")
    func burstAdmissionIsBounded() async throws {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(prepareGate: gate)
        let queue = HALRetirementQueue()
        let controllers = (0..<6).map { _ in controller(adapter, queue: queue, timeout: 1) }
        let jobs = controllers.map { tap in Task { try await tap.activateAwaiting(initialDSP: TapDSPConfiguration()) } }
        await waitUntil { adapter.state.withLock { $0.prepare == 4 } }
        #expect(adapter.state.withLock { $0.prepare <= 4 })
        for _ in 0..<6 { gate.signal() }
        for job in jobs { try await job.value }
        #expect(adapter.state.withLock { $0.prepare == 6 && $0.start == 6 })
        for controller in controllers { try await controller.invalidateAndWait() }
        #expect(adapter.state.withLock { $0.destroy == 6 })
    }

    private func process(_ context: TapRenderContext, frames: Int = 64) -> [Float] {
        let input = [Float](repeating: 0.25, count: frames * 2)
        var output = [Float](repeating: -1, count: frames * 2)
        input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
            var inputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: UnsafeMutableRawPointer(mutating: i.baseAddress!)))
            var outputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: o.baseAddress!))
            withUnsafePointer(to: &inputs) { p in withUnsafeMutablePointer(to: &outputs) { context.process(p, to: $0) } }
        } }
        return output
    }
}

@MainActor
private final class LifecycleProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp]
    var onAppsChanged: (([AudioApp]) -> Void)?
    init(_ app: AudioApp) { activeApps = [app] }
    func start() {}
    func stop() {}
}

@Suite("Engine pending capture ownership", .serialized)
@MainActor
struct EnginePendingCaptureTests {
    private func fixture(_ adapter: ControlledTapHAL, queue: HALRetirementQueue) -> (AudioEngine, AudioApp, SettingsManager, URL) {
        let app = AudioApp(id: 99300, processObjectIDs: [], name: "Pending", icon: NSImage(), bundleID: "test.pending")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
        let settings = SettingsManager(directory: directory)
        let devices = MockAudioDeviceMonitor()
        devices.addOutputDevice(AudioDevice(id: 99301, uid: "first", name: "First", icon: nil, supportsAutoEQ: false))
        devices.addOutputDevice(AudioDevice(id: 99302, uid: "second", name: "Second", icon: nil, supportsAutoEQ: false))
        let volumes = MockDeviceVolumeProviding(deviceMonitor: devices)
        volumes.defaultDeviceID = 99301; volumes.defaultDeviceUID = "first"
        let permission = AudioRecordingPermission(); permission.setStatusForTesting(.authorized)
        let executor = OwnedHALExecutor(limit: 4)
        let engine = AudioEngine(permission: permission, settingsManager: settings, deviceProvider: devices,
            processMonitor: LifecycleProcessMonitor(app), deviceVolumeMonitor: volumes,
            tapFactory: { app, uids, source in
                ProcessTapController(app: app, targetDeviceUIDs: uids, preferredTapSourceDeviceUID: source,
                    adapter: adapter, executor: executor, retirements: queue, timeout: 0.15)
            }, isAlive: { _ in true }, startMonitorsAutomatically: false)
        return (engine, app, settings, directory)
    }
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test("immediate DSP edits to a pending placeholder survive task scheduling")
    func pendingConfigurationIsNotOverwritten() async {
        let adapter = ControlledTapHAL(), queue = HALRetirementQueue()
        let (engine, app, settings, directory) = fixture(adapter, queue: queue)
        defer { engine.stop(); settings.flushSync(); try? FileManager.default.removeItem(at: directory) }
        engine.ensureTapExists(for: app, deviceUID: "first")
        // No await between beginActivation and this control edit.
        engine.taps[app.id]?.updateEQSettings(EQSettings(bandGains: [3,0,0,0,0,0,0,0,0,0], isEnabled: true))
        await waitUntil { engine.pidsBeingCreated.isEmpty && engine.taps[app.id]?.renderClock != nil }
        #expect(adapter.state.withLock { $0.render?.eq.isEnabled == true })
    }

    @Test("stop during prepare cannot resurrect a pending tap")
    func stopDuringPrepare() async {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(prepareGate: gate)
        let queue = HALRetirementQueue()
        let (engine, app, settings, directory) = fixture(adapter, queue: queue)
        defer { engine.stop(); settings.flushSync(); try? FileManager.default.removeItem(at: directory); gate.signal() }
        engine.ensureTapExists(for: app, deviceUID: "first")
        await waitUntil { adapter.state.withLock { $0.prepare == 1 } }
        engine.stop()
        gate.signal()
        await waitUntil { adapter.state.withLock { $0.destroy == 1 } }
        #expect(engine.taps.isEmpty && engine.pidsBeingCreated.isEmpty && engine.creationTokens.isEmpty)
        #expect(adapter.state.withLock { $0.start == 0 })
    }
    @Test("a new route cancels old preparation and rejects its late result")
    func routeChangeDuringPrepare() async {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(prepareGate: gate)
        let queue = HALRetirementQueue()
        let (engine, app, settings, directory) = fixture(adapter, queue: queue)
        defer { engine.stop(); settings.flushSync(); try? FileManager.default.removeItem(at: directory); gate.signal(); gate.signal() }
        engine.ensureTapExists(for: app, deviceUID: "first")
        await waitUntil { adapter.state.withLock { $0.prepare == 1 } }
        engine.setDevice(for: app, deviceUID: "second")
        await waitUntil { adapter.state.withLock { $0.prepare == 2 } }
        gate.signal(); gate.signal()
        await waitUntil { engine.pidsBeingCreated.isEmpty && engine.taps[app.id]?.renderClock != nil }
        #expect(engine.taps[app.id]?.currentDeviceUIDs == ["second"])
        await waitUntil { adapter.state.withLock { $0.destroy == 1 } }
        #expect(adapter.state.withLock { $0.start == 1 })
    }
    @Test("recovery never creates a replacement after teardown times out")
    func recoveryWaitsForAcknowledgement() async {
        let gate = DispatchSemaphore(value: 0), adapter = ControlledTapHAL(destroyGate: gate)
        let queue = HALRetirementQueue()
        let (engine, app, settings, directory) = fixture(adapter, queue: queue)
        defer { gate.signal(); engine.stop(); settings.flushSync(); try? FileManager.default.removeItem(at: directory) }
        engine.ensureTapExists(for: app, deviceUID: "first")
        await waitUntil { engine.taps[app.id]?.renderClock != nil }
        await engine.recreateTap(for: app.id)
        #expect(engine.taps[app.id] == nil)
        #expect(adapter.state.withLock { $0.prepare == 1 })
        #expect(queue.pendingCount == 1 && !queue.allowsCapture)
        #expect(engine.pidsBeingRecreated.isEmpty)
        gate.signal()
        await waitUntil { queue.pendingCount == 0 }
    }
}
