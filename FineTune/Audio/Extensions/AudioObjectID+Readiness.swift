// FineTune/Audio/Extensions/AudioObjectID+Readiness.swift
import AudioToolbox
import CoreFoundation

// MARK: - Device Readiness

extension AudioObjectID {
    /// Check if an audio device is currently alive and operational.
    /// Uses kAudioDevicePropertyDeviceIsAlive to verify device state.
    /// - Returns: `true` if device is alive, `false` if dead or query fails.
    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    /// Three-state liveness for *teardown* decisions. Unlike `isDeviceAlive()`,
    /// which collapses "device reports not-alive" and "the query failed" into a
    /// single `false`, this distinguishes a **definitively gone** device from a
    /// **transient** HAL hiccup under load.
    ///
    /// This matters because the audio engine tears a tap down and recreates it
    /// when it looks dead. Under heavy CPU/memory load the `coreaudiod` IPC can
    /// return a transient error for a perfectly healthy aggregate — and treating
    /// that as "dead" causes a recreate storm that cuts audio every ~0.5–1 s.
    /// Only a `kAudioHardwareBadObjectError`/`BadDeviceError` (the object no
    /// longer exists — exactly what a `coreaudiod` restart produces) is treated
    /// as definitively gone.
    enum DeviceLiveness {
        case alive
        case dead       // definitively gone (object no longer exists)
        case unknown    // transient query failure — caller should assume alive
    }

    func deviceLiveness() -> DeviceLiveness {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        switch status {
        case noErr:
            return isAlive != 0 ? .alive : .dead
        case kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError:
            return .dead
        default:
            return .unknown
        }
    }

    /// Wait for an audio device to become ready, processing HAL events via CFRunLoop.
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds (default: 1.0)
    ///   - pollInterval: Time between readiness checks in seconds (default: 0.01)
    /// - Returns: `true` if device became ready within timeout, `false` otherwise.
    /// - Warning: This method blocks the calling thread via CFRunLoopRunInMode. Do not call from the main thread without careful consideration.
    /// - Note: Uses CFRunLoopRunInMode to allow Core Audio HAL events to be processed
    ///         during the wait. This is critical for aggregate device initialization.
    func waitUntilReady(timeout: TimeInterval = 1.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() {
                return true
            }
            // Process HAL events while waiting - critical for aggregate device stabilization
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }

        return false
    }
}
