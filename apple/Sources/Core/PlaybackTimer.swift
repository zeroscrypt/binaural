import Foundation

/// The playback timer of SPEC §5 F5.
///
/// A **value** built from the session's `timer_minutes`, and a pure function of "now" —
/// no run loop, no `Date` of its own. The app starts it when playback starts and asks it
/// `remaining(at:)` once a second; that split is what makes the countdown and the
/// expiry testable to the second without waiting for a second to pass.
///
/// `0` minutes means "no timer — play until stopped" (`Session.timerOff`), which is why
/// ``isEnabled`` is false and ``remaining(at:)`` is infinite rather than zero: a timer
/// that is off must never read as "expired".
public struct PlaybackTimer: Sendable, Equatable {

    /// How long a session runs, in seconds. `0` = off.
    public let duration: TimeInterval

    /// The moment playback ends, or `nil` while the timer is not armed.
    public let deadline: Date?

    public init(duration: TimeInterval, startedAt: Date? = nil) {
        let duration = duration.isFinite ? max(0, duration) : 0
        self.duration = duration
        deadline = startedAt.map { $0.addingTimeInterval(duration) }
    }

    /// A timer for a `Session.timerMinutes` value.
    ///
    /// Negative values cannot come from a session — ``Session`` clamps them to `0…1440` on
    /// load — but a caller passing one must not get a timer that has already expired.
    public init(minutes: Int, startedAt: Date? = nil) {
        self.init(
            duration: TimeInterval(max(0, minutes)) * 60,
            startedAt: startedAt
        )
    }

    /// The timer that never fires.
    public static let off = PlaybackTimer(duration: 0)

    /// False for `0` minutes — the session plays until the user stops it.
    public var isEnabled: Bool { duration > 0 }

    /// Seconds left, or `TimeInterval.infinity` while the timer is off.
    public func remaining(at now: Date) -> TimeInterval {
        guard let deadline else { return .infinity }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// True once the session is over. Never true while the timer is off.
    public func hasExpired(at now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// A timer for a `Session`, armed at `now`.
    public static func timer(for session: Session, startedAt: Date) -> PlaybackTimer {
        PlaybackTimer(minutes: session.timerMinutes, startedAt: startedAt)
    }

    // MARK: - Text

    /// `mm:ss` below an hour, `h:mm:ss` above it — the countdown the window shows.
    ///
    /// Written out rather than taken from a `DateComponentsFormatter`, so the format is
    /// identical on every OS version and testable to the character.
    public static func countdownText(_ remaining: TimeInterval) -> String {
        guard remaining.isFinite else { return "" }
        // Round to microseconds before ceiling: `(started + duration) - started` can be a
        // hair above the integer, and `ceil` would read a fresh 5:00 timer as 5:01.
        let total = max(0, Int(((remaining * 1_000_000).rounded() / 1_000_000).rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The window's countdown label for `now`: empty while the timer is off, so the label
    /// is hidden rather than showing a misleading `00:00`.
    public func countdownText(at now: Date) -> String {
        guard isEnabled else { return "" }
        return Self.countdownText(remaining(at: now))
    }
}
