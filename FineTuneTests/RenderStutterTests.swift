import Testing
@testable import FineTune

struct RenderStutterTests {
    @Test("Repeated sub-second interruptions trigger recovery even though callbacks keep arriving")
    func repeatedGaps() {
        var timing = RenderGapTracker()
        var detector = RenderStutterDetector()
        var count: UInt64 = 0
        _ = timing.record(time: 0, callbackID: 1, bufferDuration: 0.01)
        let initial = detector.observe(longGapCount: count)
        #expect(!initial)
        for window in 1...2 {
            for frame in 1...20 {
                let time = Double((window - 1) * 20 + frame) * 0.1
                if timing.record(time: time, callbackID: 1, bufferDuration: 0.01) { count += 1 }
            }
            let recover = detector.observe(longGapCount: count)
            #expect(recover == (window == 2))
        }
    }

    @Test("A single burst, quiet window, or counter reset does not trigger recovery")
    func transientGaps() {
        var detector = RenderStutterDetector()
        for count: UInt64 in [0, 8, 8, 9, 20, 0, 0] {
            let recover = detector.observe(longGapCount: count)
            #expect(!recover)
        }
    }

    @Test("Callback generations and large valid buffers do not look like stalls")
    func generationAndBufferSize() {
        var timing = RenderGapTracker()
        let results = [
            timing.record(time: 0, callbackID: 1, bufferDuration: 0.1),
            timing.record(time: 0.1, callbackID: 1, bufferDuration: 0.1),
            timing.record(time: 50, callbackID: 2, bufferDuration: 0.01),
            timing.record(time: 50.01, callbackID: 2, bufferDuration: 0.01),
            timing.record(time: 50.2, callbackID: 2, bufferDuration: 0.01)
        ]
        #expect(results == [false, false, false, false, true])
    }
}
