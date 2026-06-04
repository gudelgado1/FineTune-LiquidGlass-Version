// FineTune/Audio/Extensions/AudioObjectID+AsyncChanges.swift
import AudioToolbox
import CoreAudio

// MARK: - Property-Change AsyncStream
//
// Core Audio property change notifications historically require manual lifecycle
// management: `AudioObjectAddPropertyListenerBlock` to register, an equally
// well-balanced `AudioObjectRemovePropertyListenerBlock` to deregister, and a
// stored block reference so the *same* pointer can be removed later.
//
// This file wraps that pattern in an `AsyncStream`. Callers `for await` the
// changes; if the stream is cancelled (the for-loop exits, the parent Task is
// cancelled, or the consumer breaks early), `onTermination` removes the
// listener exactly once. No leaks, no double-registration, no forgotten
// `remove` calls.
//
// Threading note: Core Audio delivers callbacks on whatever queue you pass.
// We use `.main` to mirror existing call sites in `DeviceVolumeMonitor` and
// friends — but the API lets the caller override.

extension AudioObjectID {
    /// Returns an `AsyncStream` that yields once per property change.
    ///
    /// The element is `Void` because the callback only signals "the property
    /// changed; read its current value yourself". This matches how Core Audio
    /// itself behaves and avoids holding stale snapshots in the stream.
    ///
    /// - Parameters:
    ///   - address: The property to observe.
    ///   - queue: Dispatch queue on which Core Audio delivers the callback.
    ///     Defaults to `.main` to match existing FineTune patterns.
    ///   - bufferingPolicy: Stream buffering for cases where consumers can't
    ///     keep up. Defaults to `.bufferingNewest(1)` — for property changes
    ///     we only care about the latest signal, not a history.
    /// - Returns: An `AsyncStream<Void>` that automatically removes the
    ///   listener on termination (cancellation, finish, or consumer release).
    func propertyChanges(
        for address: AudioObjectPropertyAddress,
        on queue: DispatchQueue = .main,
        bufferingPolicy: AsyncStream<Void>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            // Core Audio requires a mutable pointer to the address — we take
            // a local copy so the caller's value doesn't outlive the stream.
            var mutableAddress = address
            let objectID = self

            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                continuation.yield()
            }

            let status = AudioObjectAddPropertyListenerBlock(
                objectID, &mutableAddress, queue, listener
            )

            guard status == noErr else {
                continuation.finish()
                return
            }

            continuation.onTermination = { _ in
                // Use a fresh local var — Core Audio mutates `&address` internally
                // and we don't want to share state with the listener registration.
                var removeAddress = address
                AudioObjectRemovePropertyListenerBlock(
                    objectID, &removeAddress, queue, listener
                )
            }
        }
    }
}

// MARK: - Convenience Selectors
//
// Common Core Audio property selectors as typed constants. These avoid the
// "magic UInt32" feel of `kAudioHardwarePropertyDefaultOutputDevice` etc. at
// the call site and let the AsyncStream API feel like a Swift idiom.

extension AudioObjectPropertyAddress {
    /// Default output device changed.
    static let defaultOutputDevice = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Default input device changed.
    static let defaultInputDevice = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Default system output device changed (the one that plays UI sounds).
    static let defaultSystemOutputDevice = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Output volume on a device changed (scoped to the output scope).
    static let outputVolume = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Output mute state on a device changed (scoped to the output scope).
    static let outputMute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Set of devices on the system changed (added/removed).
    static let devices = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

// MARK: - Usage Example
//
// ```swift
// let task = Task { @MainActor [weak self] in
//     for await _ in AudioObjectID(kAudioObjectSystemObject).propertyChanges(
//         for: .defaultOutputDevice
//     ) {
//         self?.handleDefaultDeviceChange()
//     }
// }
// // Cancel later — listener is automatically removed:
// task.cancel()
// ```
//
// Migration from imperative pattern:
//
// ```swift
// // BEFORE — manual registration & cleanup
// let block: AudioObjectPropertyListenerBlock = { _, _ in self.handle() }
// AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
// // (must remember to call AudioObjectRemovePropertyListenerBlock somewhere)
//
// // AFTER — streamed, scoped, leak-free
// for await _ in id.propertyChanges(for: address) { handle() }
// ```
