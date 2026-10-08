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

    // MARK: - The four sections (SPEC §7 item 6)

    /// The four headings, in the order the dialog shows them. Named as constants so a
    /// heading reworded on one side and not the other fails here rather than reading as
    /// a different section with the same meaning.
    private static let sectionTitles = [
        AboutContent.whoMadeItTitle,
        AboutContent.howItWorksTitle,
        AboutContent.whatItIsForTitle,
        AboutContent.technicalTitle,
    ]

    /// Every section is there, as a heading, before the disclaimer panel — which is the
    /// only text in the product whose position is fixed by SPEC §6.13.
    func testTheDialogShowsTheFourSections() {
        let dialog = makeDialog()
        let lines = dialog.visibleLines
        for title in Self.sectionTitles {
            XCTAssertTrue(lines.contains(title), "About is missing the section: \(title)")
        }
        let firstHeading = try? XCTUnwrap(lines.firstIndex(of: AboutContent.whoMadeItTitle))
        let disclaimer = try? XCTUnwrap(lines.firstIndex(of: AboutContentText.disclaimer))
        XCTAssertLessThan(
            firstHeading ?? .max, disclaimer ?? 0,
            "the sections come before the disclaimer"
        )
    }

    /// Each section says what SPEC §7 item 6 asks it to say. Named per phrase, so a
    /// section that loses a sentence is one named failure rather than a whole-text match.
    func testTheSectionsSayWhatTheyShould() {
        let dialog = makeDialog()
        let lines = dialog.visibleLines
        let expected: [String: [String]] = [
            AboutContent.whoMadeItTitle: [
                "@zeroscrypt", "@hakatao", "2026", "github.com/zeroscrypt/binaural",
            ],
            AboutContent.howItWorksTitle: [
                "one sent to each ear", "third tone",
                "The beat is the difference", "The carrier is their average",
                "physical requirement", "volume", "timer", "presets", "headphone check",
            ],
            AboutContent.whatItIsForTitle: [
                "desktop generator of binaural beats", "not a medical device",
                "diagnose, treat or prevent",
            ],
            AboutContent.technicalTitle: [
                "Platform:", "macOS", "MIT", "Swift", "AVAudioEngine", "unsigned",
            ],
        ]
        XCTAssertEqual(Set(expected.keys), Set(Self.sectionTitles))
        for (title, phrases) in expected {
            let body = lines.filter { $0 != title }
            let text = body.joined(separator: "\n")
            for phrase in phrases {
                XCTAssertTrue(
                    text.contains(phrase),
                    "the About text lost \(phrase) — is it still in \(title)?"
                )
            }
        }
    }

    /// No section makes a health claim. SPEC §6.13 forbids promising treatment, diagnosis
    /// or a cure anywhere, and the new prose is the most likely place for one to creep in.
    func testTheSectionsClaimNoHealth() {
        let dialog = makeDialog()
        let text = dialog.visibleLines.joined(separator: "\n").lowercased()
        for word in ["treats", "cures", "heals", "guarantees", "proven to", "safe for"] {
            XCTAssertFalse(text.contains(word), "the About text must not claim: \(word)")
        }
    }

    /// The macOS `.app` is unsigned, and the dialog says so rather than leaving a reader
    /// to find out from Gatekeeper.
    func testTheTechnicalSectionSaysTheAppIsUnsigned() {
        let dialog = makeDialog()
        XCTAssertTrue(dialog.visibleLines.contains(AboutContentText.unsignedLine))
        XCTAssertTrue(AboutContentText.unsignedLine.contains("unsigned"))
        XCTAssertTrue(AboutContentText.unsignedLine.contains("Gatekeeper"))
    }

    /// The version is shown once, by the version line above. A second copy inside the
    /// technical section would be two numbers to keep in step for no gain.
    func testTheTechnicalSectionDoesNotRepeatTheVersion() {
        let dialog = makeDialog()
        let text = AboutContentText.technicalTitle
            + " " + AboutContentText.platformLicenceLine
            + " " + AboutContentText.stackLine
            + " " + AboutContentText.unsignedLine
        XCTAssertFalse(text.contains("Version"), "the version line is already shown above")
        XCTAssertTrue(dialog.visibleLines.contains(AboutContent.versionText()))
    }

    /// §7.4 again, for the new sections specifically: the Russian comes from `ru.py`,
    /// so a language switch leaves no English heading behind.
    func testTheSectionsFollowTheLanguage() {
        let dialog = makeDialog()
        L10n.setLanguage("ru")
        for title in Self.sectionTitles {
            let russian = RussianCatalogue.all[title] ?? RussianWindowAdditions.messages[title]
            XCTAssertNotNil(russian, "no Russian for the section heading: \(title)")
            XCTAssertTrue(
                dialog.visibleLines.contains(russian ?? ""),
                "the Russian heading is not shown: \(russian ?? "")"
            )
        }
        XCTAssertFalse(dialog.visibleLines.contains(AboutContent.howItWorksTitle))
        L10n.setLanguage("en")
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
        XCTAssertTrue(line.contains("0.2"), "the marketing version from project.yml: \(line)")
    }

    func testTheVersionLineSurvivesTranslation() {
        L10n.setLanguage("ru")
        let line = AboutContent.versionText(bundle: .main)
        XCTAssertTrue(line.hasPrefix("Версия"), "the caption is translated: \(line)")
        L10n.setLanguage("en")
    }
}