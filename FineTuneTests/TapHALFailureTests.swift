import AudioToolbox
import Foundation
import os
import Testing
@testable import FineTune

nonisolated private final class HALStepLedger: Sendable {
    let state = OSAllocatedUnfairLock(initialState: (events: [String](), fail: Optional<String>.none))
    func step(_ name: String) throws {
        try state.withLock {
            $0.events.append(name)
            if $0.fail == name { throw TapLifecycleError.retirementFailed }
        }
    }
    var operations: TapHALOperations {
        TapHALOperations(createTap: { [self] _ in
            try step("tap"); let desc = CATapDescription(stereoMixdownOfProcesses: []); return (desc, 101)
        }, createAggregate: { [self] _, _ in try step("aggregate"); return 102 },
        format: { [self] _, _ in try step("format"); return TapHALFormat(sampleRate: 48_000) },
        install: { [self] _, _ in try step("install"); return nil },
        start: { [self] _, _ in try step("start") },
        removeProc: { [self] _, _ in try step("proc-remove") },
        removeAggregate: { [self] _ in try step("aggregate-remove") },
        removeTap: { [self] _ in try step("tap-remove") })
    }
}

@Suite("HAL resource failure paths", .serialized)
@MainActor
struct TapHALFailureTests {
    private let plan = TapHALPlan(pid: 1, processObjectIDs: [], outputUIDs: ["test"], preferredSourceUID: nil)
    @Test("partial prepare failure cleans only the IDs already acquired", arguments: ["tap", "aggregate", "format"])
    func partialPrepareFailure(step: String) async {
        let ledger = HALStepLedger(), queue = HALRetirementQueue()
        ledger.state.withLock { $0.fail = step }
        let adapter = NativeTapHALAdapter(operations: ledger.operations, retirements: queue)
        do { _ = try adapter.prepare(plan); Issue.record("Must fail") } catch {}
        for _ in 0..<200 { if queue.pendingCount == 0 { break }; try? await Task.sleep(for: .milliseconds(5)) }
        let cleanup = ledger.state.withLock { $0.events.filter { $0.hasSuffix("remove") } }
        #expect(cleanup == (step == "tap" ? [] : step == "aggregate" ? ["tap-remove"] : ["aggregate-remove", "tap-remove"]))
        #expect(queue.pendingCount == 0)
    }
    @Test("start failures retire proc before aggregate and tap", arguments: ["install", "start"])
    func partialStartFailure(step: String) async throws {
        let ledger = HALStepLedger(), queue = HALRetirementQueue()
        let adapter = NativeTapHALAdapter(operations: ledger.operations, retirements: queue)
        let resource = try adapter.prepare(plan)
        let render = TapRenderContext(id: 1, sampleRate: 48_000, role: .primary, crossfade: CrossfadeState(), dsp: TapDSPConfiguration(), volume: 1, muted: false)
        ledger.state.withLock { $0.fail = step }
        do { try adapter.start(resource, context: render); Issue.record("Must fail") } catch {}
        render.setRole(.retired)
        #expect(await resource.retire(adapter: adapter, queue: queue).wait(timeout: 1))
        let cleanup = ledger.state.withLock { $0.events.filter { $0.hasSuffix("remove") } }
        #expect(cleanup == (step == "install" ? ["aggregate-remove", "tap-remove"] : ["proc-remove", "aggregate-remove", "tap-remove"]))
    }
    @Test("a failed IO-proc acknowledgement quarantines the whole resource")
    func failedProcRemovalCannotFreeRemainingResources() async throws {
        let ledger = HALStepLedger(), queue = HALRetirementQueue()
        let adapter = NativeTapHALAdapter(operations: ledger.operations, retirements: queue)
        let resource = try adapter.prepare(plan)
        var render: TapRenderContext? = TapRenderContext(id: 1, sampleRate: 48_000, role: .primary, crossfade: CrossfadeState(), dsp: TapDSPConfiguration(), volume: 1, muted: false)
        weak var weakRender: TapRenderContext?
        weakRender = render
        try adapter.start(resource, context: render!)
        ledger.state.withLock { $0.fail = "proc-remove" }
        render?.setRole(.retired)
        render = nil
        let ticket = resource.retire(adapter: adapter, queue: queue)
        #expect(await ticket.wait(timeout: 1) == false)
        #expect(ledger.state.withLock { !$0.events.contains("aggregate-remove") && !$0.events.contains("tap-remove") })
        #expect(!queue.allowsCapture)
        #expect(weakRender != nil, "quarantine owns the render context until IO proc removal")
        ledger.state.withLock { $0.fail = nil }
        queue.retryFailed()
        #expect(await ticket.wait(timeout: 1))
        #expect(weakRender == nil, "release only after native teardown acknowledgement")
        #expect(ledger.state.withLock { Array($0.events.suffix(3)) == ["proc-remove", "aggregate-remove", "tap-remove"] })
    }
}
