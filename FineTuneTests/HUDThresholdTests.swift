// FineTuneTests/HUDThresholdTests.swift
// Verifies wave-icon glyph selection mirrors what the user sees on the bar/label
// (displayed integer percent), not internal float thresholds.

import Testing
import SwiftUI
@testable import FineTune

@Suite("HUD wave-icon thresholds use displayed-percent semantics")
struct HUDThresholdTests {
    // NOTE: the Tahoe HUD no longer uses a level-dependent wave glyph — it now
    // mirrors the macOS volume HUD, flanking a segmented track with fixed min
    // (speaker.fill) and max (speaker.wave.3.fill) icons. Only the Classic HUD
    // still maps level → wave bucket, so only those cases remain here.

    @Test("Classic icon: 0% → speaker.fill")
    func classicZeroPercent() {
        let hud = ClassicStyleHUD(sliderFraction: 0, mute: false)
        #expect(hud.waveIconNameForTest == "speaker.fill")
    }

    @Test("Classic icon: 33% → wave.1")
    func classicLow() {
        let hud = ClassicStyleHUD(sliderFraction: 0.33, mute: false)
        #expect(hud.waveIconNameForTest == "speaker.wave.1.fill")
    }
}
