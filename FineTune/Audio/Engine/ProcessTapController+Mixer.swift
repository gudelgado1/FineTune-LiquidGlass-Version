// FineTune/Audio/Engine/ProcessTapController+Mixer.swift
import AudioToolbox
import Foundation

// MARK: - Audio Buffer Mixer
//
// Extracted from ProcessTapController.swift to keep the per-frame mixer in a
// focused, reviewable file (~165 lines vs ~1370 in the parent). The function
// is `static` and parameterless on `self` — it touches NO instance state and
// can be reasoned about purely from its inputs. RT-safety properties are
// identical to the original implementation: no allocation, no locks, no ObjC.
//
// Channel mapping rules:
//   1. Equal channel count (e.g. 2→2, 6→6): direct copy with per-frame gain ramp.
//   2. Stereo → Surround (2→N>2): place L/R into preferred output channels.
//   3. Mono → Multi (1→N>1): duplicate into preferred output channels.
//   4. Other mismatched layouts: copy min(in, out) channels, zero the rest.
//
// Effects pipeline (applied to the stereo-interleaved output buffer):
//   EQ → AutoEQ → Loudness Equalization → Loudness Compensation → SoftLimiter

extension ProcessTapController {
    /// Mixes one input AudioBufferList into one output AudioBufferList,
    /// applying ramped gain, channel mapping, EQ, loudness, and soft limiting.
    ///
    /// - Parameter currentVol: Inout — the ramped per-callback current volume.
    ///   The caller (audio callback) writes this back to its role-specific
    ///   state var so the ramp persists across callbacks.
    @inline(__always)
    static func processMappedBuffers(
        inputBuffers: UnsafeMutableAudioBufferListPointer,
        outputBuffers: UnsafeMutableAudioBufferListPointer,
        targetVol: Float,
        crossfadeMultiplier: Float,
        rampCoefficient: Float,
        preferredStereoLeft: Int,
        preferredStereoRight: Int,
        currentVol: inout Float,
        eqProc: EQProcessor?,
        autoEQProc: AutoEQProcessor?,
        loudnessEqualizerProc: LoudnessEqualizer?,
        loudnessCompensatorProc: LoudnessCompensator?
    ) {
        let inputBufferCount = inputBuffers.count
        let outputBufferCount = outputBuffers.count

        for outputIndex in 0..<outputBufferCount {
            let outputBuffer = outputBuffers[outputIndex]
            guard let outputData = outputBuffer.mData else { continue }

            let inputIndex: Int
            if inputBufferCount > outputBufferCount {
                inputIndex = inputBufferCount - outputBufferCount + outputIndex
            } else {
                inputIndex = outputIndex
            }

            guard inputIndex < inputBufferCount else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputBuffer = inputBuffers[inputIndex]
            guard let inputData = inputBuffer.mData else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let inputSamples = inputData.assumingMemoryBound(to: Float.self)
            let outputSamples = outputData.assumingMemoryBound(to: Float.self)
            let inputChannels = max(1, Int(inputBuffer.mNumberChannels))
            let outputChannels = max(1, Int(outputBuffer.mNumberChannels))
            let inputSampleCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let outputSampleCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let inputFrameCount = inputSampleCount / inputChannels
            let outputFrameCount = outputSampleCount / outputChannels
            let frameCount = min(inputFrameCount, outputFrameCount)

            guard frameCount > 0 else {
                memset(outputData, 0, Int(outputBuffer.mDataByteSize))
                continue
            }

            let safeLeft = min(max(preferredStereoLeft, 0), max(outputChannels - 1, 0))
            let safeRight = min(max(preferredStereoRight, 0), max(outputChannels - 1, 0))

            let eq = eqProc  // Parameter read — each callback passes its own processor
            let eqCanProcessStereoInterleaved = (inputChannels == 2 && outputChannels == 2)

            if inputChannels == outputChannels {
                let sampleCount = frameCount * inputChannels
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier
                    let base = frame * inputChannels
                    for ch in 0..<inputChannels {
                        outputSamples[base + ch] = inputSamples[base + ch] * gain
                    }
                }
                if sampleCount < outputSampleCount {
                    memset(outputSamples.advanced(by: sampleCount), 0, (outputSampleCount - sampleCount) * MemoryLayout<Float>.size)
                }
            } else if inputChannels == 2 && outputChannels > 2 {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier
                    let inBase = frame * 2
                    let outBase = frame * outputChannels
                    let left = inputSamples[inBase] * gain
                    let right = inputSamples[inBase + 1] * gain

                    for ch in 0..<outputChannels {
                        outputSamples[outBase + ch] = 0
                    }
                    outputSamples[outBase + safeLeft] = left
                    outputSamples[outBase + safeRight] = right
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else if inputChannels == 1 && outputChannels > 1 {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier
                    let sample = inputSamples[frame] * gain
                    let outBase = frame * outputChannels

                    for ch in 0..<outputChannels {
                        outputSamples[outBase + ch] = 0
                    }
                    outputSamples[outBase + safeLeft] = sample
                    outputSamples[outBase + safeRight] = sample
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            } else {
                for frame in 0..<frameCount {
                    currentVol += (targetVol - currentVol) * rampCoefficient
                    let gain = currentVol * crossfadeMultiplier
                    let inBase = frame * inputChannels
                    let outBase = frame * outputChannels
                    let copiedChannels = min(inputChannels, outputChannels)
                    for ch in 0..<copiedChannels {
                        outputSamples[outBase + ch] = inputSamples[inBase + ch] * gain
                    }
                    if copiedChannels < outputChannels {
                        for ch in copiedChannels..<outputChannels {
                            outputSamples[outBase + ch] = 0
                        }
                    }
                }
                let writtenSamples = frameCount * outputChannels
                if writtenSamples < outputSampleCount {
                    memset(outputSamples.advanced(by: writtenSamples), 0, (outputSampleCount - writtenSamples) * MemoryLayout<Float>.size)
                }
            }

            if let eq = eq, eq.isEnabled, eqCanProcessStereoInterleaved {
                eq.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }

            // Per-device AutoEQ correction (after per-app EQ)
            if let autoEQProc, autoEQProc.isEnabled, eqCanProcessStereoInterleaved {
                autoEQProc.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }

            // Loudness Equalization (before loudness compensation)
            if let loudnessEqualizerProc, loudnessEqualizerProc.isEnabled, eqCanProcessStereoInterleaved {
                loudnessEqualizerProc.process(input: UnsafePointer(outputSamples), output: outputSamples, frameCount: frameCount, channelCount: outputChannels)
            }

            // Loudness compensation (after all EQ, before limiting)
            if let loudnessCompensatorProc, loudnessCompensatorProc.isEnabled, eqCanProcessStereoInterleaved {
                loudnessCompensatorProc.process(input: outputSamples, output: outputSamples, frameCount: frameCount)
            }

            let writtenSampleCount = frameCount * outputChannels
            let shouldLimit = currentVol > 1.0
                || targetVol > 1.0
                || crossfadeMultiplier > 1.0
                || (eq?.isEnabled ?? false)
                || (autoEQProc?.isEnabled ?? false)
                || (loudnessEqualizerProc?.isEnabled ?? false)
                || (loudnessCompensatorProc?.isEnabled ?? false)

            if shouldLimit {
                SoftLimiter.processBuffer(outputSamples, sampleCount: writtenSampleCount)
            }
        }
    }
}
