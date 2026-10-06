import Foundation
import XCTest

@testable import BinauralCore

/// Parity with `tests/test_i18n.py`.
///
/// The Python suite checks the catalogue from three sides: `tr` resolves, every string
/// the app references has a Russian translation, and the catalogue has no orphans and
/// no lost placeholders. This file does the same for the Swift side, plus the one check
/// Python cannot make — that the *generated* catalogue still carries every key `ru.py`
/// has, which `PythonCatalogueSource` reads out of `ru.py` for.
@MainActor
final class L10nTests: XCTestCase {

    /// An isolated store, because `setLanguage` mutates process-wide state. Python
    /// solves it with a temporary `HOME`; a closure-backed store is the same idea.
    private final class MemoryStore: PreferenceStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]

        init(_ values: [String: String] = [:]) { self.values = values }

        func string(forKey key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func set(_ value: String?, forKey key: String) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
        }

        var snapshot: [String: String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private var store = MemoryStore()

    override func setUp() async throws {
        try await super.setUp()
        store = MemoryStore()
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: store)
    }

    override func tearDown() async throws {
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryStore())
        try await super.tearDown()
    }

    // MARK: - Core: tr()

    func testTrReturnsSourceInEnglish() {
        XCTAssertEqual(L10n.language, .en)
        XCTAssertEqual(L10n.tr("Play"), "Play")
        XCTAssertEqual(L10n.tr("&Help"), "&Help")
    }

    func testTrTranslatesKnownKeyInRussian() {
        L10n.setLanguage("ru")
        XCTAssertEqual(L10n.language, .ru)
        XCTAssertEqual(L10n.tr("Play"), RussianCatalogue.messages["Play"])
        XCTAssertNotEqual(L10n.tr("Play"), "Play")
    }

    func testTrFallsBackToEnglishForAMissingKey() {
        L10n.setLanguage("ru")
        let missing = "A string nobody ever put into the catalogue"
        XCTAssertEqual(L10n.tr(missing), missing)
    }

    func testMissingEnglishKeyReturnsTheKeyItself() {
        // English is the source language and has no table, so an unknown key is
        // visible rather than silently empty — the M2-a rule.
        XCTAssertEqual(L10n.tr("An unknown source string"), "An unknown source string")
    }

    func testTrSubstitutesPositionalPlaceholders() {
        L10n.setLanguage("ru")
        let out = L10n.tr("Active channel: %1", "ЛЕВОЕ УХО")
        XCTAssertFalse(out.contains("%1"))
        XCTAssertTrue(out.contains("ЛЕВОЕ УХО"))
    }

    func testTrKeepsPlaceholderTextAroundTheSubstitution() {
        L10n.setLanguage("ru")
        XCTAssertEqual(
            L10n.tr("Preset applied: difference %1 Hz", "10"),
            "Пресет применён: разность 10 Гц"
        )
    }

    // MARK: - Switching

    func testSetLanguageEmitsTheChange() {
        let seen = expectation(description: "languageDidChange")
        // Boxed so the `@Sendable` observer body does not capture a mutable local.
        let codes = Codes()
        let token = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange, object: nil, queue: .main
        ) { notification in
            codes.append((notification.object as? LanguageCode)?.rawValue ?? "")
            seen.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        L10n.setLanguage("ru")
        wait(for: [seen], timeout: 1)
        XCTAssertEqual(codes.values, ["ru"])
    }

    /// A lock-protected collector: the notification is delivered on the main queue, but
    /// the closure itself must be `Sendable`.
    private final class Codes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ code: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(code)
        }

        var values: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    func testSetLanguageIgnoresUnknownCodes() {
        L10n.setLanguage("ru")
        XCTAssertEqual(L10n.setLanguage("de"), .ru)
        XCTAssertEqual(L10n.language, .ru)
        XCTAssertEqual(L10n.setLanguage(""), .ru)
    }

    func testSetLanguageReturnsTheActiveCode() {
        XCTAssertEqual(L10n.setLanguage("ru"), .ru)
        // Same code twice: no notification, but the return value stays truthful.
        XCTAssertEqual(L10n.setLanguage("ru"), .ru)
    }

    func testSetLanguageIsCaseAndSpaceTolerant() {
        XCTAssertEqual(L10n.setLanguage("  RU "), .ru)
    }

    func testLanguagesRegistry() {
        XCTAssertEqual(L10n.languages, [.en, .ru])
        XCTAssertEqual(LanguageCode.name(.ru), "Русский")
        XCTAssertNil(LanguageCode.parse("xx"))
        XCTAssertEqual(LanguageCode.parse("xx"), nil)
    }

    // MARK: - Initial language

    func testResolveInitialLanguagePrefersTheStoredValue() {
        store.set("ru", forKey: L10n.settingsKey)
        XCTAssertEqual(L10n.resolveInitialLanguage(locale: Locale(identifier: "en_US")), .ru)
    }

    func testResolveInitialLanguageFallsBackToTheSystemLocale() {
        store.set(nil, forKey: L10n.settingsKey)
        XCTAssertEqual(L10n.resolveInitialLanguage(locale: Locale(identifier: "ru_RU")), .ru)
        XCTAssertEqual(L10n.resolveInitialLanguage(locale: Locale(identifier: "en_US")), .en)
    }

    func testResolveInitialLanguageIgnoresACorruptStoredValue() {
        store.set("klingon", forKey: L10n.settingsKey)
        XCTAssertEqual(L10n.resolveInitialLanguage(locale: Locale(identifier: "en_US")), .en)
    }

    func testSetLanguagePersistsTheChoice() {
        L10n.setLanguage("ru")
        XCTAssertEqual(store.snapshot[L10n.settingsKey], "ru")
    }

    func testBootstrapDoesNotPersist() {
        L10n.bootstrap(locale: Locale(identifier: "ru_RU"), store: store)
        XCTAssertEqual(L10n.language, .ru)
        XCTAssertNil(store.snapshot[L10n.settingsKey])
    }

    // MARK: - The Russian catalogue

    func testEnglishNeedsNoCatalogue() {
        // The source strings *are* the English text, so an empty table is correct and
        // a missing EN key is impossible to express.
        XCTAssertTrue(L10n.catalogue(for: .en).isEmpty)
    }

    func testCatalogValuesAreUsableStrings() {
        for (key, value) in RussianCatalogue.all {
            XCTAssertFalse(key.trimmingCharacters(in: .whitespaces).isEmpty, "empty key")
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty value for \(key)")
        }
    }

    func testPlaceholdersSurviveTranslation() {
        let pattern = try! NSRegularExpression(pattern: "%[1-9]|\\{[a-z_]+\\}")
        for (key, value) in RussianCatalogue.all {
            let inKey = matches(pattern, key)
            let inValue = matches(pattern, value)
            XCTAssertEqual(inKey, inValue, "placeholder mismatch for \(key)")
        }
    }

    private func matches(_ pattern: NSRegularExpression, _ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .sorted()
    }

    // MARK: - Parity with ru.py

    /// The generated catalogue must carry exactly the keys of `ru.MESSAGES`.
    ///
    /// Python's test asserts this in the other direction (every `tr()` string is
    /// translated). This direction — *the Swift port has every key Python wrote* — is the
    /// one Python cannot check, and it is checked here by reading `ru.py` at test time:
    /// `L10nKeysTests` scans the Swift sources, but nothing scanned both sides, which is
    /// how the Settings dialog, the playback timer and the preset registry grew 27 keys
    /// Python-only and 27 keys' worth of Russian silently vanished from the app.
    ///
    /// Key *sets*, not a count: two catalogues can hold the same number of keys and still
    /// disagree about which, and a stale port that dropped one key and gained another would
    /// pass a count comparison.
    func testCatalogMatchesThePythonKeyCount() throws {
        // Reads ru.py rather than trusting a literal: a hard-coded count here cannot fail
        // when Python grows a key, which is the drift this test exists to catch.
        let ruPath = PythonCatalogueSource.repositoryRoot
            .appendingPathComponent("src/binaural/locales/ru.py")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ruPath.path),
            "cannot find \(ruPath.path); the tests locate the repository from #filePath"
        )
        let keys: Set<String>
        do {
            keys = try PythonCatalogueSource.messageKeys(at: ruPath)
        } catch {
            return XCTFail("cannot parse \(ruPath.path): \(error)")
        }
        let catalogued = Set(RussianCatalogue.messages.keys)
        XCTAssertEqual(
            catalogued.subtracting(keys).sorted(),
            [],
            "keys only in the Swift catalogue: regenerate with "
                + "apple/Tools/generate_russian_catalogue.py"
        )
        XCTAssertEqual(
            keys.subtracting(catalogued).sorted(),
            [],
            "keys ru.py has that the Swift catalogue is missing: regenerate with "
                + "apple/Tools/generate_russian_catalogue.py"
        )
        // The count stays as a first line of defence: a parser that quietly returned one
        // key would satisfy both set differences above, so the size is checked too.
        XCTAssertEqual(
            catalogued.count,
            keys.count,
            "the parsed key set and the catalogue disagree in size"
        )
    }

    /// The parser this guard rests on must actually parse `ru.py` — a reader of the two
    /// tests above has no other way to tell a working guard from a vacuous one.
    func testThePythonCatalogueParserReadsEveryKey() throws {
        let keys = try PythonCatalogueSource.messageKeys()
        // Deliberately *not* compared against the catalogue: that comparison is the guard's
        // job, and duplicating it here would turn every real drift into two failures with
        // one cause. What this test answers is the other question — could the parser be
        // returning a handful of keys and still satisfying the guard? It cannot: the parser
        // reads every entry of the dict, and a floor this high rules out a scan that stopped
        // at the first section.
        XCTAssertGreaterThan(keys.count, 150, "the parse returned implausibly few keys")
        // The keys that must be there for the parse to have reached the end of the file.
        // One key from the first section, one from the middle, one from the last, and the
        // entry written with single quotes — so a scan that stops early, or one that only
        // accepts double quotes, is caught here rather than in the guard.
        for expected in ["Play", "&Help", "Could not start audio output.",
                         "Reference categories",
                         #"Ready. Press "Play test" and listen."#] {
            XCTAssertTrue(keys.contains(expected), "the parse lost \(expected)")
        }
        // A key written across three implicitly concatenated literals, with a `\"` escape in
        // the text: the two shapes a naive line-based scanner gets wrong.
        XCTAssertTrue(
            keys.contains(
                #"Permission is hereby granted, free of charge, to any person obtaining a copy of "#
                    + #"this software and associated documentation files (the "Software"), to deal in "#
                    + #"the Software without restriction, including without limitation the rights to use, "#
                    + #"copy, modify, merge, publish, distribute, sublicense and/or sell copies of the "#
                    + #"Software, and to permit persons to whom the Software is furnished to do so, "#
                    + #"subject to the conditions of the MIT licence. The software is provided "as is", "#
                    + #"without warranty of any kind, express or implied."#
            ),
            "implicitly concatenated keys are not being joined"
        )
        // The same licence entry is the file's only `\"` escape, so it is the one place a
        // parser that passes escapes through verbatim shows up.
        XCTAssertFalse(
            keys.contains { $0.contains(#"\""#) },
            "escapes are not being decoded"
        )
    }

    /// The Swift-only additions are a documented, deliberate superset — not drift.
    ///
    /// A *rule* about the additions rather than the literal dictionary M2-a pinned: the
    /// set grows as M2-b adds controls Python has no call site for (mute, the macOS-only
    /// About wording, SPEC §7's "Lock difference"), and a hard-coded copy of it would be
    /// edited on every milestone. What must stay true is that each entry is a key the app
    /// really shows — `testEveryAdditionIsShownByTheApp` pins that — and that its Russian is
    /// a real translation, not the English copied through.
    func testWindowAdditionsAreFewAndActuallyTranslated() {
        let additions = RussianWindowAdditions.messages
        XCTAssertFalse(additions.isEmpty, "M2-b adds keys ru.py has no call site for")
        // The ceiling moves when a milestone adds controls Python has no call site for, and
        // it moves *down* when Python grows a key: it was 16 with the mute button, the
        // timer, the Settings dialog, the macOS-only About wording and the "Lock
        // difference" checkbox. `ru.py` now carries the timer, the settings titles and the
        // headphone-check help text, and three keys nothing showed were dropped, so the
        // ceiling is 8. Raising it needs a milestone that adds Swift-only strings.
        XCTAssertLessThanOrEqual(
            additions.count, 8,
            "the additions are a documented superset, not a second catalogue"
        )
        for (key, value) in additions {
            XCTAssertFalse(value.isEmpty, "\(key) added with no Russian")
            // Cyrillic, and not the English repeated back.
            XCTAssertTrue(
                value.rangeOfCharacter(from: .decimalDigits.inverted) != nil
                    || value.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) },
                "\(key) does not look translated: \(value)"
            )
        }
    }

    /// Every addition is a key some source really references — an addition nobody shows
    /// is dead weight in the catalogue, and the way to notice is to check.
    ///
    /// The corpus deliberately **excludes `Sources/Core/Locales`**. The catalogue files
    /// spell out every key they hold, so scanning them made this test vacuous: it passed
    /// for keys no interface ever shows, which is how three of them (the Audio/Playback
    /// section titles and "Show or hide the main window") survived into the file.
    func testEveryAdditionIsShownByTheApp() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var corpus = ""
        if let walker = try? FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) {
            for case let file as URL in walker
            where file.pathExtension == "swift"
                && !file.path.contains("/Sources/Core/Locales/") {
                corpus += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(corpus.isEmpty, "no Swift sources found under \(sources.path)")
        for key in RussianWindowAdditions.messages.keys.sorted() {
            XCTAssertTrue(
                corpus.contains(key),
                "\(key) is in RussianWindowAdditions but no source outside the catalogue shows it"
            )
        }
    }

    /// `RussianCatalogue.all` is what callers and tests see: port + additions.
    func testMergedCatalogueCoversBothFiles() {
        let merged = RussianCatalogue.all
        XCTAssertEqual(
            merged.count,
            RussianCatalogue.messages.count + RussianWindowAdditions.messages.count
        )
        XCTAssertEqual(merged["Mute"], "Без звука")
        XCTAssertEqual(merged["Play"], "Воспроизвести")
    }

    func testNoKeyLivesInBothCatalogueFiles() {
        // The merge gives the hand-written file precedence, which is only ever a tie-break:
        // the two files must not overlap at all. `ru.py` now carries the timer, the
        // settings titles and the headphone-check help text, so those entries must have
        // moved out of `RussianWindowAdditions` — this is what pins that pruning.
        let shared = Set(RussianCatalogue.messages.keys)
            .intersection(RussianWindowAdditions.messages.keys)
            .sorted()
        XCTAssertEqual(
            shared,
            [],
            "these keys are in both files; delete the hand-written copy — ru.py owns them"
        )
        // Defence in depth: the merge above is written as `merging(_:) { _, added in added }`,
        // so a hand-written entry would win. Better that the situation never arises.
        XCTAssertFalse(RussianCatalogue.messages.keys.contains("Mute"))
    }
}