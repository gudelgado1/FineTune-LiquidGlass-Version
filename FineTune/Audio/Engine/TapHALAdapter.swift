import AudioToolbox
import Foundation
import os

nonisolated struct TapHALPlan: Sendable {
    let pid: pid_t
    let processObjectIDs: [AudioObjectID]
    let outputUIDs: [String]
    let preferredSourceUID: String?
}

nonisolated protocol TapHALAdapting: Sendable {
    func prepare(_ plan: TapHALPlan) throws -> PreparedTap
    func start(_ tap: PreparedTap, context: TapRenderContext) throws
    func destroy(_ tap: PreparedTap) throws
}

/// Descriptor is immutable after prepare. Native storage is exclusively used by
/// its worker until delivery, then exclusively by start/retirement workers.
nonisolated final class PreparedTap: @unchecked Sendable {
    let aggregateID: AudioDeviceID
    let sampleRate: Double
    let stereoLeft: Int
    let stereoRight: Int
    let profile: CrossfadeProfile
    let storage: AnyObject
    private let retirement = OSAllocatedUnfairLock<HALRetirementTicket?>(initialState: nil)
    init(aggregateID: AudioDeviceID, sampleRate: Double, stereoLeft: Int = 0, stereoRight: Int = 1,
         profile: CrossfadeProfile = .usb, storage: AnyObject) {
        self.aggregateID = aggregateID; self.sampleRate = sampleRate
        self.stereoLeft = stereoLeft; self.stereoRight = stereoRight
        self.profile = profile; self.storage = storage
    }
    @discardableResult
    func retire(adapter: any TapHALAdapting, queue: HALRetirementQueue) -> HALRetirementTicket {
        retirement.withLock { ticket in
            if let ticket { return ticket }
            let next = queue.enqueue { [self] in try adapter.destroy(self) }
            ticket = next
            return next
        }
    }
}

nonisolated struct TapHALFormat: Sendable {
    let sampleRate: Double
    var left: Int = 0
    var right: Int = 1
    var profile: CrossfadeProfile = .usb
}

/// Internal seam for deterministic failure at every native resource step. All
/// operations run on the submitting/retiring worker, never the render thread.
nonisolated struct TapHALOperations: Sendable {
    let createTap: @Sendable (TapHALPlan) throws -> (CATapDescription, AudioObjectID)
    let createAggregate: @Sendable (TapHALPlan, UUID) throws -> AudioDeviceID
    let format: @Sendable (TapHALPlan, AudioDeviceID) throws -> TapHALFormat
    let install: @Sendable (AudioDeviceID, TapRenderContext) throws -> AudioDeviceIOProcID?
    let start: @Sendable (AudioDeviceID, AudioDeviceIOProcID?) throws -> Void
    let removeProc: @Sendable (AudioDeviceID, AudioDeviceIOProcID?) throws -> Void
    let removeAggregate: @Sendable (AudioDeviceID) throws -> Void
    let removeTap: @Sendable (AudioObjectID) throws -> Void
}

nonisolated final class NativeTapHALAdapter: TapHALAdapting {
    static let shared = NativeTapHALAdapter()
    static let retirements = HALRetirementQueue()
    static let executor = OwnedHALExecutor(limit: 4)
    private let calls: TapHALOperations
    private let queue: HALRetirementQueue
    init(operations: TapHALOperations? = nil, retirements: HALRetirementQueue? = nil) {
        calls = operations ?? NativeTapHALCalls().operations
        queue = retirements ?? Self.retirements
    }
    private final class Storage: @unchecked Sendable {
        var tapID: AudioObjectID = .unknown
        var aggregateID: AudioDeviceID = .unknown
        var procID: AudioDeviceIOProcID?
        var installed = false
        var description: CATapDescription?
        var context: TapRenderContext?
    }
    func prepare(_ plan: TapHALPlan) throws -> PreparedTap {
        let storage = Storage()
        do {
            let (description, id) = try calls.createTap(plan)
            storage.description = description; storage.tapID = id
            storage.aggregateID = try calls.createAggregate(plan, description.uuid)
            let format = try calls.format(plan, storage.aggregateID)
            return PreparedTap(aggregateID: storage.aggregateID, sampleRate: format.sampleRate,
                stereoLeft: format.left, stereoRight: format.right, profile: format.profile, storage: storage)
        } catch {
            queue.enqueue { [self, storage] in try destroyStorage(storage) }
            throw error
        }
    }
    func start(_ tap: PreparedTap, context: TapRenderContext) throws {
        let storage = tap.storage as! Storage
        storage.context = context
        storage.procID = try calls.install(storage.aggregateID, context)
        storage.installed = true
        guard context.role != .retired else { throw CancellationError() }
        try calls.start(storage.aggregateID, storage.procID)
    }
    func destroy(_ tap: PreparedTap) throws { try destroyStorage(tap.storage as! Storage) }
    private func destroyStorage(_ storage: Storage) throws {
        if storage.installed {
            try calls.removeProc(storage.aggregateID, storage.procID)
            storage.installed = false; storage.procID = nil
        }
        if storage.aggregateID.isValid {
            try calls.removeAggregate(storage.aggregateID)
            storage.aggregateID = .unknown
        }
        if storage.tapID.isValid {
            try calls.removeTap(storage.tapID)
            storage.tapID = .unknown
        }
        storage.description = nil
        storage.context = nil
    }
}

nonisolated private final class NativeTapHALCalls: Sendable {
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "TapHAL")
    var operations: TapHALOperations {
        TapHALOperations(createTap: { [self] in try createTap($0) }, createAggregate: { [self] plan, uuid in
            let description = buildAggregateDescription(outputUIDs: plan.outputUIDs, tapUUID: uuid, name: "FineTune-\(plan.pid)")
            var id: AudioDeviceID = .unknown
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id))
            CrashGuard.trackDevice(id)
            return id
        }, format: { [self] plan, id in
            guard id.waitUntilReady(timeout: 2) else { throw CrossfadeError.deviceNotReady }
            let rate = (try? id.readNominalSampleRate()) ?? 48_000
            let device = plan.outputUIDs.first.flatMap { audioDeviceID(for: $0) }
            let stereo = device?.preferredStereoChannelIndices() ?? (left: 0, right: 1)
            return TapHALFormat(sampleRate: rate, left: stereo.left, right: stereo.right,
                profile: CrossfadeProfile.profile(for: device?.readTransportType()))
        }, install: { [self] id, context in
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, input, _, output, _ in context.process(input, to: output) })
            guard proc != nil else { throw TapLifecycleError.retirementFailed }
            disableHardwareInputStreams(aggregateID: id, procID: proc)
            return proc
        }, start: { [self] in try check(AudioDeviceStart($0, $1)) }, removeProc: { [self] id, proc in
            guard let proc else { throw TapLifecycleError.retirementFailed }
            _ = AudioDeviceStop(id, proc)
            try checkRemoval(AudioDeviceDestroyIOProcID(id, proc))
        }, removeAggregate: { [self] id in
            try checkRemoval(AudioHardwareDestroyAggregateDevice(id)); CrashGuard.untrackDevice(id)
        }, removeTap: { [self] in try checkRemoval(AudioHardwareDestroyProcessTap($0)) })
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private func checkRemoval(_ status: OSStatus) throws {
        guard status != kAudioHardwareBadObjectError, status != kAudioHardwareBadDeviceError else { return }
        try check(status)
    }
    private func audioDeviceID(for uid: String) -> AudioDeviceID? {
        (try? AudioObjectID.readDeviceList())?.first { (try? $0.readDeviceUID()) == uid }
    }
    func createTap(_ plan: TapHALPlan) throws -> (CATapDescription, AudioObjectID) {
        if let uid = plan.preferredSourceUID, let device = audioDeviceID(for: uid),
           let stream = try? device.firstOutputStreamIndex() {
            let desc = CATapDescription(processes: plan.processObjectIDs, deviceUID: uid, stream: stream)
            desc.uuid = UUID(); desc.muteBehavior = .mutedWhenTapped; desc.isPrivate = true
            var id: AudioObjectID = .unknown
            if AudioHardwareCreateProcessTap(desc, &id) == noErr { return (desc, id) }
        }
        let desc = CATapDescription(stereoMixdownOfProcesses: plan.processObjectIDs)
        desc.uuid = UUID(); desc.muteBehavior = .mutedWhenTapped; desc.isPrivate = true
        var id: AudioObjectID = .unknown
        try check(AudioHardwareCreateProcessTap(desc, &id))
        return (desc, id)
    }
    private func buildAggregateDescription(outputUIDs: [String], tapUUID: UUID, name: String) -> [String: Any] {
        precondition(!outputUIDs.isEmpty, "Must have at least one target device")

        let plan = ProcessTapController.planAggregate(
            outputUIDs: outputUIDs,
            expand: { [self] uid in
                self.audioDeviceID(for: uid)?.aggregateSubDeviceUIDs()
            },
            outputStreamCount: { [self] uid in
                self.audioDeviceID(for: uid)?.streamCount(scope: kAudioObjectPropertyScopeOutput) ?? 0
            }
        )

        if plan.subDeviceUIDs != outputUIDs {
            logger.info("Flattened output \(outputUIDs, privacy: .public) → sub-devices \(plan.subDeviceUIDs, privacy: .public) (stacked=\(plan.isStacked))")
        }

        // Build sub-device list - first device is clock source
        var subDevices: [[String: Any]] = []
        for (index, deviceUID) in plan.subDeviceUIDs.enumerated() {
            subDevices.append([
                kAudioSubDeviceUIDKey: deviceUID,
                // First device (index 0) is clock source - no drift compensation needed
                // All other devices have drift compensation enabled to sync to clock
                kAudioSubDeviceDriftCompensationKey: index > 0
            ])
        }

        return [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: plan.clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: plan.clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Stacked mirrors the same audio to every sub-device (needed for
            // multi-device output); a single flattened aggregate stays
            // non-stacked so all of its channels stay addressable.
            kAudioAggregateDeviceIsStackedKey: plan.isStacked,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
    }

    private func disableHardwareInputStreams(aggregateID: AudioObjectID, procID: AudioDeviceIOProcID?) {
        guard let procID else { return }

        let inputCount = aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput)
        let outputCount = aggregateID.streamCount(scope: kAudioObjectPropertyScopeOutput)
        guard let flagsArray = ProcessTapController.inputStreamUsageFlags(inputCount: inputCount, outputCount: outputCount) else { return }
        let usedInputStreams = flagsArray.reduce(0) { $0 + Int($1) }

        // AudioHardwareIOProcStreamUsage is a variable-length C struct:
        //   { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[mNumberStreams]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment
        )
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        let flags = raw.advanced(by: headerSize)
        for (i, isUsed) in flagsArray.enumerated() {
            flags.advanced(by: i * MemoryLayout<UInt32>.size).storeBytes(of: isUsed, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(totalSize), raw)
        if err == noErr {
            logger.info("Disabled \(inputCount - usedInputStreams) hardware input stream(s); kept \(usedInputStreams) tap stream(s)")
        } else {
            logger.warning("Could not disable hardware input streams (\(err)); microphone permission may be requested")
        }
    }

}
