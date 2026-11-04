import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class InputLockProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

/// Input-device lock: the feature that stops macOS from yanking your microphone
/// to whatever just connected. These paths are almost entirely state machine and
/// persistence, so they're testable without hardware — and getting them wrong
/// means the user's mic silently changes mid-call.
@Suite("AudioEngine — input device lock", .serialized)
@MainActor
struct AudioEngineInputLockTests {

    // MARK: - Enabling the lock

    @Test("enabling the lock captures the current default as both locked and preferred")
    func enablingLockCapturesCurrentDefault() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-usb")

        h.engine.handleInputLockEnabled()

        #expect(h.settings.lockedInputDeviceUID == "mic-usb")
        // Preferred is the durable "what the user wanted" record: the lock may
        // fall back to another device on disconnect, but preference must survive.
        #expect(h.settings.preferredInputDeviceUID == "mic-usb")
    }

    @Test("enabling the lock with no resolvable default records nothing")
    func enablingLockWithoutDefaultIsNoOp() {
        let h = makeHarness(inputs: [("mic-usb", 10)], defaultInput: nil)

        h.engine.handleInputLockEnabled()

        #expect(h.settings.lockedInputDeviceUID == nil)
        #expect(h.settings.preferredInputDeviceUID == nil)
    }

    @Test("explicitly choosing a device persists it and applies it")
    func choosingDeviceAppliesAndPersists() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-xlr", 12)], defaultInput: "mic-usb")
        let xlr = h.device("mic-xlr")

        h.engine.setLockedInputDevice(xlr)

        #expect(h.settings.lockedInputDeviceUID == "mic-xlr")
        #expect(h.settings.preferredInputDeviceUID == "mic-xlr")
        #expect(h.volume.defaultInputDeviceUID == "mic-xlr")
    }

    // MARK: - Restoring

    @Test("restore switches the system back to the locked device")
    func restoreSwitchesBack() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-builtin")
        h.settings.setLockedInputDeviceUID("mic-usb")

        h.engine.restoreLockedInputDevice()

        #expect(h.volume.defaultInputDeviceUID == "mic-usb")
    }

    @Test("restore is a no-op when already on the locked device")
    func restoreIsNoOpWhenAlreadyCorrect() {
        let h = makeHarness(inputs: [("mic-usb", 10)], defaultInput: "mic-usb")
        h.settings.setLockedInputDeviceUID("mic-usb")
        let before = h.volume.setDefaultInputCallCount

        h.engine.restoreLockedInputDevice()

        // Re-asserting a device we're already on would emit a pointless HAL
        // write and a spurious echo the state machine then has to consume.
        #expect(h.volume.setDefaultInputCallCount == before)
    }

    // MARK: - Reacting to external changes

    @Test("an external change is undone while the lock is on")
    func externalChangeIsUndone() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-usb")
        h.settings.appSettings.lockInputDevice = true
        h.settings.setLockedInputDeviceUID("mic-usb")

        // macOS (or System Settings) moves the default elsewhere.
        h.volume.defaultInputDeviceUID = "mic-builtin"
        h.engine.handleDefaultInputDeviceChanged("mic-builtin")

        #expect(h.volume.defaultInputDeviceUID == "mic-usb")
    }

    @Test("an external change is respected while the lock is off")
    func externalChangeRespectedWhenUnlocked() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-usb")
        h.settings.appSettings.lockInputDevice = false
        h.settings.setLockedInputDeviceUID("mic-usb")

        h.volume.defaultInputDeviceUID = "mic-builtin"
        h.engine.handleDefaultInputDeviceChanged("mic-builtin")

        #expect(h.volume.defaultInputDeviceUID == "mic-builtin")
    }

    @Test("a change onto the locked device itself triggers no correction")
    func changeToLockedDeviceIsNoOp() {
        let h = makeHarness(inputs: [("mic-usb", 10)], defaultInput: "mic-usb")
        h.settings.appSettings.lockInputDevice = true
        h.settings.setLockedInputDeviceUID("mic-usb")
        let before = h.volume.setDefaultInputCallCount

        h.engine.handleDefaultInputDeviceChanged("mic-usb")

        #expect(h.volume.setDefaultInputCallCount == before)
    }

    @Test("our own override echo is consumed instead of being treated as user intent")
    func ownEchoIsConsumed() {
        // Without echo suppression the engine reacts to the notification caused
        // by its own write — a feedback loop of restores.
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-builtin")
        h.settings.appSettings.lockInputDevice = true
        h.settings.setLockedInputDeviceUID("mic-usb")

        h.engine.restoreLockedInputDevice()          // writes + registers an echo
        let afterRestore = h.volume.setDefaultInputCallCount

        h.engine.handleDefaultInputDeviceChanged("mic-usb")  // the resulting callback

        #expect(h.volume.setDefaultInputCallCount == afterRestore)
    }

    // MARK: - Connect / disconnect

    @Test("the preferred device reconnecting takes the lock back")
    func preferredDeviceReconnectReclaimsLock() {
        // The user's chosen mic was unplugged and the lock fell back; plugging it
        // back in must return to it rather than stranding them on the fallback.
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-builtin")
        h.settings.appSettings.lockInputDevice = true
        h.settings.setPreferredInputDeviceUID("mic-usb")
        h.settings.setLockedInputDeviceUID("mic-builtin")

        h.engine.handleInputDeviceConnected("mic-usb", name: "USB Mic")

        #expect(h.settings.lockedInputDeviceUID == "mic-usb")
        #expect(h.volume.defaultInputDeviceUID == "mic-usb")
    }

    @Test("a device connecting while the lock is off is ignored")
    func connectIgnoredWhenUnlocked() {
        let h = makeHarness(inputs: [("mic-usb", 10), ("mic-builtin", 11)], defaultInput: "mic-builtin")
        h.settings.appSettings.lockInputDevice = false
        h.settings.setPreferredInputDeviceUID("mic-usb")

        h.engine.handleInputDeviceConnected("mic-usb", name: "USB Mic")

        #expect(h.volume.defaultInputDeviceUID == "mic-builtin")
    }

    @Test("losing the locked device falls back to the highest-priority survivor")
    func disconnectFallsBackByPriority() {
        let h = makeHarness(
            inputs: [("mic-usb", 10), ("mic-xlr", 12), ("mic-builtin", 11)],
            defaultInput: "mic-usb"
        )
        h.settings.appSettings.lockInputDevice = true
        h.settings.setLockedInputDeviceUID("mic-usb")
        h.settings.setInputDevicePriorityOrder(["mic-usb", "mic-xlr", "mic-builtin"])

        h.engine.handleInputDeviceDisconnected("mic-usb")

        // mic-xlr is next in priority and still connected.
        #expect(h.settings.lockedInputDeviceUID == "mic-xlr")
    }

    @Test("losing a device that isn't locked leaves the lock alone")
    func disconnectOfOtherDeviceKeepsLock() {
        let h = makeHarness(
            inputs: [("mic-usb", 10), ("mic-xlr", 12)],
            defaultInput: "mic-usb"
        )
        h.settings.appSettings.lockInputDevice = true
        h.settings.setLockedInputDeviceUID("mic-usb")
        h.settings.setInputDevicePriorityOrder(["mic-usb", "mic-xlr"])

        h.engine.handleInputDeviceDisconnected("mic-xlr")

        #expect(h.settings.lockedInputDeviceUID == "mic-usb")
    }

    @Test("the preferred device survives a disconnect that moves the lock")
    func preferenceSurvivesFallback() {
        let h = makeHarness(
            inputs: [("mic-usb", 10), ("mic-xlr", 12)],
            defaultInput: "mic-usb"
        )
        h.settings.appSettings.lockInputDevice = true
        h.settings.setPreferredInputDeviceUID("mic-usb")
        h.settings.setLockedInputDeviceUID("mic-usb")
        h.settings.setInputDevicePriorityOrder(["mic-usb", "mic-xlr"])

        h.engine.handleInputDeviceDisconnected("mic-usb")

        #expect(h.settings.lockedInputDeviceUID == "mic-xlr", "lock follows the fallback")
        #expect(h.settings.preferredInputDeviceUID == "mic-usb", "preference must not be overwritten")
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let engine: AudioEngine
        let settings: SettingsManager
        let deviceMonitor: MockAudioDeviceMonitor
        let volume: CountingDeviceVolumeProviding

        func device(_ uid: String) -> AudioDevice {
            deviceMonitor.inputDevice(for: uid)!
        }
    }

    private func makeHarness(
        inputs: [(String, AudioDeviceID)],
        defaultInput: String?
    ) -> Harness {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        let deviceMonitor = MockAudioDeviceMonitor()
        for (uid, id) in inputs {
            deviceMonitor.addInputDevice(
                AudioDevice(id: id, uid: uid, name: uid, icon: nil, supportsAutoEQ: false)
            )
        }
        let volume = CountingDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volume.defaultInputDeviceUID = defaultInput

        let permission = AudioRecordingPermission()
        permission.setStatusForTesting(.authorized)

        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            deviceProvider: deviceMonitor,
            processMonitor: InputLockProcessMonitor(),
            deviceVolumeMonitor: volume,
            tapFactory: { _, _, _ in throw CancellationError() },
            isAlive: { _ in true },
            startMonitorsAutomatically: false
        )
        return Harness(engine: engine, settings: settings, deviceMonitor: deviceMonitor, volume: volume)
    }
}

/// Counts input-default writes so tests can assert "nothing was written" —
/// the difference between a correct no-op and a redundant HAL round-trip that
/// spawns an echo the state machine must then absorb.
@MainActor
final class CountingDeviceVolumeProviding: DeviceVolumeProviding {
    var defaultDeviceID: AudioDeviceID = 0
    var defaultDeviceUID: String?
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    private(set) var setDefaultInputCallCount = 0

    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?

    let deviceMonitor: MockAudioDeviceMonitor

    init(deviceMonitor: MockAudioDeviceMonitor) {
        self.deviceMonitor = deviceMonitor
    }

    func setVolume(for deviceID: AudioDeviceID, to volume: Float) { volumes[deviceID] = volume }
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) { muteStates[deviceID] = muted }

    @discardableResult
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceMonitor.device(for: deviceID)?.uid else { return false }
        defaultDeviceID = deviceID
        defaultDeviceUID = uid
        return true
    }

    @discardableResult
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let uid = deviceMonitor.device(for: deviceID)?.uid else { return false }
        setDefaultInputCallCount += 1
        defaultInputDeviceUID = uid
        return true
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
    func applyTierOverrideChange(for deviceID: AudioDeviceID) {}
    func start() {}
    func stop() {}
}
