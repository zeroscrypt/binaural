"""Thin, backend-agnostic device access layer.

Everything above this module (headphones detection, UI) talks to audio devices
only through these functions, so the platform layer stays swappable.
"""

from __future__ import annotations

from .platform import get_backend
from .platform.base import (
    AudioDevice,
    DeviceClass,
    classify_confidence,
    classify_device,
)

__all__ = [
    "AudioDevice",
    "DeviceClass",
    "get_backend",
    "list_outputs",
    "default_output",
    "classify",
    "classify_device",
    "classify_confidence",
    "current_verdict",
]


def list_outputs() -> list[AudioDevice]:
    """All output devices the backend can see. Empty list on any failure."""
    try:
        return get_backend().list_outputs()
    except Exception:
        return []


def default_output() -> AudioDevice | None:
    """The current default output device, or None."""
    try:
        return get_backend().default_output()
    except Exception:
        return None


def classify(device: AudioDevice) -> DeviceClass:
    """Classifies a single device. Never raises."""
    try:
        return get_backend().classify(device)
    except Exception:
        return DeviceClass.UNKNOWN


def current_verdict() -> tuple[DeviceClass, AudioDevice | None]:
    """Heuristic verdict for the default output: (class, device)."""
    try:
        return get_backend().heuristic_verdict()
    except Exception:
        return DeviceClass.UNKNOWN, None