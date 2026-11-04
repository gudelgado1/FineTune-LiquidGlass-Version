import AudioToolbox
import Foundation

/// Listener teardown participates in the same bounded retirement ownership as
/// capture teardown. Capture the block/address until HAL acknowledges removal.
nonisolated enum HALListenerRetirement {
    static func remove(_ id: AudioObjectID, address: AudioObjectPropertyAddress,
                       queue: DispatchQueue = .main, block: @escaping AudioObjectPropertyListenerBlock) {
        NativeTapHALAdapter.retirements.enqueue {
            var address = address
            let status = AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
            try check(status)
        }
    }
    static func enqueue(_ remove: @escaping @Sendable () -> OSStatus) {
        NativeTapHALAdapter.retirements.enqueue { try check(remove()) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status != noErr, status != kAudioHardwareBadObjectError,
              status != kAudioHardwareBadDeviceError, status != kAudioHardwareUnknownPropertyError else { return }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
