import Foundation
import Accelerate
import Atomics
import os

nonisolated private final class BiquadSetupOwner {
    let setup: vDSP_biquad_Setup
    init(_ setup: vDSP_biquad_Setup) { self.setup = setup }
    deinit { vDSP_biquad_DestroySetup(setup) }
}

/// Control publishes immutable scalar parameters and a pinned C setup. Only the
/// single render reader touches delay buffers. Primary and secondary callbacks
/// use separate processor instances. Reclamation runs on control, never render.
nonisolated class BiquadProcessor: @unchecked Sendable, BiquadProcessable {
    private struct Parameters {
        var setup: vDSP_biquad_Setup?
        var enabled: Bool
        var preamp: Float = 1
        var resetRevision: UInt64 = 0
    }

    let logger: Logger
    private(set) var sampleRate: Double
    private let parameters: RealtimeSnapshot<Parameters>
    // Mixer fast-path hint; the snapshot remains authoritative inside process().
    private let enabledHint: ManagedAtomic<Bool>
    // Control-writer-only resource reference; each published storage pins its owner too.
    private var setupOwner: BiquadSetupOwner?
    private let delayBufferL: UnsafeMutablePointer<Float>
    private let delayBufferR: UnsafeMutablePointer<Float>
    private let delayBufferSize: Int
    // Render-only, including resets and recovery from non-finite output.
    private var appliedResetRevision: UInt64 = 0

    var isEnabled: Bool { enabledHint.load(ordering: .relaxed) }
    func setEnabled(_ enabled: Bool) {
        var next = parameters.controlValue
        next.enabled = enabled
        parameters.publish(next, owner: setupOwner)
        enabledHint.store(enabled, ordering: .relaxed)
    }

    init(sampleRate: Double, maxSections: Int, category: String, initiallyEnabled: Bool = false) {
        self.sampleRate = sampleRate
        logger = Logger(subsystem: "com.finetuneapp.FineTune", category: category)
        parameters = RealtimeSnapshot(Parameters(enabled: initiallyEnabled))
        enabledHint = ManagedAtomic(initiallyEnabled)
        delayBufferSize = 2 * maxSections + 2
        delayBufferL = .allocate(capacity: delayBufferSize)
        delayBufferR = .allocate(capacity: delayBufferSize)
        delayBufferL.initialize(repeating: 0, count: delayBufferSize)
        delayBufferR.initialize(repeating: 0, count: delayBufferSize)
    }

    deinit { delayBufferL.deallocate(); delayBufferR.deallocate() }

    /// Called only by the control writer. Keep existing delay history for EQ drags.
    func swapSetup(_ setup: vDSP_biquad_Setup?) {
        var next = parameters.controlValue
        setupOwner = setup.map(BiquadSetupOwner.init)
        next.setup = setup
        parameters.publish(next, owner: setupOwner)
    }

    /// Publish related profile parameters together so a buffer sees one configuration.
    func installSetup(_ setup: vDSP_biquad_Setup?, enabled: Bool, preamp: Float = 1) {
        var next = parameters.controlValue
        setupOwner = setup.map(BiquadSetupOwner.init)
        next.setup = setup
        next.enabled = enabled
        next.preamp = preamp
        parameters.publish(next, owner: setupOwner)
        enabledHint.store(enabled, ordering: .relaxed)
    }

    func resetDelayBuffers() {
        var next = parameters.controlValue
        next.resetRevision &+= 1
        parameters.publish(next, owner: setupOwner)
    }

    func updateSampleRate(_ newRate: Double) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard newRate != sampleRate else { return }
        let oldRate = sampleRate
        sampleRate = newRate
        guard let (coefficients, sections) = recomputeCoefficients() else { return }
        let setup = coefficients.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(sections)) }
        guard let setup else {
            logger.warning("Could not create biquad at sample rate \(newRate)")
            return
        }
        var next = parameters.controlValue
        setupOwner = BiquadSetupOwner(setup)
        next.setup = setup
        next.resetRevision &+= 1
        parameters.publish(next, owner: setupOwner)
        logger.info("Sample rate: \(oldRate) → \(newRate) Hz")
    }

    func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? { nil }
    func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {}

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        parameters.withValue { state in
            if state.resetRevision != appliedResetRevision {
                clearDelays()
                appliedResetRevision = state.resetRevision
            }
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            guard state.enabled, let setup = state.setup else { return }
            var preamp = state.preamp
            if preamp != 1 { vDSP_vsmul(output, 1, &preamp, output, 1, vDSP_Length(frameCount * 2)) }
            preProcess(output: output, frameCount: frameCount)
            vDSP_biquad(setup, delayBufferL, output, 2, output, 2, vDSP_Length(frameCount))
            vDSP_biquad(setup, delayBufferR, output.advanced(by: 1), 2, output.advanced(by: 1), 2, vDSP_Length(frameCount))
            if output[0].isNaN || output[1].isNaN {
                clearDelays()
                memset(output, 0, frameCount * 2 * MemoryLayout<Float>.size)
            }
        }
    }

    private func clearDelays() {
        memset(delayBufferL, 0, delayBufferSize * MemoryLayout<Float>.size)
        memset(delayBufferR, 0, delayBufferSize * MemoryLayout<Float>.size)
    }
}
