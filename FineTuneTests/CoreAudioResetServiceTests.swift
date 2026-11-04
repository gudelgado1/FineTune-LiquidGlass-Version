import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("CoreAudioResetService — probe safety and phase reporting")
@MainActor
struct CoreAudioResetServiceTests {

    @Test("probe returns within the deadline instead of blocking the caller")
    func probeHonorsDeadline() async {
        // The whole point of the probe: on a wedged daemon the HAL query never
        // returns, so the CALLER must come back on a deadline regardless. On a
        // healthy machine it answers immediately; either way it must not hang.
        let start = Date()
        _ = await CoreAudioResetService.probeResponsive(timeout: 1.0)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5.0)
    }

    @Test("service starts idle with unknown health")
    func startsIdle() {
        let service = CoreAudioResetService()
        #expect(service.phase == .idle)
        #expect(service.health == .unknown)
        #expect(service.isBusy == false)
        #expect(service.lastCheck == nil)
    }

    @Test("checkHealth resolves to a definite health and returns to idle")
    func checkHealthResolves() async {
        let service = CoreAudioResetService()
        let health = await service.checkHealth(timeout: 2.0)
        #expect(health != .unknown)
        #expect(service.health == health)
        #expect(service.phase == .idle)
        #expect(service.isBusy == false)
        #expect(service.lastCheck != nil)
    }

    @Test("isBusy covers every in-progress phase and no terminal one")
    func isBusyCoversInProgressPhases() {
        // Guards the Reset button's disabled state: a terminal phase must leave
        // the button clickable, an in-progress one must not.
        for phase in [CoreAudioResetService.Phase.checking, .restarting, .waitingForDaemon, .rebuilding] {
            #expect(CoreAudioResetService.isBusy(phase) == true, "\(phase) should be busy")
        }
        for phase in [CoreAudioResetService.Phase.idle, .succeeded, .cancelled, .failed("boom")] {
            #expect(CoreAudioResetService.isBusy(phase) == false, "\(phase) should not be busy")
        }
    }

    @Test("a busy service ignores a second reset request")
    func busyServiceIgnoresSecondReset() async {
        let service = CoreAudioResetService()
        // Simulate an authorization dialog already on screen: a second click
        // must NOT spawn another privileged restart (no second password prompt).
        service.setPhaseForTesting(.restarting)
        await service.resetCoreAudio(engine: nil)
        #expect(service.phase == .restarting)
    }

    @Test("acknowledge clears terminal phases and leaves in-progress ones alone")
    func acknowledgeClearsTerminalPhasesOnly() {
        let service = CoreAudioResetService()

        for terminal in [CoreAudioResetService.Phase.succeeded, .cancelled, .failed("boom")] {
            service.setPhaseForTesting(terminal)
            service.acknowledge()
            #expect(service.phase == .idle, "\(terminal) should clear to idle")
        }

        service.setPhaseForTesting(.rebuilding)
        service.acknowledge()
        #expect(service.phase == .rebuilding, "in-progress phase must survive acknowledge")
    }
}
