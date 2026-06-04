// FineTuneTests/AutoEQParserTests.swift
import Testing
@testable import FineTune

struct AutoEQParserTests {

    // MARK: - Minimal Valid Input

    private let minimalText = """
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 1000 Hz Gain -2.3 dB Q 1.41
    """

    @Test("Valid ParametricEQ text returns a profile")
    func validInput_returnsProfile() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Test", source: .imported)
        #expect(profile != nil)
    }

    @Test("Parsed preamp is correct")
    func parsedPreamp() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Test", source: .imported)
        #expect(abs((profile?.preampDB ?? 0) - (-6.2)) < 0.001)
    }

    @Test("Parsed filters count is correct")
    func parsedFiltersCount() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Test", source: .imported)
        #expect(profile?.filters.count == 1)
    }

    @Test("Parsed filter frequency, gain, and Q are correct")
    func parsedFilterValues() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Test", source: .imported)
        let filter = profile?.filters.first
        #expect(filter?.type == .peaking)
        #expect(abs((filter?.frequency ?? 0) - 1000) < 0.1)
        #expect(abs((filter?.gainDB ?? 0) - (-2.3)) < 0.001)
        #expect(abs((filter?.q ?? 0) - 1.41) < 0.01)
    }

    // MARK: - Filter Types

    @Test("PK and PEQ map to peaking")
    func filterTypePeaking() {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1.0\nFilter 2: ON PEQ Fc 2000 Hz Gain 1 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 2)
        #expect(profile?.filters.allSatisfy { $0.type == .peaking } == true)
    }

    @Test("LS and LSC map to lowShelf")
    func filterTypeLowShelf() {
        let text = "Filter 1: ON LS Fc 80 Hz Gain 4 dB Q 0.71\nFilter 2: ON LSC Fc 100 Hz Gain 3 dB Q 0.71"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 2)
        #expect(profile?.filters.allSatisfy { $0.type == .lowShelf } == true)
    }

    @Test("HS and HSC map to highShelf")
    func filterTypeHighShelf() {
        let text = "Filter 1: ON HS Fc 10000 Hz Gain -2 dB Q 0.71\nFilter 2: ON HSC Fc 8000 Hz Gain -1 dB Q 0.71"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 2)
        #expect(profile?.filters.allSatisfy { $0.type == .highShelf } == true)
    }

    // MARK: - Disabled Filters

    @Test("Disabled (OFF) filters are skipped")
    func disabledFilters_skipped() {
        let text = "Filter 1: OFF PK Fc 1000 Hz Gain -2 dB Q 1.0\nFilter 2: ON PK Fc 2000 Hz Gain 1 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 1)
        #expect(abs((profile?.filters.first?.frequency ?? 0) - 2000) < 0.1)
    }

    // MARK: - Empty / Invalid Input

    @Test("Empty string returns nil")
    func emptyString_returnsNil() {
        let profile = AutoEQParser.parse(text: "", name: "Test", source: .imported)
        #expect(profile == nil)
    }

    @Test("Only comments return nil")
    func onlyComments_returnsNil() {
        let text = "# This is a comment\n# Another comment"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile == nil)
    }

    @Test("Only preamp line (no filters) returns nil")
    func onlyPreamp_returnsNil() {
        let text = "Preamp: -3 dB"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile == nil)
    }

    @Test("Filter with invalid frequency (zero) is rejected")
    func invalidFrequency_filterRejected() {
        let text = "Filter 1: ON PK Fc 0 Hz Gain -2 dB Q 1.0\nFilter 2: ON PK Fc 1000 Hz Gain 1 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 1)
        #expect(abs((profile?.filters.first?.frequency ?? 0) - 1000) < 0.1)
    }

    @Test("Filter with gain exceeding ±30 dB is rejected")
    func invalidGain_filterRejected() {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain -35 dB Q 1.0\nFilter 2: ON PK Fc 2000 Hz Gain 2 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 1)
        #expect(abs((profile?.filters.first?.frequency ?? 0) - 2000) < 0.1)
    }

    @Test("Filter with zero Q is rejected")
    func invalidQ_filterRejected() {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 0\nFilter 2: ON PK Fc 2000 Hz Gain 1 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 1)
    }

    // MARK: - Max Filters

    @Test("Filters beyond maxFilters limit are truncated")
    func maxFilters_truncated() {
        var lines = ["Preamp: 0 dB"]
        for i in 1...15 {
            lines.append("Filter \(i): ON PK Fc \(1000 * i) Hz Gain 1 dB Q 1.0")
        }
        let profile = AutoEQParser.parse(text: lines.joined(separator: "\n"), name: "Test", source: .imported)
        #expect(profile?.filters.count == AutoEQProfile.maxFilters)
    }

    // MARK: - ID Generation

    @Test("Imported source uses UUID as ID")
    func importedSource_usesUUID() {
        let profile = AutoEQParser.parse(text: minimalText, name: "My Profile", source: .imported)
        // UUID is 36 chars (with dashes)
        let id = profile?.id ?? ""
        #expect(id.count == 36, "UUID should be 36 chars, got '\(id)'")
    }

    @Test("Fetched source uses slugified name as ID")
    func fetchedSource_usesSlug() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Sennheiser HD 600", source: .fetched)
        #expect(profile?.id == "sennheiser-hd-600")
    }

    @Test("Bundled source uses slugified name as ID")
    func bundledSource_usesSlug() {
        let profile = AutoEQParser.parse(text: minimalText, name: "AKG K240 Studio", source: .bundled)
        #expect(profile?.id == "akg-k240-studio")
    }

    @Test("Explicit ID overrides auto-generated ID")
    func explicitID_overridesGenerated() {
        let profile = AutoEQParser.parse(text: minimalText, name: "Test", source: .imported, id: "my-explicit-id")
        #expect(profile?.id == "my-explicit-id")
    }

    // MARK: - Preamp Clamping

    @Test("Preamp beyond ±30 dB is clamped")
    func preampClamped() {
        let text = "Preamp: -40 dB\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.preampDB == -30, "Preamp below -30 should be clamped to -30")
    }

    // MARK: - Comment and Whitespace Handling

    @Test("Comment lines (#) are ignored")
    func commentLines_ignored() {
        let text = """
        # Generated by AutoEQ
        Preamp: -4.2 dB
        # This is a filter comment
        Filter 1: ON PK Fc 500 Hz Gain 2 dB Q 0.8
        """
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile != nil)
        #expect(profile?.filters.count == 1)
        #expect(abs((profile?.preampDB ?? 0) - (-4.2)) < 0.001)
    }

    @Test("Blank lines are ignored")
    func blankLines_ignored() {
        let text = "\n\nPreamp: -2 dB\n\nFilter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1.0\n\n"
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile != nil)
        #expect(profile?.filters.count == 1)
    }

    // MARK: - Multiple Filters

    @Test("Multiple valid filters are all parsed")
    func multipleFilters_allParsed() {
        let text = """
        Preamp: -6.0 dB
        Filter 1: ON PK Fc 200 Hz Gain -3.0 dB Q 1.2
        Filter 2: ON LSC Fc 80 Hz Gain 4.0 dB Q 0.71
        Filter 3: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.71
        """
        let profile = AutoEQParser.parse(text: text, name: "Test", source: .imported)
        #expect(profile?.filters.count == 3)
        #expect(profile?.filters[0].type == .peaking)
        #expect(profile?.filters[1].type == .lowShelf)
        #expect(profile?.filters[2].type == .highShelf)
    }
}
