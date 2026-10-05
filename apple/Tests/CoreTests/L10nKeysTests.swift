import Foundation
import XCTest

@testable import BinauralCore

/// Every string the app passes to `L10n.tr` exists in both languages.
///
/// This is the Swift half of `tests/test_i18n.py::test_every_tr_string_is_translated`:
/// Python walks the AST of `src/binaural` and collects every literal that reaches
/// `tr()`; this scans the Swift sources with the same intent.
///
/// The referenced-key list below is hand-maintained, which is the one weak point of the
/// Python approach too — but here it cannot rot, because two tests close the loop in
/// both directions: a `tr("…")` literal in the sources that is missing from the list
/// fails `testEveryTrStringIsCoveredHere`, and a listed key no source mentions fails
/// `testEveryListedKeyIsUsed`. Adding an untranslated string therefore fails the suite.
@MainActor
final class L10nKeysTests: XCTestCase {

    /// Every key the app references, grouped the way the interface is.
    ///
    /// Kept as a single literal per line: the scanner in ``trLiteralsInSources()`` reads
    /// one literal per `tr(` call, and a concatenated literal would hide half a key.
    static let referencedKeys: [String] = [
        // main window and transport
        "Binaural", "LEFT EAR", "RIGHT EAR", "Play", "Stop", "Volume", "Mute",
        "Play or stop the binaural tone", "Play the binaural tone", "Stop the binaural tone",
        "Starts or stops playback. The keyboard shortcut is Space.",
        "Output level from 0 to 100 percent. Not medical advice: keep it low.",
        // menus
        "Quit", "&View", "Language",
        // per-ear frequency control
        "1 – 20000 Hz",
        "Frequency for %1, from 1 to 20000 hertz. Use the arrow keys for 0.1 hertz steps.",
        "%1 frequency in hertz", "%1 frequency slider",
        "Type an exact value between 1 and 20000, in steps of 0.1 hertz.",
        "Sweeps the frequency from 1 to 20000 hertz.",
        // beat card
        "BEAT", "CARRIER", "Hz", "Beat and carrier frequencies",
        "Difference is %1 Hz — outside the %2–%3 Hz range the ear usually perceives as a beat.",
        "Warning",
        // status indicator
        "Audio output status", "Headphones detected",
        "Speakers detected — binaural beats need headphones", "Unknown device",
        // errors
        "Error", "Could not start audio output.", "Could not open the audio output device."
    ]

    /// `<repo>/apple/Sources` — the same `#filePath` trick as `ReferenceFile`, three
    /// levels up because this file sits in `Tests/CoreTests/`.
    private static let sourcesRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apple
            .appendingPathComponent("Sources")
    }()

    // MARK: - Parity

    func testEveryReferencedKeyIsTranslated() {
        let russian = RussianCatalogue.all
        let missing = Self.referencedKeys.filter { russian[$0]?.isEmpty != false }
        XCTAssertTrue(
            missing.isEmpty,
            "referenced but not translated into Russian:\n" + missing.joined(separator: "\n")
        )
    }

    /// English is the source language and has no catalogue, so "exists in English" means
    /// "resolves to itself" — the M2-a rule that a missing EN key returns the key.
    func testEveryReferencedKeyResolvesInEnglish() {
        for key in Self.referencedKeys {
            XCTAssertEqual(L10n.catalogue(for: .en)[key] ?? key, key)
        }
    }

    func testEveryReferencedKeyResolvesInRussian() {
        L10n.setLanguage("ru")
        defer { L10n.setLanguage("en") }
        for key in Self.referencedKeys {
            XCTAssertFalse(L10n.tr(key).isEmpty, "\(key) translated to nothing")
        }
    }

    // MARK: - The scan that keeps the list honest

    /// Every string literal that reaches `tr`, however the call is spelled.
    ///
    /// A scan, not an AST walk: Swift has no parser in a test bundle, and the rule worth
    /// enforcing is the one this checks — "no user-visible string outside `tr`". It
    /// reads each `tr(` call's whole argument list, so the ternary form
    /// `tr(playing ? "Stop" : "Play")` is caught as well as the plain one.
    ///
    /// Multi-line literals are not used anywhere in the app, and that is not a silent
    /// hole: such a key would be missing from the scan *and* from the list, so
    /// `testEveryListedKeyIsUsed` would fail on it and name it.
    private static func trLiteralsInSources() -> Set<String> {
        let literal = try! NSRegularExpression(pattern: "\"((?:[^\"\\]|\\.)*)\"")
        var found: Set<String> = []
        for file in swiftFiles() {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var searchStart = text.startIndex
            while let call = text.range(of: "tr(", range: searchStart..<text.endIndex),
                  // `L10n.tr(` and the local `tr(` helper — but not a name ending in "tr".
                  !isPartOfAnIdentifier(text, at: call.lowerBound) {
                guard let close = balancedParenthesis(in: text, from: call.upperBound) else { break }
                let arguments = String(text[call.upperBound..<close])
                let range = NSRange(arguments.startIndex..., in: arguments)
                for match in literal.matches(in: arguments, range: range) {
                    guard let captured = Range(match.range(at: 1), in: arguments) else { continue }
                    found.insert(unescape(String(arguments[captured])))
                }
                searchStart = text.index(after: close)
            }
        }
        return found
    }

    /// Keys that never appear as a `tr` argument because they are named constants
    /// translated when shown: `engine.py`'s `_ERROR_SOURCES` rule, mirrored by
    /// `AudioFailure`.
    private static func namedKeys() -> Set<String> {
        Set(AudioFailure.all)
    }

    /// True when the character before `index` is part of an identifier, which would make
    /// the match part of a longer name (`Extra.tr(`) rather than a call.
    private static func isPartOfAnIdentifier(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return false }
        let previous = text[text.index(before: index)]
        return previous.isLetter || previous.isNumber || previous == "_"
    }

    /// The index of the `)` matching the `(` that starts at `index`, or `nil` when the
    /// text runs out — which a malformed scan should report, not loop on.
    private static func balancedParenthesis(in text: String, from index: String.Index) -> String.Index? {
        var depth = 1
        var cursor = index
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func swiftFiles() -> [URL] {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// Undo the escaping the scanner matched, so a key containing `\"` compares equal to
    /// the literal the compiler sees.
    private static func unescape(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}