import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The language control in the main window (SPEC §7.4), and the removal of the Settings
/// dialog it replaced.
///
/// The dialog held language, the timer, the volume and re-running the headphone check —
/// and the last three were already in the window. What was left of it was one control
/// costing a whole window, so the dialog is gone and the control is here.
@MainActor
final class WindowLanguageTests: XCTestCase {

    private var controller: MainWindowController!

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-window-language-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        store.save(Session(leftHz: 205, rightHz: 215, volume: 0.7, timerMinutes: 15))
        controller = MainWindowController(engine: AudioEngine(), store: store)
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        controller?.tearDown()
        controller = nil
        try await super.tearDown()
    }

    // MARK: - The control

    /// Both languages, and the current one selected — the list is the same the *View →
    /// Language* menu offers, so neither can drift.
    func testTheControlOffersBothLanguagesWithTheCurrentOneSelected() {
        XCTAssertEqual(controller.languageTitles, ["English", "Русский"])
        XCTAssertEqual(controller.selectedLanguage, .en)

        L10n.setLanguage("ru")
        XCTAssertEqual(controller.selectedLanguage, .ru, "the control follows the app")
    }

    /// No caption: the popup reads "English" or "Русский", which says what it is. The
    /// accessibility label is still translated — that one is read aloud, not looked at.
    func testThereIsNoCaptionButTheAccessibilityLabelIsTranslated() {
        XCTAssertEqual(controller.languageTitles, ["English", "Русский"],
                       "the language names stay native, as they must")
        XCTAssertEqual(controller.languageAccessibilityLabel, "Language")
        L10n.setLanguage("ru")
        XCTAssertEqual(controller.languageAccessibilityLabel, "Язык")
    }

    /// SPEC §7: the top row carries the app's state — the headphone indicator, the re-check
    /// button and the language. The language sits at the **right**, after the re-check
    /// button, and the row is pinned to the top of the window.
    func testTheControlSitsAtTheTopRight() throws {
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(controller.statusRow)
        let titles = row.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertEqual(
            titles, ["Check headphones…", "English"],
            "the re-check button first, then the language popup: \(titles)"
        )

        let rowFrame = row.convert(row.bounds, to: window.contentView)
        let popupFrame = controller.languageControl.convert(
            controller.languageControl.bounds, to: window.contentView
        )
        XCTAssertGreaterThan(
            popupFrame.minX, rowFrame.minX + rowFrame.width - popupFrame.width - 1,
            "the language popup is the last thing in the row, at its right edge"
        )
        XCTAssertLessThan(popupFrame.maxY, rowFrame.maxY + 1, "the row is at the top")
    }

    /// `setLanguage` is the same call the *View → Language* menu makes — one implementation
    /// of "switch the language", not a second one that could disagree.
    func testChoosingALanguageSwitchesTheWholeApp() {
        controller.selectLanguage(.ru)

        XCTAssertEqual(L10n.language, .ru)
        XCTAssertEqual(controller.timerCaptionTitle, "Таймер", "the window follows")
        XCTAssertEqual(NSApp.mainMenu?.items.map(\.title), ["Binaural", "Вид", "Справка"],
                       "the menu bar follows too")
    }

    /// SPEC §7.2's 44 px minimum click target. The control is a popup, not a slider, but the
    /// rule does not care. The layout pass is what gives the popup its height; before it,
    /// AppKit has not sized the row it lives in.
    func testTheControlKeepsTheMinimumClickTarget() throws {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let height = controller.languagePopupHeight
        XCTAssertGreaterThanOrEqual(height, 44, "the language popup is \(Int(height)) pt tall")
    }

    // MARK: - The dialog is gone

    /// `SettingsDialogController` is deleted from the source tree. The test no longer builds
    /// a dialog — which is the assertion that there is nothing left to build.
    func testNoSettingsDialogExistsAnymore() {
        XCTAssertNil(NSClassFromString("Binaural.SettingsDialogController"),
                     "the Settings dialog is retired; its language lives in the window")
    }
}