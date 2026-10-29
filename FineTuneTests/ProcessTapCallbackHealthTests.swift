import AppKit
import AudioToolbox
import Testing
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
