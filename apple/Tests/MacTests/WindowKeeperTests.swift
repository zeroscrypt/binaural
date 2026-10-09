import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// A dialog whose controller was thrown away answers nothing.
///
/// ``WindowKeeper`` exists because three dialogs — the frequency reference, *About* and
/// the L/R test inside the headphone check — were all created in a **local variable** of
/// the method that opened them. The window survives: it is the controller that owns it
/// which goes. And AppKit holds a control's target *weakly*, so every button stays exactly
/// where it was, captioned and laid out, with a `nil` target.
///
/// Nothing about that is visible in a screenshot and none of it throws. The dialog reads
/// as fine and responds to nothing: no category chip, no Apply, no Close, no Escape. The
/// trap is worth its own tests because the fix is one indirection and the failure is total.
@MainActor
final class WindowKeeperTests: XCTestCase {

    /// `<repo>/src/binaural/data/frequencies.json` — the real catalogue, so the sidebar
    /// being inspected is the real sidebar.
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
        WindowKeeper.shared.resetForTest()
    }

    override func tearDown() async throws {
        WindowKeeper.shared.resetForTest()
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    // MARK: - The trap

    /// A controller held in a local dies with its scope.
    ///
    /// Worth asserting on its own: if something ever started holding it on its own, the
    /// keeper below would be fixing nothing and these tests would be testing a no-op.
    func testAControllerHeldOnlyInALocalIsGoneWithItsScope() throws {
        weak var weakDialog: ReferenceDialogController?
        do {
            let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
            weakDialog = dialog
        }
        XCTAssertNil(weakDialog, "nothing holds the controller, so it goes with the scope")
    }

    /// And that is what it does to the buttons inside the window.
    func testTheChipsOfADeadControllerHaveNoTarget() throws {
        var chips: [NSButton] = []
        do {
            let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
            chips = dialog.sidebarChips
        }
        XCTAssertFalse(chips.isEmpty, "the sidebar has chips")
        XCTAssertTrue(
            chips.allSatisfy { $0.target == nil },
            "AppKit holds a target weakly: every control in a dialog whose controller is "
                + "gone is a control that looks alive and answers nothing"
        )
    }

    // MARK: - The fix

    /// Kept, the same controller outlives the scope that made it.
    func testAKeptDialogOutlivesItsScope() throws {
        weak var weakDialog: ReferenceDialogController?
        do {
            let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
            _ = dialog.window
            WindowKeeper.shared.keep(dialog)
            weakDialog = dialog
        }
        let dialog = try XCTUnwrap(weakDialog, "the keeper holds the controller")
        XCTAssertEqual(
            dialog.sidebarChips.compactMap { $0.target }.count,
            dialog.sidebarChips.count,
            "and every chip in it has a live target again"
        )
        XCTAssertEqual(WindowKeeper.shared.count, 1, "it is being kept")
    }

    /// A dialog the keeper holds still answers a real click.
    func testAKeptDialogStillFiltersWhenItsScopeIsGone() throws {
        weak var weakDialog: ReferenceDialogController?
        let before: String
        do {
            let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
            _ = dialog.window
            before = dialog.resultCountText
            WindowKeeper.shared.keep(dialog)
            weakDialog = dialog
        }
        let dialog = try XCTUnwrap(weakDialog)
        guard let category = dialog.sidebarChips.compactMap(\.representedID).first
        else { return XCTFail("the sidebar has no categories") }

        XCTAssertEqual(dialog.resultCountText, before, "the window is still showing")
        dialog.selectCategory(category)
        XCTAssertEqual(dialog.selectedCategoryID, category, "the control still works")
        XCTAssertNotEqual(dialog.resultCountText, before, "and it still changes something")
    }

    /// The keeper lets go when the window closes, so a finished dialog is not kept for
    /// the life of the process.
    func testTheKeeperLetsGoWhenTheWindowCloses() throws {
        let dialog = ReferenceDialogController(catalogue: try Self.catalogue())
        _ = dialog.window
        WindowKeeper.shared.keep(dialog)
        XCTAssertEqual(WindowKeeper.shared.count, 1)

        dialog.window?.close()
        // `willClose` is posted to the main queue, so the run loop has to turn once.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(
            WindowKeeper.shared.count, 0,
            "a closed dialog must not be retained for the rest of the process"
        )
    }
}
