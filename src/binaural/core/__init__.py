"""Core signal generation and session state."""

from __future__ import annotations

from .difference_lock import Channel, DifferenceLock, Resolution
from .oscillator import (
    DEFAULT_CARRIER_HZ,
    MAX_BEAT_HZ,
    MAX_FREQ_HZ,
    MIN_FREQ_HZ,
    RECOMMENDED_BEAT_HZ,
    StereoOscillator,
    beat_frequency,
    carrier_frequency,
    pair_from_beat,
)

__all__ = [
    "DEFAULT_CARRIER_HZ",
    "MAX_BEAT_HZ",
    "MAX_FREQ_HZ",
    "MIN_FREQ_HZ",
    "RECOMMENDED_BEAT_HZ",
    "Channel",
    "DifferenceLock",
    "Resolution",
    "StereoOscillator",
    "beat_frequency",
    "carrier_frequency",
    "pair_from_beat",
]