import Foundation

/// Two rendered channel buffers.
public struct StereoBuffer: Sendable, Equatable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    /// Number of frames per channel.
    public var frameCount: Int { left.count }

    /// True when both channels are present and the same length.
    public var isWellFormed: Bool { left.count == right.count }
}

/// Offline renderer for a whole binaural pair.
///
/// The Python implementation only ever renders audio *live* (block by block from the
/// audio callback in `core/engine.py`), so there is no Python counterpart to copy here.
/// What is reused, unchanged, is the waveform and the phase accumulation:
/// ``Synthesizer`` drives a ``StereoOscillator`` exactly as the engine does, one block
/// at a time, and hands back the two buffers.
///
/// The ramp is the same one the engine uses: the buffer starts at silence and the gain
/// accumulates to full scale, so the first sample is not a step (SPEC §F2, "no
/// clicks"). The buffer ends at full scale — a fade-out would mean inventing an
/// envelope the Python renderer does not have.
///
/// A value type, hence `Sendable`: it holds no mutable state between calls.
public struct Synthesizer: Sendable {

    /// Seconds the amplitude takes to reach full scale.
    public let rampSeconds: Double

    /// Frames per chunk handed to the oscillator. Matches the ~256-frame buffer a
    /// typical 48 kHz render callback pulls; it does not change the output because the
    /// fade is accumulated per sample.
    public static let defaultChunkSize = 1024

    public init(rampSeconds: Double = BeatMath.defaultRampSeconds) {
        self.rampSeconds = rampSeconds
    }

    /// Render `duration` seconds of the pair that produces `beatHz` around `carrierHz`.
    ///
    /// - Throws: ``FrequencyError`` when the pair is impossible (negative beat, or a
    ///   channel outside the audible range) or the sample rate is not positive.
    public func render(
        beatHz: Double,
        carrierHz: Double = BeatMath.defaultCarrierHz,
        duration: Double,
        sampleRate: Int = BeatMath.defaultSampleRate
    ) throws -> StereoBuffer {
        let (leftHz, rightHz) = try BeatMath.pair(fromBeat: beatHz, carrierHz: carrierHz)
        return try render(
            leftHz: leftHz,
            rightHz: rightHz,
            duration: duration,
            sampleRate: sampleRate
        )
    }

    /// Render `duration` seconds of an explicit frequency pair.
    public func render(
        leftHz: Double,
        rightHz: Double,
        duration: Double,
        sampleRate: Int = BeatMath.defaultSampleRate
    ) throws -> StereoBuffer {
        guard duration.isFinite, duration >= 0 else {
            throw FrequencyError.notFinite(name: "duration", value: duration)
        }

        let oscillator = try StereoOscillator(sampleRate: sampleRate)
        try oscillator.setFrequencies(leftHz: leftHz, rightHz: rightHz)
        oscillator.setFade(1.0, rampSeconds: rampSeconds)

        let total = Int((duration * Double(sampleRate)).rounded())
        guard total > 0 else { return StereoBuffer(left: [], right: []) }

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(total)
        right.reserveCapacity(total)

        var remaining = total
        while remaining > 0 {
            let chunk = min(Synthesizer.defaultChunkSize, remaining)
            let block = oscillator.render(frames: chunk)
            left.append(contentsOf: block.left)
            right.append(contentsOf: block.right)
            remaining -= chunk
        }

        return StereoBuffer(left: left, right: right)
    }
}