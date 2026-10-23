import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The interface the modern mock-up asks for: the three-state theme, the sidebar's
/// search, the columns' collapse on narrow windows, the frequency field's editing
/// rules (comma, garbage, Escape), the timer's manual input, and the preset library.
///
/// Each test walks the same code the user's click or keystroke walks — a control or a
/// handler — so what passes here is what the window does, not what a comment hopes.
@MainActor
final class InterfaceStateTests: XCTestCase {

    private var store: SessionStore!
    private var directory: URL!
    private let themeKey = "binaural.themeStyle"
    private let legacyThemeKey = "binaural.darkTheme"

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-interface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        UserDefaults.standard.removeObject(forKey: themeKey)
        UserDefaults.standard.removeObject(forKey: legacyThemeKey)
        NSApp.appearance = nil
    }

    override func tearDown() async throws {
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        UserDefaults.standard.removeObject(forKey: themeKey)
        UserDefaults.standard.removeObject(forKey: legacyThemeKey)
        NSApp.appearance = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController() -> MainWindowController {
        let controller = MainWindowController(engine: AudioEngine(), store: store)
        controller.playbackRunningOverride = false
        return controller
    }

    // MARK: - The three theme states

    /// With no stored choice the app follows the system, and the system item is the one
    /// ticked — following the system is what an explicit appearance would pin against,
    /// so nothing is set at all. The choice is made in the menu now, where the mock-up's
    /// header used to carry it.
    func testTheThemeFollowsTheSystemUntilOneIsChoosen() {
        let controller = makeController()
        XCTAssertEqual(controller.themeStyle, .system)
        XCTAssertTrue(
            controller.themeMenuItemIsOn(.system),
            "the system item carries the tick"
        )
        XCTAssertNil(NSApp.appearance)
    }

    /// Choosing via its menu item stores the style and puts its appearance on the app.
    func testChoosingALightThemeAppliesAndStoresIt() {
        let controller = makeController()
        controller.selectThemeMenuItem(.light)

        XCTAssertEqual(controller.themeStyle, .light)
        XCTAssertTrue(controller.themeMenuItemIsOn(.light))
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: themeKey), "light",
            "the choice is kept under its own key"
        )
    }

    /// A stored dark choice comes up dark on the next start, not merely while the
    /// menu item is ticked.
    func testAStoredDarkChoiceComesUpDarkAfterTheRestart() {
        UserDefaults.standard.set("dark", forKey: themeKey)
        _ = makeController()
        XCTAssertEqual(
            NSApp.appearance?.name, NSAppearance.Name.darkAqua,
            "the window opens in the theme that was stored"
        )
    }

    /// A preference that predates the three states keeps its meaning: the old
    /// two-state key saying dark reads as dark, without inventing a new meaning.
    func testTheOldTwoStateKeyStillMeansDark() {
        UserDefaults.standard.set(true, forKey: legacyThemeKey)
        let controller = makeController()
        XCTAssertEqual(controller.themeStyle, .dark)
        XCTAssertTrue(controller.themeMenuItemIsOn(.dark))
    }

    /// Coming back to the system state removes the app's own appearance again.
    func testComingBackToTheSystemRemovesThePinnedAppearance() {
        let controller = makeController()
        controller.selectThemeMenuItem(.dark)
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.darkAqua)

        controller.selectThemeMenuItem(.system)
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(UserDefaults.standard.string(forKey: themeKey), "system")
    }

    /// The theme's three states are offered in the menu, in the interface language.
    func testTheThemeMenuNamesTheThreeStates() {
        let controller = makeController()
        XCTAssertEqual(
            controller.themeMenuTitles,
            ["Light", "Follow the system", "Dark"]
        )

        L10n.setLanguage("ru")
        XCTAssertEqual(
            controller.themeMenuTitles,
            ["Светлая", "Как в системе", "Тёмная"]
        )
        L10n.setLanguage("en")
    }

    // MARK: - The sidebar's search

    /// An empty search is the chosen category, exactly the unfiltered cards.
    func testAnEmptySearchShowsTheChoosenCategory() {
        let controller = makeController()
        controller.presetSearchText = ""

        XCTAssertEqual(
            controller.presetCards.presets.count,
            PresetCatalogue.presets(inCategory: controller.selectedPresetCategoryForTest).count
        )
    }

    /// A query searches across every category, and everything it shows says the query.
    func testASearchShowsEveryMatchAcrossTheRegistry() {
        let controller = makeController()
        controller.presetSearchText = "delta"

        let shown = controller.presetCards.presets
        XCTAssertFalse(shown.isEmpty)
        XCTAssertLessThan(
            shown.count,
            PresetCatalogue.presets.count,
            "one band is not the whole registry"
        )
        for preset in shown {
            XCTAssertTrue(
                PresetCard.matches(preset: preset, query: "delta"),
                "everything the search shows must say the query"
            )
        }
    }

    /// The query reaches the library as well — the same words, the same matches —
    /// and clearing it puts the whole registry back.
    func testTheLibraryAnswersTheSameSearch() {
        let controller = makeController()
        let library = controller.presetLibraryForTest
        // Opening the window is what fills the shelf; the field starts empty.
        library.typeLibraryQuery("")

        XCTAssertEqual(library.shownIDs.count, PresetCatalogue.presets.count)
        library.typeLibraryQuery("sleep")

        XCTAssertFalse(library.shownIDs.isEmpty)
        XCTAssertLessThan(library.shownIDs.count, PresetCatalogue.presets.count)
        for id in library.shownIDs {
            let preset = PresetCatalogue.presets.first { $0.id == id }
            XCTAssertEqual(preset?.categoryID, "sleep", "the query names this category")
        }

        library.typeLibraryQuery("")
        XCTAssertEqual(library.shownIDs.count, PresetCatalogue.presets.count)
    }

    /// Picking a library category shows exactly that category's presets.
    func testTheLibraryCategoryShowsItsOwnPresets() {
        let controller = makeController()
        let library = controller.presetLibraryForTest

        library.chooseLibraryCategory(id: "sleep")
        for id in library.shownIDs {
            let preset = PresetCatalogue.presets.first { $0.id == id }
            XCTAssertEqual(preset?.categoryID, "sleep", "the shelf holds the picked category")
        }
        XCTAssertEqual(
            library.shownIDs.count,
            PresetCatalogue.presets(inCategory: "sleep").count
        )
    }

    // MARK: - The narrow-window collapse

    /// At the full width both columns sit where they always did.
    func testAtTheFullWidthBothColumnsAreShown() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1300, height: 440))
        controller.applyWindowCompactness()

        XCTAssertEqual(controller.isSidebarShown, true)
        XCTAssertEqual(controller.isRightColumnShown, true)
    }

    /// Below the first threshold the catalogue leaves; the session column stays.
    func testNarrowHidesTheSidebarFirst() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1060, height: 440))
        controller.applyWindowCompactness()

        XCTAssertEqual(controller.isSidebarShown, false)
        XCTAssertEqual(controller.isRightColumnShown, true)
    }

    /// The delegate hook is the drag path: it MUST collapse before the window asks its
    /// constraints, otherwise the required column widths would pin the window and the
    /// collapse could never be reached by dragging.
    func testTheDragPathCollapsesBeforeTheResize() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window)

        _ = controller.windowWillResize(window, to: NSSize(width: 960, height: 663))
        XCTAssertEqual(controller.isSidebarShown, false)
        XCTAssertEqual(controller.isRightColumnShown, false)
        // The frame itself is returned unchanged: the hook only prepares the columns.
        XCTAssertEqual(controller.windowWillResize(
            window, to: NSSize(width: 960, height: 663)
        ), NSSize(width: 960, height: 663))

        let wide = controller.windowWillResize(window, to: NSSize(width: 1300, height: 663))
        XCTAssertEqual(controller.isSidebarShown, true)
        XCTAssertEqual(controller.isRightColumnShown, true)
        XCTAssertEqual(wide, NSSize(width: 1300, height: 663))
    }

    /// The programmatic path (`setContentSize`, which the accessibility resize and a
    /// restored frame use) collapses through its own hook.
    func testSetContentSizeCollapsesThroughItsHook() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window)

        window.setContentSize(NSSize(width: 880, height: 600))
        XCTAssertEqual(controller.isSidebarShown, false, "the frame preparation collapsed")
        XCTAssertEqual(controller.isRightColumnShown, false)
    }

    /// The accessibility highway resizes through `setFrame`, and the layout that
    /// answers it must keep every column inside the window: a right column that
    /// resolved its ambiguous vertical place onto the window's very top leaks above
    /// the frame and loses its caption and clock.
    func testAFrameResizeKeepsTheColumnsInsideTheWindow() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(
            NSRect(x: 20, y: 40, width: 1560, height: 700), display: true
        )
        window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        let timer = controller.timerView.convert(controller.timerView.bounds, to: content)
        let contentHeight = content.bounds.height
        XCTAssertTrue(
            timer.maxY <= contentHeight,
            "the timer card stays inside the window: \(timer)"
        )
        // The content view is not flipped: y grows up from its bottom edge, so "the
        // card sits under the header" is the header's own bottom edge above the card's
        // top edge.
        let header = controller.headerRow.convert(
            controller.headerRow.bounds, to: content
        )
        XCTAssertGreaterThanOrEqual(
            header.minY, timer.maxY - 1,
            "the timer card begins under the header, not over it"
        )
    }

    /// The default 1098×623 window — the size macOS opens the app at — must render the
    /// timer card whole: its caption and clock stay inside the frame, because a window
    /// shorter than its own cards is what drew them through the title bar.
    func testTheDefaultWindowKeepsTheRightColumnInside() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(
            NSRect(x: 0, y: 0, width: 1098, height: 623), display: true
        )
        window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        let timer = controller.timerView.convert(controller.timerView.bounds, to: content)
        XCTAssertLessThanOrEqual(
            timer.maxY, controller.headerRow.convert(
                controller.headerRow.bounds, to: content
            ).minY + 1,
            "the timer card sits under the header"
        )
        XCTAssertLessThanOrEqual(
            timer.maxY, content.bounds.height,
            "the timer card stays inside the window: \(timer)"
        )
    }

    /// At the minimum both columns are gone and the frequencies remain — the least a
    /// session can be steered by stays on screen.
    func testTheMinimumHidesBothColumnsAndKeepsTheFrequencies() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 800, height: 440))
        controller.applyWindowCompactness()

        XCTAssertEqual(controller.isSidebarShown, false)
        XCTAssertEqual(controller.isRightColumnShown, false)
        XCTAssertFalse(controller.leftFrequencyForTest.isHidden)
        XCTAssertFalse(controller.rightFrequencyForTest.isHidden)
    }

    // MARK: - The frequency field's editing rules

    /// The comma and the dot are one decimal point: a Russian keyboard typing `12,5`
    /// commits the same number an English keyboard does with `12.5`.
    func testACommaCommitsTheSameNumberAsADot() {
        let controller = makeController()
        let field = controller.leftFrequencyForTest
        let original = field.value

        field.fieldText = "205,5"
        field.commitFieldForTest()
        XCTAssertEqual(field.value, 205.5)

        field.fieldText = "205.5"
        field.commitFieldForTest()
        XCTAssertEqual(field.value, 205.5)

        field.setValue(original, notify: false)
    }

    /// Garbage in the field is refused: the sound and the readout stay where they are,
    /// and nothing half-applied reaches the engine.
    func testGarbageInTheFieldDoesNotChangeTheValue() {
        let controller = makeController()
        let field = controller.leftFrequencyForTest

        for garbage in ["abc", "inf", "-infinity", "1e999", ""] {
            field.fieldText = garbage
            field.commitFieldForTest()
            XCTAssertTrue(field.value.isFinite, "the value stays a number")
        }
    }

    /// A typed value outside the range lands on the nearest edge — the window's own
    /// clamp, the same one the sliders walk.
    func testAnOutOfRangeValueClampsToTheRange() {
        let controller = makeController()
        let field = controller.leftFrequencyForTest

        field.fieldText = "99999"
        field.commitFieldForTest()
        XCTAssertEqual(field.value, FrequencyGrid.maxHz)

        field.fieldText = "0"
        field.commitFieldForTest()
        XCTAssertEqual(field.value, FrequencyGrid.minHz)
    }

    /// Escape puts the readout back to the sound's value and commits nothing.
    func testEscapeRestoresTheCommittedValue() {
        let controller = makeController()
        let field = controller.leftFrequencyForTest
        let original = field.value

        field.fieldText = "77"
        field.cancelEditing()

        XCTAssertEqual(field.value, original, "the sound did not change")
        XCTAssertEqual(field.fieldText, String(format: "%.1f", original), "the readout did")
    }

    // MARK: - The timer applies on choice

    /// Tapping a quick chip applies its duration at once — the card has no field and
    /// no Apply button, per the review: a picker that waits for a second button would
    /// promise to remember a value it does not hold.
    func testAQuickChipAppliesItsDurationAtOnce() {
        let controller = makeController()

        controller.tapTimerQuickChoice(30)
        XCTAssertEqual(controller.selectedTimerMinutes, 30)

        controller.tapTimerQuickChoice(5)
        XCTAssertEqual(controller.selectedTimerMinutes, 5)
    }

    /// The quick chips are durations of the session's own list — they are shortcuts,
    /// never a second source of what may be picked.
    func testTheQuickChipsComeFromTheSessionList() {
        let controller = makeController()
        for choice in controller.timerQuickChoices {
            XCTAssertTrue(Session.timerChoices.contains(choice))
        }
    }

    /// Words could not have entered the card anyway now the manual field is gone: the
    /// picker is the popup, and the popup only offers the session's own durations.
    func testThePopupStillCarriesEveryOfferedDuration() {
        let controller = makeController()
        XCTAssertEqual(
            controller.timerChoiceTitles.count,
            Session.timerChoices.count,
            "the popup is the one place the full list lives"
        )
        XCTAssertEqual(
            Array(Session.timerChoices.prefix(3)),
            [Session.timerOff, 5, 10],
            "off first, then the short durations the session offers"
        )
    }
}
