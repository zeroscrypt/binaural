import Foundation
import XCTest

@testable import BinauralCore

/// Parity with `tests/test_i18n.py`.
///
/// The Python suite checks the catalogue from three sides: `tr` resolves, every string
/// the app references has a Russian translation, and the catalogue has no orphans and
/// no lost placeholders. This file does the same for the Swift side, plus one check
/// Python cannot make — that the *generated* catalogue still matches `ru.py`.
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
    /// translated); here it is a count, because `L10nKeysTests` cannot see ru.py and this
    /// test cannot see a Swift literal from Python. A count plus the per-key tests in
    /// `L10nKeysTests` together pin the file: regeneration from a changed `ru.py`
    /// changes the number, and a hand-edit that drops a key changes it too.
    func testCatalogMatchesThePythonKeyCount() {
        XCTAssertEqual(
            RussianCatalogue.messages.count,
            171,
            "src/binaural/locales/ru.py has 171 keys; regenerate with "
                + "apple/Tools/generate_russian_catalogue.py"
        )
    }

    /// The Swift-only additions are a documented, deliberate superset — not drift.
    ///
    /// A *rule* about the additions rather than the literal dictionary M2-a pinned: the
    /// set grows as M2-b adds controls Python has no call site for (mute, the timer, the
    /// Settings dialog, the macOS-only About wording), and a hard-coded copy of it would
    /// be edited on every milestone. What must stay true is that each entry is a key the
    /// app really shows — `testEveryAdditionsKeyIsUsed` pins that — and that its Russian
    /// is a real translation, not the English copied through.
    func testWindowAdditionsAreFewAndActuallyTranslated() {
        let additions = RussianWindowAdditions.messages
        XCTAssertFalse(additions.isEmpty, "M2-b adds keys ru.py has no call site for")
        XCTAssertLessThanOrEqual(
            additions.count, 12,
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
    func testEveryAdditionsKeyIsReferenced() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var corpus = ""
        if let walker = try? FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) {
            for case let file as URL in walker where file.pathExtension == "swift" {
                corpus += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(corpus.isEmpty, "no Swift sources found under \(sources.path)")
        for key in RussianWindowAdditions.messages.keys.sorted() {
            XCTAssertTrue(
                corpus.contains(key),
                "\(key) is in RussianWindowAdditions but no source mentions it"
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

    func testAdditionsWinOverThePortOnAConflict() {
        // Defence in depth: if a key ever exists in both files, the hand-written one
        // must be the one the UI shows, or the merge would be order-dependent.
        XCTAssertFalse(RussianCatalogue.messages.keys.contains("Mute"))
    }
}