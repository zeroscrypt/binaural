import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The frequency reference as the user meets it: two columns, a filter list down the left
/// and cards down the right.
///
/// Every test here goes through the **real catalogue** (`src/binaural/data/frequencies.json`,
/// 11 categories and 110 records) rather than a stub of three entries, because the two bugs
/// worth catching are both about scale: a sidebar taller than its scroll view, and a click
/// that lands nowhere.
@MainActor
final class ReferenceDialogTests: XCTestCase {

    /// `<repo>/src/binaural/data/frequencies.json` — located through `#filePath` so the
    /// tests always read the file being edited.
    private static func catalogue() throws -> FrequencyCatalogue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try FrequencyCatalogue(
            contentsOf: root.appendingPathComponent("src/binaural/data/frequencies.json")
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A dialog with a laid-out window at `size`.
    private func makeDialog(
        size: NSSize = NSSize(width: 960, height: 680)
    ) throws -> (ReferenceDialogController, NSWindow) {
        let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
        let window = try XCTUnwrap(dialog.window)
        window.setContentSize(size)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return (dialog, window)
    }

    /// Send a real click to the view under a point, the way the mouse does.
    ///
    /// Calling `categoryClicked(_:)` directly would have passed with the sidebar collapsed
    /// to nothing — the selector, the filter and `refresh()` were all correct. What was
    /// broken was the **frame**: hit-testing walks the view tree, so a chip sitting outside
    /// a zero-height clip view is a chip the user cannot press.
    @discardableResult
    private func click(at point: NSPoint, in window: NSWindow) -> Bool {
        guard let hit = window.contentView?.hitTest(point) else { return false }
        guard let control = hit as? NSControl, let action = control.action else { return false }
        control.performClick(nil)
        return true
    }

    private func frame(of view: NSView, in window: NSWindow) -> NSRect {
        view.convert(view.bounds, to: window.contentView)
    }

    // MARK: - The sidebar is a scroll view that works

    /// The sidebar must be as tall as the row it sits in.
    ///
    /// An `NSScrollView` has no intrinsic height, so in a horizontal stack it collapsed to
    /// zero and its document — twelve chips of 44 pt each — was drawn straight over the
    /// disclaimer box at the bottom of the window. The frames below are what a user saw:
    /// a list running off the bottom of the dialog, on top of the text it should have been
    /// beside.
    func testTheSidebarIsAsTallAsItsRow() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        let sidebar = frame(of: dialog.sidebarScroller, in: window)
        let body = frame(of: dialog.bodyRow, in: window)

        XCTAssertGreaterThan(sidebar.height, 200, "a sidebar with no height shows nothing")
        XCTAssertEqual(
            sidebar.height, body.height, accuracy: 1,
            "the sidebar fills the row it is in"
        )
        XCTAssertEqual(sidebar.minY, body.minY, accuracy: 1, "and it starts at the row's top")
    }

    /// Nothing in the sidebar column may overlap anything below it.
    func testTheSidebarDoesNotCoverTheDisclaimer() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        // AppKit's origin is bottom-left: the sidebar sits *above* the disclaimer.
        let sidebarLow = frame(of: dialog.sidebarScroller, in: window).minY
        let disclaimerTop = frame(of: dialog.disclaimerPanel, in: window).maxY
        XCTAssertGreaterThanOrEqual(
            sidebarLow, disclaimerTop - 1,
            "the chips used to be drawn over the disclaimer text"
        )
    }

    /// The chips are 44 pt tall (SPEC §7.2) and the column scrolls — twelve of them are
    /// far more than fits, and that is fine as long as the scroller says so.
    func testTheCategoryChipsAreFullHeightAndTheColumnScrolls() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        let chips = dialog.sidebarChips
        XCTAssertGreaterThan(chips.count, 2, "the reference has categories")
        for chip in chips {
            let height = frame(of: chip, in: window).height
            XCTAssertGreaterThanOrEqual(height, 44 - 0.5, "\(chip.title) is a 44 px target")
        }
        let content = dialog.sidebarColumn.frame.height
        let visible = dialog.sidebarScroller.contentView.bounds.height
        if content > visible {
            XCTAssertTrue(
                dialog.sidebarScroller.hasVerticalScroller,
                "\(Int(content)) pt of chips do not fit in \(Int(visible)) pt, so they scroll"
            )
        }
    }

    /// At the smallest size the window allows, the two columns still fit beside each other
    /// and the sidebar still has somewhere to draw.
    func testItHoldsTogetherAtTheMinimumWindowSize() throws {
        let (dialog, window) = try makeDialog(size: NSSize(width: 760, height: 500))
        defer { window.close() }

        let sidebar = frame(of: dialog.sidebarScroller, in: window)
        let disclaimerTop = frame(of: dialog.disclaimerPanel, in: window).maxY
        XCTAssertGreaterThan(sidebar.height, 120, "the sidebar still has room to draw")
        XCTAssertGreaterThan(sidebar.minY, disclaimerTop - 1, "and stays clear of the footer")
    }

    /// Every button says what it does.
    ///
    /// The Apply buttons and the Close button were all built with `title: ""` and nothing
    /// ever set one, so the results column was 110 blank grey rectangles and the corner of
    /// the footer was a blank blue rectangle. A test that only checked the button's target,
    /// its action and its `representedID` passed the whole time — the button was
    /// perfectly wired and perfectly invisible.
    func testEveryButtonSaysWhatItDoes() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        XCTAssertFalse(dialog.applyButtonTitles.isEmpty, "there are records on screen")
        for title in dialog.applyButtonTitles {
            XCTAssertEqual(title, "Apply", "every card offers the same, named action")
        }
        XCTAssertEqual(dialog.closeButtonTitle, "Close")
    }

    /// And they say it in the interface language — the captions are catalogue keys like
    /// everything else (SPEC §7.4).
    func testTheButtonsAreTranslated() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }
        defer { L10n.setLanguage("en") }

        L10n.setLanguage("ru")
        dialog.retranslate()
        XCTAssertEqual(dialog.applyButtonTitles.first, "Применить")
        XCTAssertEqual(dialog.closeButtonTitle, "Закрыть")
    }

    /// Apply sits at the card's right edge, not pressed against the record's name.
    func testApplySitsAtTheRightOfTheCard() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        guard let button = dialog.applyButtons.first,
              let card = button.superview?.superview
        else { return XCTFail("the first record has no Apply button on screen") }

        let cardFrame = frame(of: card, in: window)
        let buttonFrame = frame(of: button, in: window)
        XCTAssertGreaterThan(
            buttonFrame.midX, cardFrame.midX,
            "the action belongs on the right of the card, not beside the name"
        )
    }

    /// The disclaimer has to be on the screen. It is the one line of this dialog that
    /// says what the numbers are not, and it was being laid out at **0 pt** — present in
    /// the view tree, clipped to nothing.
    func testTheDisclaimerIsTallEnoughToRead() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        XCTAssertTrue(dialog.isDisclaimerVisible)
        let panel = frame(of: dialog.disclaimerPanel, in: window)
        XCTAssertGreaterThan(
            panel.height, 40,
            "a disclaimer squeezed to \(panel.height) pt shows no text"
        )
        XCTAssertFalse(
            dialog.disclaimerText.isEmpty,
            "and it is the text of the disclaimer, not a frame around nothing"
        )
    }

    // MARK: - Clicking a category actually filters

    /// The click has to arrive, and the list has to change.
    ///
    /// This is the exact report: *«когда я выбираю в левом меню то ничего не происходит»*.
    /// Both halves are asserted — the chip under the cursor is the chip that gets pressed,
    /// and the records on screen are the ones in that category.
    func testClickingASidebarChipFiltersTheRecords() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        let before = dialog.resultCountText
        XCTAssertNil(dialog.selectedCategoryID, "the reference opens on every category")
        let category = try XCTUnwrap(
            dialog.sidebarChips.compactMap(\.representedID).first,
            "a category chip with an id"
        )

        let chip = try XCTUnwrap(dialog.sidebarChips.first { $0.representedID == category })
        let centre = NSPoint(
            x: frame(of: chip, in: window).midX,
            y: frame(of: chip, in: window).midY
        )
        XCTAssertTrue(
            click(at: centre, in: window),
            "there is nothing under the cursor at the chip's own centre"
        )
        XCTAssertEqual(dialog.selectedCategoryID, category, "the click reached the chip")
        XCTAssertNotEqual(dialog.resultCountText, before, "and the list changed")

        let visible = try XCTUnwrap(
            dialog.visibleEntries.first?.category,
            "the category has records"
        )
        XCTAssertTrue(
            dialog.visibleEntries.allSatisfy { $0.category == visible },
            "only that category is left on screen"
        )
    }

    /// The cards on the right are clickable too — the *Apply* button is the whole reason
    /// the reference exists.
    ///
    /// The results column had the same flipped-document bug as the sidebar, so it needed
    /// its own guard: it is a different scroll view, and a fix to one is not a fix to the
    /// other.
    func testTheFirstRecordCanBeAppliedByClickingIt() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        var applied: (Double, Double)?
        dialog.onApply = { applied = ($0, $1) }

        guard let entry = dialog.visibleEntries.first,
              let button = dialog.applyButtons.first(where: { $0.representedID == entry.id })
        else { return XCTFail("the first record has no Apply button on screen") }

        let target = frame(of: button, in: window)
        XCTAssertTrue(
            click(at: NSPoint(x: target.midX, y: target.midY), in: window),
            "the Apply button of the first record is not under the cursor at its own centre"
        )
        XCTAssertNotNil(applied, "clicking it applied the frequencies")
    }

    /// Going back to "All categories" restores everything — one click, no dead ends.
    func testClickingAllCategoriesRestoresEverything() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        let every = dialog.resultCountText
        guard let chip = dialog.sidebarChips.first,
              let category = dialog.sidebarChips.compactMap(\.representedID).first
        else { return XCTFail("the sidebar has no chips") }

        dialog.selectCategory(category)
        XCTAssertNotEqual(dialog.resultCountText, every)

        let centre = NSPoint(
            x: frame(of: chip, in: window).midX,
            y: frame(of: chip, in: window).midY
        )
        XCTAssertTrue(click(at: centre, in: window))
        XCTAssertNil(dialog.selectedCategoryID, "back to every category")
        XCTAssertEqual(dialog.resultCountText, every)
    }

    /// The chips say which one is on, both by state and by colour — the same rule the
    /// preset bar follows (SPEC §7.2: colour is never the only carrier).
    func testTheSelectedCategoryChipIsMarked() throws {
        let (dialog, window) = try makeDialog()
        defer { window.close() }

        let chips = dialog.sidebarChips
        guard let all = chips.first,
              let category = chips.compactMap(\.representedID).first
        else { return XCTFail("the sidebar has no chips") }

        XCTAssertEqual(all.state, .on, "everything is shown first")
        XCTAssertEqual(
            dialog.categoryTint(for: category), .labelColor,
            "so no category chip is highlighted yet"
        )

        dialog.selectCategory(category)
        XCTAssertEqual(
            dialog.sidebarChips.first { $0.representedID == category }?.state, .on,
            "the chosen chip says so in its state"
        )
        XCTAssertEqual(
            dialog.categoryTint(for: category), .controlAccentColor,
            "and in its colour"
        )
        let other = try XCTUnwrap(chips.compactMap(\.representedID).last, "two categories")
        XCTAssertEqual(
            dialog.categoryTint(for: other), .labelColor,
            "the others stay plain"
        )
    }
}
