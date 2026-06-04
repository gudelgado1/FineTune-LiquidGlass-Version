// FineTuneTests/MenuBarPopupSizeTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("MenuBarPopupWidth / Density — Codable round-trip")
struct MenuBarPopupLayoutCodableTests {

    @Test("All width cases round-trip through JSON as their raw String value")
    func widthRoundTrip() throws {
        for width in MenuBarPopupWidth.allCases {
            let data = try JSONEncoder().encode(width)
            let decoded = try JSONDecoder().decode(MenuBarPopupWidth.self, from: data)
            #expect(decoded == width)
        }
    }

    @Test("All density cases round-trip through JSON as their raw String value")
    func densityRoundTrip() throws {
        for density in MenuBarPopupDensity.allCases {
            let data = try JSONEncoder().encode(density)
            let decoded = try JSONDecoder().decode(MenuBarPopupDensity.self, from: data)
            #expect(decoded == density)
        }
    }

    @Test("Width/density default to medium/comfortable when keys are missing")
    func defaultsWhenMissing() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.popupWidth == .medium)
        #expect(decoded.popupDensity == .comfortable)
        #expect(decoded.showSoundEffectsRow == true)
    }

    @Test("Width / density / showSoundEffectsRow round-trip through full JSON")
    func roundTripThroughAppSettings() throws {
        var settings = AppSettings()
        settings.popupWidth = .wide
        settings.popupDensity = .compact
        settings.showSoundEffectsRow = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.popupWidth == .wide)
        #expect(decoded.popupDensity == .compact)
        #expect(decoded.showSoundEffectsRow == false)
    }
}

@Suite("Legacy popupSize migration")
struct MenuBarPopupSizeMigrationTests {

    /// An older settings file only has `popupSize`; it should map onto the new
    /// independent width + density without the user losing their choice.
    @Test("Legacy popupSize maps to the matching width + density")
    func legacyMigration() throws {
        let cases: [(String, MenuBarPopupWidth, MenuBarPopupDensity)] = [
            ("compact", .narrow, .compact),
            ("comfortable", .medium, .comfortable),
            ("spacious", .wide, .spacious),
        ]
        for (raw, expectedWidth, expectedDensity) in cases {
            let json = "{\"popupSize\":\"\(raw)\"}"
            let decoded = try JSONDecoder().decode(AppSettings.self, from: json.data(using: .utf8)!)
            #expect(decoded.popupWidth == expectedWidth)
            #expect(decoded.popupDensity == expectedDensity)
        }
    }

    /// When both legacy and new keys exist, the new keys win (the user has
    /// re-chosen since upgrading).
    @Test("Explicit new keys override the legacy popupSize")
    func newKeysOverrideLegacy() throws {
        let json = "{\"popupSize\":\"spacious\",\"popupWidth\":\"narrow\",\"popupDensity\":\"compact\"}"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json.data(using: .utf8)!)
        #expect(decoded.popupWidth == .narrow)
        #expect(decoded.popupDensity == .compact)
    }
}

@Suite("PopupDimensions resolution")
struct PopupDimensionsTests {

    @Test("Width presets resolve to strictly increasing point widths")
    func widthsMonotonic() {
        let widths = MenuBarPopupWidth.allCases.map(\.points)
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
        #expect(MenuBarPopupWidth.narrow.points == 470)
        #expect(MenuBarPopupWidth.medium.points == 510)
        #expect(MenuBarPopupWidth.wide.points == 560)
    }

    @Test("Density padding / spacing / max height increase with roominess")
    func densityMonotonic() {
        let paddings = MenuBarPopupDensity.allCases.map(\.contentPadding)
        let spacings = MenuBarPopupDensity.allCases.map(\.sectionSpacing)
        let heights = MenuBarPopupDensity.allCases.map(\.maxContentHeight)
        #expect(paddings == paddings.sorted())
        #expect(spacings == spacings.sorted())
        #expect(heights == heights.sorted())
    }

    @Test("AppSettings.popupDimensions composes width + density independently")
    func dimensionsCompose() {
        var settings = AppSettings()
        settings.popupWidth = .wide
        settings.popupDensity = .compact

        let d = settings.popupDimensions
        #expect(d.width == MenuBarPopupWidth.wide.points)            // 560
        #expect(d.contentPadding == MenuBarPopupDensity.compact.contentPadding)  // 12
        #expect(d.sectionSpacing == MenuBarPopupDensity.compact.sectionSpacing)
        #expect(d.maxContentHeight == MenuBarPopupDensity.compact.maxContentHeight)  // 560
    }
}
