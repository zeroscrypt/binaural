import XCTest

@testable import BinauralCore

/// Parity with `tests/test_oscillator.py`: constants, `pair_from_beat`, validation.
final class BeatMathTests: XCTestCase {

    // MARK: - Constants (CONTRACT §1)

    func testConstantsMatchContract() {
        XCTAssertEqual(BeatMath.defaultCarrierHz, 200.0)
        XCTAssertEqual(BeatMath.minFrequencyHz, 1.0)
        XCTAssertEqual(BeatMath.maxFrequencyHz, 20000.0)
        XCTAssertEqual(BeatMath.maxBeatHz, 100.0)
        XCTAssertEqual(BeatMath.recommendedBeatRangeHz, 0.5...100.0)
        XCTAssertEqual(BeatMath.defaultRampSeconds, 0.03)
    }

    // MARK: - Arithmetic

    func testBeatFrequencyIsAbsoluteDifference() {
        assertClose(BeatMath.beatFrequency(leftHz: 205, rightHz: 215), 10.0, accuracy: 1e-12)
        assertClose(BeatMath.beatFrequency(leftHz: 215, rightHz: 205), 10.0, accuracy: 1e-12)
        assertClose(BeatMath.beatFrequency(leftHz: 200, rightHz: 200), 0.0, accuracy: 1e-12)
    }

    func testCarrierFrequencyIsMean() {
        assertClose(BeatMath.carrierFrequency(leftHz: 205, rightHz: 215), 210.0, accuracy: 1e-12)
        assertClose(BeatMath.carrierFrequency(leftHz: 200, rightHz: 240), 220.0, accuracy: 1e-12)
    }

    // MARK: - pair(fromBeat:carrier:)

    func testPairFromBeatIsTheDocumentedCase() {
        let pair = try? BeatMath.pair(fromBeat: 10, carrierHz: 200)
        XCTAssertEqual(pair?.left, 195)
        XCTAssertEqual(pair?.right, 205)
    }

    func testPairFromBeatRoundTrip() throws {
        let pair = try BeatMath.pair(fromBeat: 10, carrierHz: 210)
        assertClose(pair.left, 205.0, accuracy: 1e-12)
        assertClose(pair.right, 215.0, accuracy: 1e-12)
        assertClose(BeatMath.beatFrequency(leftHz: pair.left, rightHz: pair.right), 10.0, accuracy: 1e-12)
        assertClose(BeatMath.carrierFrequency(leftHz: pair.left, rightHz: pair.right), 210.0, accuracy: 1e-12)
    }

    func testPairFromBeatDefaultsTo200HzCarrier() throws {
        let pair = try BeatMath.pair(fromBeat: 6)
        assertClose(BeatMath.carrierFrequency(leftHz: pair.left, rightHz: pair.right),
                    BeatMath.defaultCarrierHz, accuracy: 1e-12)
        assertClose(BeatMath.beatFrequency(leftHz: pair.left, rightHz: pair.right), 6.0, accuracy: 1e-12)
    }

    func testZeroBeatProducesOneCarrier() throws {
        let pair = try BeatMath.pair(fromBeat: 0)
        assertClose(pair.left, 200.0, accuracy: 1e-12)
        assertClose(pair.right, 200.0, accuracy: 1e-12)
    }

    func testInvalidPairFromBeatThrows() {
        // Would push the left channel below MIN_FREQ_HZ.
        XCTAssertThrowsError(try BeatMath.pair(fromBeat: 10, carrierHz: 5)) { error in
            XCTAssertEqual(error as? FrequencyError, .outOfRange(name: "left_hz", value: 0.0))
        }
        XCTAssertThrowsError(try BeatMath.pair(fromBeat: -1, carrierHz: 200)) { error in
            XCTAssertEqual(error as? FrequencyError, .negativeBeat(-1))
        }
    }

    func testBoundaryFrequenciesAreAccepted() {
        XCTAssertNoThrow(try BeatMath.validated(BeatMath.minFrequencyHz, name: "left_hz"))
        XCTAssertNoThrow(try BeatMath.validated(BeatMath.maxFrequencyHz, name: "right_hz"))
    }

    func testOutOfRangeFrequenciesThrow() {
        for bad in [0.5, 0.0, -100.0, 20000.1, 30000.0] {
            XCTAssertThrowsError(try BeatMath.validated(bad, name: "left_hz"), "\(bad)")
        }
        XCTAssertThrowsError(try BeatMath.validated(.nan, name: "left_hz"))
        XCTAssertThrowsError(try BeatMath.validated(.infinity, name: "left_hz"))
    }

    func testRecommendedRangeMatchesContract() {
        XCTAssertTrue(BeatMath.isRecommendedBeat(0.5))
        XCTAssertTrue(BeatMath.isRecommendedBeat(10))
        XCTAssertTrue(BeatMath.isRecommendedBeat(100))
        XCTAssertFalse(BeatMath.isRecommendedBeat(0.4))
        XCTAssertFalse(BeatMath.isRecommendedBeat(100.1))
    }
}