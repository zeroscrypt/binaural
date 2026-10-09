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
        "Play the binaural tone", "Stop the binaural tone",
        "Starts or stops playback. The keyboard shortcut is Space.",
        "Output level from 0 to 100 percent. Not medical advice: keep it low.",
        // menus
        "Quit", "&View", "Language", "&Help", "Frequency &reference…",
        "&Check headphones…", "&About", "Binaural",
        "The frequency reference is not available in this build.",
        // the window's own headphone-check button (SPEC §7)
        "Check headphones…",
        "Re-reads the default audio output device and offers the L/R test.",
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
        // "Lock difference" checkbox, next to the beat readout (SPEC §7)
        "Lock difference",
        "Keeps the difference between the two frequencies. Changing one channel moves the other by the same amount, so the beat stays the same.",
        "Difference lock turned off — a preset set its own difference.",
        "Stopped at the range limit: the difference is locked, so the other channel cannot follow any further.",
        // status indicator
        "Audio output status", "Headphones detected",
        "Speakers detected — binaural beats need headphones", "Unknown device",
        // timer (SPEC §5 F5)
        "Timer", "Off", "%1 min",
        // the language control in the main window (SPEC §7.4)
        "Language",
        // menu-bar status item (SPEC §7; Python's TrayController). All four were already in
        // ru.py for the tray, which is why none of them needed a Swift addition.
        "Show Binaural", "Hide Binaural", "Frequency reference…",
        "⏹ %1 / %2 Hz", "▶ %1 / %2 Hz — beat %3 Hz",
        // headphone check at launch (SPEC §4)
        "Headphones recommended", "Headphones detected", "Speakers detected",
        "Virtual audio device — cannot tell what is playing",
        "Output device not recognised — run the L/R test",
        "Headphones", "Speakers", "Virtual device", "Unknown", "Unknown output device",
        "Device", "Verdict", "Confidence", "High", "Medium", "Low",
        "Binaural beats only work when each ear receives its own tone. On speakers the two frequencies mix in the air before reaching your ears, and the effect disappears. You can continue anyway — the app will keep showing a “Speakers detected” indicator in the status bar.",
        "This check can be repeated at any time from the Help menu.",
        "L/R test: Left → Right — headphones confirmed, channels correct.",
        "L/R test: Right → Left — headphones confirmed, channels are swapped. Binaural will swap them when generating.",
        "L/R test: both at once or unclear — this sounds like speakers or a mono mixer.",
        "Run L/R test", "Run the perceptual left/right channel test",
        "Plays a tone in the left ear, then the right ear, and asks what you heard.",
        "Retry check", "Run the device check again",
        "Re-reads the default audio output device.",
        "Continue anyway", "Continue anyway, even without confirmed headphones",
        "Nothing is blocked; the app will keep the speakers warning in the status bar.",
        // perceptual L/R test dialog (SPEC §4.2)
        "Left / right channel test",
        "You will hear a tone in one ear, then a pause, then a tone in the other ear. Tell us what you heard.",
        "What did you hear?", "Ready. Press \"Play test\" and listen.", "Answer recorded.",
        "Playing in LEFT ear…", "Pause…", "Playing in RIGHT ear…",
        "Left → Right", "The first tone came from the left ear: the channels are correct.",
        "Right → Left", "The channels are swapped. The application will swap them for you.",
        "Both at once / Can't tell",
        "Sounds like speakers or a mono mixer, where no beat can be perceived.",
        "{answer}. {hint}",
        "Headphones confirmed, the channels are correct.",
        "Headphones confirmed, but the channels are swapped. Binaural will swap them so the beat stays on the side you expect.",
        "No clear answer. This usually means speakers or a mono mixer.",
        "Play test", "Play test again", "Play the left/right test sequence",
        "A short tone in the left ear, a pause, then the right ear.",
        "Close the test without answering",
        "Tone: {freq} Hz — one channel at a time, no beat",
        "Close",
        // errors
        "Error", "Could not start audio output.", "Could not open the audio output device.",
        // presets (SPEC §5 F3)
        "Presets", "Sets both channels around a %1 Hz carrier so the difference is %2 Hz.",
        "Preset applied: difference %1 Hz",
        // About and the shared disclaimer (SPEC §6.13)
        "About Binaural", "Binaural beats for macOS",
        "Two sine tones of different frequency are sent to the left and the right ear. Your brain fuses them into a third tone that has no sound source: the difference between the two frequencies. That phantom tone is the binaural beat.",
        "Headphones are a physical requirement, not a recommendation: on speakers both frequencies mix in the air before they reach your ears, and the effect is gone. The application checks the audio output on every start and reports what it found.",
        "The frequency reference keeps every record it has — from peer-reviewed EEG literature to esoteric traditions — each marked with how well it is studied.",
        // SPEC §7 item 6: the four descriptive sections of the About dialog, in the
        // order `AboutDialogController` shows them. Two of them (platform, stack) are
        // macOS-only and live in `RussianWindowAdditions`, like the tagline above.
        "Who made it", "How it works", "What it is and what it is for",
        "Technical details",
        "Written by @zeroscrypt (Dmitriy Solontsov), with special thanks to @hakatao.",
        "The project lives at github.com/zeroscrypt/binaural. Released in 2026.",
        "Two sine tones of different frequency, one sent to each ear, and the brain hears a third tone that is not there. That third tone is the difference between the two frequencies, and it is called the beat.",
        "The beat is the difference between the two frequencies. The carrier is their average — the tone you actually hear in each ear, with the beat pulsing inside it.",
        "Headphones are not a preference but a physical requirement: the two frequencies have to reach your ears separately, and only headphones do that. On speakers they mix in the air first, and there is nothing left to fuse.",
        "The application itself does the plain part: two independent frequencies you set, play and stop, volume, a timer, presets, the frequency reference and a headphone check. Nothing is added to the sound and nothing is sent anywhere.",
        "Binaural is a desktop generator of binaural beats. It makes a sound and shows you what is known about the frequencies it can play.",
        "It is not a medical device and makes no health claim. It does not diagnose, treat or prevent anything, and it does not promise an effect. The disclaimer below is the full version of that sentence.",
        "Platform: macOS. Licence: MIT — use it, change it, ship it.",
        "Built with Swift and AVAudioEngine. Two applications are built from this repository; they share their frequency arithmetic, not their code.",
        "The macOS app is unsigned: no Apple Developer identity is available, so it runs for whoever built it and Gatekeeper blocks it for anyone else. Right-click, then Open, gets past it. GitHub releases carry source only.",
        "Version {version} · macOS {system}",
        "Disclaimer",
        "These frequencies and the descriptions of their effects come from research, and also from esoteric, energy and alternative practices. This application is not a medical device and is not intended for the diagnosis, treatment or prevention of any disease. Do not use it if you have epilepsy or a pacemaker, during pregnancy, or if you are photosensitive, without consulting a doctor. Do not turn the volume above a comfortable level. Binaural beats are sound, not a substance, and they do not replace one. Nothing here helps with withdrawal, craving, tolerance or relapse, and this app does not treat dependence of any kind. Dependence is a medical condition with risks of its own: withdrawal from alcohol and from sedatives can be dangerous. If you are dependent on something, or want to use less of it, that is a question for a doctor or a specialist service, not for a tone generator.",
        "MIT License", "Copyright (c) {year} {holder}",
        "Open project page", "Open {url} in the browser",
        "Close the About dialog",
        "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the conditions of the MIT licence. The software is provided \"as is\", without warranty of any kind, express or implied.",
        // frequency reference dialog (SPEC §6)
        "Frequency reference",
        "Every record from the built-in reference, from EEG literature to esoteric traditions. Nothing is ranked and nothing is hidden.",
        "Search the frequency reference", "Search name, frequency or effect…",
        "Filter by evidence level", "All evidence", "All categories",
        "Reference categories", "Reference records", "Show every record of the reference",
        "Showing {shown} of {total} records", "Nothing matches this filter.",
        "Badges show how well a record is studied. Nothing is hidden by default.",
        "Well-studied", "Studied", "Reported", "Traditional", "Unknown",
        "Apply {label}",
        "Set left = {left} Hz and right = {right} Hz (difference {beat})",
        "Tone — applied as the carrier with a {beat} Hz beat",
        "Carries {carrier} Hz",
        "Medical disclaimer — read it before using the application.",
        // update check
        "Check for updates", "Checking for updates…", "You are up to date",
        "Version {version} is available", "Download and install", "Later",
        "Skip this version", "Downloading update…", "Could not check for updates",
        "Could not download the update.", "Could not install the update.",
        "Binaural will restart to finish the update.", "Install and restart",
        "Open the release page"
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

    /// Every key a source passes to `tr`, plus the named constants translated when shown.
    func testEveryTrStringIsCoveredHere() {
        let used = Self.trLiteralsInSources().union(Self.namedKeys())
        let missing = used.subtracting(Self.referencedKeys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "passed to tr() but not listed in referencedKeys — add them:\n"
                + missing.joined(separator: "\n")
        )
    }

    /// …and the other direction, so the list cannot quietly keep a key nothing shows.
    func testEveryListedKeyIsUsed() {
        let used = Self.trLiteralsInSources().union(Self.namedKeys())
        let stale = Set(Self.referencedKeys).subtracting(used).sorted()
        XCTAssertTrue(
            stale.isEmpty,
            "listed in referencedKeys but referenced nowhere:\n" + stale.joined(separator: "\n")
        )
    }

    /// Every string literal that reaches `tr`, however the call is spelled.
    ///
    /// A scan, not an AST walk: Swift has no parser in a test bundle, and the rule worth
    /// enforcing is the one this checks — "no user-visible string outside `tr`". It
    /// reads each `tr(` call's whole argument list, so the ternary form
    /// `tr(playing ? "Stop" : "Play")` is caught as well as the plain one.
    private static func trLiteralsInSources() -> Set<String> {
        var found: Set<String> = []
        for file in swiftFiles() {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var searchStart = text.startIndex
            while let call = text.range(of: "tr(", range: searchStart..<text.endIndex),
                  // `L10n.tr(` and the local `tr(` helper — but not a name ending in "tr".
                  !isPartOfAnIdentifier(text, at: call.lowerBound) {
                guard let close = balancedParenthesis(in: text, from: call.upperBound) else { break }
                let arguments = String(text[call.upperBound..<close])
                found.formUnion(catalogKeys(inArguments: arguments))
                searchStart = text.index(after: close)
            }
        }
        return found
    }

    /// The catalogue keys inside one `tr(...)` argument list.
    ///
    /// Two rules make the scan agree with what the compiler sees:
    ///
    /// * the list is cut at a top-level `named:` — everything after it belongs to the
    ///   named-argument overload, where the literals are dictionary *keys* (`"label"`)
    ///   and not catalogue keys at all;
    /// * a **run** of adjacent string literals is joined into one key, exactly as the
    ///   compiler joins it, so a long sentence written over two lines is the single
    ///   catalogue key it is rather than two fragments neither of which is in `ru.py`.
    ///   Both spellings of "joined" are recognised — Swift's implicit concatenation
    ///   (`"a" "b"`) and the explicit `+` (`"a" + "b"`), which is what the reference
    ///   dialog's two-line caption uses. A comma keeps two literals apart, so the
    ///   positional arguments of `tr(key, value…)` never merge into one key.
    private static func catalogKeys(inArguments arguments: String) -> Set<String> {
        let fullRange = NSRange(arguments.startIndex..., in: arguments)
        let cut = namedArgumentLabel.firstMatch(in: arguments, range: fullRange)
            .flatMap { Range($0.range, in: arguments)?.lowerBound }
        let head = cut.map { String(arguments[arguments.startIndex..<$0]) } ?? arguments

        let range = NSRange(head.startIndex..., in: head)
        var keys: Set<String> = []
        for match in joinedLiterals.matches(in: head, range: range) {
            let run = Range(match.range, in: head).map { String(head[$0]) } ?? ""
            // Concatenated, not collected: the fragments of a joined run are not keys,
            // the joined string is. Two fragments would both fail the translation check
            // and hide the real key from the list.
            keys.insert(unescape(matches(inString: run).joined()))
        }
        return keys
    }

    private static let namedArgumentLabel = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])named\\s*:"
    )
    /// One literal, or several glued together by whitespace and/or `+`.
    private static let joinedLiterals = try! NSRegularExpression(
        pattern: "\"(?:[^\"\\\\]|\\\\.)*\"(?:[ \\t\\n\\r]*(?:\\+[ \\t\\n\\r]*)?\"(?:[^\"\\\\]|\\\\.)*\")*"
    )
    private static let literalPattern = try! NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")

    private static func matches(inString text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return literalPattern.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    /// Keys that never appear as a `tr` argument because they are named constants
    /// translated when shown: `engine.py`'s `_ERROR_SOURCES` rule, mirrored by
    /// `AudioFailure`, and the About/disclaimer text the reference dialog and About both
    /// share (`AboutContent`).
    private static func namedKeys() -> Set<String> {
        Set(AudioFailure.all).union(AboutContent.namedKeys)
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

    /// Undo the escaping the scanner matched, so a key compares equal to the literal the
    /// compiler sees.
    ///
    /// `\\"` and `\\\\` are the two the sources use; `\u{201C}` is resolved as well, because
    /// the compiler resolves it into the character — a scanner that did not would report a
    /// key containing a backslash that is in no catalogue.
    private static func unescape(_ literal: String) -> String {
        guard literal.contains("\\") else { return literal }
        var text = literal
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")

        // `\u{XXXX}` — a handful of curly quotes the sources write that way rather than
        // pasting the character itself. Walked over `Character`s and rebuilt: `String.range(of:)`
        // answers in **UTF-8 offsets**, which do not index the same thing as
        // `String.index(after:)`, so mixing the two silently drops digits.
        var result = ""
        result.reserveCapacity(text.count)
        var characters = Array(text)
        var index = 0
        while index < characters.count {
            let start = index + 3
            guard characters[index] == "\\", start < characters.count,
                  characters[index + 1] == "u", characters[index + 2] == "{",
                  let close = characters[start..<characters.count].firstIndex(of: "}")
            else {
                result.append(characters[index])
                index += 1
                continue
            }
            let digits = String(characters[start..<close])
            // Radix 16, explicitly: `UInt32("201C")` is *decimal*, which is nil, and the
            // escape would then silently be kept as written — exactly the bug this walk
            // exists to prevent.
            if let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                // Not an escape after all: keep the characters as written.
                result.append(contentsOf: characters[index...close])
            }
            index = close + 1
        }
        return result
    }
}