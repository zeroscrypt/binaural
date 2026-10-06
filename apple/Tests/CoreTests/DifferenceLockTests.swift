import XCTest

@testable import BinauralCore

/// The "Lock difference" arithmetic of SPEC §7, on its own.
///
/// These are pure numbers, so they are checked without AppKit: the window tests prove the
/// checkbox is wired to this, and these prove the following is right.
final class DifferenceLockTests: XCTestCase {

    private func locked(_ left: Double, _ right: Double) -> DifferenceLock {
        var lock = DifferenceLock.unlocked
        lock.capture(leftHz: left, rightHz: right)
        return lock
    }

    // MARK: - Capture

    func testUnlockedByDefault() {
        XCTAssertFalse(DifferenceLock.unlocked.isLocked)
        XCTAssertEqual(DifferenceLock.unlocked.signedDifferenceHz, 0)
    }

    /// Capture, do not edit: the box locks whatever the difference is at that moment.
    func testCaptureTakesTheCurrentSignedDifference() {
        XCTAssertEqual(locked(200, 260).signedDifferenceHz, 60, accuracy: 1e-9)
        // fR < fL is a real state (the right ear can be the lower one) and must survive.
        XCTAssertEqual(locked(260, 200).signedDifferenceHz, -60, accuracy: 1e-9)
        XCTAssertEqual(locked(205, 205).signedDifferenceHz, 0, accuracy: 1e-9)
    }

    func testCaptureQuantisesToTheGrid() {
        // The two controls are already on the 0.1 Hz grid; capturing them must not invent
        // a difference the user cannot see on screen.
        XCTAssertEqual(locked(205.0, 215.1).signedDifferenceHz, 10.1, accuracy: 1e-9)
    }

    func testUnlockForgetsTheDifference() {
        var lock = locked(200, 260)
        lock.unlock()
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(lock.signedDifferenceHz, 0)
    }

    // MARK: - Following

    /// The two worked examples from the spec note: a positive difference moves the right
    /// channel, and the same signed difference is preserved when it is negative.
    func testUntouchedChannelFollows() throws {
        let positive = locked(200, 260)
        let moved = try XCTUnwrap(positive.resolve(edited: .left, to: 250))
        XCTAssertEqual(moved.leftHz, 250, accuracy: 1e-9)
        XCTAssertEqual(moved.rightHz, 310, accuracy: 1e-9)

        let negative = locked(260, 200)
        let other = try XCTUnwrap(negative.resolve(edited: .right, to: 150))
        XCTAssertEqual(other.rightHz, 150, accuracy: 1e-9)
        XCTAssertEqual(other.leftHz, 210, accuracy: 1e-9)
    }

    func testFollowingPreservesTheSignedDifferenceExactly() throws {
        for (left, right) in [(200.0, 260.0), (260.0, 200.0), (205.0, 205.0), (7.83, 432.0)] {
            let lock = locked(left, right)
            for edited in [DifferenceLock.Channel.left, .right] {
                for target in [12.0, 199.9, 480.0, 1500.0] {
                    guard let resolution = lock.resolve(edited: edited, to: target) else {
                        return XCTFail("no resolution for \(edited) \(target)")
                    }
                    let difference = resolution.rightHz - resolution.leftHz
                    XCTAssertEqual(
                        difference, lock.signedDifferenceHz, accuracy: 1e-9,
                        "\(left)/\(right) editing \(edited) to \(target)"
                    )
                }
            }
        }
    }

    func testResultStaysOnTheGridAndInRange() throws {
        let lock = locked(205.0, 215.1)
        for target in [1.0, 2.05, 33.33, 19_999.9, 20_000.0] {
            for edited in [DifferenceLock.Channel.left, .right] {
                guard let resolution = lock.resolve(edited: edited, to: target) else { continue }
                for hz in [resolution.leftHz, resolution.rightHz] {
                    XCTAssertGreaterThanOrEqual(hz, FrequencyGrid.minHz)
                    XCTAssertLessThanOrEqual(hz, FrequencyGrid.maxHz)
                    XCTAssertEqual(hz, FrequencyGrid.quantized(hz), accuracy: 1e-9, "off the grid")
                }
            }
        }
    }

    func testUnlockedResolvesToNothing() {
        XCTAssertNil(DifferenceLock.unlocked.resolve(edited: .left, to: 250))
        XCTAssertNil(DifferenceLock.unlocked.resolve(edited: .right, to: 250))
    }

    // MARK: - The boundary (SPEC §7: the edited channel stops at the limit)

    func testEditedChannelStopsAtTheTopOfTheRange() throws {
        // A +10 Hz difference: pushing the left channel to 20000 would ask 20010 of the
        // right one, so the left one stops where the right one is still legal.
        let lock = locked(205, 215)
        let resolution = try XCTUnwrap(lock.resolve(edited: .left, to: 20_000))
        XCTAssertEqual(resolution.rightHz, 20_000, accuracy: 1e-9)
        XCTAssertEqual(resolution.leftHz, 19_990, accuracy: 1e-9)
        XCTAssertTrue(resolution.isAtBoundary)
        // The lock itself is untouched — the difference is still exactly +10.
        XCTAssertEqual(resolution.rightHz - resolution.leftHz, 10, accuracy: 1e-9)
        XCTAssertTrue(lock.isLocked)
    }

    /// Which channel stops at the bottom depends on the sign of the difference, so both
    /// directions are checked. A **positive** difference means the left channel is the lower
    /// one, and pushing the right one below 11 Hz would ask a non-positive frequency of the
    /// left, so the right one stops at 11.
    func testEditedChannelStopsAtTheBottomOfTheRange() throws {
        let lock = locked(205, 215)   // +10 Hz
        let resolution = try XCTUnwrap(lock.resolve(edited: .right, to: 1))
        XCTAssertEqual(resolution.rightHz, 11, accuracy: 1e-9)
        XCTAssertEqual(resolution.leftHz, 1, accuracy: 1e-9)
        XCTAssertTrue(resolution.isAtBoundary)
        XCTAssertEqual(resolution.rightHz - resolution.leftHz, 10, accuracy: 1e-9)
    }

    func testANegativeDifferencePushesTheLeftChannelToTheBottom() throws {
        // −10 Hz: the right channel is the lower one, so dragging the left one down stops it
        // at 11 Hz rather than asking a negative frequency of the right.
        let lock = locked(215, 205)
        let resolution = try XCTUnwrap(lock.resolve(edited: .left, to: 1))
        XCTAssertEqual(resolution.leftHz, 11, accuracy: 1e-9)
        XCTAssertEqual(resolution.rightHz, 1, accuracy: 1e-9)
        XCTAssertTrue(resolution.isAtBoundary)
        XCTAssertEqual(resolution.rightHz - resolution.leftHz, -10, accuracy: 1e-9)
    }

    func testAnAcceptedStepIsNotReportedAsTheBoundary() throws {
        let lock = locked(205, 215)
        let resolution = try XCTUnwrap(lock.resolve(edited: .left, to: 205.4))
        XCTAssertFalse(resolution.isAtBoundary)
        XCTAssertEqual(resolution.leftHz, 205.4, accuracy: 1e-9)
        XCTAssertEqual(resolution.rightHz, 215.4, accuracy: 1e-9)
    }

    /// A difference as wide as the whole range leaves exactly one legal pair, and both
    /// channels pin to it rather than producing an illegal frequency.
    func testTheWidestPossibleDifferenceStillResolves() throws {
        let lock = locked(1, 20_000)
        let resolution = try XCTUnwrap(lock.resolve(edited: .left, to: 500))
        XCTAssertEqual(resolution.leftHz, 1, accuracy: 1e-9)
        XCTAssertEqual(resolution.rightHz, 20_000, accuracy: 1e-9)
        XCTAssertTrue(resolution.isAtBoundary)
    }

    func testBeatIsTheAbsoluteDifference() {
        XCTAssertEqual(locked(260, 200).beatHz, 60, accuracy: 1e-9)
        XCTAssertEqual(locked(200, 260).beatHz, 60, accuracy: 1e-9)
    }
}