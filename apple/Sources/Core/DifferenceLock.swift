import Foundation

/// The "Lock difference" rule of SPEC §7: while it is on, editing one channel moves the
/// other by the same amount, so the **signed** difference `fR - fL` stays exactly as it was
/// when the box was ticked.
///
/// Pure maths, no AppKit, no audio — so the follower arithmetic and the boundary clamp are
/// unit-testable on their own (CONTRACT rule 5) and the window only has to render what this
/// decides.
///
/// Three rules make it a value rather than a flag:
///
/// * **Capture, do not edit.** ``capture(leftHz:rightHz:)`` takes whatever the difference
///   happens to be at that instant — including a negative one. There is no field for typing
///   a difference: the beat card stays an indicator.
/// * **The follower is clamped, the edited channel is not.** A follower that would leave
///   `FrequencyGrid`'s 1–20000 Hz range is impossible, so the *edited* value is pulled back
///   to the last position that keeps both channels legal and `isAtBoundary` reports it.
///   The lock itself is never violated, and it is never silently dropped.
/// * **Unlocking forgets everything.** The frequencies stay where they are; only the
///   following stops.
public struct DifferenceLock: Sendable, Equatable {

    /// Which channel a frequency edit came from.
    public enum Channel: Sendable, Equatable {
        case left
        case right
    }

    /// The lock, off. The signed difference is meaningless while off and reads as `0`.
    public static let unlocked = DifferenceLock()

    /// True while the box is ticked.
    public var isLocked: Bool

    /// The captured difference, `fR - fL`, in Hz. Signed: a session where the right ear is
    /// the lower one locks a negative number, and following keeps it negative.
    public private(set) var signedDifferenceHz: Double

    public init(isLocked: Bool = false, signedDifferenceHz: Double = 0) {
        self.isLocked = isLocked
        self.signedDifferenceHz = signedDifferenceHz
    }

    // MARK: - State changes

    /// Tick the box: capture the difference the pair has right now.
    public mutating func capture(leftHz: Double, rightHz: Double) {
        isLocked = true
        signedDifferenceHz = FrequencyGrid.quantized(rightHz) - FrequencyGrid.quantized(leftHz)
    }

    /// Clear the box. The pair on screen is untouched.
    public mutating func unlock() {
        self = .unlocked
    }

    // MARK: - Following

    /// What one channel becomes when the other is edited.
    public struct Resolution: Sendable, Equatable {

        /// The pair to display, both on the 0.1 Hz grid and inside 1–20000 Hz.
        public let leftHz: Double
        public let rightHz: Double

        /// True when following would have pushed the other channel out of range, so the
        /// edited channel was pulled back to the boundary instead. The difference is still
        /// the locked one; only the requested step was refused.
        public let isAtBoundary: Bool

        public init(leftHz: Double, rightHz: Double, isAtBoundary: Bool) {
            self.leftHz = leftHz
            self.rightHz = rightHz
            self.isAtBoundary = isAtBoundary
        }
    }

    /// The pair after `channel` was moved to `hz`.
    ///
    /// - Returns: `nil` when there is no lock to honour, or when the locked difference is
    ///   so wide that no legal pair exists at all (impossible for a difference captured from
    ///   a legal pair, but a corrupt caller must not produce an illegal frequency). The
    ///   window then leaves both channels as they are rather than breaking the range.
    public func resolve(edited channel: Channel, to hz: Double) -> Resolution? {
        guard isLocked else { return nil }
        let requested = FrequencyGrid.quantized(hz)
        let lowest = FrequencyGrid.minHz
        let highest = FrequencyGrid.maxHz
        let difference = signedDifferenceHz

        switch channel {
        case .left:
            // `right = left + difference`, both legal: the edited value is confined to the
            // overlap of its own range and the range shifted by the difference.
            guard let resolved = clamp(
                requested,
                to: (lowest - difference)...(highest - difference)
            ) else { return nil }
            let left = min(highest, max(lowest, resolved))
            return Resolution(
                // Both sides re-quantised: the captured difference is a difference of two
                // grid values, and adding it back can land a double just off the 0.1 Hz
                // grid. `quantized` is idempotent, so this cannot move a legal value.
                leftHz: FrequencyGrid.quantized(left),
                rightHz: FrequencyGrid.quantized(left + difference),
                isAtBoundary: left != requested
            )
        case .right:
            // `left = right - difference`, the same overlap seen from the other ear.
            guard let resolved = clamp(
                requested,
                to: (lowest + difference)...(highest + difference)
            ) else { return nil }
            let right = min(highest, max(lowest, resolved))
            return Resolution(
                leftHz: right - difference,
                rightHz: right,
                isAtBoundary: right != requested
            )
        }
    }

    /// `value` confined to `window` intersected with the audible range, or `nil` when that
    /// intersection is empty.
    private func clamp(
        _ value: Double,
        to window: ClosedRange<Double>
    ) -> Double? {
        let low = max(FrequencyGrid.minHz, window.lowerBound)
        let high = min(FrequencyGrid.maxHz, window.upperBound)
        guard low <= high else { return nil }
        return min(high, max(low, value))
    }

    // MARK: - Description

    /// The captured difference, as the beat card shows it (always positive).
    public var beatHz: Double { abs(signedDifferenceHz) }
}