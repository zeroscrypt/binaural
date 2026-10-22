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

    /// The corner menu is an icon, so it has no caption. The accessibility label is
    /// still translated — that one is read aloud, not looked at.
    func testThereIsNoCaptionButTheAccessibilityLabelIsTranslated() {
        XCTAssertEqual(controller.languageTitles, ["English", "Русский"],
                       "the language names stay native, as they must")
        XCTAssertEqual(controller.cornerMenuAccessibilityLabel, "More")
        L10n.setLanguage("ru")
        XCTAssertEqual(controller.cornerMenuAccessibilityLabel, "Ещё")
    }

    /// SPEC §7: the top row carries the app's state — the headphone indicator and the
    /// mode's switch. The corner menu sits at the **right**, and the row is pinned to the
    /// top of the window.
    func testTheControlSitsAtTheTopRight() throws {
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        // The header carries the navigation, and the corner menu is the last thing in
        // it, at its right edge.
        let row = try XCTUnwrap(controller.headerRow)
        let titles = row.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("Reference"), "\(titles)")
        XCTAssertTrue(
            titles.contains(""), "the corner menu is an icon, so it has no title: \(titles)"
        )

        let rowFrame = row.convert(row.bounds, to: window.contentView)
        let menuFrame = controller.menuButtonFrame(in: window.contentView!)
        XCTAssertGreaterThan(
            menuFrame.minX, rowFrame.minX + rowFrame.width - menuFrame.width - 1,
            "the corner menu is the last thing in the row, at its right edge"
        )
        XCTAssertLessThan(menuFrame.maxY, rowFrame.maxY + 1, "the row is at the top")

        // The mode's trigger and its own switch live in the catalogue column, which is
        // where the mock-up puts the things that choose what will be played.
        let modeRow = try XCTUnwrap(controller.statusRow)
        let modeTitles = modeRow.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertEqual(modeTitles, ["Chakras", "On"], "\(modeTitles)")
    }

    /// The corner menu holds the three things that used to sit in the row as buttons: the
    /// headphone check, the frequency reference and the language.
    func testTheCornerMenuHoldsTheThreeThings() {
        let menu = controller.overflowMenuControl
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Check headphones…"), "\(titles)")
        XCTAssertTrue(titles.contains("Frequency reference…"), "\(titles)")
        XCTAssertTrue(titles.contains("Language"), "\(titles)")

        let language = try? XCTUnwrap(menu.items.first { $0.title == "Language" }?.submenu)
        XCTAssertEqual(language?.items.map(\.title), ["English", "Русский"])
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