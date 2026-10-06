import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The preset bar as the window shows it (SPEC §7 layout, §5 F3 registry).
///
/// `PresetBarView` alone is covered here too, because the two levels it owns — the chips
/// and the write-back — only mean anything together with the window that persists them.
/// Clicks go through the buttons' own actions, so a chip wired to the wrong selector
/// fails here instead of passing because a test called the handler directly.
@MainActor
final class PresetBarTests: XCTestCase {

    private var store: SessionStore!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
    }

    override func tearDown() async throws {
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController(session: Session? = nil) -> MainWindowController {
        if let session { store.save(session) }
        return MainWindowController(engine: AudioEngine(), store: store)
    }

    // MARK: - It is in the window (SPEC §7)

    /// The reason this file exists: `PresetBarView` was written and tested but never
    /// instantiated. A chip row nobody can reach is not a feature.
    func testThePresetBarIsPartOfTheMainWindow() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let bar = controller.presetBarControl

        XCTAssertTrue(bar.isDescendant(of: window.contentView!),
                      "the preset bar must be in the window's content view")
        // …and laid out inside it, not merely attached: a zero-height bar is invisible.
        layout(window)
        XCTAssertGreaterThan(bar.frame.height, 44)
        // The bar asks for at least 520 pt; the window gives it the full content width.
        XCTAssertGreaterThanOrEqual(bar.frame.width, 520)
        XCTAssertLessThanOrEqual(bar.frame.maxY, window.contentView!.bounds.maxY)
    }

    /// Seven category chips, in F3's order, and the presets of the selected one.
    func testCategoryChipsAreShownInRegistryOrder() {
        let controller = makeController()
        XCTAssertEqual(controller.presetCategoryTitles,
                       ["Sleep", "Meditation", "Relaxation", "Awareness",
                        "Concentration", "Work", "Sport"])
    }

    func testPresetsShownAreThoseOfTheSelectedCategory() {
        let controller = makeController()
        // The default category is relaxation (F3), so the bar opens on Alpha 8/9/10.
        XCTAssertEqual(controller.visiblePresetTitles, ["Alpha 8", "Alpha 9", "Alpha 10"])

        controller.tapPresetCategory("sleep")
        XCTAssertEqual(controller.visiblePresetTitles, ["Delta 1", "Delta 2", "Delta 3"])

        controller.tapPresetCategory("concentration")
        XCTAssertEqual(controller.visiblePresetTitles, ["Beta 13", "Beta 14", "Beta 15"])
    }

    /// F3: a category chip is *state*, so it must be persisted like any other field.
    func testSelectingACategoryWritesItBackToTheSession() {
        let controller = makeController()
        controller.tapPresetCategory("sport")
        XCTAssertEqual(controller.selectedPresetCategory, "sport")
        XCTAssertEqual(controller.currentSession.presetCategory, "sport")
    }

    func testSelectedCategorySurvivesARelaunch() {
        let controller = makeController()
        controller.tapPresetCategory("work")
        controller.saveNow()

        let reloaded = MainWindowController(engine: AudioEngine(), store: store)
        XCTAssertEqual(reloaded.selectedPresetCategory, "work")
        XCTAssertEqual(reloaded.visiblePresetTitles, ["Beta 16", "Beta 18", "Beta 20"])
    }

    /// An unknown id in the settings file must not take the bar down.
    func testUnknownStoredCategoryFallsBackToTheDefault() {
        let controller = makeController(session: Session(presetCategory: "focus"))
        XCTAssertEqual(controller.selectedPresetCategory, "relaxation")
        XCTAssertEqual(controller.visiblePresetTitles, ["Alpha 8", "Alpha 9", "Alpha 10"])
    }

    // MARK: - Applying a preset (F3)

    /// F3's core promise: one click sets **both** channels so their difference is the
    /// preset's beat.
    func testClickingAPresetSetsBothFrequencies() {
        let controller = makeController()
        controller.tapPreset("relaxation-10")
        XCTAssertEqual(controller.displayedFrequencies.left, 195)
        XCTAssertEqual(controller.displayedFrequencies.right, 205)
        XCTAssertEqual(controller.beat.hz, 10, accuracy: 1e-9)
        XCTAssertEqual(controller.beat.carrier, 200, accuracy: 1e-9)
    }

    /// Every registry preset, not just the F3 example: the pair must always differ by
    /// exactly the beat and sit on the default carrier.
    func testEveryPresetInTheRegistrySetsTheRightPair() throws {
        let controller = makeController()
        for preset in PresetCatalogue.presets {
            controller.tapPreset(preset.id, inCategory: preset.categoryID)
            XCTAssertEqual(controller.displayedFrequencies.left,
                           200 - preset.beatHz / 2, accuracy: 1e-9, preset.id)
            XCTAssertEqual(controller.displayedFrequencies.right,
                           200 + preset.beatHz / 2, accuracy: 1e-9, preset.id)
        }
    }

    /// The beat readout must follow the click — the visible half of "shows what it did".
    func testTheBeatCardFollowsThePreset() {
        let controller = makeController(session: Session(leftHz: 100, rightHz: 900))
        controller.tapPreset("concentration-15", inCategory: "concentration")
        XCTAssertEqual(controller.beat.hz, 15, accuracy: 1e-9)
        XCTAssertEqual(controller.beat.carrier, 200, accuracy: 1e-9)
        XCTAssertFalse(controller.isShowingBeatHint, "a preset beat is inside the hint range")
    }

    /// The applied chip is highlighted, and the message says which beat was applied.
    func testAppliedPresetIsHighlightedAndAnnounced() {
        let controller = makeController()
        XCTAssertFalse(controller.isShowingPresetStatus)

        controller.tapPreset("relaxation-9")
        XCTAssertEqual(controller.highlightedPresetID, "relaxation-9")
        XCTAssertTrue(controller.isShowingPresetStatus)
        XCTAssertEqual(controller.presetStatusText, "Preset applied: difference 9 Hz")
    }

    /// Python stores the applied label in `last_preset`; here it is the preset id, so the
    /// chip comes back highlighted on the next launch.
    func testAppliedPresetIsRememberedForTheNextLaunch() {
        let controller = makeController()
        // The way a user does it: pick the category, then the preset. Only then does the
        // saved category put the chip back on screen for the highlight to show.
        controller.tapPresetCategory("meditation")
        controller.tapPreset("meditation-5")
        controller.saveNow()

        let reloaded = MainWindowController(engine: AudioEngine(), store: store)
        XCTAssertEqual(reloaded.highlightedPresetID, "meditation-5")
        XCTAssertEqual(reloaded.currentSession.lastPreset, "meditation-5")
        XCTAssertEqual(reloaded.beat.hz, 5, accuracy: 1e-9)
    }

    /// A stored preset outside the category being shown cannot be highlighted — the bar
    /// shows one category at a time, and inventing a highlight would be a lie.
    func testStoredPresetInAnotherCategoryIsNotHighlighted() {
        let controller = makeController(session: Session(lastPreset: "sport-28"))
        XCTAssertNil(controller.highlightedPresetID)
        XCTAssertEqual(controller.visiblePresetTitles, ["Alpha 8", "Alpha 9", "Alpha 10"])
    }

    // MARK: - Two levels are independent (F3)

    /// Changing the category never moves a frequency. Only the preset click does.
    func testChangingCategoryDoesNotTouchTheFrequencies() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        controller.tapPresetCategory("sleep")
        controller.tapPresetCategory("sport")
        XCTAssertEqual(controller.displayedFrequencies.left, 205)
        XCTAssertEqual(controller.displayedFrequencies.right, 215)
    }

    /// Pressing an unknown id is a no-op, not a crash or an empty row.
    func testUnknownPresetIdIsIgnored() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        XCTAssertFalse(controller.presetBarControl.tapPreset(id: "no-such-preset"))
        XCTAssertFalse(controller.presetBarControl.tapCategory(id: "focus"))
        XCTAssertEqual(controller.displayedFrequencies.left, 205)
        XCTAssertEqual(controller.displayedFrequencies.right, 215)
    }

    // MARK: - Language (SPEC §7.4)

    /// The chips are data, but their captions must follow the language like everything
    /// else — F3 carries both names, and the bar has to pick the right one.
    func testChipCaptionsFollowTheLanguage() {
        let controller = makeController()
        XCTAssertEqual(controller.presetCategoryTitles.first, "Sleep")
        XCTAssertEqual(controller.visiblePresetTitles.first, "Alpha 8")

        L10n.setLanguage("ru")
        XCTAssertEqual(controller.presetCategoryTitles,
                       ["Сон", "Медитация", "Расслабление", "Ясность",
                        "Сосредоточенность", "Работа", "Спорт"])
        XCTAssertEqual(controller.visiblePresetTitles, ["Альфа 8", "Альфа 9", "Альфа 10"])

        L10n.setLanguage("en")
        XCTAssertEqual(controller.presetCategoryTitles.first, "Sleep")
    }

    /// The confirmation message is a catalogue key, so it is translated too.
    func testTheAppliedMessageFollowsTheLanguage() {
        let controller = makeController()
        L10n.setLanguage("ru")
        controller.tapPreset("relaxation-10")
        XCTAssertEqual(controller.presetStatusText, "Пресет применён: разность 10 Гц")
    }

    // MARK: - The bar on its own

    /// The wrapping is the one piece of layout with real logic in it: seven chips do not
    /// fit one line in a narrow window, so the rows have to wrap without losing a chip.
    func testNarrowWindowWrapsChipsWithoutLosingAny() {
        let bar = PresetBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        content.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.frame = NSRect(x: 0, y: 0, width: 560, height: 200)

        layout(window)
        XCTAssertEqual(bar.categoryTitles.count, 7)
        XCTAssertEqual(bar.visiblePresetTitles.count, 3)
    }

    /// `select` does not notify — restoring a session must not look like a user click.
    func testSelectingProgrammaticallyDoesNotNotify() {
        let bar = PresetBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        var notified: [String] = []
        bar.onCategorySelected = { notified.append($0) }
        bar.select(categoryID: "work")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertEqual(bar.selectedCategory, "work")

        XCTAssertTrue(bar.tapCategory(id: "sport"))
        XCTAssertEqual(notified, ["sport"])
    }

    func testDefaultCategoryIsRelaxation() {
        let bar = PresetBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
        XCTAssertEqual(bar.selectedCategory, "relaxation")
        XCTAssertEqual(bar.visiblePresetTitles, ["Alpha 8", "Alpha 9", "Alpha 10"])
    }

    func testTeardownIsSafeToCallTwice() {
        let controller = makeController()
        controller.tapPreset("relaxation-10")
        controller.tearDown()
        controller.tearDown()
    }

    // MARK: - Helper

    /// Force one layout pass, so frame-based assertions mean something.
    private func layout(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }
}
