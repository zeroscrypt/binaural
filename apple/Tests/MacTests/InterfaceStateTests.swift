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

    /// With no stored choice the app follows the system, and the middle segment is the
    /// one lit — following the system is what an explicit appearance would pin against,
    /// so nothing is set at all.
    func testTheThemeFollowsTheSystemUntilOneIsChoosen() {
        let controller = makeController()
        XCTAssertEqual(controller.themeStyle, .system)
        XCTAssertTrue(
            controller.themeSegments.isSelected(forSegment: 1),
            "the middle segment says 'whatever the system says'"
        )
        XCTAssertNil(NSApp.appearance)
    }

    /// Clicking a segment stores the style and puts its appearance on the app.
    func testChoosingALightThemeAppliesAndStoresIt() {
        let controller = makeController()
        controller.chooseTheme(.light)

        XCTAssertEqual(controller.themeStyle, .light)
        XCTAssertTrue(controller.themeSegments.isSelected(forSegment: 0))
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.aqua)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: themeKey), "light",
            "the choice is kept under its own key"
        )
    }

    /// A stored dark choice comes up dark on the next start, not merely while the
    /// segment is lit.
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
        XCTAssertTrue(controller.themeSegments.isSelected(forSegment: 2))
    }

    /// Coming back to the system state removes the app's own appearance again.
    func testComingBackToTheSystemRemovesThePinnedAppearance() {
        let controller = makeController()
        controller.chooseTheme(.dark)
        XCTAssertEqual(NSApp.appearance?.name, NSAppearance.Name.darkAqua)

        controller.chooseTheme(.system)
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(UserDefaults.standard.string(forKey: themeKey), "system")
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

    // MARK: - The timer's manual input

    /// A typed duration lands on the nearest offered duration — the offered ones are
    /// data, so the popup keeps saying what can be clicked.
    func testATypedDurationSnapsToTheNearestOffer() {
        let controller = makeController()

        controller.typeTimerMinutes("17")
        XCTAssertEqual(controller.selectedTimerMinutes, 15)

        controller.typeTimerMinutes("52")
        XCTAssertEqual(controller.selectedTimerMinutes, 45)

        controller.typeTimerMinutes("999")
        XCTAssertEqual(controller.selectedTimerMinutes, Session.timerChoices.last ?? 120)
    }

    /// `0` switches the timer off, not onto some duration.
    func testZeroSwitchesTheTimerOff() {
        let controller = makeController()
        controller.typeTimerMinutes("20")
        XCTAssertEqual(controller.selectedTimerMinutes, 20)

        controller.typeTimerMinutes("0")
        XCTAssertEqual(controller.selectedTimerMinutes, Session.timerOff)
    }

    /// Words in the field leave the choice where it was — a bad answer is ignored,
    /// not half-applied.
    func testGarbageInTheManualFieldChangesNothing() {
        let controller = makeController()
        controller.typeTimerMinutes("30")
        XCTAssertEqual(controller.selectedTimerMinutes, 30)

        controller.typeTimerMinutes("abc")
        XCTAssertEqual(controller.selectedTimerMinutes, 30)
    }
}
