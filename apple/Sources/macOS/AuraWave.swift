import Foundation

/// The waves the aura is made of.
///
/// The aura is not decoration on top of a picture: it is a picture of three things that
/// are happening anyway — the beat, the step the journey is on, and the colour of the
/// chakra being played. The waves are **summed** into one amplitude, so they do not
/// argue with each other: what the eye sees is the sum of them, in the colour of the
/// step.
///
/// The rules of the sum are the same as the rules of the picture: the ring closes on
/// itself after one round, so every rate here is a whole number of cycles per round,
/// and the wave's phase is continuous across a step's boundary.
enum AuraWave {

    /// How long the ring's round takes, in seconds.
    ///
    /// The round is the unit the whole aura is measured in: the grains go round it once,
    /// and every wave on it is a whole number of cycles per round.
    static let roundSeconds: Double = 16

    /// How long the beat's wave takes to go round the ring, in seconds.
    ///
    /// The beat is between half a hertz and forty, and none of that is visible: the eye
    /// cannot follow twenty-one pulses a second. The wave is slowed by a factor
    /// everywhere, so a faster beat means a faster wave and a slower one a slower wave,
    /// but always something the eye can follow — a flashlight rather than a strobe.
    static func beatPeriod(beatHz: Double) -> Double {
        guard beatHz > 0 else { return roundSeconds }
        let period = roundSeconds * 21 / beatHz
        return min(40, max(4, period))
    }

    /// How long the step's wave takes to go round the ring, in seconds: one step.
    ///
    /// The wave therefore says how much of the step is left — it is at the start of the
    /// ring when the step begins and at the end of it when the step ends.
    static func stepPeriod(stepSeconds: Int) -> Double {
        Double(max(1, stepSeconds))
    }

    /// The wave's shape at a place on the ring.
    ///
    /// A bump and not a sine: a wave is a thing that goes round, and a sine reads as a
    /// texture. `sharpness` is how narrow the bump is — the beat's is narrow, like the
    /// beam of a flashlight, and the step's is broad.
    static func bump(at s: CGFloat, phase: CGFloat, sharpness: CGFloat) -> CGFloat {
        let angle = 2 * .pi * (s - phase)
        let value = (cos(angle) + 1) / 2
        return pow(value, sharpness)
    }

    /// The beat's wave, as a place on the ring.
    ///
    /// `travel` is the fraction of the round the grains have come round, so the phase
    /// is measured in the same units as everything else.
    static func beatPhase(travel: CGFloat, beatHz: Double) -> CGFloat {
        let period = beatPeriod(beatHz: beatHz)
        guard period > 0 else { return 0 }
        return travel * CGFloat(roundSeconds / period)
    }
}
