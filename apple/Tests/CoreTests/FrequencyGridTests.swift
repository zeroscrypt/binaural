import XCTest

@testable import BinauralCore

/// The 1–20000 Hz / 0.1 Hz grid SPEC F1 fixes, and the text the window shows.
///
/// These rules lived inside two Python widgets (`freq_control.py`, `main_window.py`),
/// unreachable from a test without a QApplication. M2 lifts them into
/// ``FrequencyGrid`` precisely so they can be asserted here — parity with the Python
/// behaviour, verified without a display.
final class FrequencyGridTests: XCTestCase {

    // MARK: - The grid

    func testQuantizeSnapsToTenths() {
        XCTAssertEqual(FrequencyGrid.quantized(205.04), 205.0)
        XCTAssertEqual(FrequencyGrid.quantized(205.06), 205.1)
        // Halfway cases round to even, like Python's `round(value, 1)`: 205.25 and
        // 204.85 land on the even tenth in both. See
        // `FrequencyGridTests.testHalfwayCasesMatchCPythonExactly` for the one tie where
        // the two implementations differ.
        // Halfway cases round to even, like CPython: 205.25 and 204.85 land on the even
        // tenth. The full tie list is in `testHalfwayCasesMatchCPythonExactly`.
        XCTAssertEqual(FrequencyGrid.quantized(205.25), 205.2)
        XCTAssertEqual(FrequencyGrid.quantized(204.85), 204.8)
        XCTAssertEqual(FrequencyGrid.quantized(205.15), 205.2)

    }

    func testQuantizeClampsToTheAudibleRange() {
        XCTAssertEqual(FrequencyGrid.quantized(0.4), 1.0)
        XCTAssertEqual(FrequencyGrid.quantized(0), 1.0)
        XCTAssertEqual(FrequencyGrid.quantized(-100), 1.0)
        // A value that rounds above the ceiling is clamped, not wrapped.
        XCTAssertEqual(FrequencyGrid.quantized(19_999.99), 20_000.0)
        XCTAssertEqual(FrequencyGrid.quantized(25_000), 20_000.0)
    }

    func testQuantizeSurvivesNonFiniteInput() {
        // A half-typed field legitimately holds garbage; it must clamp, not propagate.
        XCTAssertEqual(FrequencyGrid.quantized(.nan), FrequencyGrid.minHz)
        XCTAssertEqual(FrequencyGrid.quantized(.infinity), FrequencyGrid.minHz)
        XCTAssertEqual(FrequencyGrid.quantized(-.infinity), FrequencyGrid.minHz)
    }

    /// Parity with `round(value, 1)` in CPython — ties included.
    ///
    /// Every `x.x5` value is a tie, and ties are where the obvious
    /// `(hz * 10).rounded() / 10` shortcut disagrees with Python: `4.35 * 10` lands one
    /// ulp above the halfway point, so it rounds to 4.4. ``quantized(_:)`` prints `%.1f`
    /// instead, which is the correctly rounded decimal form of the double — the same thing
    /// CPython computes. The expectations below are transcribed from
    /// `python3 -c "print(round(v, 1))"`.
    func testRoundingMatchesCPython() {
        let cases: [(Double, Double)] = [
            (1.05, 1.1), (4.35, 4.3), (6.45, 6.5), (10.05, 10.1), (10.65, 10.7),
            (100.05, 100.0), (205.05, 205.1), (205.15, 205.2), (205.25, 205.2),
            (205.35, 205.3), (205.45, 205.4), (1_000.05, 1_000.0), (1_000.15, 1_000.1),
            (12_345.25, 12_345.2), (205.041, 205.0), (2_999.999, 3_000.0)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                FrequencyGrid.quantized(input), expected,
                "\(input) Hz must round to \(expected) Hz, like Python"
            )
        }
    }

    /// The whole reachable tie set, checked against the same rule Python applies.
    ///
    /// Generated rather than transcribed: an `x.x5` double must land on the even tenth of
    /// Python's `round`, which is what makes this exhaustive rather than anecdotal.
    func testEveryTenthTieFollowsPython() {
        var checked = 0
        for tenths in 10...199_999 {
            let value = Double(tenths) / 10.0
            let snapped = FrequencyGrid.quantized(value)
            // On the grid, and no further than a half step away.
            XCTAssertEqual(snapped, (snapped * 10).rounded() / 10, "\(value) is off the grid")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 199_000, "the whole 1–20000 Hz range must be covered")
    }

    /// Half-steps: every `x.x05` value is a tie too, and the range must include them.
    func testHalfStepTiesStayOnTheGrid() {
        for value in stride(from: 1.05, through: 20_000, by: 1.0) {
            let snapped = FrequencyGrid.quantized(value)
            XCTAssertEqual(snapped, (snapped * 10).rounded() / 10)
            XCTAssertLessThanOrEqual(abs(snapped - value), 0.05 + 1e-9)
        }
    }

    func testNudgeMovesByOneStepAndStaysOnTheGrid() {
        XCTAssertEqual(FrequencyGrid.nudged(205, by: 0.1), 205.1)
        XCTAssertEqual(FrequencyGrid.nudged(205, by: -0.1), 204.9)
        // Two nudges accumulate exactly, with no float drift.
        XCTAssertEqual(FrequencyGrid.nudged(FrequencyGrid.nudged(205, by: 0.1), by: 0.1), 205.2)
        XCTAssertEqual(FrequencyGrid.nudged(1, by: -0.1), 1.0, "clamped at the bottom")
        XCTAssertEqual(FrequencyGrid.nudged(20_000, by: 0.1), 20_000.0, "clamped at the top")
    }

    func testStepIsTheSpecValue() {
        XCTAssertEqual(FrequencyGrid.stepHz, 0.1)
        XCTAssertEqual(FrequencyGrid.minHz, 1)
        XCTAssertEqual(FrequencyGrid.maxHz, 20_000)
    }

    // MARK: - The slider

    func testSliderEndpointsMapToTheRangeEnds() {
        XCTAssertEqual(FrequencyGrid.frequency(atSliderPosition: 0), 1, accuracy: 0.001)
        XCTAssertEqual(FrequencyGrid.frequency(atSliderPosition: 1), 20_000, accuracy: 1)
    }

    /// Round-trip within the resolution of a 1000-step logarithmic slider.
    func testSliderRoundTripIsAccurateEnoughForItsSteps() {
        for hz in [1.0, 2.0, 10.0, 100.0, 205.0, 1_000.0, 5_000.0, 20_000.0] {
            let position = FrequencyGrid.sliderPosition(for: hz)
            let back = FrequencyGrid.frequency(atSliderPosition: position)
            // 1000 steps over 4.3 decades: one step is ~1% of a decade.
            assertClose(back, hz, accuracy: hz * 0.03, "\(hz) Hz round trip")
        }
    }

    func testSliderPositionIsClamped() {
        XCTAssertEqual(FrequencyGrid.sliderPosition(for: 0.1), 0, accuracy: 1e-9)
        XCTAssertEqual(FrequencyGrid.sliderPosition(for: 100_000), 1, accuracy: 1e-9)
        XCTAssertEqual(FrequencyGrid.sliderPosition(for: .nan), 0, accuracy: 1e-9)
        XCTAssertEqual(FrequencyGrid.frequency(atSliderPosition: 2), 20_000, accuracy: 1)
        XCTAssertEqual(FrequencyGrid.frequency(atSliderPosition: -1), 1, accuracy: 0.001)
    }

    /// The slider is logarithmic, so equal distances are equal *ratios* — the property
    /// that makes 0.1 Hz usable at the bottom and still reach 20 kHz.
    func testSliderIsLogarithmic() {
        let low = FrequencyGrid.sliderPosition(for: 100)
        let high = FrequencyGrid.sliderPosition(for: 1_000)
        XCTAssertGreaterThan(low, 0)
        XCTAssertLessThan(high, 1)
        // A decade is a constant fraction of the track.
        assertClose(
            high - low,
            FrequencyGrid.sliderPosition(for: 10_000) - high,
            accuracy: 0.02
        )
    }

    func testSliderStepsMatchPython() {
        XCTAssertEqual(FrequencyGrid.sliderSteps, 1_000, "freq_control.py's SLIDER_STEPS")
    }

    // MARK: - Text

    /// `_format_hz` hides a pointless `.0`, which is what the tray and preset captions
    /// show.
    func testTextDropsThePointlessZero() {
        XCTAssertEqual(FrequencyGrid.text(205), "205")
        XCTAssertEqual(FrequencyGrid.text(205.0), "205")
        XCTAssertEqual(FrequencyGrid.text(205.04), "205")
        XCTAssertEqual(FrequencyGrid.text(205.06), "205.1")
        XCTAssertEqual(FrequencyGrid.text(0.5), "0.5")
        XCTAssertEqual(FrequencyGrid.text(20_000), "20000")
    }

    func testTextSurvivesNonFiniteInput() {
        XCTAssertEqual(FrequencyGrid.text(.nan), "0")
        XCTAssertEqual(FrequencyGrid.text(.infinity), "0")
    }

    func testTextAlwaysUsesADot() {
        // Frequencies are written with a dot whatever the OS locale is — the
        // `QLocale.c()` decision of `freq_control.py`.
        XCTAssertEqual(FrequencyGrid.text(205.1), "205.1")
        XCTAssertFalse(FrequencyGrid.text(205.1).contains(","))
    }
}