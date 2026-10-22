import Foundation

/// One step of the chakra sequence: a solfeggio frequency and an id.
///
/// The step carries no text. The names and the descriptions are catalogue entries, so
/// they are looked up through ``L10n`` at the moment they are shown — the same way the
/// rest of the interface reads its captions, and the same way the Python side does it.
/// Storing a second copy of the Russian text here would be a second thing to keep in
/// step with `ru.py`, and there is no gain: the catalogue is the one place a string
/// lives.
public struct ChakraStep: Sendable, Equatable, Identifiable {

    public let id: String
    /// The solfeggio frequency this step plays, in Hz.
    public let hz: Double

    public init(id: String, hz: Double) {
        self.id = id
        self.hz = hz
    }
}

/// The seven solfeggio chakras, root to crown, and the rules for playing them.
///
/// The frequencies are the solfeggio set — 396, 417, 528, 639, 741, 852, 963 Hz — and
/// they are **carriers**, not beats. A listener hears the carrier as the pitch and the
/// difference between the ears as the beat, which is the same division of labour every
/// other mode in this app uses.
///
/// ## Where the default beat comes from
///
/// The default of 21 Hz is not a round number someone picked. It was *measured*: a
/// reference app playing this same sequence was recorded, and its left and right
/// channels turned out to be identical, so the pulsing was not binaural at all — it was
/// two tones summed inside one ear, and the envelope of that sum pulsated at a measured
/// 21.00 Hz in every step after the first. That measurement is what this default
/// reproduces, and the number is exposed because a different figure suits a different
/// listener: 21 Hz sits in the alpha band, which many people find bright, and the same
/// carrier works just as well with 8 or 12.
public enum ChakraSequence {

    /// The steps, earth first. The order is the whole point of the mode: the sound rises
    /// from the ground through the body to the crown.
    ///
    /// The first step is not one of the seven chakras. The **earth** step is 174 Hz — the
    /// lowest tone of the extended Solfeggio set, the one traditionally called *the
    /// foundation*: grounding, stability, easing physical tension. It sits below the root
    /// the way the earth sits below the body, and without it the sequence starts at the
    /// root, which is already one step up the spine.
    ///
    /// (There is an "earth star" in some esoteric systems, but it is said to lie below
    /// the soles of the feet and to have no frequency in this system at all. 174 Hz is
    /// the closest thing to an earth frequency that is actually a note.)
    public static let steps: [ChakraStep] = [
        ChakraStep(id: "earth", hz: 174),
        ChakraStep(id: "root", hz: 396),
        ChakraStep(id: "sacral", hz: 417),
        ChakraStep(id: "solar-plexus", hz: 528),
        ChakraStep(id: "heart", hz: 639),
        ChakraStep(id: "throat", hz: 741),
        ChakraStep(id: "third-eye", hz: 852),
        ChakraStep(id: "crown", hz: 963)
    ]

    /// The beat the mode starts on. 21 Hz, measured — see the type's documentation.
    public static let defaultBeatHz: Double = 21.0

    /// The offered lengths of one step, in seconds.
    ///
    /// This is the *switch timer*: how long a chakra lasts before the next one. The
    /// journey's total follows from it and the number of steps, and the journey ends by
    /// itself when it is over.
    public static let stepSecondsChoices: [Int] = [30, 60, 120, 300]

    /// The length a step starts on, in seconds.
    public static let defaultStepSeconds: Int = 30

    /// A step length as a caption: `30 s`, `1 min`, `5 min`.
    @MainActor
    public static func stepText(_ seconds: Int) -> String {
        if seconds < 60 {
            return L10n.tr("%1 s", String(seconds))
        }
        return L10n.tr("%1 min", String(seconds / 60))
    }

    /// Which way a journey walks first.
    public enum Direction: String, Sendable, CaseIterable {
        /// From the earth upwards, to the crown and back down.
        case up
        /// From the crown downwards, to the earth and back up.
        case down

        /// The caption of the direction control, in the current language.
        @MainActor
        public func name(for language: LanguageCode) -> String {
            switch self {
            case .up: return L10n.tr("Up, then back")
            case .down: return L10n.tr("Down, then back")
            }
        }
    }

    /// Where a journey starts when the user has not picked a step.
    ///
    /// The direction decides which end the walk begins at: "up" starts at the earth and
    /// climbs, "down" starts at the crown and descends. Either way the journey covers
    /// the whole body and comes back.
    public static func defaultStart(for direction: Direction) -> Int {
        direction == .up ? 0 : steps.count - 1
    }

    /// The steps a journey visits, in order.
    ///
    /// The journey goes from one end of the body to the other and comes back, and
    /// stops there. A walk that ended at the crown would leave the sound playing with
    /// nowhere left to go, and one that went up and down forever would never be
    /// finished.
    ///
    /// The last entry is the step the journey *ends* on, and the mode switches itself
    /// off there.
    public static func journey(from start: Int, direction: Direction) -> [Int] {
        let start = index(of: start)
        let forward = direction == .up
            ? Array(start...steps.count - 1)
            : Array((0...start).reversed())
        return forward + forward.dropLast().reversed()
    }

    /// The number of steps a journey visits.
    public static func journeyLength(from start: Int, direction: Direction) -> Int {
        journey(from: start, direction: direction).count
    }

    /// The shortest and longest beat the mode accepts. The upper bound is roughly where
    /// a binaural difference stops being heard as a beat and starts being heard as
    /// roughness; the lower one keeps the difference audible against a 396 Hz carrier.
    public static let minBeatHz: Double = 0.5
    public static let maxBeatHz: Double = 40.0

    // MARK: - Names

    /// The name of a step, in the current language.
    @MainActor
    public static func name(of step: ChakraStep) -> String {
        switch step.id {
        case "earth": return L10n.tr("Earth")
        case "root": return L10n.tr("Root")
        case "sacral": return L10n.tr("Sacral")
        case "solar-plexus": return L10n.tr("Solar plexus")
        case "heart": return L10n.tr("Heart")
        case "throat": return L10n.tr("Throat")
        case "third-eye": return L10n.tr("Third eye")
        case "crown": return L10n.tr("Crown")
        default: return step.id
        }
    }

    /// What a step is about, in the current language.
    @MainActor
    public static func description(of step: ChakraStep) -> String {
        switch step.id {
        case "earth":
            return L10n.tr("Ground and stability: the body's own base.")
        case "root":
            return L10n.tr("Letting go of fear and touching ground.")
        case "sacral":
            return L10n.tr("Undoing what got stuck and opening up to change.")
        case "solar-plexus":
            return L10n.tr("The love frequency. The best known of the nine.")
        case "heart":
            return L10n.tr("Relationships, connection, forgiving others.")
        case "throat":
            return L10n.tr("Finding your words and telling the truth.")
        case "third-eye":
            return L10n.tr("Seeing clearly before you decide.")
        case "crown":
            return L10n.tr("Unity and presence, to feel whole.")
        default:
            return ""
        }
    }

    // MARK: - Captions

    /// The name of the mode.
    @MainActor
    public static var modeName: String { L10n.tr("Chakras") }

    /// The caption of the beat control.
    @MainActor
    public static var beatCaption: String { L10n.tr("Beat") }

    /// Why the default beat is what it is. The number is on screen anyway, and a number
    /// without a reason reads as an arbitrary constant.
    @MainActor
    public static var defaultBeatNote: String {
        L10n.tr("The default 21 Hz sits in the alpha band.")
    }

    // MARK: - Lookup

    /// The step with the given id, or `nil` when there is no such step.
    public static func step(id: String) -> ChakraStep? {
        steps.first { $0.id == id }
    }

    /// The index of a step, clamped into range. An out-of-range index is not an error
    /// here: the step index moves with a timer, and a stale value must not be able to
    /// stop the sequence.
    public static func index(of stepIndex: Int) -> Int {
        min(max(0, stepIndex), steps.count - 1)
    }

    // MARK: - The pair

    /// The frequency pair that plays a step.
    ///
    /// The carrier is the step's own frequency and the beat is split evenly between the
    /// two ears, so the pitch the listener hears stays on the solfeggio frequency and
    /// only the beat moves. `fL = c - b/2`, `fR = c + b/2` — the same division
    /// `oscillator.pair_from_beat` uses, so a mode and a manual pair agree.
    ///
    /// The result is clamped to the audible range and snapped to the 0.1 Hz grid, because
    /// the engine only ever plays quantised frequencies.
    public static func pair(for step: ChakraStep, beatHz: Double) -> (left: Double, right: Double) {
        let beat = min(maxBeatHz, max(minBeatHz, beatHz.isFinite ? beatHz : defaultBeatHz))
        // Both tones have to sit on the 0.1 Hz grid *and* differ by the beat. With a
        // whole-hertz carrier and a 0.5 Hz beat the two cannot both hold: the tones
        // would be 395.75 and 396.25, and neither is on the grid. So the lower tone is
        // placed on the grid and the upper one is derived from it, which makes the
        // difference exact and moves the carrier by at most half a grid step — 0.05 Hz,
        // inaudible.
        let wanted = FrequencyGrid.snapped(beat)
        let left = FrequencyGrid.quantized(step.hz - wanted / 2)
        let right = FrequencyGrid.quantized(left + wanted)
        return (left, right)
    }

    /// The frequency pair for a step index, clamped into range.
    public static func pair(forStepIndex stepIndex: Int, beatHz: Double) -> (left: Double, right: Double) {
        pair(for: steps[index(of: stepIndex)], beatHz: beatHz)
    }
}
