import Foundation

/// Beat/carrier arithmetic — the Swift half of `docs/CONTRACT.md` §1.
///
/// Ported from `src/binaural/core/oscillator.py`. Pure maths: no audio, no UI, so it
/// is unit-testable without any device (CONTRACT rule 5).
public enum BeatMath {

    // MARK: - Constants (CONTRACT §1)

    /// Carrier used when none is given. Low carriers work best (SPEC §2.1: peak
    /// response around 250 Hz, nothing detected above 3 kHz).
    public static let defaultCarrierHz: Double = 200.0

    /// Lowest frequency the sliders and the entry points accept.
    public static let minFrequencyHz: Double = 1.0

    /// Highest frequency the sliders and the entry points accept.
    public static let maxFrequencyHz: Double = 20_000.0

    /// Outside this the beat is a hint, not an error.
    public static let maxBeatHz: Double = 100.0

    /// Perceptual range quoted in SPEC §2.1 / CONTRACT §1.
    public static let recommendedBeatRangeHz: ClosedRange<Double> = 0.5...100.0

    /// Default fade ramp, in seconds. Short enough to feel instant, long enough
    /// that the step is not a click (SPEC §F2).
    public static let defaultRampSeconds: Double = 0.03

    /// Fallback sample rate when the output device does not report one.
    public static let defaultSampleRate: Int = 48_000

    // MARK: - Arithmetic

    /// The perceived tone: `|fL - fR|`.
    public static func beatFrequency(leftHz: Double, rightHz: Double) -> Double {
        abs(leftHz - rightHz)
    }

    /// The tone each ear actually hears: `(fL + fR) / 2`.
    public static func carrierFrequency(leftHz: Double, rightHz: Double) -> Double {
        (leftHz + rightHz) / 2.0
    }

    /// The `(fL, fR)` pair that produces `beatHz` around `carrierHz`:
    /// `fL = c - b/2`, `fR = c + b/2`.
    ///
    /// - Throws: ``FrequencyError/negativeBeat(_:)`` for a negative beat, or
    ///   ``FrequencyError/outOfRange(name:value:)`` when either side would leave the
    ///   audible range — the same cases the Python `pair_from_beat` rejects.
    public static func pair(
        fromBeat beatHz: Double,
        carrierHz: Double = BeatMath.defaultCarrierHz
    ) throws -> (left: Double, right: Double) {
        guard beatHz.isFinite else {
            throw FrequencyError.notFinite(name: "beat_hz", value: beatHz)
        }
        guard beatHz >= 0 else {
            throw FrequencyError.negativeBeat(beatHz)
        }
        guard carrierHz.isFinite else {
            throw FrequencyError.notFinite(name: "carrier_hz", value: carrierHz)
        }
        let half = beatHz / 2.0
        return (
            try validated(carrierHz - half, name: "left_hz"),
            try validated(carrierHz + half, name: "right_hz")
        )
    }

    /// True when the beat sits inside ``recommendedBeatRangeHz``.
    public static func isRecommendedBeat(_ beatHz: Double) -> Bool {
        recommendedBeatRangeHz.contains(beatHz)
    }

    // MARK: - Validation

    /// Accepts only finite frequencies inside the audible range.
    public static func validated(_ hz: Double, name: String = "frequency") throws -> Double {
        guard hz.isFinite else {
            throw FrequencyError.notFinite(name: name, value: hz)
        }
        guard hz >= minFrequencyHz, hz <= maxFrequencyHz else {
            throw FrequencyError.outOfRange(name: name, value: hz)
        }
        return hz
    }
}

/// Why a frequency was rejected. Mirrors the `ValueError`s raised by the Python
/// implementation, including their wording.
public enum FrequencyError: Error, Equatable, CustomStringConvertible, Sendable {
    case notFinite(name: String, value: Double)
    case outOfRange(name: String, value: Double)
    case negativeBeat(Double)
    case invalidSampleRate(Int)

    public var description: String {
        switch self {
        case let .notFinite(name, value):
            return "\(name) must be finite, got \(value)"
        case let .outOfRange(name, value):
            return "\(name) must be within [\(BeatMath.minFrequencyHz), \(BeatMath.maxFrequencyHz)] Hz, got \(value)"
        case let .negativeBeat(value):
            return "beat must be >= 0, got \(value)"
        case let .invalidSampleRate(rate):
            return "sample_rate must be > 0, got \(rate)"
        }
    }
}