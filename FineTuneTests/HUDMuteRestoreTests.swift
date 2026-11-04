import AppKit
import AudioToolbox
import SwiftUI
import Testing
@testable import FineTune

/// Models the software backend's real contract: mute publishes zero; unmute
/// restores the saved scalar synchronously. Hardware/DDC retain their scalar.
@MainActor private final class MuteRestoringVolume: DeviceVolumeProviding {
    var defaultDeviceID: AudioDeviceID = 1
    var defaultDeviceUID: String? = "QA-Mute"
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [1: 0.25]
    var muteStates: [AudioDeviceID: Bool] = [1: false]
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    let tier: VolumeControlTier
    init(_ tier: VolumeControlTier) { self.tier = tier }
    func setDefaultDevice(_ id: AudioDeviceID) -> Bool { false }
    func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool { false }
    func setVolume(for id: AudioDeviceID, to volume: Float) { volumes[id] = volume }
    func setMute(for id: AudioDeviceID, to muted: Bool) {
        muteStates[id] = muted
        if tier == .software { volumes[id] = muted ? 0 : 0.25 }
    }
    func outputVolumeBackend(for id: AudioDeviceID) -> VolumeControlTier { tier }
    func start() {}
    func stop() {}
}

@Suite("Media key mute restores the rendered HUD", .serialized)
@MainActor struct HUDMuteRestoreTests {
    @Test("unmute displays the restored backend level rather than its captured muted zero",
          arguments: [VolumeControlTier.software, .hardware, .ddc])
    func restoredTrack(tier: VolumeControlTier) throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let devices = MockAudioDeviceMonitor(), volume = MuteRestoringVolume(tier)
        let engine = AudioEngine(settingsManager: settings, deviceProvider: devices, deviceVolumeMonitor: volume, startMonitorsAutomatically: false)
        let popup = PopupVisibilityService(), status = MediaKeyStatus()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.fullscreenProvider = { false }; hud.observesOutsideClicks = false
        hud.frameProvider = { NSRect(x: -10000, y: -10000, width: 1440, height: 900) }
        defer { hud.shutdown() }
        let monitor = MediaKeyMonitor(decoder: StubMediaKeyDecoder(), audioEngine: engine, settingsManager: settings,
                                      accessibility: MockAccessibilityTrustProviding(), hudController: hud, popupVisibility: popup, mediaKeyStatus: status)
        func trackInk() throws -> Int {
            let view = try #require(hud.panel?.contentView as? NSHostingView<AnyView>)
            let renderer = ImageRenderer(content: view.rootView.frame(width: 388, height: 145))
            renderer.scale = 2
            let image = try #require(renderer.cgImage), bitmap = NSBitmapImageRep(cgImage: image)
            var ink = 0
            for y in 115..<170 { for x in 200..<660 {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.alphaComponent > 0.85, min(c.redComponent, c.greenComponent, c.blueComponent) > 0.85 { ink += 1 }
            }}
            return ink
        }
        hud.show(sliderFraction: VolumeMapping.sliderFraction(forSystemGain: 0.25, tier: tier), mute: false, deviceName: "")
        let before = try trackInk()
        #expect(before > 100)
        monitor.handle(.muteToggle)
        #expect(try trackInk() == 0)
        monitor.handle(.muteToggle)
        #expect(volume.volumes[1] == 0.25 && volume.muteStates[1] == false)
        #expect(try trackInk() == before)
    }
}
