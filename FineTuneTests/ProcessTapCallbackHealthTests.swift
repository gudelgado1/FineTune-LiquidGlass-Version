import AppKit
import AudioToolbox
import Testing
import Foundation
import os
@testable import FineTune

/// Executes the production callback with owned buffers and no CoreAudio resources.
@Suite("ProcessTapController — callback generation health")
@MainActor
struct ProcessTapCallbackHealthTests {
    @Test("A retired IO proc cannot mark its replacement healthy")
    func retiredCallbackDoesNotRefreshHealth() {
        let controller = makeController()
        let retiredID = controller.reservePrimaryCallbackID()
        let currentID = controller.reservePrimaryCallbackID()

        let retiredOutput = render(controller, callbackID: retiredID)

        #expect(retiredOutput.allSatisfy { $0 == 0 })
        #expect(!controller.hasRecentAudioCallback(within: 60))

        // The replacement must render for the heartbeat to become healthy.
        let currentOutput = render(controller, callbackID: currentID)
        #expect(currentOutput.allSatisfy { $0 == 0.25 })
        #expect(controller.hasRecentAudioCallback(within: 60))
    }

    @Test("Zero is never a valid callback identity, including before activation")
    func invalidationSentinelDoesNotRender() {
        let controller = makeController()

        let output = render(controller, callbackID: 0)

        #expect(output.allSatisfy { $0 == 0 })
        #expect(!controller.hasRecentAudioCallback(within: 60))
    }

    @Test("An intentionally muted current callback still counts as live")
    func mutedCurrentCallbackRemainsHealthy() {
        let controller = makeController()
        let currentID = controller.reservePrimaryCallbackID()
        controller.isMuted = true

        let output = render(controller, callbackID: currentID)

        #expect(output.allSatisfy { $0 == 0 })
        #expect(controller.hasRecentAudioCallback(within: 60))
    }

    @Test("control volume and mute updates overlap production rendering")
    func concurrentControlAndRender() async {
        let controller = makeController()
        _ = controller.reservePrimaryCallbackID()
        let context = controller.renderContextForTesting()!
        let running = OSAllocatedUnfairLock(initialState: true)
        let done = OSAllocatedUnfairLock(initialState: false)
        let started = OSAllocatedUnfairLock(initialState: false)
        let finite = OSAllocatedUnfairLock(initialState: true)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = renderContext(context)
            started.withLock { $0 = true }
            while running.withLock({ $0 }) {
                let output = renderContext(context)
                finite.withLock { $0 = $0 && output.allSatisfy(\.isFinite) }
            }
            done.withLock { $0 = true }
        }
        for _ in 0..<600 {
            if started.withLock({ $0 }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.withLock { $0 })
        for index in 0..<100_000 {
            if index % 500 == 0 { await Task.yield() }
            if index % 1000 == 0 {
                var leveler = LoudnessEqualizerSettings()
                leveler.enabled = index % 2000 == 0
                controller.updateLoudnessEqualization(leveler)
                controller.updateEQSettings(EQSettings(bandGains: [3,0,0,0,0,0,0,0,0,0], isEnabled: true))
                controller.updateLoudnessCompensation(volume: 0.5, enabled: index % 2000 == 0)
            }
            controller.volume = index % 2 == 0 ? 0.2 : 0.8
            controller.isMuted = index % 3 == 0
            controller.setDSPBypass(index % 5 == 0)
            _ = controller.audioLevel
            _ = controller.hasRecentAudioCallback(within: 1)
        }
        running.withLock { $0 = false }
        for _ in 0..<1000 {
            if done.withLock({ $0 }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(done.withLock { $0 })
        #expect(finite.withLock { $0 })
    }

    nonisolated private func renderContext(_ context: TapRenderContext) -> [Float] {
        let input = [Float](repeating: 0.25, count: 128)
        var output = [Float](repeating: -1, count: 128)
        input.withUnsafeBufferPointer { i in output.withUnsafeMutableBufferPointer { o in
            var inputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 512, mData: UnsafeMutableRawPointer(mutating: i.baseAddress!)))
            var outputs = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 512, mData: o.baseAddress!))
            withUnsafePointer(to: &inputs) { p in withUnsafeMutablePointer(to: &outputs) { context.process(p, to: $0) } }
        } }
        return output
    }

    private func makeController() -> ProcessTapController {
        ProcessTapController(
            app: AudioApp(
                id: 79001,
                processObjectIDs: [],
                name: "Callback test",
                icon: NSImage(),
                bundleID: "test.callback-health"
            ),
            targetDeviceUID: "test-output"
        )
    }

    private func render(_ controller: ProcessTapController, callbackID: UInt32) -> [Float] {
        let input = [Float](repeating: 0.25, count: 128)
        var output = [Float](repeating: -1, count: input.count)
        input.withUnsafeBufferPointer { inputSamples in
            output.withUnsafeMutableBufferPointer { outputSamples in
                var inputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(inputSamples.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(mutating: inputSamples.baseAddress!)
                    )
                )
                var outputList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outputSamples.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(outputSamples.baseAddress!)
                    )
                )
                withUnsafePointer(to: &inputList) { inputPointer in
                    withUnsafeMutablePointer(to: &outputList) { outputPointer in
                        controller.processAudioCallback(inputPointer, to: outputPointer, callbackID: callbackID)
                    }
                }
            }
        }
        return output
    }
}
