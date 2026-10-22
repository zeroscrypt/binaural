import XCTest

@testable import BinauralCore

/// The chakra sequence: seven solfeggio steps, the measured default beat, and the
/// frequency pair each step plays.
///
/// The frequencies are the contract. A solfeggio set is a fixed table, and a mode that
/// drifts from it is not the mode — it is a different app. The default beat is pinned
/// here too, because it was measured rather than chosen: 21 Hz is the pulsing rate of
/// the reference recording, and changing it silently would change what the mode is.
@MainActor
final class ChakraSequenceTests: XCTestCase {

    // MARK: - Shape

    func testEightStepsFromEarthToCrown() {
        /// Eight, not seven: the earth step below the root is 174 Hz, the lowest tone of
        /// the extended Solfeggio set — the one called *the foundation*, for grounding and
        /// stability. Without it the sequence starts one step up the spine.
        XCTAssertEqual(
            ChakraSequence.steps.map(\.id),
            ["earth", "root", "sacral", "solar-plexus", "heart", "throat", "third-eye", "crown"]
        )
    }

    /// The solfeggio set, transcribed. Every value is a whole number of hertz, which is
    /// what makes them solfeggio notes rather than brainwave beats.
    func testTheFrequenciesAreTheSolfeggioSet() {
        XCTAssertEqual(
            ChakraSequence.steps.map(\.hz),
            [174, 396, 417, 528, 639, 741, 852, 963]
        )
    }

    /// The mode rises. A sequence that went up and down would not be "from root to
    /// crown", and the order is the whole point of the mode.
    func testTheStepsRise() {
        let hz = ChakraSequence.steps.map(\.hz)
        XCTAssertEqual(hz, hz.sorted())
        XCTAssertEqual(Set(hz).count, hz.count, "no step repeats a frequency")
    }

    /// Every step has a name and a description. A step with an empty description would
    /// leave the panel showing a bare number.
    func testEveryStepIsNamedAndDescribed() {
        for step in ChakraSequence.steps {
            XCTAssertFalse(ChakraSequence.name(of: step).isEmpty, "\(step.id) has no name")
            XCTAssertFalse(
                ChakraSequence.description(of: step).isEmpty,
                "\(step.id) has no description"
            )
        }
    }

    /// The names and the descriptions are catalogue entries, so the Russian text lives
    /// in `ru.py` like every other caption. A step that fell through to its id would
    /// show `solar-plexus` in the panel, which is not a caption anyone can read.
    func testTheNamesAreCaptionsAndNotIds() {
        for step in ChakraSequence.steps {
            XCTAssertNotEqual(ChakraSequence.name(of: step), step.id)
        }
    }

    // MARK: - The beat

    /// The measured default. 21.00 Hz came out of a spectrum analysis of a reference
    /// recording: the envelope of its 380–430 Hz band pulsated at exactly 21 Hz in every
    /// step after the first.
    func testTheDefaultBeatIsTheMeasuredOne() {
        XCTAssertEqual(ChakraSequence.defaultBeatHz, 21.0)
    }

    func testTheDefaultBeatIsInsideTheAllowedRange() {
        XCTAssertGreaterThanOrEqual(ChakraSequence.defaultBeatHz, ChakraSequence.minBeatHz)
        XCTAssertLessThanOrEqual(ChakraSequence.defaultBeatHz, ChakraSequence.maxBeatHz)
    }

    /// The step is the *switch timer*: how long a chakra lasts before the next one. The
    /// choices run from half a minute to five.
    func testTheDefaultStepIsHalfAMinuteAndTheChoicesAreOrdered() {
        XCTAssertEqual(ChakraSequence.defaultStepSeconds, 30)
        XCTAssertEqual(ChakraSequence.stepSecondsChoices, [30, 60, 120, 300])
        XCTAssertTrue(
            ChakraSequence.stepSecondsChoices.contains(ChakraSequence.defaultStepSeconds)
        )
    }

    // MARK: - The pair

    /// The carrier is the step's own frequency and the beat is split evenly, so the
    /// pitch a listener hears stays on the solfeggio note.
    func testThePairIsCentredOnTheCarrier() {
        let step = ChakraSequence.steps[3]           // 528 Hz, the solar plexus
        let (left, right) = ChakraSequence.pair(for: step, beatHz: 21)
        XCTAssertEqual((left + right) / 2, 528, accuracy: 0.05)
        XCTAssertEqual(right - left, 21, accuracy: 0.05)
    }

    /// Every step with every offered beat stays on the 0.1 Hz grid and inside the
    /// audible range. The engine only plays quantised frequencies, so an unquantised
    /// pair would not be what the slider and the readout show.
    func testEveryPairIsQuantisedAndAudible() {
        for step in ChakraSequence.steps {
            for beat in [ChakraSequence.minBeatHz, 21.0, 40.0] {
                let (left, right) = ChakraSequence.pair(for: step, beatHz: beat)
                XCTAssertEqual(left, FrequencyGrid.quantized(left), accuracy: 1e-9)
                XCTAssertEqual(right, FrequencyGrid.quantized(right), accuracy: 1e-9)
                XCTAssertGreaterThanOrEqual(left, FrequencyGrid.minHz)
                XCTAssertLessThanOrEqual(right, FrequencyGrid.maxHz)
            }
        }
    }

    /// A beat outside the range is clamped rather than refused: the field it comes from
    /// is free text, and refusing would leave the mode stuck on the old value.
    func testTheBeatIsClampedIntoRange() {
        let step = ChakraSequence.steps[0]
        let (lowLeft, lowRight) = ChakraSequence.pair(for: step, beatHz: 0)
        XCTAssertEqual(lowRight - lowLeft, ChakraSequence.minBeatHz, accuracy: 0.1)
        let (highLeft, highRight) = ChakraSequence.pair(for: step, beatHz: 5000)
        XCTAssertEqual(highRight - highLeft, ChakraSequence.maxBeatHz, accuracy: 0.1)
    }

    /// A half-typed field is not a number, and a non-finite beat must not reach the
    /// engine.
    func testANonFiniteBeatFallsBackToTheDefault() {
        let step = ChakraSequence.steps[0]
        let (left, right) = ChakraSequence.pair(for: step, beatHz: .nan)
        XCTAssertEqual(right - left, ChakraSequence.defaultBeatHz, accuracy: 0.1)
        let (infLeft, infRight) = ChakraSequence.pair(for: step, beatHz: .infinity)
        XCTAssertEqual(infRight - infLeft, ChakraSequence.defaultBeatHz, accuracy: 0.1)
    }

    // MARK: - Indexing

    /// The step index moves with a timer, so an out-of-range value has to be survivable
    /// rather than fatal.
    func testTheIndexIsClampedIntoRange() {
        XCTAssertEqual(ChakraSequence.index(of: -5), 0)
        XCTAssertEqual(ChakraSequence.index(of: 0), 0)
        XCTAssertEqual(ChakraSequence.index(of: 6), 6)
        XCTAssertEqual(ChakraSequence.index(of: 99), ChakraSequence.steps.count - 1)
    }

    func testAStepIsFoundByItsId() {
        XCTAssertEqual(ChakraSequence.step(id: "heart")?.hz, 639)
        XCTAssertNil(ChakraSequence.step(id: "kundalini"))
    }
}
