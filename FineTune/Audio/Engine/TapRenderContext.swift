import Accelerate
import Atomics
import AudioToolbox
import Foundation

/// One context per IO proc for its entire lifetime. Only that IO proc writes
/// history; control publishes scalar parameters and pinned processor replacements.
nonisolated final class TapRenderContext: @unchecked Sendable {
    enum Role: Int { case primary, secondary, retired }
    struct Parameters {
        var volume: Float
        var muted: Bool
        var bypass: Bool
        var silent: Bool = false
    }
    let id: UInt32
    let sampleRate: Double
    let stereoLeft: Int
    let stereoRight: Int
    let eq: EQProcessor
    let autoEQ: AutoEQProcessor
    let compensator: LoudnessCompensator
    private let equalizer: RealtimeSnapshot<Unmanaged<LoudnessEqualizer>>
    private let parameters: RealtimeSnapshot<Parameters>
    private let roleStorage: ManagedAtomic<Int>
    private let crossfade: CrossfadeState
    private let lastTick = ManagedAtomic<UInt64>(0)
    private let peakBits = ManagedAtomic<UInt32>(0)
    private let callbackCount = ManagedAtomic<UInt64>(0)
    private let gapCount = ManagedAtomic<UInt64>(0)
    private var currentVolume: Float // render-owned, never transferred at promotion
    private var peak: Float = 0
    private var timing = RenderTimingState()
    private let ramp: Float
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(max(1, info.denom))
    }()

    @MainActor
    init(id: UInt32, sampleRate: Double, stereoLeft: Int = 0, stereoRight: Int = 1,
         role: Role, crossfade: CrossfadeState, dsp: TapDSPConfiguration,
         volume: Float, muted: Bool) {
        self.id = id; self.sampleRate = sampleRate
        self.stereoLeft = stereoLeft; self.stereoRight = stereoRight
        self.crossfade = crossfade; self.currentVolume = volume
        self.roleStorage = ManagedAtomic(role.rawValue)
        self.parameters = RealtimeSnapshot(Parameters(volume: volume, muted: muted, bypass: dsp.bypass))
        let processors = dsp.makeProcessors(sampleRate: sampleRate)
        eq = processors.eq; autoEQ = processors.autoEQ; compensator = processors.compensator
        equalizer = RealtimeSnapshot(.passUnretained(processors.equalizer), owner: processors.equalizer, keepLastReadAlive: true)
        ramp = 1 - exp(-1 / (Float(sampleRate) * 0.030))
    }
    var role: Role { Role(rawValue: roleStorage.load(ordering: .acquiring)) ?? .retired }
    func setRole(_ role: Role) { roleStorage.store(role.rawValue, ordering: .releasing) }
    var lastRenderTick: UInt64 { lastTick.load(ordering: .relaxed) }
    var audioLevel: Float { Float(bitPattern: peakBits.load(ordering: .relaxed)) }
    var diagnostics: TapRenderDiagnostics {
        TapRenderDiagnostics(callbackCount: callbackCount.load(ordering: .relaxed), longGapCount: gapCount.load(ordering: .relaxed))
    }
    // Single control writer, separate instances per callback.
    @MainActor
    func update(volume: Float, muted: Bool, bypass: Bool, silent: Bool = false) {
        parameters.publish(Parameters(volume: volume, muted: muted, bypass: bypass, silent: silent))
    }
    @MainActor
    func updateEqualizer(_ settings: LoudnessEqualizerSettings) {
        let processor = LoudnessEqualizer(settings: settings, sampleRate: Float(sampleRate))
        equalizer.publish(.passUnretained(processor), owner: processor)
    }
    func isRecent(within seconds: Double) -> Bool {
        let tick = lastRenderTick
        return role != .retired && tick != 0 && Double(mach_absolute_time() &- tick) * Self.nanosPerTick <= seconds * 1_000_000_000
    }

    func process(_ input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>) {
        let generation = crossfade.generation
        let role = self.role
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard role != .retired else { Self.silence(outputs); return }
        let now = mach_absolute_time()
        lastTick.store(now, ordering: .relaxed)
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frames = 0
        var maxPeak: Float = 0
        for buffer in inputs {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            if frames == 0 { frames = count }
            if count > 0 {
                var value: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), vDSP_Stride(channels), &value, vDSP_Length(count))
                maxPeak = max(maxPeak, value)
            }
        }
        if timing.tracker.record(time: Double(now) * Self.nanosPerTick / 1_000_000_000,
                                 callbackID: id, bufferDuration: Double(frames) / max(1, sampleRate)) {
            gapCount.wrappingIncrement(ordering: .relaxed)
        }
        callbackCount.wrappingIncrement(ordering: .relaxed)
        peak += 0.3 * (min(maxPeak, 1) - peak)
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        if role == .secondary { _ = crossfade.updateProgress(samples: frames, generation: generation) }
        parameters.withValue { params in
            guard self.role != .retired, !params.muted, !params.silent else { Self.silence(outputs); return }
            equalizer.withValue { processor in
                ProcessTapController.processMappedBuffers(
                    inputBuffers: inputs, outputBuffers: outputs, targetVol: params.volume,
                    crossfadeMultiplier: role == .primary ? crossfade.primaryMultiplier : crossfade.secondaryMultiplier,
                    rampCoefficient: ramp, preferredStereoLeft: stereoLeft, preferredStereoRight: stereoRight,
                    currentVol: &currentVolume, eqProc: params.bypass ? nil : eq,
                    autoEQProc: params.bypass ? nil : autoEQ,
                    loudnessEqualizerProc: params.bypass ? nil : processor.takeUnretainedValue(),
                    loudnessCompensatorProc: params.bypass ? nil : compensator)
            }
        }
        // A control-side retirement may arrive while this buffer is in flight.
        // Never restore the old route's gain after the shared fade returned idle.
        if self.role == .retired { Self.silence(outputs) }
    }
    private static func silence(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
    }
}
