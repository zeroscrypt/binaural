import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The menu-bar status item — the role `TrayController` plays in Python
/// (`src/binaural/ui/tray.py`).
///
/// An `NSStatusBar` item needs a real login session, so the tests do not install one:
/// what is verified is the part that can be wrong, which is the **menu** (captions,
/// translate, route) and the **window contract** it depends on (a close hides instead of
/// destroying, the window survives, the tooltip follows the transport). The install itself
/// was verified by launching the app and reading the item's menu through System Events.
@MainActor
final class StatusItemTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    // MARK: - The menu

    /// M2.md §9 asks for show/hide and Quit; Python's tray also carries Play/Stop, the
    /// headphone check and the reference, and this one does too — a closed window must not
    /// take the app's controls with it.
    func testTheMenuCarriesShowHideAndQuit() {
        let tray = StatusItemController()
        XCTAssertFalse(tray.isInstalled, "nothing is installed until install()")
        tray.buildMenu()
        tray.setWindowVisible(false)   // hidden, so the caption says what the click will do
        let titles = tray.menuTitles()
        XCTAssertTrue(titles.contains("Show Binaural"))
        XCTAssertTrue(titles.contains("Quit"))
    }

    func testTheMenuAlsoCarriesTheTrayRoleItems() {
        let tray = StatusItemController()
        tray.buildMenu()
        let titles = tray.menuTitles()
        for expected in ["Play", "Check headphones…", "Frequency reference…"] {
            XCTAssertTrue(titles.contains(expected), "missing \(expected): \(titles)")
        }
    }

    /// Every action routes through a closure the host installed — the tray never touches the
    /// audio engine itself (Python's "the window stays the single source of truth").
    func testEveryActionReachesItsHandler() {
        let tray = StatusItemController()
        tray.buildMenu()
        var toggles = 0, plays = 0, checks = 0, references = 0, quits = 0
        tray.onToggleWindow = { toggles += 1 }
        tray.onTogglePlayback = { plays += 1 }
        tray.onCheckHeadphones = { checks += 1 }
        tray.onOpenReference = { references += 1 }
        tray.onQuit = { quits += 1 }

        tray.press(toggle: true, play: true, check: true, reference: true, quit: true)
        XCTAssertEqual([toggles, plays, checks, references, quits], [1, 1, 1, 1, 1])
    }

    /// Pressing a menu item with no handler installed must be harmless — Python's "never
    /// fatal" rule, and the reason `TrayController` degrades to a no-op instead of a crash.
    func testActionsWithoutHandlersAreHarmless() {
        let tray = StatusItemController()
        tray.buildMenu()
        tray.press(toggle: true, play: true, check: true, reference: true, quit: true)
        XCTAssertFalse(tray.isInstalled)
    }

    // MARK: - Captions and state

    /// Show becomes Hide and back, so the caption always says what the click will do.
    func testTheToggleCaptionFollowsTheWindow() {
        let tray = StatusItemController()
        tray.buildMenu()
        tray.setWindowVisible(true)
        XCTAssertEqual(tray.toggleTitle, "Hide Binaural")
        tray.setWindowVisible(false)
        XCTAssertEqual(tray.toggleTitle, "Show Binaural")
    }

    func testThePlayCaptionFollowsTheTransport() {
        let tray = StatusItemController()
        tray.buildMenu()
        tray.reportPlayback(isPlaying: false, leftHz: 205, rightHz: 215, beatHz: 10)
        XCTAssertEqual(tray.playTitle, "Play")
        tray.reportPlayback(isPlaying: true, leftHz: 205, rightHz: 215, beatHz: 10)
        XCTAssertEqual(tray.playTitle, "Stop")
    }

    /// Python's tray tooltip: the pair, and the beat while playing.
    func testTheTooltipStatesTheFrequencies() {
        let tray = StatusItemController()
        tray.buildMenu()
        tray.setWindowVisible(true)
        tray.install()
        tray.reportPlayback(isPlaying: false, leftHz: 205.5, rightHz: 215.25, beatHz: 9.75)
        // The same formatting the window's readouts use (`FrequencyGrid.text`), not a
        // second opinion: 205.0 hertz is shown as "205".
        XCTAssertEqual(tray.tooltip, L10n.tr("⏹ %1 / %2 Hz", "205.5", "215.2"))
        tray.reportPlayback(isPlaying: true, leftHz: 205.5, rightHz: 215.25, beatHz: 9.75)
        XCTAssertEqual(
            tray.tooltip, L10n.tr("▶ %1 / %2 Hz — beat %3 Hz", "205.5", "215.2", "9.8")
        )
        tray.uninstall()
    }

    /// SPEC §7.4: the tray follows the language like everything else. `ru.py` already has
    /// "Show Binaural", "Hide Binaural" and both tooltips for exactly this menu.
    func testTheCaptionsFollowTheLanguage() {
        let tray = StatusItemController()
        tray.buildMenu()
        tray.setWindowVisible(false)
        L10n.setLanguage("ru")
        tray.retranslate()
        XCTAssertEqual(tray.toggleTitle, "Показать Binaural")
        XCTAssertEqual(tray.quitTitle, "Выход")
        L10n.setLanguage("en")
        tray.retranslate()
        XCTAssertEqual(tray.quitTitle, "Quit")
    }

    func testInstallingAndUninstallingIsIdempotent() {
        let tray = StatusItemController()
        tray.install()
        XCTAssertTrue(tray.isInstalled)
        tray.install()
        XCTAssertTrue(tray.isInstalled, "a second install must not add a second item")
        tray.uninstall()
        XCTAssertFalse(tray.isInstalled)
        tray.uninstall()
        XCTAssertFalse(tray.isInstalled, "uninstalling twice must be harmless")
    }

    // MARK: - The window contract the tray needs

    /// The tray can only bring back a window that was hidden rather than destroyed.
    func testTheWindowSurvivesBeingHidden() {
        let controller = MainWindowController(
            engine: AudioEngine(),
            store: SessionStore(url: temporaryStoreURL())
        )
        controller.showAndActivateForTests()

        controller.setWindowVisible(false)
        XCTAssertFalse(controller.isWindowOnScreen)

        controller.setWindowVisible(true)
        XCTAssertTrue(controller.isWindowOnScreen)
        XCTAssertEqual(controller.displayedFrequencies.left, 205, "state survived the round trip")
        controller.tearDown()
    }

    /// Hiding does not stop playback: the window is the remote control, not the player.
    func testHidingTheWindowDoesNotStopPlayback() {
        let controller = MainWindowController(
            engine: AudioEngine(),
            store: SessionStore(url: temporaryStoreURL())
        )
        controller.showAndActivateForTests()
        controller.setWindowVisible(false)
        XCTAssertFalse(controller.isPlaying, "nothing started it; still nothing stopped it")
        XCTAssertEqual(controller.selectedTimerMinutes, 15, "the countdown survives")
        controller.tearDown()
    }

    /// The window reports its transport and frequencies to whoever is listening, so the
    /// tooltip is the window's own numbers rather than a second copy of them.
    func testTheWindowPublishesItsTransportState() {
        let controller = MainWindowController(
            engine: AudioEngine(),
            store: SessionStore(url: temporaryStoreURL())
        )
        var published: [(Bool, Double, Double, Double)] = []
        controller.setStatusItemHandler { playing, left, right, beat in
            published.append((playing, left, right, beat))
        }
        controller.setFrequency(300, for: .left)
        controller.setFrequency(320, for: .right)

        XCTAssertFalse(published.isEmpty)
        let last = published[published.count - 1]
        XCTAssertEqual(last.1, 300, accuracy: 1e-9)
        XCTAssertEqual(last.2, 320, accuracy: 1e-9)
        XCTAssertEqual(last.3, 20, accuracy: 1e-9, "the beat follows the displayed pair")
        controller.tearDown()
    }

    /// A close must hide, not destroy: with a tray item present the app keeps running
    /// (Python's `setQuitOnLastWindowClosed(False)`).
    func testClosingTheWindowHidesItInsteadOfDestroyingIt() {
        let controller = MainWindowController(
            engine: AudioEngine(),
            store: SessionStore(url: temporaryStoreURL())
        )
        var closeRequests = 0
        controller.setWindowCloseHandler { closeRequests += 1 }
        controller.showAndActivateForTests()

        let shouldClose = controller.windowShouldCloseForTests(controller.window!)
        XCTAssertFalse(shouldClose, "the window must not close itself")
        XCTAssertEqual(closeRequests, 1, "the close was turned into a hide")
        controller.tearDown()
    }

    private func temporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-tray-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(SessionStore.fileName)
    }
}