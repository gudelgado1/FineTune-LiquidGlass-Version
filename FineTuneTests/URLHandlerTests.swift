import AppKit
import Foundation
import Testing
@testable import FineTune

// MARK: - Recording engine double

/// Records every mutation the handler performs so tests assert on effects, not
/// on log output. Distinguishes active-app calls from inactive-identifier calls
/// because routing to the wrong one is a real bug class here: an inactive app's
/// setting must persist by identifier, not be silently dropped.
@MainActor
private final class RecordingURLEngine: URLHandlerEngine {
    struct VolumeCall: Equatable { let identifier: String; let volume: Float }
    struct MuteCall: Equatable { let identifier: String; let muted: Bool }
    struct DeviceCall: Equatable { let identifier: String; let deviceUID: String? }

    var apps: [AudioApp] = []
    let settingsManager: SettingsManager

    private(set) var activeVolumeCalls: [VolumeCall] = []
    private(set) var inactiveVolumeCalls: [VolumeCall] = []
    private(set) var activeMuteCalls: [MuteCall] = []
    private(set) var inactiveMuteCalls: [MuteCall] = []
    private(set) var deviceCalls: [DeviceCall] = []

    /// Backing state so get/set round-trips (toggle paths depend on reads).
    var volumes: [String: Float] = [:]
    var mutes: [String: Bool] = [:]
    var inactiveMutes: [String: Bool] = [:]

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumes[app.persistenceIdentifier] = volume
        activeVolumeCalls.append(VolumeCall(identifier: app.persistenceIdentifier, volume: volume))
    }

    func getVolume(for app: AudioApp) -> Float {
        volumes[app.persistenceIdentifier] ?? 1.0
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        mutes[app.persistenceIdentifier] = muted
        activeMuteCalls.append(MuteCall(identifier: app.persistenceIdentifier, muted: muted))
    }

    func getMute(for app: AudioApp) -> Bool {
        mutes[app.persistenceIdentifier] ?? false
    }

    func setDevice(for app: AudioApp, deviceUID: String?) {
        deviceCalls.append(DeviceCall(identifier: app.persistenceIdentifier, deviceUID: deviceUID))
    }

    func setVolumeForInactive(identifier: String, to volume: Float) {
        inactiveVolumeCalls.append(VolumeCall(identifier: identifier, volume: volume))
    }

    func setMuteForInactive(identifier: String, to muted: Bool) {
        inactiveMutes[identifier] = muted
        inactiveMuteCalls.append(MuteCall(identifier: identifier, muted: muted))
    }

    func getMuteForInactive(identifier: String) -> Bool {
        inactiveMutes[identifier] ?? false
    }

    /// Every mutating call the handler made, for "nothing happened" assertions.
    var totalMutations: Int {
        activeVolumeCalls.count + inactiveVolumeCalls.count
            + activeMuteCalls.count + inactiveMuteCalls.count + deviceCalls.count
    }
}

@Suite("URLHandler — finetune:// scheme", .serialized)
@MainActor
struct URLHandlerTests {

    // MARK: - Scheme and routing

    @Test("a foreign scheme is ignored entirely")
    func foreignSchemeIgnored() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "spotify://set-volumes?app=com.a&volume=50")!)
        #expect(engine.totalMutations == 0)
    }

    @Test("an unknown action changes nothing")
    func unknownActionIgnored() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://obliterate?app=com.a")!)
        #expect(engine.totalMutations == 0)
    }

    // MARK: - set-volumes

    @Test("set-volumes maps percent to gain linearly for an active app")
    func setVolumesActiveApp() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.a&volume=50")!)
        #expect(engine.activeVolumeCalls == [.init(identifier: "com.a", volume: 0.5)])
        #expect(engine.inactiveVolumeCalls.isEmpty)
    }

    @Test("set-volumes applies each app/volume pair in order")
    func setVolumesMultiplePairs() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b"])
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.a&volume=100&app=com.b&volume=0")!)
        #expect(engine.activeVolumeCalls == [
            .init(identifier: "com.a", volume: 1.0),
            .init(identifier: "com.b", volume: 0.0)
        ])
    }

    @Test("set-volumes persists by identifier when the app isn't running")
    func setVolumesInactiveApp() {
        let (handler, engine) = makeHandler(activeApps: [])
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.ghost&volume=25")!)
        #expect(engine.inactiveVolumeCalls == [.init(identifier: "com.ghost", volume: 0.25)])
        #expect(engine.activeVolumeCalls.isEmpty)
    }

    @Test("set-volumes rejects out-of-range and non-numeric volumes, keeping valid pairs")
    func setVolumesRejectsInvalidValues() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b", "com.c", "com.d"])
        // 101 and -1 are out of the documented 0-100 range; "loud" isn't a number.
        // The valid pair must still be applied — one bad parameter must not
        // discard the whole request.
        handler.handleURL(URL(string:
            "finetune://set-volumes?app=com.a&volume=101&app=com.b&volume=-1&app=com.c&volume=loud&app=com.d&volume=40")!)
        #expect(engine.activeVolumeCalls == [.init(identifier: "com.d", volume: 0.4)])
    }

    @Test("set-volumes ignores a volume with no preceding app")
    func setVolumesOrphanVolume() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-volumes?volume=50")!)
        #expect(engine.totalMutations == 0)
    }

    @Test("set-volumes ignores a trailing app with no volume")
    func setVolumesTrailingApp() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b"])
        handler.handleURL(URL(string: "finetune://set-volumes?app=com.a&volume=30&app=com.b")!)
        #expect(engine.activeVolumeCalls == [.init(identifier: "com.a", volume: 0.3)])
    }

    @Test("set-volumes accepts the parameter names case-insensitively")
    func setVolumesCaseInsensitiveParameters() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-volumes?APP=com.a&VOLUME=60")!)
        #expect(engine.activeVolumeCalls == [.init(identifier: "com.a", volume: 0.6)])
    }

    // MARK: - step-volume

    @Test("step-volume up moves one 5% slider step and writes the mapped gain")
    func stepVolumeUp() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        engine.volumes["com.a"] = VolumeMapping.sliderToGain(0.5)

        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=up")!)

        let expected = VolumeMapping.sliderToGain(0.55)
        #expect(engine.activeVolumeCalls.count == 1)
        #expect(abs((engine.activeVolumeCalls.first?.volume ?? 0) - expected) < 0.0001)
    }

    @Test("step-volume down clamps at silence instead of going negative")
    func stepVolumeDownClampsAtZero() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        engine.volumes["com.a"] = 0.0

        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=down")!)

        #expect(engine.activeVolumeCalls.count == 1)
        #expect((engine.activeVolumeCalls.first?.volume ?? -1) == 0.0)
    }

    @Test("step-volume up clamps at unity instead of exceeding it")
    func stepVolumeUpClampsAtOne() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        engine.volumes["com.a"] = 1.0

        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=up")!)

        let value = engine.activeVolumeCalls.first?.volume ?? -1
        #expect(value <= 1.0)
        #expect(abs(value - 1.0) < 0.0001)
    }

    @Test("step-volume accepts + and - as directions")
    func stepVolumeSymbolDirections() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        engine.volumes["com.a"] = VolumeMapping.sliderToGain(0.5)

        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=%2B")!)
        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=-")!)

        #expect(engine.activeVolumeCalls.count == 2)
    }

    @Test("step-volume does nothing without a direction, an app, or with a bad direction")
    func stepVolumeRequiresValidParameters() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://step-volume?app=com.a")!)
        handler.handleURL(URL(string: "finetune://step-volume?direction=up")!)
        handler.handleURL(URL(string: "finetune://step-volume?app=com.a&direction=sideways")!)
        #expect(engine.totalMutations == 0)
    }

    @Test("step-volume ignores an app that isn't running (no inactive fallback by design)")
    func stepVolumeIgnoresInactiveApp() {
        let (handler, engine) = makeHandler(activeApps: [])
        handler.handleURL(URL(string: "finetune://step-volume?app=com.ghost&direction=up")!)
        #expect(engine.totalMutations == 0)
    }

    // MARK: - set-mute

    @Test("set-mute accepts true/1/yes and false/0/no")
    func setMuteBooleanForms() {
        let truthy = ["true", "1", "yes", "TRUE", "Yes"]
        let falsy = ["false", "0", "no", "FALSE", "No"]

        for value in truthy {
            let (handler, engine) = makeHandler(activeApps: ["com.a"])
            handler.handleURL(URL(string: "finetune://set-mute?app=com.a&muted=\(value)")!)
            #expect(engine.activeMuteCalls == [.init(identifier: "com.a", muted: true)], "\(value) should mute")
        }
        for value in falsy {
            let (handler, engine) = makeHandler(activeApps: ["com.a"])
            handler.handleURL(URL(string: "finetune://set-mute?app=com.a&muted=\(value)")!)
            #expect(engine.activeMuteCalls == [.init(identifier: "com.a", muted: false)], "\(value) should unmute")
        }
    }

    @Test("set-mute rejects a value that isn't a recognised boolean")
    func setMuteRejectsGarbage() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-mute?app=com.a&muted=maybe")!)
        #expect(engine.totalMutations == 0)
    }

    @Test("set-mute persists by identifier when the app isn't running")
    func setMuteInactiveApp() {
        let (handler, engine) = makeHandler(activeApps: [])
        handler.handleURL(URL(string: "finetune://set-mute?app=com.ghost&muted=true")!)
        #expect(engine.inactiveMuteCalls == [.init(identifier: "com.ghost", muted: true)])
    }

    // MARK: - toggle-mute

    @Test("toggle-mute inverts current state for each listed app")
    func toggleMuteInvertsState() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b"])
        engine.mutes["com.a"] = true
        engine.mutes["com.b"] = false

        handler.handleURL(URL(string: "finetune://toggle-mute?app=com.a&app=com.b")!)

        #expect(engine.activeMuteCalls == [
            .init(identifier: "com.a", muted: false),
            .init(identifier: "com.b", muted: true)
        ])
    }

    @Test("toggle-mute inverts persisted state for an app that isn't running")
    func toggleMuteInactiveApp() {
        let (handler, engine) = makeHandler(activeApps: [])
        engine.inactiveMutes["com.ghost"] = true

        handler.handleURL(URL(string: "finetune://toggle-mute?app=com.ghost")!)

        #expect(engine.inactiveMuteCalls == [.init(identifier: "com.ghost", muted: false)])
    }

    @Test("toggle-mute with no app does nothing")
    func toggleMuteRequiresApp() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://toggle-mute")!)
        #expect(engine.totalMutations == 0)
    }

    // MARK: - set-device

    @Test("set-device routes an active app to the requested device UID")
    func setDeviceRoutesApp() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-device?app=com.a&device=AirPods-UID")!)
        #expect(engine.deviceCalls == [.init(identifier: "com.a", deviceUID: "AirPods-UID")])
    }

    @Test("set-device does nothing without both parameters or for an unknown app")
    func setDeviceRequiresBothParameters() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-device?app=com.a")!)
        handler.handleURL(URL(string: "finetune://set-device?device=X")!)
        handler.handleURL(URL(string: "finetune://set-device?app=com.ghost&device=X")!)
        #expect(engine.deviceCalls.isEmpty)
    }

    // MARK: - reset

    @Test("reset with no app resets every active app to unity and unmuted")
    func resetAllApps() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b"])
        handler.handleURL(URL(string: "finetune://reset")!)

        #expect(engine.activeVolumeCalls == [
            .init(identifier: "com.a", volume: 1.0),
            .init(identifier: "com.b", volume: 1.0)
        ])
        #expect(engine.activeMuteCalls == [
            .init(identifier: "com.a", muted: false),
            .init(identifier: "com.b", muted: false)
        ])
    }

    @Test("reset with named apps touches only those apps")
    func resetNamedApps() {
        let (handler, engine) = makeHandler(activeApps: ["com.a", "com.b"])
        handler.handleURL(URL(string: "finetune://reset?app=com.b")!)

        #expect(engine.activeVolumeCalls == [.init(identifier: "com.b", volume: 1.0)])
        #expect(engine.activeMuteCalls == [.init(identifier: "com.b", muted: false)])
    }

    @Test("reset persists defaults for an app that isn't running")
    func resetInactiveApp() {
        let (handler, engine) = makeHandler(activeApps: [])
        handler.handleURL(URL(string: "finetune://reset?app=com.ghost")!)

        #expect(engine.inactiveVolumeCalls == [.init(identifier: "com.ghost", volume: 1.0)])
        #expect(engine.inactiveMuteCalls == [.init(identifier: "com.ghost", muted: false)])
    }

    // MARK: - Hostile input

    @Test("percent-encoded and unusual identifiers survive parsing intact")
    func encodedIdentifiersRoundTrip() {
        let (handler, engine) = makeHandler(activeApps: [])
        // A name-based persistence identifier ("name:Some App") contains a
        // space and a colon; it must arrive byte-identical or the setting lands
        // on the wrong key and silently does nothing for the user.
        handler.handleURL(URL(string: "finetune://set-volumes?app=name%3ASome%20App&volume=10")!)
        #expect(engine.inactiveVolumeCalls == [.init(identifier: "name:Some App", volume: 0.1)])
    }

    @Test("an empty app value is not treated as a valid target")
    func emptyAppValueIgnored() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        handler.handleURL(URL(string: "finetune://set-volumes?app=&volume=50")!)
        // Empty string matches no app, so it may only ever persist as an
        // inactive identifier — it must never fall through onto a real app.
        #expect(engine.activeVolumeCalls.isEmpty)
    }

    @Test("a URL with no query items is harmless for every action")
    func bareActionsAreHarmless() {
        let (handler, engine) = makeHandler(activeApps: ["com.a"])
        for action in ["set-volumes", "step-volume", "set-mute", "toggle-mute", "set-device"] {
            handler.handleURL(URL(string: "finetune://\(action)")!)
        }
        #expect(engine.totalMutations == 0)
    }

    // MARK: - Helpers

    private func makeHandler(activeApps identifiers: [String]) -> (URLHandler, RecordingURLEngine) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let engine = RecordingURLEngine(settingsManager: SettingsManager(directory: tempDir))
        engine.apps = identifiers.enumerated().map { index, identifier in
            AudioApp(
                id: pid_t(9000 + index),
                processObjectIDs: [],
                name: identifier,
                icon: NSImage(),
                bundleID: identifier
            )
        }
        return (URLHandler(audioEngine: engine), engine)
    }
}
