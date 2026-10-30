import AudioToolbox

extension ProcessTapController {
    nonisolated struct AggregatePlan: Equatable {
        var subDeviceUIDs: [String]
        var isStacked: Bool
        var clockDeviceUID: String
    }

    /// Pure planning step for `buildAggregateDescription`. Three CoreAudio
    /// constraints drive it:
    ///
    ///   1. An aggregate cannot be nested inside another aggregate — the wrapper
    ///      then reports 0 output channels. A user-created aggregate target is
    ///      therefore *flattened* into its hardware sub-devices via `expand`.
    ///   2. A *stacked* aggregate collapses a multichannel sub-device's output to
    ///      one stereo pair, discarding the device's preferred (e.g. 3/4) channel
    ///      assignment. A single flattened output stays NON-stacked so every
    ///      channel remains addressable and the callback can place audio on the
    ///      preferred pair.
    ///   3. That placement only holds when the wrapper exposes exactly ONE output
    ///      stream: preferred-channel indices are device-global, and the callback
    ///      finds the tap as the trailing input buffer(s). A flatten yielding
    ///      several sub-devices (or one device with several output streams) breaks
    ///      both, so those stay stacked — which is also what makes Multi-Output
    ///      targets mirror instead of playing out of a single sub-device.
    ///
    /// - Parameters:
    ///   - outputUIDs: user-selected outputs (1 = single, >1 = mirroring).
    ///   - expand: an aggregate's hardware sub-device UIDs, or `nil` if not an aggregate.
    ///   - outputStreamCount: a device's output-stream count (0 when unknown).
    nonisolated static func planAggregate(
        outputUIDs: [String],
        expand: (String) -> [String]?,
        outputStreamCount: (String) -> Int
    ) -> AggregatePlan {
        precondition(!outputUIDs.isEmpty, "Must have at least one target device")

        var flatUIDs: [String] = []
        var didFlatten = false
        for uid in outputUIDs {
            if let subDevices = expand(uid), !subDevices.isEmpty {
                flatUIDs.append(contentsOf: subDevices)
                didFlatten = true
            } else {
                flatUIDs.append(uid)
            }
        }

        // De-duplicate, preserving order: one device can belong to two aggregates.
        var seen = Set<String>()
        flatUIDs = flatUIDs.filter { seen.insert($0).inserted }

        let isMirroring = outputUIDs.count > 1
        let isSingleFlatten = didFlatten && !isMirroring && flatUIDs.count == 1
        let isStacked = !(isSingleFlatten && outputStreamCount(flatUIDs[0]) == 1)

        return AggregatePlan(
            subDeviceUIDs: flatUIDs,
            isStacked: isStacked,
            clockDeviceUID: flatUIDs[0]
        )
    }

    nonisolated static func inputStreamUsageFlags(inputCount: Int, outputCount: Int) -> [UInt32]? {
        // outputCount == 0 also covers a failed stream-count read; an all-unused
        // map would disable the tap stream itself (the HAL then delivers NULL
        // buffers for unused streams).
        guard inputCount > 0, outputCount > 0 else { return nil }
        let usedInputStreams = min(outputCount, inputCount)
        guard inputCount > usedInputStreams else { return nil }  // nothing extra to disable
        return (0..<inputCount).map { $0 >= inputCount - usedInputStreams ? 1 : 0 }
    }

}
