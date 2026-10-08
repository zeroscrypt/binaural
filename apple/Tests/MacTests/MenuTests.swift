import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The menu bar of SPEC §7, and one detail that is easy to get wrong.
///
/// The catalogue is shared with the Qt implementation, where `&` marks the mnemonic of a
/// menu item (`&View`). **AppKit has no meaning for `&`**: it draws it literally, so every
/// title in this menu used to read `&View`, `&Help`, `&About` with a visible ampersand.
/// AppKit's own marker is `_`. ``AppDelegate/menuTitle(_:)`` rewrites it at the single
/// boundary where a translated string becomes a menu title.
///
/// The tests assert the titles of the real `NSApp.mainMenu`, which the app delegate built
/// in `applicationWillFinishLaunching` — the menu a user actually clicks, not a
/// reconstruction. A test that only checked the helper would pass with the helper
/// unwired, which is the failure this came from.
@MainActor
final class MenuTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Titles of a top-level menu, in bar order: `["Binaural", "_View", "_Help"]`.
    private func topLevelTitles() -> [String] {
        (NSApp.mainMenu?.items ?? []).map(\.title)
    }

    /// Every title in the whole tree, submenus included.
    private func everyTitle(in menu: NSMenu) -> [String] {
        menu.items.flatMap { [$0.title] + (($0.submenu).map { everyTitle(in: $0) } ?? []) }
    }

    private func allTitles() -> [String] {
        guard let main = NSApp.mainMenu else { return [] }
        return topLevelTitles() + everyTitle(in: main)
    }

    // MARK: - The bug

    /// No title may carry a literal `&`: AppKit renders it, it does not interpret it.
    func testNoMenuTitleShowsALiteralAmpersand() {
        let offenders = allTitles().filter { $0.contains("&") }
        XCTAssertTrue(
            offenders.isEmpty,
            "a literal '&' in a menu title — AppKit spells the mnemonic '_':\n"
                + offenders.joined(separator: "\n")
        )
    }

    /// …and the mnemonic is not merely deleted: it is AppKit's marker, on the right letter.
    func testTheMnemonicIsAppKitsUnderscore() {
        XCTAssertTrue(topLevelTitles().contains("_View"), "\(topLevelTitles())")
        XCTAssertTrue(topLevelTitles().contains("_Help"), "\(topLevelTitles())")
    }

    /// The menu keeps its shape: the application menu, *View* and *Help*, with *Language*
    /// under *View* and the three §7 dialogs under *Help*.
    func testTheMenuHasTheThreeTopLevelMenus() {
        XCTAssertEqual(topLevelTitles().count, 3, "\(topLevelTitles())")
        let view = NSApp.mainMenu?.items[1].submenu
        XCTAssertEqual(view?.items.first?.title, "Language")
        let help = NSApp.mainMenu?.items[2].submenu
        let helpTitles = help?.items.map(\.title) ?? []
        XCTAssertTrue(helpTitles.contains("Frequency _reference…"), "\(helpTitles)")
        XCTAssertTrue(helpTitles.contains("_Check headphones…"), "\(helpTitles)")
        XCTAssertTrue(helpTitles.contains("_About"), "\(helpTitles)")
    }

    /// The application menu is where macOS puts Settings: `Cmd-,` plus Quit.
    func testSettingsSitsInTheApplicationMenu() {
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let titles = (appMenu?.items ?? []).map(\.title)
        XCTAssertEqual(titles, ["Settings…", "", "Quit"], "\(titles)")
        XCTAssertEqual(appMenu?.items.first?.keyEquivalent, ",")
        XCTAssertEqual(appMenu?.items.last?.keyEquivalent, "q")
    }

    // MARK: - Both languages

    /// The marker is rewritten after translation, so the Russian titles carry it too —
    /// `&` → `_` applies to `&Справка` just as it does to `&Help`.
    func testTheRussianTitlesCarryTheAppKitMnemonicAndNoAmpersand() {
        L10n.setLanguage("ru")
        let titles = topLevelTitles()
        XCTAssertTrue(titles.contains("_Вид"), "\(titles)")
        XCTAssertTrue(titles.contains("_Справка"), "\(titles)")
        let offenders = allTitles().filter { $0.contains("&") }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    /// A language switch re-reads every title, mnemonic included: `retranslateMenus()` runs
    /// through the same helper, so the marker cannot survive in one language only.
    func testSwitchingLanguageRewritesTheMnemonicToo() {
        L10n.setLanguage("ru")
        L10n.setLanguage("en")
        XCTAssertTrue(topLevelTitles().contains("_View"), "\(topLevelTitles())")
    }

    /// The helper itself, including the rule that matters: `&` is replaced **everywhere**,
    /// not only at the front.
    func testTheHelperRewritesEveryMarker() {
        XCTAssertEqual(AppDelegate.menuTitle("&View"), "_View")
        XCTAssertEqual(AppDelegate.menuTitle("Frequency &reference…"), "Frequency _reference…")
        XCTAssertEqual(AppDelegate.menuTitle("Quit"), "Quit")
        XCTAssertEqual(AppDelegate.menuTitle("Settings…"), "Settings…")
    }

    /// A title with no marker passes through untouched — a plain caption must not gain one.
    func testATitleWithoutAMarkerIsUnchanged() {
        for key in ["Play", "Stop", "Volume", "Language", "Binaural"] {
            XCTAssertEqual(AppDelegate.menuTitle(key), key)
        }
    }
}