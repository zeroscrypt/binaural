import XCTest

@testable import BinauralCore

/// The allocation-free render path M2-a added for the audio callback.
///
/// `render(frames:)` still allocates two arrays per call, which is fine for tests and
/// offline rendering but not for a real-time thread. `render(frames:into:intoRight:)` is
/// what the audio thread calls, so it has to produce *identical* samples and identical
/// state — these tests pin that, because a divergence between the two would mean the
/// parity suite proves nothing about what is actually heard.
final class StereoOscillatorBufferTests: XCTestCase {

    private let rate = 48_000

    private func makeOscillator() throws -> StereoOscillator {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 205, rightHz: 215)
        oscillator.setFade(1.0, rampSeconds: 0)
        return oscillator
    }

    func testBufferRenderMatchesTheArrayRender() throws {
        let frames = 512
        let arrayOscillator = try makeOscillator()
        let expected = arrayOscillator.render(frames: frames)

        let bufferOscillator = try makeOscillator()
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                bufferOscillator.render(frames: frames, into: leftBuffer, intoRight: rightBuffer)
            }
        }

        XCTAssertEqual(left, expected.left)
        XCTAssertEqual(right, expected.right)
        // State advanced identically too.
        XCTAssertEqual(bufferOscillator.phase.left, arrayOscillator.phase.left)
        XCTAssertEqual(bufferOscillator.phase.right, arrayOscillator.phase.right)
        XCTAssertEqual(bufferOscillator.gain, arrayOscillator.gain)
    }

    /// Chunking must not change the output — the property CONTRACT §1 asks of
    /// `render`, now for the buffer form too.
    func testChunkingDoesNotChangeTheOutput() throws {
        let frames = 4_096

        let single = try makeOscillator()
        var whole = [Float](repeating: 0, count: frames)
        var wholeRight = [Float](repeating: 0, count: frames)
        whole.withUnsafeMutableBufferPointer { leftBuffer in
            wholeRight.withUnsafeMutableBufferPointer { rightBuffer in
                single.render(frames: frames, into: leftBuffer, intoRight: rightBuffer)
            }
        }

        let chunked = try makeOscillator()
        var assembled = [Float](repeating: 0, count: frames)
        var assembledRight = [Float](repeating: 0, count: frames)
        var offset = 0
        for size in [128, 512, 64, 1_024, 256, 512, 1_600] {
            var left = [Float](repeating: 0, count: size)
            var right = [Float](repeating: 0, count: size)
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    chunked.render(frames: size, into: leftBuffer, intoRight: rightBuffer)
                }
            }
            for index in 0..<size {
                assembled[offset + index] = left[index]
                assembledRight[offset + index] = right[index]
            }
            offset += size
        }

        XCTAssertEqual(offset, frames)
        XCTAssertEqual(assembled, whole)
        XCTAssertEqual(assembledRight, wholeRight)
    }

    /// The shorter buffer decides the length: a partially filled buffer is left alone
    /// rather than overrun. This is what makes an over-sized engine block safe.
    func testShorterBufferIsNotOverrun() throws {
        let oscillator = try makeOscillator()
        var left = [Float](repeating: 9, count: 10)
        var right = [Float](repeating: 9, count: 10)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                oscillator.render(frames: 1_000, into: leftBuffer, intoRight: rightBuffer)
            }
        }
        XCTAssertEqual(left.count, 10)
        XCTAssertNotEqual(left[9], 9, "the 10 samples the buffer does have were written")
        XCTAssertFalse(left.contains(9), "and nothing beyond was touched")
    }

    func testZeroAndEmptyBuffersAreSafe() throws {
        let oscillator = try makeOscillator()
        let framesBefore = oscillator.phase
        var empty = [Float]()
        var scratch = [Float]()
        empty.withUnsafeMutableBufferPointer { leftBuffer in
            scratch.withUnsafeMutableBufferPointer { rightBuffer in
                oscillator.render(frames: 512, into: leftBuffer, intoRight: rightBuffer)
            }
        }
        XCTAssertEqual(oscillator.phase.left, framesBefore.left, "an empty buffer renders nothing")
        XCTAssertEqual(oscillator.phase.right, framesBefore.right)
    }

    /// Same maths, therefore same audible result: the buffer path is the closed-form sine
    /// at the same 1e-6 tolerance the M1 suite uses (see `StereoOscillatorTests`).
    func testBufferRenderMatchesTheAnalyticSine() throws {
        let oscillator = try StereoOscillator(sampleRate: rate)
        try oscillator.setFrequencies(leftHz: 440, rightHz: 440)
        oscillator.setFade(1.0, rampSeconds: 0)

        let frames = 4_096
        var left = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { buffer in
            var right = [Float](repeating: 0, count: frames)
            right.withUnsafeMutableBufferPointer { rightBuffer in
                oscillator.render(frames: frames, into: buffer, intoRight: rightBuffer)
            }
        }

        assertClose(SignalAnalysis.frequency(of: left, sampleRate: Double(rate)), 440, accuracy: 0.5)
        // First sample is phase 0, so exactly zero; the peak is full scale.
        XCTAssertEqual(left[0], 0, accuracy: 1e-6)
        assertClose(Double(SignalAnalysis.peak(left)), 1, accuracy: 1e-5)
    }
}