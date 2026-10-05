"""Reusable widgets for the main window."""

from __future__ import annotations

from .beat_display import BeatDisplay
from .freq_control import FreqControl
from .status_indicator import (
    STATE_HEADPHONES,
    STATE_SPEAKERS,
    STATE_UNKNOWN,
    StatusIndicator,
    state_for_verdict,
)

__all__ = [
    "BeatDisplay",
    "FreqControl",
    "StatusIndicator",
    "STATE_HEADPHONES",
    "STATE_SPEAKERS",
    "STATE_UNKNOWN",
    "state_for_verdict",
]