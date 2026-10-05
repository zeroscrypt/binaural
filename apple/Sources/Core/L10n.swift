import Foundation

/// The UI languages. English is the source language, Russian is a catalogue.
///
/// Port of `SUPPORTED_LANGUAGES` in `src/binaural/i18n.py`. The display names stay
/// native in both languages ("English", "Русский"), because a user has to be able to
/// find their own language in the list.
public enum LanguageCode: String, CaseIterable, Sendable {
    case en
    case ru

    /// Code -> native name, shown verbatim in the language menu.
    public static let names: [LanguageCode: String] = [.en: "English", .ru: "Русский"]

    /// Native display name; the code itself when unknown.
    public static func name(_ code: LanguageCode) -> String { names[code] ?? code.rawValue }

    /// A stored or system-supplied string -> a supported code, or `nil`.
    public static func parse(_ raw: String?) -> LanguageCode? {
        guard let raw else { return nil }
        return LanguageCode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// Where ``L10n`` remembers the chosen language.
///
/// A protocol rather than a direct `UserDefaults` dependency so the tests can run
/// against an isolated store — `set_language` writes process-wide state in Python for
/// exactly the same reason (`tests/test_i18n.py` redirects `HOME`).
public protocol PreferenceStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults` storage for the language choice.
///
/// Only the suite *name* is stored, not the `UserDefaults` object: `UserDefaults` is
/// documented thread-safe but is not `Sendable` in Swift, so keeping the name (a
/// `String`) keeps this type honestly `Sendable` without an `@unchecked` claim. The
/// lookup happens on a language switch only, never in a hot path.
public struct UserDefaultsPreferenceStore: PreferenceStore, Sendable {

    /// `nil` is the app's own domain, i.e. `UserDefaults.standard`.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// The one entry point for every user-visible string.
///
/// English is the **source** language, exactly as in `src/binaural/i18n.py`: a call
/// site passes the English string, which is what the Russian catalogue is keyed on.
/// So `L10n.tr("Play")` is `"Play"` in English by construction — there is no English
/// table to miss an entry in, which is the "missing EN key returns the key itself"
/// rule of `apple/M2.md`.
///
/// Fallbacks, in order: Russian catalogue -> the English source -> the key itself.
/// Nothing here ever throws: a half-finished catalogue must degrade to a usable UI,
/// not to a crash.
///
/// Main-actor isolated on purpose. The language is UI state, only the UI reads it,
/// and the audio thread has no business translating anything — that keeps the global
/// out of the data race without a lock.
@MainActor
public enum L10n {

    /// Posted (on the main thread) after the language actually changed. The object is
    /// the new ``LanguageCode``. Long-lived views re-read their captions from it —
    /// the Swift counterpart of the Python `language_changed` signal.
    public static let languageDidChange = Notification.Name("app.binaural.languageDidChange")

    /// Settings key, the same spelling Python uses in `QSettings`.
    public static let settingsKey = "ui/language"

    /// The source language. English needs no table, so it has none.
    public static let sourceLanguage: LanguageCode = .en

    /// Every supported language, in menu order.
    public static var languages: [LanguageCode] { LanguageCode.allCases }

    private static var store: PreferenceStore = UserDefaultsPreferenceStore()
    private static var current: LanguageCode = sourceLanguage

    // MARK: - Current language

    /// The active language. Defaults to English until something calls
    /// ``resolveInitialLanguage()``.
    public static var language: LanguageCode { current }

    /// Switch the UI language; returns the code that is active afterwards.
    ///
    /// Unknown codes are ignored and the current language is kept, rather than
    /// throwing: a corrupt setting must not stop the app from starting (the rule from
    /// `i18n.set_language`).
    @discardableResult
    public static func setLanguage(_ code: String) -> LanguageCode {
        guard let parsed = LanguageCode.parse(code), parsed != current else { return current }
        apply(parsed)
        return current
    }

    /// Switch to an already-parsed code.
    @discardableResult
    public static func setLanguage(_ code: LanguageCode) -> LanguageCode {
        guard code != current else { return current }
        apply(code)
        return current
    }

    private static func apply(_ code: LanguageCode) {
        current = code
        // Persistence is a convenience, never a blocker.
        store.set(code.rawValue, forKey: settingsKey)
        NotificationCenter.default.post(name: languageDidChange, object: code)
    }

    /// Stored preference, else the system locale, else English — the first-run
    /// detection of `i18n.resolve_initial_language`.
    ///
    /// - Parameter locale: the system locale; injected by the tests.
    public static func resolveInitialLanguage(locale: Locale = .current) -> LanguageCode {
        if let stored = LanguageCode.parse(store.string(forKey: settingsKey)) {
            return stored
        }
        let identifier = locale.identifier.lowercased()
        return identifier.hasPrefix("ru") ? .ru : sourceLanguage
    }

    /// Install the language resolved for this launch. Called once, before any view is
    /// built, and deliberately without posting a change notification.
    ///
    /// - Parameter newStore: replaces where the choice is remembered. The apps pass
    ///   nothing; the tests pass an in-memory store so they never touch the real
    ///   preferences of the machine they run on.
    public static func bootstrap(locale: Locale = .current, store newStore: PreferenceStore? = nil) {
        if let newStore { store = newStore }
        current = resolveInitialLanguage(locale: locale)
    }

    // MARK: - Translation

    /// Translate `key` and fill `%1`..`%n` (the Qt idiom the Python catalogues use).
    public static func tr(_ key: String, _ arguments: String...) -> String {
        var text: String
        switch current {
        case .en:
            // Source language: the key *is* the text.
            text = key
        case .ru:
            // Two lookups instead of a merged table: `all` would copy 170+ entries on
            // every label. The additions are three entries and are tried first.
            text = RussianWindowAdditions.messages[key]
                ?? RussianCatalogue.messages[key]
                ?? key
        }
        for (index, value) in arguments.enumerated() {
            text = text.replacingOccurrences(of: "%\(index + 1)", with: value)
        }
        return text
    }

    /// The catalogue of a language. English is empty: its source strings need no
    /// table, so a missing key can only ever come from the catalogue.
    public static func catalogue(for code: LanguageCode) -> [String: String] {
        switch code {
        case .en: [:]
        case .ru: RussianCatalogue.all
        }
    }
}