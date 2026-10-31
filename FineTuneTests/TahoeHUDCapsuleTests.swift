import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Capsule content in light and dark appearances", .serialized)
@MainActor
struct TahoeHUDCapsuleTests {
    @Test("non-finite volume cannot enter geometry or accessibility conversions")
    func invalidVolumeIsSilent() {
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(CapsuleVolumeHUD.normalizedFraction(value) == 0)
        }
        #expect(CapsuleVolumeHUD.normalizedFraction(-0.2) == 0)
        #expect(CapsuleVolumeHUD.normalizedFraction(1.2) == 1)
        #expect(CapsuleVolumeHUD.normalizedFraction(0.4375) == 0.4375)
    }

    @Test("offscreen snapshots preserve capsule geometry and audible track levels")
    func renderReferenceLevels() throws {
        _ = NSApplication.shared
        let directory = (AppDataLocations.unitTestRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("HUD-fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, Float, Bool)] = [
            ("zero", 0, false), ("seven-of-sixteen", 7.0 / 16.0, false),
            ("full", 1, false), ("muted", 7.0 / 16.0, true),
        ]
        for scheme in [ColorScheme.dark, .light] {
        var activeTrackPixels: [String: Int] = [:]
        for (name, value, mute) in cases {
            let renderer = ImageRenderer(content: CapsuleVolumeHUD(
                sliderFraction: value, mute: mute, deviceName: "Test output").environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 616)
            #expect(image.height == 130)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent((scheme == .light ? "light-" : "") + name + ".png"))

            // Count bright pixels only in the track, excluding the speaker and
            // material rim. This catches an empty/frozen track and mute regressions.
            var bright = 0
            for y in 60..<68 {
                for x in 124..<552 {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.alphaComponent > 0.85 {
                        let channelMean = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if channelMean > 0.85 { bright += 1 }
                    }
                }
            }
            activeTrackPixels[name] = bright
        }
        #expect(activeTrackPixels["zero"] == 0)
        #expect(activeTrackPixels["muted"] == 0)
        #expect(try #require(activeTrackPixels["seven-of-sixteen"]) > 0)
        #expect(try #require(activeTrackPixels["full"]) > #require(activeTrackPixels["seven-of-sixteen"]))
        }
    }
}
