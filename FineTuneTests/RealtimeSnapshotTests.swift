import Accelerate
import Foundation
import os
import Testing
@testable import FineTune

nonisolated private final class SnapshotTestOwner {}

@Suite("Real-time snapshot lifetime", .serialized)
@MainActor
struct RealtimeSnapshotTests {
    @Test("render pins its resource across arbitrary control-side publication")
    func pinnedResourceSurvivesChurn() {
        var owner: SnapshotTestOwner? = SnapshotTestOwner()
        weak var weakOwner: SnapshotTestOwner?
        weakOwner = owner
        let snapshot = RealtimeSnapshot(11, owner: owner)
        owner = nil
        let pinned = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let observed = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.global().async {
            snapshot.withValue { value in
                pinned.signal()
                release.wait()
                observed.withLock { $0 = value }
            }
            finished.signal()
        }
        let didPin = pinned.wait(timeout: .now() + 3) == .success
        defer { release.signal() }
        #expect(didPin)
        guard didPin else { return }
        for index in 0..<10_000 { snapshot.publish(index) }
        #expect(weakOwner != nil)
        #expect(snapshot.retainedStorageCount == 2)
        release.signal()
        #expect(finished.wait(timeout: .now() + 3) == .success)
        snapshot.collectRetired()
        #expect(weakOwner == nil)
        #expect(snapshot.retainedStorageCount == 1)
        #expect(observed.withLock { $0 } == 11)
        #expect(snapshot.withValue { $0 } == 9_999)
    }

    @Test("Swift processor owner stays pinned until the next callback entry")
    func swiftOwnerGraceEndsAtNextRead() {
        var owner: SnapshotTestOwner? = SnapshotTestOwner()
        weak var weakOwner: SnapshotTestOwner?
        weakOwner = owner
        let snapshot = RealtimeSnapshot(1, owner: owner, keepLastReadAlive: true)
        owner = nil
        #expect(snapshot.withValue { $0 } == 1)
        for index in 2..<1000 { snapshot.publish(index) }
        snapshot.collectRetired()
        #expect(weakOwner != nil)
        #expect(snapshot.retainedStorageCount == 2)
        #expect(snapshot.withValue { $0 } == 999)
        snapshot.collectRetired()
        #expect(weakOwner == nil)
        #expect(snapshot.retainedStorageCount == 1)
    }

    @Test("real vDSP render overlaps EQ enable, coefficient and reset changes")
    func concurrentEQRenderAndUpdates() {
        let processor = EQProcessor(sampleRate: 48_000)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let keepRunning = OSAllocatedUnfairLock(initialState: true)
        let stats = OSAllocatedUnfairLock(initialState: (buffers: 0, finite: true))
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 256)
            defer { buffer.deallocate(); finished.signal() }
            started.signal()
            repeat {
                for i in 0..<256 { buffer[i] = Float(sin(Double(i) * 0.1)) * 0.1 }
                _ = processor.isEnabled // exercise the mixer's concurrent fast-path read
                processor.process(input: buffer, output: buffer, frameCount: 128)
                let finite = (0..<256).allSatisfy { buffer[$0].isFinite }
                stats.withLock { $0.buffers += 1; $0.finite = $0.finite && finite }
            } while keepRunning.withLock({ $0 })
        }
        #expect(started.wait(timeout: .now() + 3) == .success)
        for index in 0..<2_000 {
            var settings = EQSettings.flat
            settings.isEnabled = index % 3 != 0
            settings.bandGains[index % EQSettings.bandCount] = index % 2 == 0 ? 4 : -4
            processor.updateSettings(settings)
            if index % 7 == 0 { processor.resetDelayBuffers() }
            if index % 100 == 0 { processor.updateSampleRate(index % 200 == 0 ? 44_100 : 48_000) }
        }
        keepRunning.withLock { $0 = false }
        #expect(finished.wait(timeout: .now() + 5) == .success)
        let result = stats.withLock { $0 }
        #expect(result.buffers > 0)
        #expect(result.finite)
    }
    @Test("AutoEQ profile and preamp changes overlap real rendering")
    func concurrentAutoEQRenderAndUpdates() {
        let processor = AutoEQProcessor(sampleRate: 48_000)
        let finished = DispatchSemaphore(value: 0)
        let keepRunning = OSAllocatedUnfairLock(initialState: true)
        let stats = OSAllocatedUnfairLock(initialState: (buffers: 0, coherent: true))
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            defer { buffer.deallocate(); finished.signal() }
            repeat {
                buffer.update(repeating: 1, count: 128)
                processor.process(input: buffer, output: buffer, frameCount: 64)
                let gain = buffer[0]
                let coherent = [Float(1), powf(10, -6 / 20), powf(10, -12 / 20)].contains {
                    abs($0 - gain) < 0.0001
                } && (0..<128).allSatisfy { abs(buffer[$0] - gain) < 0.0001 }
                stats.withLock { $0.buffers += 1; $0.coherent = $0.coherent && coherent }
            } while keepRunning.withLock({ $0 })
        }
        for index in 0..<500 {
            let profile = AutoEQProfile(id: "stress", name: "stress", source: .imported,
                preampDB: index % 2 == 0 ? -6 : -12,
                filters: [.init(type: .peaking, frequency: 1000, gainDB: 0, q: 1)],
                measuredBy: nil, optimizedSampleRate: 48_000)
            processor.updateProfile(index % 5 == 0 ? nil : profile)
            processor.setPreampEnabled(index % 3 != 0)
            if index % 10 == 0 { processor.resetDelayBuffers() }
        }
        keepRunning.withLock { $0 = false }
        #expect(finished.wait(timeout: .now() + 5) == .success)
        let result = stats.withLock { $0 }
        #expect(result.buffers > 0)
        #expect(result.coherent)
    }

}
