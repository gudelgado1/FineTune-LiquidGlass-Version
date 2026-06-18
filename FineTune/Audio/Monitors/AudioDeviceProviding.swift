import AudioToolbox

@MainActor
protocol AudioDeviceProviding: AnyObject {
    var outputDevices: [AudioDevice] { get }
    var inputDevices: [AudioDevice] { get }

    var onDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceDisconnected: ((_ uid: String, _ name: String) -> Void)? { get set }
    var onInputDeviceConnected: ((_ uid: String, _ name: String) -> Void)? { get set }

    /// Fired once after every (debounced) HAL device-list change, regardless of
    /// which specific devices changed. Used to revalidate tap liveness, since a
    /// `coreaudiod` restart surfaces as a device-list change that destroys our
    /// private aggregate devices without a clean per-device disconnect.
    var onDeviceListChanged: (() -> Void)? { get set }

    func device(for uid: String) -> AudioDevice?
    func inputDevice(for uid: String) -> AudioDevice?

    func start()
    func stop()
}
