import XCTest

@testable import BinauralCore

/// Parity with `tests/test_oscillator.py::StereoOscillator`.
///
/// The Python test asserts the closed-form sine at `abs=1e-12` because its buffers are
/// doubles. CONTRACT §1 asks for "float32-like samples", so the Swift buffers are
/// `[Float]` and the same comparison is stated at `1e-6` — the single-precision
/// resolution, nothing looser.
final class StereoOscillatorTests: XCTestCase {

    private let rate = 48_000

    func testInitialState() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        XCTAssertEqual(oscillator.sampleRate, rate)
        XCTAssertEqual(oscillator.leftHz, BeatMath.defaultCarrierHz)
        XCTAssertEqual(oscillator.rightHz, BeatMath.defaultCarrierHz)
        XCTAssertEqual(oscillator.gain, 0.0)
    }

    func testRenderReturnsRequestedLength() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        oscillator.setFade(1.0, rampSeconds: 0)
        for frames in [1, 64, 1024] {
            let block = oscillator.render(frames: frames)
            XCTAssertEqual(block.left.count, frames)
            XCTAssertEqual(block.right.count, frames)
        }
    }

    func testRenderZeroFrames() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        let block = oscillator.render(frames: 0)
        XCTAssertTrue(block.left.isEmpty)
        XCTAssertTrue(block.right.isEmpty)
    }

    func testRenderSamplesMatchAnalyticSine() throws {
        // Ramp disabled: the block must equal the closed-form sine.
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 1000, rightHz: 1000)
        oscillator.setFade(1.0, rampSeconds: 0)

        let block = oscillator.render(frames: 256)
        for n in 0..<256 {
            let expected = sin(2 * Double.pi * 1000.0 * Double(n) / Double(rate))
            assertClose(Double(block.left[n]), expected, accuracy: 1e-6, "left sample \(n)")
            assertClose(Double(block.right[n]), expected, accuracy: 1e-6, "right sample \(n)")
        }
    }

    func testChannelsAreIndependent() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 200, rightHz: 300)
        oscillator.setFade(1.0, rampSeconds: 0)

        let block = oscillator.render(frames: 512)
        XCTAssertNotEqual(block.left, block.right)
        assertClose(Double(SignalAnalysis.peak(block.left)), 1.0, accuracy: 1e-3)
        assertClose(Double(SignalAnalysis.peak(block.right)), 1.0, accuracy: 1e-3)
    }

    func testPhaseSurvivesFrequencyChange() throws {
        // No click: the step between consecutive blocks stays small.
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 205, rightHz: 215)
        oscillator.setFade(1.0, rampSeconds: 0)

        let first = oscillator.render(frames: 1000)
        try oscillator.setFrequencies(leftHz: 210, rightHz: 210)   // jump; phase continues
        let second = oscillator.render(frames: 1000)

        XCTAssertLessThan(abs(Double(second.left[0]) - Double(first.left[999])), 0.1)

        // A phase reset would restart at 0.0 and produce a large jump here.
        let phase = oscillator.phase
        XCTAssertTrue((0.0..<1.0).contains(phase.left))
        XCTAssertTrue((0.0..<1.0).contains(phase.right))
        XCTAssertTrue(phase.left != 0.0 || phase.right != 0.0)
    }

    func testPhaseStaysNormalisedOverLongRun() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 20000, rightHz: 19999.5)
        oscillator.setFade(1.0, rampSeconds: 0)
        for _ in 0..<50 {
            _ = oscillator.render(frames: 4096)
        }
        let phase = oscillator.phase
        XCTAssertTrue((0.0..<1.0).contains(phase.left))
        XCTAssertTrue((0.0..<1.0).contains(phase.right))
    }

    func testFadeRampsFromZeroToOne() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 200, rightHz: 200)
        oscillator.setFade(0.0, rampSeconds: 0.05)
        XCTAssertEqual(SignalAnalysis.peak(oscillator.render(frames: 1024).left), 0)

        oscillator.setFade(1.0, rampSeconds: 0.05)
        let block = oscillator.render(frames: 1024)
        let firstPeak = Double(SignalAnalysis.peak(block.left))
        XCTAssertGreaterThan(firstPeak, 0.0)
        XCTAssertLessThan(firstPeak, 1.0)   // smooth, not instant

        var last = 0.0
        for _ in 0..<20 {
            last = Double(SignalAnalysis.peak(oscillator.render(frames: 1024).left))
        }
        assertClose(last, 1.0, accuracy: 1e-3)
    }

    func testFadeIsIndependentOfBlockSize() throws {
        // Accumulation happens per sample, so block size must not change the curve.
        func run(chunk: Int) throws -> [Float] {
            let oscillator = try StereoOscillator(sampleRate: rate)
            try oscillator.setFrequencies(leftHz: 200, rightHz: 200)
            oscillator.setFade(1.0, rampSeconds: 0.02)
            var out: [Float] = []
            for _ in 0..<(2000 / chunk) {
                out.append(contentsOf: oscillator.render(frames: chunk).left)
            }
            return out
        }

        let coarse = try run(chunk: 100)
        let fine = try run(chunk: 10)
        XCTAssertEqual(coarse.count, fine.count)
        for (a, b) in zip(coarse, fine) {
            XCTAssertLessThan(abs(Double(a) - Double(b)), 1e-12)
        }
    }

    func testFadeDownToZero() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 200, rightHz: 200)
        oscillator.setFade(1.0, rampSeconds: 0)
        _ = oscillator.render(frames: 2048)
        assertClose(oscillator.gain, 1.0, accuracy: 1e-9)

        oscillator.setFade(0.0, rampSeconds: 0.01)
        for _ in 0..<20 {
            _ = oscillator.render(frames: 1024)
        }
        XCTAssertLessThan(Double(SignalAnalysis.peak(oscillator.render(frames: 1024).left)), 0.01)
        assertClose(oscillator.gain, 0.0, accuracy: 1e-6)
    }

    func testGainIsClamped() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        oscillator.setFade(5.0, rampSeconds: 0)
        XCTAssertEqual(oscillator.targetGain, 1.0)
        oscillator.setFade(-3.0, rampSeconds: 0)
        XCTAssertEqual(oscillator.targetGain, 0.0)
    }

    func testSetSampleRateKeepsPhase() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 300, rightHz: 300)
        oscillator.setFade(1.0, rampSeconds: 0.03)
        _ = oscillator.render(frames: 500)
        let before = oscillator.phase

        try oscillator.setSampleRate(44100)
        XCTAssertEqual(oscillator.sampleRate, 44100)
        assertClose(oscillator.phase.left, before.left, accuracy: 1e-12)
        assertClose(oscillator.phase.right, before.right, accuracy: 1e-12)
    }

    func testOutOfRangeFrequenciesThrow() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        for bad in [0.5, 0.0, -100.0, 20000.1, 30000.0] {
            XCTAssertThrowsError(try oscillator.setFrequencies(leftHz: bad, rightHz: 200), "\(bad)")
            XCTAssertThrowsError(try oscillator.setFrequencies(leftHz: 200, rightHz: bad), "\(bad)")
        }
        XCTAssertThrowsError(try oscillator.setFrequencies(leftHz: .nan, rightHz: 200))
    }

    func testInvalidSampleRateThrows() {
        XCTAssertThrowsError(try StereoOscillator(sampleRate: 0)) { error in
            XCTAssertEqual(error as? FrequencyError, .invalidSampleRate(0))
        }
    }

    func testPanSilencesOneChannel() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 440, rightHz: 440)
        oscillator.setFade(1.0, rampSeconds: 0)
        oscillator.setPan(left: 1, right: 0)
        let block = oscillator.render(frames: 256)
        XCTAssertEqual(SignalAnalysis.peak(block.left) > 0.5, true)
        XCTAssertEqual(block.right, [Float](repeating: 0, count: 256))
    }
}