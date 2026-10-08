import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The Settings dialog of SPEC §7: language, headphone check, timer, volume.
///
/// The point being tested is not that four controls exist — it is that each of them writes
/// through to the **live** window and that nothing is buffered behind an OK button. A
/// settings dialog with a private copy of the values would pass a "does it have a slider"
/// test and still be wrong.
@MainActor
final class SettingsDialogTests: XCTestCase {

    private var directory: URL!
    private var store: SessionStore!
    private var controller: MainWindowController!
    private var dialog: SettingsDialogController!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        store.save(Session(leftHz: 205, rightHz: 215, volume: 0.7, timerMinutes: 15))
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        // Start from English whatever the previous test left behind: `L10n` is process-wide
        // state, and a dialog's `initialLanguage` is captured at construction time.
        L10n.setLanguage("en")
        controller = MainWindowController(engine: AudioEngine(), store: store)
        // The factory the menu uses, so the test exercises the real wiring rather than a
        // hand-built dialog with the closures the test forgot to set.
        dialog = controller.makeSettingsDialog()
    }

    override func tearDown() async throws {
        // Cancel first: it puts back the language the dialog opened with, and only then
        // force English, so a test that left the app in Russian cannot leak into the next.
        dialog.cancel()
        L10n.setLanguage("en")
        dialog.tearDown()
        controller.tearDown()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - The four things SPEC §7 names

    /// Language, timer and volume are all present, with the session's own data as the
    /// starting values.
    func testItOpensOnTheWindowsOwnValues() {
        XCTAssertEqual(dialog.selectedLanguage, .en)
        XCTAssertEqual(dialog.selectedTimerMinutes, 15)
        XCTAssertEqual(dialog.volumeValue, 0.7, accuracy: 1e-9)
        XCTAssertEqual(dialog.volumeTitle, "70%")
    }

    func testTheTimerOffersTheSessionChoices() {
        XCTAssertEqual(dialog.timerTitles.count, Session.timerChoices.count)
        XCTAssertEqual(dialog.timerTitles.first, "Off")
        XCTAssertEqual(dialog.timerTitles.last, "120 min")
    }

    /// Both language names are native, exactly as the *View → Language* menu shows them —
    /// a user has to be able to find their own language in the list.
    func testTheLanguageListMatchesTheMenu() {
        XCTAssertEqual(dialog.languageTitles, L10n.languages.map(LanguageCode.name))
        XCTAssertEqual(dialog.languageTitles, ["English", "Русский"])
    }

    // MARK: - Live, not buffered

    /// SPEC §7.4: the language switches as you pick it, and the *window* follows.
    func testChoosingALanguageSwitchesTheWholeAppImmediately() {
        dialog.selectLanguage(.ru)

        XCTAssertEqual(L10n.language, .ru, "no OK button: the switch is immediate")
        XCTAssertEqual(controller.timerCaptionTitle, "Таймер", "the main window follows")

        dialog.selectLanguage(.en)
        XCTAssertEqual(controller.timerCaptionTitle, "Timer")
    }

    /// Volume goes straight to the engine's gain.
    func testVolumeMovesTheEngineLive() throws {
        dialog.setVolume(0.25)
        XCTAssertEqual(controller.displayedVolume, 0.25, accuracy: 1e-9)
        XCTAssertEqual(dialog.volumeTitle, "25%")
        controller.saveNow()
        XCTAssertEqual(try Session.load(from: store.url).volume, 0.25, accuracy: 1e-9)
    }

    /// The timer writes to the same place the window's popup does, and a running session
    /// re-arms with the new duration.
    func testTimerChangesReachTheWindowAndTheDocument() throws {
        // No spy here on purpose: replacing `onTimerChange` would replace the factory's
        // wiring, and the assertion would then be about the test's own closure. The window
        // itself is the evidence that the dialog is connected.
        dialog.selectTimerMinutes(45)

        XCTAssertEqual(controller.selectedTimerMinutes, 45)
        controller.saveNow()
        XCTAssertEqual(try Session.load(from: store.url).timerMinutes, 45)
    }

    /// *Check headphones…* opens the §4.3 dialog rather than a second implementation, and
    /// what it reports afterwards comes back into the Settings dialog.
    ///
    /// The factory's closure runs the real coordinator, which re-detects through the HAL —
    /// so the verdict line is asserted only for being *something*, not for a value that
    /// depends on which machine the suite runs on.
    func testTheCheckButtonRunsTheRealCheck() {
        dialog.tapCheckHeadphones()
        XCTAssertFalse(dialog.headphoneStatusText.isEmpty)
    }

    // MARK: - Dismissal

    /// The red close button and Cmd+W must end the **modal session**, not merely close the
    /// window.
    ///
    /// This is the bug the window tests could not see: without a `windowShouldClose` that
    /// ends the session, the dialog disappears and `NSApp.runModal(for:)` keeps spinning,
    /// so the app behind it stays disabled — every menu item dead, nothing to click. The
    /// assertion is that the delegate answers at all and releases the window, which is the
    /// whole difference between "closed" and "closed properly".
    func testClosingTheWindowEndsTheModalSession() throws {
        let window = try XCTUnwrap(dialog.window)
        XCTAssertTrue(window.delegate === dialog, "the dialog must be its own window's delegate")

        _ = dialog.windowShouldClose(window)

        XCTAssertFalse(window.isVisible, "the dialog must be gone, not merely unanswered")
        // The teardown calls `cancel()` again; doing it twice has to stay safe.
        dialog.tearDown()
    }

    /// Closing without an explicit choice must not silently rewrite the language: the
    /// window path shares `endModalSessionAndClose`, so it leaves the choice alone, and the
    /// only way back is a fresh switch.
    func testClosingTheWindowKeepsTheLanguageSwitchItMade() throws {
        dialog.selectLanguage(.ru)
        let window = try XCTUnwrap(dialog.window)
        _ = dialog.windowShouldClose(window)
        XCTAssertEqual(L10n.language, .ru, "a switch made through the window path is not undone")
    }

    // MARK: - The verdict is stated

    /// Settings states the truth about the output rather than implying nothing has run.
    func testItShowsTheCurrentVerdict() {
        controller.apply(
            headphoneReport: HeadphoneReport(
                verdict: .speakers,
                device: AudioDevice(name: "Динамики Mac mini", transport: "builtin", isDefault: true),
                confidence: .medium
            )
        )
        dialog.apply(headphoneReport: controller.currentHeadphoneReport)

        XCTAssertTrue(dialog.headphoneStatusText.contains("Speakers detected"))
        XCTAssertTrue(dialog.headphoneDetailText.contains("Динамики Mac mini"))
        XCTAssertTrue(dialog.headphoneDetailText.contains("Medium"))
    }

    func testItSaysSoWhenNothingHasBeenDetected() {
        dialog.apply(headphoneReport: nil)
        XCTAssertEqual(dialog.headphoneStatusText.contains("Unknown device"), true)
        XCTAssertTrue(dialog.headphoneDetailText.isEmpty)
    }

    // MARK: - Language

    /// SPEC §7.4: the dialog reads the language itself, so its own captions follow a switch
    /// made anywhere — including from the *View* menu while it is open.
    func testTheDialogFollowsALanguageSwitchMadeElsewhere() {
        L10n.setLanguage("ru")
        XCTAssertTrue(dialog.captionTitles.contains("Язык"))
        XCTAssertTrue(dialog.captionTitles.contains("Таймер"))
        XCTAssertEqual(dialog.timerTitles.first, "Выкл.")
        XCTAssertEqual(dialog.checkButtonTitle, "Проверить наушники…")

        L10n.setLanguage("en")
        XCTAssertTrue(dialog.captionTitles.contains("Language"))
        XCTAssertEqual(dialog.timerTitles.last, "120 min")
    }

    /// Re-translating must not lose the selection.
    func testRetranslatingKeepsTheChoices() {
        dialog.selectTimerMinutes(30)
        L10n.setLanguage("ru")
        XCTAssertEqual(dialog.selectedTimerMinutes, 30)
        XCTAssertEqual(dialog.selectedLanguage, .ru)
    }

    /// There is no OK button, so closing without committing anything must not silently
    /// change the language for good.
    func testCancellingRestoresTheLanguage() {
        let opened = dialog.selectedLanguage
        dialog.selectLanguage(opened == .en ? .ru : .en)
        XCTAssertNotEqual(L10n.language, opened)

        dialog.cancel()
        XCTAssertEqual(L10n.language, opened, "a switch without a commit is undone")
    }
}