import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The menu bar of SPEC §7, and one detail that is easy to get wrong.
///
/// The catalogue is shared with the Qt implementation, where `&` marks the mnemonic of a
/// menu item (`&View`). **AppKit has no meaning for `&`**: it draws it literally, so every
/// title in this menu used to read `&View`, `&Help`, `&About` with a visible ampersand.
/// ``AppDelegate/menuTitle(_:)`` strips it at the single boundary where a translated string
/// becomes a menu title — and strips it rather than substituting AppKit's own `_` marker,
/// because an underlined first letter is a look nobody asked for and the menu is fully
/// usable without a mnemonic.
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

    /// Titles of a top-level menu, in bar order.
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
            "a literal '&' in a menu title:\n" + offenders.joined(separator: "\n")
        )
    }

    /// …and no title carries AppKit's mnemonic marker either. The marker is **removed**,
    /// not substituted: an underlined first letter is not what this menu should look like.
    func testNoMenuTitleCarriesAMnemonicMarker() {
        let offenders = allTitles().filter { $0.hasPrefix("_") || $0.contains(" _") }
        XCTAssertTrue(
            offenders.isEmpty,
            "an AppKit mnemonic marker in a menu title:\n" + offenders.joined(separator: "\n")
        )
    }

    /// The menu keeps its shape: the application menu, *View* and *Help*, with *Language*
    /// under *View* and the three §7 dialogs under *Help*.
    func testTheMenuHasTheThreeTopLevelMenus() {
        XCTAssertEqual(topLevelTitles(), ["Binaural", "View", "Help"])
        let view = NSApp.mainMenu?.items[1].submenu
        XCTAssertEqual(view?.items.first?.title, "Language")
        let help = NSApp.mainMenu?.items[2].submenu
        let helpTitles = help?.items.map(\.title) ?? []
        XCTAssertTrue(helpTitles.contains("Frequency reference…"), "\(helpTitles)")
        XCTAssertTrue(helpTitles.contains("Check headphones…"), "\(helpTitles)")
        XCTAssertTrue(helpTitles.contains("About"), "\(helpTitles)")
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

    /// The marker is stripped after translation, so the Russian titles come out clean too —
    /// `&Справка` reads `Справка`, exactly as `&Help` reads `Help`.
    func testTheRussianTitlesCarryNoMarkerEither() {
        L10n.setLanguage("ru")
        let titles = topLevelTitles()
        XCTAssertTrue(titles.contains("Вид"), "\(titles)")
        XCTAssertTrue(titles.contains("Справка"), "\(titles)")
        let offenders = allTitles().filter { $0.contains("&") || $0.contains("_") }
        XCTAssertTrue(offenders.isEmpty, offenders.joined(separator: "\n"))
    }

    /// A language switch re-reads every title: `retranslateMenus()` runs through the same
    /// helper, so the marker cannot survive in one language only.
    func testSwitchingLanguageKeepsTheTitlesClean() {
        L10n.setLanguage("ru")
        L10n.setLanguage("en")
        XCTAssertEqual(topLevelTitles(), ["Binaural", "View", "Help"])
    }

    // MARK: - The helper itself

    /// Every occurrence is stripped, not only a leading one — the marker sits mid-word in
    /// `Frequency &reference…`.
    func testTheHelperStripsEveryMarker() {
        XCTAssertEqual(AppDelegate.menuTitle("&View"), "View")
        XCTAssertEqual(AppDelegate.menuTitle("Frequency &reference…"), "Frequency reference…")
        XCTAssertEqual(AppDelegate.menuTitle("&Check headphones…"), "Check headphones…")
        XCTAssertEqual(AppDelegate.menuTitle("&О программе"), "О программе")
    }

    /// A title with no marker passes through untouched.
    func testATitleWithoutAMarkerIsUnchanged() {
        for key in ["Play", "Stop", "Volume", "Language", "Binaural", "Quit"] {
            XCTAssertEqual(AppDelegate.menuTitle(key), key)
        }
    }
}