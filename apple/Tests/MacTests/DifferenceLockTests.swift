import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The "Lock difference" checkbox in the real window (SPEC §7).
///
/// ``DifferenceLockTests`` in the core suite checks the arithmetic; this checks the wiring —
/// that the checkbox is next to the beat read-out, that *every* path a frequency can change
/// through goes past the lock, and that a preset still wins.
@MainActor
final class DifferenceLockWindowTests: XCTestCase {

    private var store: SessionStore!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-lock-\(UUID().uuidString)")
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

    // MARK: - The checkbox itself

    func testCheckboxSitsNextToTheBeatDisplay() {
        let controller = makeController()
        let button = controller.differenceLockControl
        XCTAssertTrue(
            button.isDescendant(of: controller.beatCard),
            "the lock belongs beside the difference it protects, not in the transport row"
        )
        // Decision 1: no text field for typing a difference — `NSTextField(labelWithString:)`
        // labels are text fields too, so the check is on `isEditable`.
        XCTAssertFalse(
            controller.beatCard.hasEditableTextField(),
            "the beat stays an indicator, not an input"
        )
    }

    func testCheckboxIsCaptionedInBothLanguages() {
        let controller = makeController()
        XCTAssertEqual(controller.differenceLockTitle, "Lock difference")
        L10n.setLanguage("ru")
        XCTAssertEqual(controller.differenceLockTitle, "Зафиксировать")
    }

    func testLockIsOffOnAFreshSession() {
        let controller = makeController()
        XCTAssertFalse(controller.isDifferenceLocked)
        XCTAssertEqual(controller.differenceLockControl.state, .off)
    }

    // MARK: - Decision 1: capture, do not edit

    func testTickingCapturesTheCurrentDifference() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        XCTAssertTrue(controller.isDifferenceLocked)
        XCTAssertEqual(controller.lockedDifferenceHz, 60, accuracy: 1e-9)
        // Ticking moves nothing by itself.
        XCTAssertEqual(controller.displayedFrequencies.left, 200, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 260, accuracy: 1e-9)
    }

    // MARK: - Decision 2: the untouched channel follows

    func testDraggingLeftMovesRight() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.setFrequency(250, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 250, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 310, accuracy: 1e-9)
        XCTAssertEqual(controller.beat.hz, 60, accuracy: 1e-9)
    }

    func testDraggingRightMovesLeft() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.setFrequency(210, for: .right)
        XCTAssertEqual(controller.displayedFrequencies.right, 210, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 150, accuracy: 1e-9)
    }

    /// The negative case: a session where the right ear is the lower one keeps its sign.
    func testANegativeDifferenceIsKeptNegative() {
        let controller = makeController(session: Session(leftHz: 260, rightHz: 200))
        controller.tapDifferenceLock(true)
        XCTAssertEqual(controller.lockedDifferenceHz, -60, accuracy: 1e-9)

        controller.setFrequency(250, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 250, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 190, accuracy: 1e-9)
        XCTAssertEqual(
            controller.displayedFrequencies.right - controller.displayedFrequencies.left,
            -60, accuracy: 1e-9
        )
    }

    /// The `↑`/`↓` nudge goes through the control like any other edit, so it follows too.
    func testNudgeFollowsAsWell() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.setFrequency(200, for: .left)
        controller.switchChannelFromKeyboard()      // right is active
        controller.nudgeFromKeyboard(0.1)

        XCTAssertEqual(controller.displayedFrequencies.right, 260.1, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 200.1, accuracy: 1e-9)
    }

    /// Exact keyboard entry: ``setFrequency(_:for:)`` is the same path the field's action
    /// takes, so a typed value follows just as a dragged one does.
    func testTypedEntryFollows() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.setFrequency(311.5, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 311.5, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 371.5, accuracy: 1e-9)
    }

    func testUnlockingStopsFollowingAndKeepsTheFrequencies() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)
        controller.setFrequency(250, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.right, 310, accuracy: 1e-9)

        controller.tapDifferenceLock(false)
        XCTAssertFalse(controller.isDifferenceLocked)
        controller.setFrequency(300, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 300, accuracy: 1e-9)
        XCTAssertEqual(
            controller.displayedFrequencies.right, 310, accuracy: 1e-9,
            "unlocking stops the following; it does not move anything"
        )
    }

    // MARK: - Decision 3: a preset wins and unlocks

    func testPresetAppliesItsOwnBeatAndClearsTheLock() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.tapPreset("sleep-1", inCategory: "sleep")

        XCTAssertFalse(
            controller.isDifferenceLocked,
            "SPEC F3 wants the preset's beat, so the lock must let go of it"
        )
        XCTAssertEqual(controller.differenceLockControl.state, .off)
        XCTAssertEqual(controller.beat.hz, 1, accuracy: 1e-9)
    }

    /// The user has to be told, or a checkbox that clears itself looks like a bug.
    func testPresetShowsTheUnlockNotice() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)
        controller.tapPreset("sleep-1", inCategory: "sleep")

        let key = controller.differenceNoticeKey
        XCTAssertEqual(key, "Difference lock turned off — a preset set its own difference.")
        XCTAssertEqual(
            L10n.tr(key!),
            "Difference lock turned off — a preset set its own difference."
        )

        L10n.setLanguage("ru")
        XCTAssertEqual(
            L10n.tr(key!),
            "Фиксация разности выключена — пресет задал свою разность."
        )
    }

    func testPresetWithoutALockShowsNoUnlockNotice() {
        let controller = makeController()
        controller.tapPreset("sleep-1", inCategory: "sleep")
        XCTAssertNil(controller.differenceNoticeKey, "nothing was turned off")
    }

    /// SPEC §6's *Apply* is the same kind of instruction as a preset — a named pair — so it
    /// wins too, rather than one channel yanking the other.
    func testReferencePairWinsOverTheLock() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)

        controller.applyFrequencyPair(leftHz: 174, rightHz: 178)

        XCTAssertEqual(controller.displayedFrequencies.left, 174, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 178, accuracy: 1e-9)
        XCTAssertFalse(controller.isDifferenceLocked)
    }

    // MARK: - Decision 4: the edited channel stops at the boundary

    func testTheEditedChannelStopsAtTheTopOfTheRange() {
        let controller = makeController(session: Session(leftHz: 19_000, rightHz: 19_010))
        controller.tapDifferenceLock(true)

        controller.setFrequency(20_000, for: .left)

        XCTAssertEqual(controller.displayedFrequencies.right, 20_000, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 19_990, accuracy: 1e-9)
        XCTAssertTrue(controller.isShowingBeatHint, "the existing hint explains the stop")
        XCTAssertTrue(controller.beatHintText.contains("range limit"))
        XCTAssertTrue(controller.isShowingDifferenceBoundaryNote)
        // The lock itself was never violated and never dropped.
        XCTAssertTrue(controller.isDifferenceLocked)
        XCTAssertEqual(controller.lockedDifferenceHz, 10, accuracy: 1e-9)
    }

    /// A positive difference makes the left channel the lower one, so dragging the *right*
    /// one down is what runs out of range.
    func testTheEditedChannelStopsAtTheBottomOfTheRange() {
        let controller = makeController(session: Session(leftHz: 1_010, rightHz: 1_020))
        controller.tapDifferenceLock(true)

        controller.setFrequency(1, for: .right)

        XCTAssertEqual(controller.displayedFrequencies.right, 11, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 1, accuracy: 1e-9)
        XCTAssertTrue(controller.isShowingBeatHint, "the existing hint explains the stop")
        XCTAssertTrue(controller.isDifferenceLocked)
        XCTAssertEqual(controller.lockedDifferenceHz, 10, accuracy: 1e-9)
    }

    func testTheHintReturnsToItsOrdinaryRuleAfterwards() {
        let controller = makeController(session: Session(leftHz: 19_000, rightHz: 19_010))
        controller.tapDifferenceLock(true)
        controller.setFrequency(20_000, for: .left)
        XCTAssertTrue(controller.isShowingDifferenceBoundaryNote)

        controller.setFrequency(500, for: .left)
        XCTAssertFalse(controller.isShowingDifferenceBoundaryNote)
        XCTAssertFalse(controller.isShowingBeatHint, "a 10 Hz beat is inside the range")
    }

    /// The timer never writes a frequency, so the lock cannot be bypassed through it: what
    /// it does (stop through the fade) is untouched by the lock, and the pair survives.
    func testTheTimerDoesNotDisturbTheLock() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)
        controller.selectTimerMinutes(5)
        controller.armTimer(at: Date(timeIntervalSince1970: 1_700_000_000))
        controller.tickTimer(at: Date(timeIntervalSince1970: 1_700_000_000 + 5 * 60 + 2))

        XCTAssertTrue(controller.isDifferenceLocked)
        XCTAssertEqual(controller.lockedDifferenceHz, 60, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 200, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 260, accuracy: 1e-9)
    }

    // MARK: - Decision 5: persistence

    func testTheLockSurvivesARelaunch() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.tapDifferenceLock(true)
        controller.saveNow()

        let reloaded = makeController()
        XCTAssertTrue(reloaded.isDifferenceLocked)
        XCTAssertEqual(reloaded.lockedDifferenceHz, 60, accuracy: 1e-9)
        XCTAssertEqual(reloaded.differenceLockControl.state, .on)

        // And it keeps following after the relaunch.
        reloaded.setFrequency(250, for: .left)
        XCTAssertEqual(reloaded.displayedFrequencies.right, 310, accuracy: 1e-9)
    }

    func testAnUnlockedSessionSavesItUnlocked() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 260))
        controller.saveNow()

        let json = String(data: try! Data(contentsOf: store.url), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"difference_locked\" : false"), json)
        XCTAssertFalse(makeController().isDifferenceLocked)
    }

    /// A document from before the field existed: it must load, and the box comes back off.
    func testASessionWrittenBeforeTheLockExistedStillOpens() throws {
        let legacy = """
        {
          "left_hz": 200.0,
          "right_hz": 260.0,
          "volume": 0.7,
          "channels_swapped": false,
          "headphone_check_acknowledged": true,
          "timer_minutes": 30,
          "preset_category": "sleep"
        }
        """
        try Data(legacy.utf8).write(to: store.url)

        let controller = makeController()
        XCTAssertEqual(controller.displayedFrequencies.left, 200, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.right, 260, accuracy: 1e-9)
        XCTAssertEqual(controller.selectedTimerMinutes, 30)
        XCTAssertEqual(controller.selectedPresetCategory, "sleep")
        XCTAssertFalse(controller.isDifferenceLocked)
    }
}

private extension NSView {
    /// True when the view tree holds a text field the user can type into.
    ///
    /// `isEditable`, not "is an `NSTextField`": AppKit's read-out labels *are* text fields,
    /// and the beat card is built entirely of them.
    func hasEditableTextField() -> Bool {
        if let field = self as? NSTextField, field.isEditable { return true }
        return subviews.contains { $0.hasEditableTextField() }
    }
}