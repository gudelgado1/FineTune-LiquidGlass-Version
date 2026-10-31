import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("HUD motion geometry from the native reference", .serialized)
@MainActor
struct HUDMotionTests {
    private func opaqueInkBounds(_ image: CGImage) throws -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.alphaComponent > 0.85, min(c.redComponent, c.greenComponent, c.blueComponent) > 0.85 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        #expect(maxX >= minX && maxY >= minY)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func render(progress: Double, reduced: Bool = false) throws -> CGImage {
        let state = HUDMotionState()
        state.progress = progress
        let root = HUDMotionRoot(content: AnyView(CapsuleVolumeHUD(sliderFraction: 7.0 / 16, mute: false, deviceName: "Test").padding(40)), state: state, reduceMotion: reduced)
        let renderer = ImageRenderer(content: root.frame(width: 388, height: 145))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    @Test("entry scales about the menu-row origin without changing the envelope")
    func scaleOriginMatchesReference() throws {
        let restingImage = try render(progress: 1)
        let initialImage = try render(progress: 0)
        #expect(initialImage.width == restingImage.width && initialImage.height == restingImage.height)
        let full = try opaqueInkBounds(restingImage), initial = try opaqueInkBounds(initialImage)
        // Reference: approximately0.9 scale, anchored at x=center, y=menu bottom.
        let origin = CGPoint(x: 388, y: 60)
        #expect(abs(initial.minX - (origin.x + 0.9 * (full.minX - origin.x))) <= 3)
        #expect(abs(initial.minY - (origin.y + 0.9 * (full.minY - origin.y))) <= 3)
        #expect(initial.width < full.width && initial.height < full.height)
    }

    @Test("Reduce Motion removes the zoom while preserving the readable content")
    func reducedMotionHasNoScale() throws {
        let full = try opaqueInkBounds(render(progress: 1))
        let reduced = try opaqueInkBounds(render(progress: 0, reduced: true))
        #expect(reduced == full)
    }

    @Test("interpolated bar data paints a partial segment between keyboard levels")
    func canvasPaintsIntermediateLevel() throws {
        func painted(_ value: Double) throws -> Int {
            var track = HUDVolumeTrack(level: 0.375, ink: .white)
            track.animatableData = value
            let renderer = ImageRenderer(content: track.frame(width: 214, height: 4))
            renderer.scale = 2
            let image = try #require(renderer.cgImage), bitmap = NSBitmapImageRep(cgImage: image)
            return (0..<image.width).reduce(0) { count, x in
                guard let c = bitmap.colorAt(x: x, y: image.height / 2) else { return count }
                return count + (c.alphaComponent > 0.85 ? 1 : 0)
            }
        }
        #expect(try painted(0.375) < painted(0.40625))
        #expect(try painted(0.40625) < painted(0.4375))
    }
}
