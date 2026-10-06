"""The playback timer of SPEC §5 F5 — a value, not a running clock.

A plain value built from ``Session.timer_minutes`` and a pure function of "now":
no QTimer, no Qt, no thread. The window arms it when playback starts and asks it
``remaining(now)`` once a second; that split is what makes the countdown and the
expiry testable to the second without waiting for a second to pass.

``0`` minutes means "no timer — play until stopped" (``TIMER_OFF``), which is why
:attr:`PlaybackTimer.is_enabled` is false and ``remaining`` is infinity rather than
zero: a timer that is off must never read as "expired".

Swift holds the same value in ``apple/Sources/Core/PlaybackTimer.swift``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .session import DEFAULT_TIMER_MINUTES, TIMER_CHOICES, TIMER_OFF

if TYPE_CHECKING:  # pragma: no cover - typing only
    from .session import Session

__all__ = [
    "PlaybackTimer",
    "countdown_text",
    "closest_choice",
    "TIMER_CHOICES",
    "TIMER_OFF",
]


def countdown_text(remaining: float) -> str:
    """``mm:ss`` below an hour, ``h:mm:ss`` above it — the countdown the window shows.

    Written out rather than delegated to a formatter, so the format is the same
    everywhere and testable to the character. Empty while the timer is off, so the
    label can be hidden rather than showing a misleading ``00:00``.
    """
    if not math.isfinite(remaining):
        return ""
    total = max(0, math.ceil(remaining))
    hours, rest = divmod(total, 3600)
    minutes, seconds = divmod(rest, 60)
    if hours > 0:
        return f"{hours}:{minutes:02d}:{seconds:02d}"
    return f"{minutes:02d}:{seconds:02d}"


def closest_choice(minutes: int, choices: tuple[int, ...] = TIMER_CHOICES) -> int:
    """The offered duration nearest to ``minutes``.

    ``Session`` clamps the *number* to 0…1440 on load, but a value inside that range
    need not be one of the offered choices (17 minutes, say), and a control can only
    show what it can offer.
    """
    if minutes in choices:
        return minutes
    return min(choices, key=lambda choice: (abs(choice - minutes), choice))


@dataclass(frozen=True)
class PlaybackTimer:
    """How long a session runs, and when it ends."""

    #: Duration in seconds; ``0`` = off.
    duration: float
    #: The moment playback ends, or ``None`` while the timer is not armed.
    deadline: float | None = None

    def __init__(self, duration: float = 0.0, started_at: float | None = None) -> None:
        seconds = float(duration)
        if not math.isfinite(seconds) or seconds <= 0.0:
            seconds = 0.0
        object.__setattr__(self, "duration", seconds)
        # An off timer has no deadline at all rather than one already reached: "no timer"
        # must never read as "expired", however far the clock moves.
        object.__setattr__(
            self,
            "deadline",
            None if (started_at is None or seconds <= 0.0) else float(started_at) + seconds,
        )

    @classmethod
    def for_minutes(cls, minutes: int, started_at: float | None = None) -> PlaybackTimer:
        """The timer for a ``timer_minutes`` value.

        A negative value cannot come from a session — ``Session`` clamps to 0…1440 on
        load — but a caller passing one must not get a timer that has already expired.
        """
        return cls(duration=max(0, int(minutes)) * 60, started_at=started_at)

    @classmethod
    def for_session(cls, session: Session, started_at: float | None = None) -> PlaybackTimer:
        """The timer a :class:`~binaural.core.session.Session` asks for."""
        minutes = getattr(session, "timer_minutes", DEFAULT_TIMER_MINUTES)
        return cls.for_minutes(int(minutes), started_at=started_at)

    @property
    def is_enabled(self) -> bool:
        """False for ``0`` minutes — the session plays until the user stops it."""
        return self.duration > 0

    def remaining(self, now: float) -> float:
        """Seconds left, or infinity while the timer is not armed."""
        if self.deadline is None:
            return math.inf
        return max(0.0, self.deadline - float(now))

    def has_expired(self, now: float) -> bool:
        """True once the session is over. Never true while the timer is off."""
        if self.deadline is None:
            return False
        return float(now) >= self.deadline

    def countdown_text(self, now: float) -> str:
        """The countdown for ``now``; empty while the timer is off."""
        if not self.is_enabled:
            return ""
        return countdown_text(self.remaining(now))

    @classmethod
    def off(cls) -> PlaybackTimer:
        """The timer that never fires — ``TIMER_OFF`` minutes, never expiring."""
        return cls(duration=0)
