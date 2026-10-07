import XCTest

@testable import BinauralCore

/// Parity with `tests/test_frequencies.py`.
///
/// Every count here comes from `src/binaural/data/frequencies.json` — the single source
/// of truth — and is cross-checked against the Python implementation. If the reference is
/// edited, these tests must be edited with it.
final class FrequencyCatalogueTests: XCTestCase {

    private static let expectedCategoryIDs = [
        "brainwave", "schumann", "planetary", "solfeggio",
        "tuning", "research", "rife", "nasa", "healing",
        "substance", "affect",
    ]

    private var catalogue: FrequencyCatalogue!

    override func setUpWithError() throws {
        catalogue = try ReferenceFile.catalogue()
    }

    override func tearDown() {
        catalogue = nil
    }

    // MARK: - File structure (SPEC §6.2)

    func testJSONParses() throws {
        XCTAssertEqual(catalogue.version, 1)
        XCTAssertEqual(catalogue.categories.count, 11)
        XCTAssertEqual(catalogue.entries.count, 110)
    }

    func testAllElevenCategoriesArePresentAndInOrder() {
        XCTAssertEqual(catalogue.categories.map(\.id), Self.expectedCategoryIDs)
        XCTAssertEqual(catalogue.categories.map(\.order), Array(1...11))
        for category in catalogue.categories {
            XCTAssertFalse(catalogue.entries(inCategory: category.id).isEmpty,
                           "\(category.id) is empty")
        }
    }

    func testCategoriesCarryTheirRegistryAppearance() {
        // icon/color come only from the registry (SPEC §6.1), never from the records.
        for category in catalogue.categories {
            XCTAssertFalse(category.icon.isEmpty, category.id)
            XCTAssertTrue(category.color.hasPrefix("#"), category.id)
            XCTAssertEqual(category.color.count, 7, category.id)
            XCTAssertFalse(category.labelEn.isEmpty, category.id)
            XCTAssertFalse(category.labelRu.isEmpty, category.id)
            XCTAssertFalse(category.descriptionEn.isEmpty, category.id)
            XCTAssertFalse(category.descriptionRu.isEmpty, category.id)
        }
    }

    // MARK: - Evidence levels (the headline count of this milestone)

    func testEvidenceTotalsMatchPython() {
        let totals = catalogue.totalsByEvidence()
        // Read out of src/binaural/data/frequencies.json with the Python loader.
        XCTAssertEqual(totals[.traditional], 68)
        XCTAssertEqual(totals[.wellStudied], 12)
        XCTAssertEqual(totals[.reported], 14)
        XCTAssertEqual(totals[.studied], 16)
        XCTAssertEqual(totals.values.reduce(0, +), 110)
    }

    func testOnlyTheFourDefinedLevelsCarryBadges() {
        XCTAssertEqual(
            EvidenceLevel.defined.map(\.rawValue),
            ["well-studied", "studied", "reported", "traditional"]
        )
        XCTAssertEqual(EvidenceLevel.wellStudied.badge, "\u{1F7E2}")
        XCTAssertEqual(EvidenceLevel.studied.badge, "\u{1F535}")
        XCTAssertEqual(EvidenceLevel.reported.badge, "\u{1F7E1}")
        XCTAssertEqual(EvidenceLevel.traditional.badge, "\u{1F7E3}")
        // An unknown level is badged, never hidden — Python returns ⚪ too.
        XCTAssertEqual(EvidenceLevel(lenient: "nonsense").badge, "\u{26AA}")
        XCTAssertEqual(EvidenceLevel(lenient: ""), .unknown)
    }

    // MARK: - Per-record validity (Python asserts these in tests; here it is callable)

    func testValidateReportsNoIssues() {
        let issues = catalogue.validate()
        XCTAssertTrue(
            issues.isEmpty,
            "catalogue issues: \(issues.map(\.description).joined(separator: "; "))"
        )
    }

    func testIDsAreGloballyUnique() {
        let ids = catalogue.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryEntryBelongsToAKnownCategory() {
        let known = Set(catalogue.categories.map(\.id))
        for entry in catalogue.entries {
            XCTAssertTrue(known.contains(entry.category), "\(entry.id): \(entry.category)")
        }
    }

    func testEveryEntryCarriesBeatOrRangeAndAPositiveCarrier() {
        for entry in catalogue.entries {
            if entry.beatHz != nil {
                XCTAssertGreaterThan(entry.beatHz ?? 0, 0, entry.id)
                XCTAssertNil(entry.beatMin, entry.id)
                XCTAssertNil(entry.beatMax, entry.id)
            } else {
                XCTAssertGreaterThan(entry.beatMin ?? 0, 0, entry.id)
                XCTAssertGreaterThan(entry.beatMax ?? 0, entry.beatMin ?? 0, entry.id)
            }
            XCTAssertGreaterThan(entry.carrierHz, 0, entry.id)
        }
    }

    func testEffectsAreBilingualAndNonEmpty() {
        for entry in catalogue.entries {
            XCTAssertFalse(entry.effectEn.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            XCTAssertFalse(entry.effectRu.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            XCTAssertFalse(entry.label.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            XCTAssertFalse(entry.source.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
        }
    }

    func testWellStudiedEntriesComeFromScienceSources() {
        for entry in catalogue.entries where entry.evidence == .wellStudied {
            XCTAssertTrue(entry.source.contains("EEG literature"), "\(entry.id): \(entry.source)")
        }
    }

    func testTraditionalEntriesAreNotClaimedAsScience() {
        for entry in catalogue.entries where entry.evidence == .traditional {
            XCTAssertFalse(entry.source.contains("EEG literature"), "\(entry.id): \(entry.source)")
        }
    }

    // MARK: - Spec coverage (SPEC §6.3–6.11)

    func testBrainwaveBandsMatchTheSpec() throws {
        var bands: [Double: Double] = [:]
        for entry in catalogue.entries(inCategory: "brainwave") where entry.isRange {
            bands[entry.beatMin ?? 0] = entry.beatMax ?? 0
        }
        XCTAssertEqual(bands, [0.5: 4.0, 4.0: 8.0, 8.0: 13.0, 13.0: 30.0, 30.0: 100.0])

        let beats = Set(catalogue.entries(inCategory: "brainwave").compactMap(\.beatHz))
        for expected in [1.94, 4.0, 10.0, 12.0, 14.0, 20.0, 40.0] {
            XCTAssertTrue(beats.contains(expected), "brainwave \(expected)")
        }
    }

    func testTonalCategoriesAreTaggedTonal() {
        for id in ["planetary", "solfeggio", "tuning"] {
            let entries = catalogue.entries(inCategory: id)
            XCTAssertFalse(entries.isEmpty, id)
            for entry in entries {
                XCTAssertTrue(entry.isTonal, "\(entry.id) should be tagged 'tonal'")
            }
        }
    }

    func testCategoryCountsMatchPython() {
        let counts = catalogue.categoriesWithCounts()
        XCTAssertEqual(
            counts.map { "\($0.category.id):\($0.count)" },
            ["brainwave:12", "schumann:5", "planetary:10", "solfeggio:9",
             "tuning:5", "research:4", "rife:40", "nasa:7", "healing:7",
             "substance:4", "affect:7"]
        )
        XCTAssertEqual(counts.reduce(0) { $0 + $1.count }, catalogue.entries.count)
        XCTAssertTrue(counts.allSatisfy { $0.count > 0 })
    }

    // MARK: - Ordering (SPEC §6.12)

    func testEntriesAreSortedRangesFirstThenByBeat() {
        let brainwave = catalogue.entries(inCategory: "brainwave")
        XCTAssertEqual(brainwave.prefix(5).map(\.id),
                       ["brainwave-delta", "brainwave-theta", "brainwave-alpha",
                        "brainwave-beta", "brainwave-gamma"])
        for (previous, next) in zip(brainwave, brainwave.dropFirst()) {
            // Ranges first, then points; ascending inside each group (SPEC §6.12).
            XCTAssertLessThanOrEqual(previous.sortKey.group, next.sortKey.group)
            if previous.sortKey.group == next.sortKey.group {
                XCTAssertLessThanOrEqual(previous.sortKey.value, next.sortKey.value)
            }
        }
    }

    // MARK: - Lookup

    func testLookupByID() {
        XCTAssertEqual(catalogue.entry(id: "brainwave-10")?.beatHz, 10.0)
        XCTAssertEqual(catalogue.entry(id: "schumann-7-83")?.beatHz, 7.83)
        XCTAssertEqual(catalogue.entry(id: "brainwave-delta")?.beatMin, 0.5)
        XCTAssertEqual(catalogue.entry(id: "brainwave-delta")?.beatMax, 4.0)
        XCTAssertNil(catalogue.entry(id: "no-such-record"))
    }

    func testLookupByCategory() {
        XCTAssertEqual(catalogue.entries(inCategory: "solfeggio").count, 9)
        XCTAssertTrue(catalogue.entries(inCategory: "solfeggio").allSatisfy { $0.category == "solfeggio" })
        XCTAssertTrue(catalogue.entries(inCategory: "nope").isEmpty)
    }

    func testFrequencyTextFormatting() {
        XCTAssertEqual(catalogue.entry(id: "brainwave-delta")?.frequencyText, "0.5\u{2013}4 Hz")
        XCTAssertEqual(catalogue.entry(id: "brainwave-10")?.frequencyText, "10 Hz")
        XCTAssertEqual(catalogue.entry(id: "schumann-7-83")?.frequencyText, "7.83 Hz")
        XCTAssertEqual(catalogue.entry(id: "brainwave-10")?.badge, "\u{1F7E2}")
    }

    // MARK: - Search

    func testSearchByText() {
        for needle in ["alpha", "Schumann", "Om"] {
            XCTAssertFalse(catalogue.search(needle).isEmpty, "nothing found for \(needle)")
        }
        XCTAssertTrue(
            catalogue.search("gamma").contains { $0.label.lowercased().contains("gamma") }
        )
        XCTAssertFalse(catalogue.search("DNA", category: "solfeggio").isEmpty)
        XCTAssertFalse(catalogue.search("заземление").isEmpty)
    }

    func testSearchByNumber() {
        XCTAssertTrue(Set(catalogue.search("7.83").map(\.id)).isSuperset(of: ["schumann-7-83", "nasa-7-83"]))
        XCTAssertTrue(Set(catalogue.search("10").map(\.id)).isSuperset(of: ["brainwave-10", "research-10"]))
        // A band boundary is findable too.
        XCTAssertTrue(catalogue.search("0.5").contains { $0.id == "brainwave-delta" })
    }

    func testSearchByCategoryAndEmptyQuery() {
        XCTAssertEqual(catalogue.search("").count, 110)
        XCTAssertEqual(catalogue.search("", category: "solfeggio").count, 9)
        XCTAssertTrue(catalogue.search("", category: "solfeggio").allSatisfy { $0.category == "solfeggio" })
        XCTAssertTrue(catalogue.search("432", category: "brainwave").isEmpty)
    }

    func testSearchIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(catalogue.search("  ALPHA  ").count, catalogue.search("alpha").count)
    }

    // MARK: - Failure modes

    func testMissingFileIsReportedNotGuessed() {
        let missing = ReferenceFile.url
            .deletingLastPathComponent()
            .appendingPathComponent("does-not-exist.json")
        XCTAssertThrowsError(try FrequencyCatalogue(contentsOf: missing)) { error in
            guard case CatalogueError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testMalformedJSONIsReported() throws {
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-broken-\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }

        XCTAssertThrowsError(try FrequencyCatalogue(contentsOf: broken)) { error in
            guard case CatalogueError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }
}