import XCTest

@testable import BinauralCore

/// The offline renderer has no Python counterpart — `core/engine.py` only ever renders
/// live — so these tests pin down what it must produce against the oscillator it is built
/// on: the same waveform, the same phase accumulation, the same fade.
final class SynthesizerTests: XCTestCase {

    private let rate = 48_000

    func testRenderHonoursDurationAndSampleRate() throws {
        let buffer = try Synthesizer().render(beatHz: 10, duration: 0.5, sampleRate: rate)
        XCTAssertEqual(buffer.frameCount, rate / 2)
        XCTAssertEqual(buffer.left.count, buffer.right.count)
        XCTAssertTrue(buffer.isWellFormed)
    }

    func testRenderFrequenciesMatchThePair() throws {
        // Frequency tolerance: the zero-crossing estimate is bounded by 1/window
        // (≈0.5 Hz over a 2 s window) and lands far inside that; 1.0 Hz is the stated
        // tolerance. The closed-form check below pins the frequency down exactly.
        let beat = 10.0
        let carrier = 200.0
        let buffer = try Synthesizer().render(
            beatHz: beat, carrierHz: carrier, duration: 2.0, sampleRate: rate
        )

        let leftHz = SignalAnalysis.frequency(of: buffer.left, sampleRate: Double(rate))
        let rightHz = SignalAnalysis.frequency(of: buffer.right, sampleRate: Double(rate))
        assertClose(leftHz, carrier - beat / 2, accuracy: 1.0, "left channel frequency")
        assertClose(rightHz, carrier + beat / 2, accuracy: 1.0, "right channel frequency")
        assertClose(abs(rightHz - leftHz), beat, accuracy: 1.0, "beat difference")
    }

    func testPeakAmplitudeIsFullScale() throws {
        let buffer = try Synthesizer().render(beatHz: 10, duration: 1.0, sampleRate: rate)
        // Peak amplitude tolerance 1e-3: the fade reaches 1/e per 30 ms and snaps to the
        // target once it is within 1e-6, so the steady part of the buffer is full scale.
        assertClose(Double(SignalAnalysis.peak(buffer.left)), 1.0, accuracy: 1e-3, "left peak")
        assertClose(Double(SignalAnalysis.peak(buffer.right)), 1.0, accuracy: 1e-3, "right peak")
    }

    func testBufferStartsAtSilenceAndRampsIn() throws {
        let buffer = try Synthesizer().render(beatHz: 10, duration: 1.0, sampleRate: rate)
        // First sample is exactly zero (the fade starts from zero gain, as in Python).
        XCTAssertEqual(buffer.left[0], 0)
        // And the opening is a ramp, not a step: the first milliseconds are quieter than
        // the steady part.
        let opening = Array(buffer.left[0..<(rate / 20)])
        XCTAssertLessThan(SignalAnalysis.rms(opening), SignalAnalysis.rms(buffer.left) * 0.6)
    }

    func testSamplesMatchClosedFormOnceGainSettled() throws {
        // No fade: the buffer is exactly sin(2*pi*f*n/rate), to single precision.
        let beat = 10.0
        let carrier = 200.0
        let leftHz = carrier - beat / 2
        let buffer = try Synthesizer(rampSeconds: 0).render(
            beatHz: beat, carrierHz: carrier, duration: 0.2, sampleRate: rate
        )
        for n in 0..<buffer.frameCount {
            let expected = sin(2 * Double.pi * leftHz * Double(n) / Double(rate))
            assertClose(Double(buffer.left[n]), expected, accuracy: 1e-6, "left sample \(n)")
        }
    }

    func testCarriersAreIndependent() throws {
        let buffer = try Synthesizer().render(
            leftHz: 200, rightHz: 300, duration: 0.5, sampleRate: rate
        )
        XCTAssertNotEqual(buffer.left, buffer.right)
        assertClose(
            SignalAnalysis.frequency(of: buffer.left, sampleRate: Double(rate)),
            200, accuracy: 1.0
        )
        assertClose(
            SignalAnalysis.frequency(of: buffer.right, sampleRate: Double(rate)),
            300, accuracy: 1.0
        )
    }

    func testRejectsImpossiblePairs() {
        XCTAssertThrowsError(try Synthesizer().render(beatHz: 10, carrierHz: 5, duration: 1))
        XCTAssertThrowsError(try Synthesizer().render(beatHz: -1, duration: 1))
        XCTAssertThrowsError(try Synthesizer().render(beatHz: 10, duration: 1, sampleRate: 0))
    }

    func testZeroDurationRendersNothing() throws {
        let buffer = try Synthesizer().render(beatHz: 10, duration: 0, sampleRate: rate)
        XCTAssertEqual(buffer.frameCount, 0)
    }

    func testChunkingDoesNotChangeTheOutput() throws {
        // The render loop hands the oscillator 1024-frame chunks; the accumulator must
        // make the result independent of that boundary.
        let buffer = try Synthesizer().render(beatHz: 10, duration: 0.25, sampleRate: rate)
        let direct = try StereoOscillator(sampleRate: rate)
        try direct.setFrequencies(leftHz: 195, rightHz: 205)
        direct.setFade(1.0, rampSeconds: BeatMath.defaultRampSeconds)
        let whole = direct.render(frames: buffer.frameCount)
        XCTAssertEqual(buffer.left, whole.left)
        XCTAssertEqual(buffer.right, whole.right)
    }
}