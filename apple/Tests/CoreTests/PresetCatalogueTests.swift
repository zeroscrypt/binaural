import XCTest

@testable import BinauralCore

/// The preset registry of SPEC §5 F3, checked against the rules F3 states.
///
/// These are the assertions the registry has to satisfy for F3 to be true at all: seven
/// categories, twenty presets, every one inside 1–30 Hz and inside **exactly one**
/// half-open band, no Gamma, labels `<band> <beat>`, and `relaxation` as the default.
/// A registry edited away from F3 fails here rather than in the window.
final class PresetCatalogueTests: XCTestCase {

    // MARK: - Shape

    func testSevenCategoriesInF3Order() {
        XCTAssertEqual(
            PresetCatalogue.categories.map(\.id),
            ["sleep", "meditation", "relaxation", "awareness",
             "concentration", "work", "sport"]
        )
    }

    func testTwentyPresetsInTotal() {
        XCTAssertEqual(PresetCatalogue.categories.count, 7)
        XCTAssertEqual(PresetCatalogue.presets.count, 20)
    }

    /// F3's own table, transcribed. If the registry and this table ever disagree, the
    /// registry is wrong — F3 is the contract, and Python reads the same list.
    func testRegistryMatchesTheF3Table() {
        let expected: [String: [Double]] = [
            "sleep": [1, 2, 3],
            "meditation": [4, 5, 6],
            "relaxation": [8, 9, 10],
            "awareness": [11, 12],
            "concentration": [13, 14, 15],
            "work": [16, 18, 20],
            "sport": [22, 25, 28],
        ]
        for category in PresetCatalogue.categories {
            XCTAssertEqual(category.presets.map(\.beatHz), expected[category.id], category.id)
        }
    }

    /// The chip order is the table order, and beats ascend inside a category.
    func testPresetsAscendInsideEachCategory() {
        for category in PresetCatalogue.categories {
            XCTAssertEqual(
                category.presets.map(\.beatHz), category.presets.map(\.beatHz).sorted(),
                category.id
            )
        }
    }

    func testCategoryNamesAreCarriedInBothLanguages() {
        XCTAssertEqual(PresetCatalogue.categories.map(\.nameEn),
                       ["Sleep", "Meditation", "Relaxation", "Awareness",
                        "Concentration", "Work", "Sport"])
        XCTAssertEqual(PresetCatalogue.categories.map(\.nameRu),
                       ["Сон", "Медитация", "Расслабление", "Ясность",
                        "Концентрация", "Работа", "Спорт"])
    }

    // MARK: - The rules

    /// F3: "все пресеты внутри 1–30 Гц".
    func testEveryPresetIsInsideThePerceptibleRange() {
        for preset in PresetCatalogue.presets {
            XCTAssertGreaterThanOrEqual(preset.beatHz, PresetCatalogue.minPresetHz, preset.id)
            XCTAssertLessThanOrEqual(preset.beatHz, PresetCatalogue.maxPresetHz, preset.id)
        }
    }

    /// F3: "каждый пресет попадает ровно в один диапазон §6.1". Half-open bounds make
    /// this total — a value can never match two bands — and the count here is the proof.
    func testEveryPresetFallsInExactlyOneBand() {
        for preset in PresetCatalogue.presets {
            let matches = BrainwaveBand.allCases.filter { $0.contains(preset.beatHz) }
            XCTAssertEqual(matches.count, 1, "\(preset.id) matched \(matches)")
        }
    }

    /// F3: "Gamma в пресеты не входит". The 30 Hz cap is the reason; Gamma staying in the
    /// reference is a separate rule F3 states explicitly.
    func testNoPresetIsInTheGammaBand() {
        for preset in PresetCatalogue.presets {
            XCTAssertNotEqual(preset.band, .gamma, "\(preset.id) is a Gamma preset")
        }
    }

    /// The half-open reading is what F3 asks for, verified at the four shared endpoints
    /// and just below each of them.
    func testBandBoundariesAreHalfOpen() {
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 0.5), .delta)
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 3.99), .delta)
        XCTAssertNil(BrainwaveBand.band(forBeatHz: 0.49))
        // 4 belongs to Theta, not Delta; 8 to Alpha; 13 to Beta.
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 4), .theta)
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 8), .alpha)
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 13), .beta)
        // …and nothing below 30 is Gamma.
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 29.99), .beta)
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 30), .gamma)
        XCTAssertEqual(BrainwaveBand.band(forBeatHz: 100), .gamma)
        XCTAssertNil(BrainwaveBand.band(forBeatHz: 100.1))
        XCTAssertNil(BrainwaveBand.band(forBeatHz: .nan))
    }

    /// The bands are read out of `frequencies.json`; these are the labels there.
    func testBandRangeLabelsMatchTheReference() {
        XCTAssertEqual(
            BrainwaveBand.allCases.map(\.jsonRangeLabel),
            ["Delta 0.5–4 Hz", "Theta 4–8 Hz", "Alpha 8–13 Hz",
             "Beta 13–30 Hz", "Gamma 30–100 Hz"]
        )
    }

    // MARK: - Labels

    /// F3: the caption is `<band> <beat>`, localised, with the four names it lists.
    func testPresetLabelsAreBandThenBeatInBothLanguages() {
        let expected: [String: (String, String, String)] = [
            // id → (EN band, RU band, beat text)
            "sleep-1": ("Delta", "Дельта", "1"),
            "meditation-6": ("Theta", "Тета", "6"),
            "relaxation-10": ("Alpha", "Альфа", "10"),
            "awareness-12": ("Alpha", "Альфа", "12"),
            "concentration-13": ("Beta", "Бета", "13"),
            "sport-28": ("Beta", "Бета", "28"),
        ]
        for (id, triple) in expected {
            let preset = PresetCatalogue.presets.first { $0.id == id }
            XCTAssertNotNil(preset, id)
            XCTAssertEqual(preset?.title(for: .en), "\(triple.0) \(triple.2)", id)
            XCTAssertEqual(preset?.title(for: .ru), "\(triple.1) \(triple.2)", id)
        }
    }

    func testEveryPresetLabelIsBandThenBeat() throws {
        for preset in PresetCatalogue.presets {
            let band = try XCTUnwrap(preset.band, preset.id)
            XCTAssertEqual(preset.title(for: .en), "\(band.nameEn) \(preset.beatText)", preset.id)
            XCTAssertEqual(preset.title(for: .ru), "\(band.nameRu) \(preset.beatText)", preset.id)
        }
    }

    /// A whole number shows without a pointless `.0` — the `_format_hz` rule.
    func testBeatTextHasNoPointlessZero() {
        for preset in PresetCatalogue.presets {
            XCTAssertFalse(preset.beatText.contains("."), preset.id)
        }
    }

    // MARK: - Default category and unknown ids

    /// F3: the default category is `relaxation`, the same value `Session.presetCategory`
    /// carries — one default, not two that can drift.
    func testDefaultCategoryIsRelaxationAndMatchesTheSession() {
        XCTAssertEqual(PresetCatalogue.defaultCategoryID, "relaxation")
        XCTAssertEqual(PresetCatalogue.defaultCategoryID, Session.defaultPresetCategory)
        XCTAssertEqual(Session().presetCategory, PresetCatalogue.defaultCategoryID)
    }

    /// CONTRACT §7 allows `preset_category` to be any string on the way in, so an unknown
    /// or missing value must fall back to the default for the chips, not fail.
    func testUnknownCategoryFallsBackToTheDefault() {
        XCTAssertEqual(PresetCatalogue.resolvedCategoryID(nil), PresetCatalogue.defaultCategoryID)
        XCTAssertEqual(PresetCatalogue.resolvedCategoryID(""), PresetCatalogue.defaultCategoryID)
        XCTAssertEqual(PresetCatalogue.resolvedCategoryID("focus"), PresetCatalogue.defaultCategoryID)
        XCTAssertEqual(PresetCatalogue.resolvedCategoryID("work"), "work")
    }

    func testUnknownCategoryYieldsNoPresets() {
        XCTAssertTrue(PresetCatalogue.presets(inCategory: "focus").isEmpty)
        XCTAssertNil(PresetCatalogue.category(id: "focus"))
        XCTAssertNil(PresetCatalogue.index(ofCategory: "focus"))
        XCTAssertEqual(PresetCatalogue.index(ofCategory: "work"), 5)
    }

    func testPresetsInACategoryAgreeWithTheCategoryList() {
        for category in PresetCatalogue.categories {
            XCTAssertEqual(PresetCatalogue.presets(inCategory: category.id), category.presets)
            for preset in category.presets {
                XCTAssertEqual(preset.categoryID, category.id)
            }
        }
    }

    // MARK: - Applying a preset

    /// F3: one click sets **both** channels so the difference is the preset's beat.
    func testApplyingAPresetSetsBothChannelsToTheChosenDifference() throws {
        for preset in PresetCatalogue.presets {
            let pair = try PresetCatalogue.frequencies(for: preset)
            XCTAssertEqual(BeatMath.beatFrequency(leftHz: pair.left, rightHz: pair.right),
                           preset.beatHz, preset.id)
            XCTAssertEqual(BeatMath.carrierFrequency(leftHz: pair.left, rightHz: pair.right),
                           BeatMath.defaultCarrierHz, accuracy: 1e-9, preset.id)
        }
    }

    /// F3's example, `fL = 205, fR = 215 → 10 Hz`. Note the carrier those two numbers
    /// imply is 210 Hz, **not** the 200 Hz of CONTRACT §1 — the example illustrates the
    /// rule (one click, difference = beat), not the default carrier. Both readings are
    /// checked so neither is mistaken for the other.
    func testTheSpecExampleHolds() throws {
        let atSpecExampleCarrier = try PresetCatalogue.frequencies(
            for: Preset(categoryID: "relaxation", beatHz: 10),
            carrierHz: 210
        )
        XCTAssertEqual(atSpecExampleCarrier.left, 205)
        XCTAssertEqual(atSpecExampleCarrier.right, 215)

        // The default the app actually applies (CONTRACT §1, `DEFAULT_CARRIER_HZ = 200`).
        let atDefaultCarrier = try PresetCatalogue.frequencies(
            for: Preset(categoryID: "relaxation", beatHz: 10)
        )
        XCTAssertEqual(atDefaultCarrier.left, 195)
        XCTAssertEqual(atDefaultCarrier.right, 205)
    }

    /// Around the default carrier no registry preset can leave the audible range, so
    /// `frequencies(for:)` never throws for a registry entry.
    func testNoRegistryPresetIsOutOfRangeAtTheDefaultCarrier() {
        for preset in PresetCatalogue.presets {
            XCTAssertNoThrow(try PresetCatalogue.frequencies(for: preset), preset.id)
        }
    }
}
