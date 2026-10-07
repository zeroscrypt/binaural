import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// About and the §6.13 disclaimer.
///
/// The disclaimer is the one text in the product that must not drift, must not be
/// softened, and must not gain a claim. These tests do three things about that: the English
/// source string is the one the shared catalogue is keyed on (so it cannot be reworded
/// without the translation breaking), every clause SPEC §6.13 names is still present, and
/// the Russian comes from `ru.py` rather than from a private translation inside this app.
@MainActor
final class AboutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        for dialog in openDialogs { dialog.tearDown() }
        openDialogs.removeAll()
        try await super.tearDown()
    }

    /// The dialogs this suite builds register a language observer; they are short-lived and
    /// the notification centre holds them weakly, so nothing leaks — but the suite's own
    /// dialogs are torn down explicitly to keep that an explicit habit.
    private var openDialogs: [AboutDialogController] = []

    private func makeDialog() -> AboutDialogController {
        let dialog = AboutDialogController()
        openDialogs.append(dialog)
        return dialog
    }

    // MARK: - The disclaimer (SPEC §6.13)

    /// The English sentence is the catalogue's key, byte for byte. If it were reworded here,
    /// the Russian would silently fall back to English — this test fails first instead.
    func testTheDisclaimerIsTheSharedCatalogueKey() {
        XCTAssertNotNil(
            RussianCatalogue.all[AboutContent.disclaimerEnglish],
            "the disclaimer must be a key of the shared catalogue"
        )
        XCTAssertNil(
            RussianWindowAdditions.messages[AboutContent.disclaimerEnglish],
            "and must NOT be overridden here: both implementations must say the same thing"
        )
    }

    /// Every clause SPEC §6.13 requires, in the English text. Named rather than matched
    /// wholesale so that dropping or softening one of them is a named failure — this is the
    /// test that would catch "no big deal, we'll drop the pacemaker line".
    func testTheDisclaimerKeepsEveryClauseOfTheSpec() {
        let text = AboutContent.disclaimerEnglish.lowercased()
        let required = [
            "not a medical device",
            "diagnosis, treatment or prevention",
            "epilepsy",
            "pacemaker",
            "pregnancy",
            "photosensitive",
            "consulting a doctor",
            "volume",
            // The addiction-safety sentence added with the substance/affect entries.
            "not a substance",
            "withdrawal",
            "dependence",
        ]
        for clause in required {
            XCTAssertTrue(text.contains(clause), "the disclaimer lost: \(clause)")
        }
    }

    /// …and nothing beyond it: no promise, no effect, no claim about what the app does.
    /// A disclaimer that grew a sentence is as much a SPEC change as one that lost one.
    func testTheDisclaimerPromisesNothing() {
        let banned = ["cures", "heals", "treats", "improves", "guarantees", "proven", "safe for"]
        let text = AboutContent.disclaimerEnglish.lowercased()
        for word in banned {
            XCTAssertFalse(text.contains(word), "the disclaimer must not claim: \(word)")
        }
    }

    /// Russian comes from `ru.py`, and the dialog shows the *same* sentence the frequency
    /// reference shows — one constant, two places (§6.13 asks for it in both).
    func testTheRussianDisclaimerIsTranslatedAndShared() {
        let russian = RussianCatalogue.all[AboutContent.disclaimerEnglish]
        XCTAssertNotNil(russian)
        XCTAssertNotEqual(russian, AboutContent.disclaimerEnglish)
        XCTAssertTrue(russian?.contains("медицинским изделием") == true)

        L10n.setLanguage("ru")
        XCTAssertEqual(AboutContent.disclaimerText(), russian)
        let dialog = makeDialog()
        XCTAssertEqual(dialog.disclaimerText, russian)
        XCTAssertTrue(
            dialog.visibleLines.contains(russian ?? ""),
            "the dialog must show the disclaimer, not paraphrase it"
        )
        L10n.setLanguage("en")
    }

    // MARK: - The dialog

    /// SPEC §6.13 wants the disclaimer *in the app*; this is the app.
    func testTheDialogShowsTheDisclaimer() {
        let dialog = makeDialog()
        XCTAssertEqual(dialog.disclaimerText, AboutContent.disclaimerEnglish)
        XCTAssertTrue(dialog.visibleLines.contains(AboutContent.disclaimerEnglish))
        XCTAssertEqual(dialog.window?.title, "About Binaural")
    }

    /// The project description is SPEC §1/§2 in words: two tones, one difference, headphones
    /// as a physical requirement. No health claim anywhere in it.
    func testTheDialogDescribesTheProject() {
        let dialog = makeDialog()
        let lines = dialog.visibleLines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("sine tones"), "SPEC §2: two sine tones")
        XCTAssertTrue(lines.contains("difference between the two frequencies"))
        XCTAssertTrue(lines.contains("physical requirement"), "SPEC §2.1: headphones are required")
        XCTAssertFalse(
            lines.lowercased().contains("treats") || lines.lowercased().contains("cures"),
            "the description must not make a health claim"
        )
    }

    func testTheDialogShowsTheVersionAndTheLicence() {
        let dialog = makeDialog()
        let lines = dialog.visibleLines
        XCTAssertTrue(
            lines.contains { $0.contains("Version") },
            "the version line is shown: \(lines.prefix(3))"
        )
        XCTAssertTrue(lines.contains { $0.contains("MIT License") })
        XCTAssertTrue(lines.contains { $0.contains("Dmitriy Solontsov") })
    }

    /// §7.4: the dialog reads the language itself, so a switch while it is open reaches every
    /// caption — and the disclaimer with it.
    func testTheDialogFollowsTheLanguage() {
        let dialog = makeDialog()
        L10n.setLanguage("ru")
        XCTAssertEqual(dialog.window?.title, "О программе Binaural")
        XCTAssertTrue(dialog.visibleLines.contains(AboutContent.disclaimerText()))
        XCTAssertFalse(
            dialog.visibleLines.contains(AboutContent.disclaimerEnglish),
            "no English left behind after a switch"
        )
        L10n.setLanguage("en")
        XCTAssertTrue(dialog.visibleLines.contains(AboutContent.disclaimerEnglish))
    }

    /// The project link is shown, and it is the real one.
    func testTheProjectLinkIsShown() {
        let dialog = makeDialog()
        XCTAssertTrue(
            dialog.visibleLines.contains(AboutContent.projectURL),
            "the project page is shown: \(dialog.visibleLines)"
        )
    }

    // MARK: - Version line

    /// The version comes from the bundle, with the build number when there is one, and the
    /// placeholders survive translation.
    func testTheVersionLineIsFilledIn() {
        let line = AboutContent.versionText(bundle: .main)
        XCTAssertFalse(line.contains("{version}"))
        XCTAssertFalse(line.contains("{system}"))
        XCTAssertTrue(line.contains("0.1"), "the marketing version from project.yml: \(line)")
    }

    func testTheVersionLineSurvivesTranslation() {
        L10n.setLanguage("ru")
        let line = AboutContent.versionText(bundle: .main)
        XCTAssertTrue(line.hasPrefix("Версия"), "the caption is translated: \(line)")
        L10n.setLanguage("en")
    }
}