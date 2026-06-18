import AudioToolbox
import Foundation
import XCTest
@testable import FineTune

/// Microbenchmarks for the real-time audio hot path (`ProcessTapController
/// .processMappedBuffers`). These use XCTest `measure {}` so Xcode can track a
/// baseline; run via `xcodebuild test` they execute and report timings without
/// failing (no baseline is committed — set one in Xcode if you want regression
/// gating).
///
/// NOTE: this measures the per-callback DSP/gain cost in isolation, fed with
/// synthetic buffers. It does NOT measure real-world CPU under live CoreAudio —
/// that requires Instruments (Time Profiler / Audio) against the running app.
final class AudioEnginePerformanceTests: XCTestCase {

    private struct StereoBuffer {
        let list: UnsafeMutableAudioBufferListPointer
        let data: UnsafeMutablePointer<Float>
        let frames: Int
    }

    /// Allocates one interleaved-stereo AudioBufferList of `frames` frames.
    private func makeStereoBuffer(frames: Int, fill: Float) -> StereoBuffer {
        let sampleCount = frames * 2
        let data = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        data.initialize(repeating: fill, count: sampleCount)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(data)
        )
        return StereoBuffer(list: list, data: data, frames: frames)
    }

    private func destroy(_ buffer: StereoBuffer) {
        free(buffer.list.unsafeMutablePointer)
        buffer.data.deallocate()
    }

    // MARK: - Correctness (guards against a benchmark that measures broken output)

    func testProcessMappedBuffers_appliesUnityGainExactly() {
        let frames = 256
        let input = makeStereoBuffer(frames: frames, fill: 0.5)
        let output = makeStereoBuffer(frames: frames, fill: 0)
        defer { destroy(input); destroy(output) }

        var currentVol: Float = 1.0  // already at target → no ramping, no limiter
        ProcessTapController.processMappedBuffers(
            inputBuffers: input.list,
            outputBuffers: output.list,
            targetVol: 1.0,
            crossfadeMultiplier: 1.0,
            rampCoefficient: 0.02,
            preferredStereoLeft: 0,
            preferredStereoRight: 1,
            currentVol: &currentVol,
            eqProc: nil,
            autoEQProc: nil,
            loudnessEqualizerProc: nil,
            loudnessCompensatorProc: nil
        )

        XCTAssertEqual(output.data[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output.data[frames * 2 - 1], 0.5, accuracy: 0.0001)
    }

    func testProcessMappedBuffers_appliesHalfGainExactly() {
        let frames = 256
        let input = makeStereoBuffer(frames: frames, fill: 0.8)
        let output = makeStereoBuffer(frames: frames, fill: 0)
        defer { destroy(input); destroy(output) }

        var currentVol: Float = 0.5  // already at target 0.5 → steady, no ramp
        ProcessTapController.processMappedBuffers(
            inputBuffers: input.list,
            outputBuffers: output.list,
            targetVol: 0.5,
            crossfadeMultiplier: 1.0,
            rampCoefficient: 0.02,
            preferredStereoLeft: 0,
            preferredStereoRight: 1,
            currentVol: &currentVol,
            eqProc: nil,
            autoEQProc: nil,
            loudnessEqualizerProc: nil,
            loudnessCompensatorProc: nil
        )

        XCTAssertEqual(output.data[0], 0.4, accuracy: 0.0001)  // 0.8 * 0.5
    }

    // MARK: - Throughput benchmarks

    /// Baseline: gain + channel copy only, no DSP. ~2000 callbacks of 512-frame
    /// stereo ≈ 21 s of 48 kHz audio processed per measure iteration.
    func testPerformance_processMappedBuffers_gainOnly() {
        let frames = 512
        let input = makeStereoBuffer(frames: frames, fill: 0.25)
        let output = makeStereoBuffer(frames: frames, fill: 0)
        defer { destroy(input); destroy(output) }

        var currentVol: Float = 1.0
        measure {
            for _ in 0..<2000 {
                ProcessTapController.processMappedBuffers(
                    inputBuffers: input.list,
                    outputBuffers: output.list,
                    targetVol: 1.0,
                    crossfadeMultiplier: 1.0,
                    rampCoefficient: 0.02,
                    preferredStereoLeft: 0,
                    preferredStereoRight: 1,
                    currentVol: &currentVol,
                    eqProc: nil,
                    autoEQProc: nil,
                    loudnessEqualizerProc: nil,
                    loudnessCompensatorProc: nil
                )
            }
        }
    }

    /// Same workload with a fully-engaged 10-band parametric EQ — shows the DSP
    /// cost that load-shedding drops under memory pressure.
    func testPerformance_processMappedBuffers_withEQ() {
        let frames = 512
        let input = makeStereoBuffer(frames: frames, fill: 0.25)
        let output = makeStereoBuffer(frames: frames, fill: 0)
        defer { destroy(input); destroy(output) }

        let eq = EQProcessor(sampleRate: 48000)
        eq.updateSettings(EQSettings(bandGains: [4, -3, 5, 0, -2, 6, -1, 3, -4, 2], isEnabled: true))

        var currentVol: Float = 1.0
        measure {
            for _ in 0..<2000 {
                ProcessTapController.processMappedBuffers(
                    inputBuffers: input.list,
                    outputBuffers: output.list,
                    targetVol: 1.0,
                    crossfadeMultiplier: 1.0,
                    rampCoefficient: 0.02,
                    preferredStereoLeft: 0,
                    preferredStereoRight: 1,
                    currentVol: &currentVol,
                    eqProc: eq,
                    autoEQProc: nil,
                    loudnessEqualizerProc: nil,
                    loudnessCompensatorProc: nil
                )
            }
        }
    }
}
