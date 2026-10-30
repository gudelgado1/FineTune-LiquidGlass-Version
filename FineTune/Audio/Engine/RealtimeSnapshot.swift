import Atomics

/// Single control writer, single render reader. Published values must contain
/// only value scalars/C pointers: the render path never owns a Swift reference
/// to the resources behind them. `owner` retains those resources on control.
///
/// A hazard pointer pins the one storage the render reader uses. The reader
/// publishes its hazard BEFORE validating the current pointer (all SC); it
/// never dereferences an unvalidated pointer. Control reclaims only retired
/// storages absent from the hazard. This replaces timing-based reclamation.
/// Multiple render readers must have separate instances (as primary/secondary DSP do).
nonisolated final class RealtimeSnapshot<Value>: @unchecked Sendable {
    private final class Storage {
        let pointer: UnsafeMutablePointer<Value>
        let owner: AnyObject?
        init(_ value: Value, owner: AnyObject?) {
            pointer = .allocate(capacity: 1)
            pointer.initialize(to: value)
            self.owner = owner
        }
        deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
    }

    private let keepLastReadAlive: Bool
    private let published: ManagedAtomic<UnsafeMutableRawPointer?>
    private let hazard = ManagedAtomic<UnsafeMutableRawPointer?>(nil)
    // Control-writer-only state. Never read from the render thread.
    private var current: Storage
    private var retired: [Storage] = []

    init(_ value: Value, owner: AnyObject? = nil, keepLastReadAlive: Bool = false) {
        self.keepLastReadAlive = keepLastReadAlive
        let storage = Storage(value, owner: owner)
        current = storage
        published = ManagedAtomic(UnsafeMutableRawPointer(storage.pointer))
    }

    var controlValue: Value { current.pointer.pointee }
    var retainedStorageCount: Int { retired.count + 1 }

    func publish(_ value: Value, owner: AnyObject? = nil) {
        let next = Storage(value, owner: owner)
        let previous = current
        current = next
        published.store(UnsafeMutableRawPointer(next.pointer), ordering: .sequentiallyConsistent)
        retired.append(previous)
        collectRetired()
    }

    func collectRetired() {
        let pinned = hazard.load(ordering: .sequentiallyConsistent)
        retired.removeAll { UnsafeMutableRawPointer($0.pointer) != pinned }
    }

    /// Allocation-free and lock-free. The pointer/value must not escape `body`.
    @inline(__always)
    func withValue<Result>(_ body: (Value) -> Result) -> Result {
        while true {
            let candidate = published.load(ordering: .sequentiallyConsistent)!
            hazard.store(candidate, ordering: .sequentiallyConsistent)
            guard published.load(ordering: .sequentiallyConsistent) == candidate else { continue }
            // A Swift-object reader may retain a temporary beyond the body.
            // In that mode keep the last snapshot pinned until the NEXT read
            // (the next IO callback), or until context destruction after HAL ack.
            defer { if !keepLastReadAlive { hazard.store(nil, ordering: .sequentiallyConsistent) } }
            return body(candidate.assumingMemoryBound(to: Value.self).pointee)
        }
    }
}
