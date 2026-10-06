"""The "Lock difference" rule of SPEC §7 — the ``Зафиксировать`` checkbox.

While the box is ticked, editing one channel moves the other by the same amount, so the
**signed** difference ``fR - fL`` stays exactly as it was when the box was ticked.

Pure maths, no Qt, no widgets (CONTRACT rule 5), so the follower arithmetic and the
boundary clamp are unit-testable on their own and the window only has to render what
this decides. Swift keeps the same rules in ``apple/Sources/Core/DifferenceLock.swift``.

Three rules make this a value rather than a flag:

* **Capture, do not edit.** :meth:`DifferenceLock.capture` takes whatever the difference
  happens to be at that instant — including a negative one. There is no field for typing
  a difference: the beat card stays an indicator.
* **The follower is clamped, the edited channel is not.** A follower outside the audible
  1–20000 Hz range of ``oscillator.MIN_FREQ_HZ`` / ``MAX_FREQ_HZ`` is impossible, so the
  *edited* value is pulled back to the last position that keeps both channels legal and
  :attr:`Resolution.is_at_boundary` reports it. Which channel hits which edge depends on
  the **sign** of the difference — that is why the arithmetic is here and not in the
  window.
* **Unlocking forgets everything.** The frequencies stay where they are; only the
  following stops.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from .oscillator import MAX_FREQ_HZ, MIN_FREQ_HZ

__all__ = ["Channel", "DifferenceLock", "Resolution", "STEP_HZ", "quantized"]

#: SPEC F1: the frequency grid every value in this module stays on.
STEP_HZ = 0.1


def quantized(hz: float) -> float:
    """Clamp to 1–20000 Hz and snap to the 0.1 Hz grid.

    Non-finite input is clamped rather than propagated: a field being edited can hold an
    empty or half-typed string, and ``FreqControl.set_value`` ignores NaN and infinity the
    same way. ``round`` is the right primitive here for the same reason ``%.1f`` is on the
    Swift side — the controls round with ``round(value, 1)``, so this cannot invent a
    frequency the user cannot see on screen.
    """
    value = float(hz)
    if not math.isfinite(value):
        return MIN_FREQ_HZ
    return min(MAX_FREQ_HZ, max(MIN_FREQ_HZ, round(value, 1)))


class Channel(Enum):
    """Which channel a frequency edit came from."""

    LEFT = "left"
    RIGHT = "right"


@dataclass(frozen=True)
class Resolution:
    """The pair to display after one channel was edited under a lock.

    ``is_at_boundary`` is True when following would have pushed the *other* channel out of
    range, so the edited channel was pulled back to the boundary instead. The difference is
    still the locked one; only the requested step was refused.
    """

    left_hz: float
    right_hz: float
    is_at_boundary: bool


@dataclass
class DifferenceLock:
    """The signed difference a locked session holds on to.

    :attr:`signed_difference_hz` is ``fR - fL``, so a session where the right ear is the
    lower one locks a **negative** number and following keeps it negative.
    """

    #: True while the box is ticked.
    is_locked: bool = False
    #: The captured difference, ``fR - fL``, in Hz. Zero while unlocked.
    signed_difference_hz: float = 0.0

    # ------------------------------------------------------------ state changes

    def capture(self, left_hz: float, right_hz: float) -> None:
        """Tick the box: capture the difference the pair has right now."""
        self.is_locked = True
        self.signed_difference_hz = quantized(right_hz) - quantized(left_hz)

    def unlock(self) -> None:
        """Clear the box. The pair on screen is untouched."""
        self.is_locked = False
        self.signed_difference_hz = 0.0

    # ----------------------------------------------------------------- following

    def resolve(self, edited: Channel, hz: float) -> Resolution | None:
        """The pair after ``edited`` was moved to ``hz``.

        ``None`` when there is no lock to honour, or when the locked difference is so wide
        that no legal pair exists at all (impossible for a difference captured from a legal
        pair, but a corrupt caller must not produce an illegal frequency). The window then
        leaves both channels as they are rather than breaking the range.
        """
        if not self.is_locked:
            return None
        requested = quantized(hz)
        difference = self.signed_difference_hz

        if edited is Channel.LEFT:
            # ``right = left + difference``, both legal: the edited value is confined to
            # the overlap of its own range and the range shifted by the difference.
            left = self._clamp(requested, MIN_FREQ_HZ - difference, MAX_FREQ_HZ - difference)
            if left is None:
                return None
            # Both sides re-quantised: the captured difference is a difference of two grid
            # values, and adding it back can land a double just off the 0.1 Hz grid.
            return Resolution(
                left_hz=quantized(left),
                right_hz=quantized(left + difference),
                is_at_boundary=left != requested,
            )

        # ``left = right - difference``, the same overlap seen from the other ear.
        right = self._clamp(requested, MIN_FREQ_HZ + difference, MAX_FREQ_HZ + difference)
        if right is None:
            return None
        return Resolution(
            left_hz=quantized(right - difference),
            right_hz=right,
            is_at_boundary=right != requested,
        )

    @staticmethod
    def _clamp(value: float, low: float, high: float) -> float | None:
        """``value`` confined to ``[low, high]`` intersected with the audible range.

        ``None`` when that intersection is empty — which is how a difference wider than the
        whole range is refused instead of producing an illegal frequency.
        """
        lower = max(MIN_FREQ_HZ, low)
        upper = min(MAX_FREQ_HZ, high)
        if lower > upper:
            return None
        return min(upper, max(lower, value))