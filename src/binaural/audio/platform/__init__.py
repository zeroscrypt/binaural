"""Backend factory: picks the platform implementation, never raises."""

from __future__ import annotations

import sys

from .base import (
    AudioBackend,
    AudioDevice,
    DeviceClass,
    NullBackend,
    classify_confidence,
    classify_device,
)

__all__ = [
    "AudioBackend",
    "AudioDevice",
    "DeviceClass",
    "NullBackend",
    "classify_device",
    "classify_confidence",
    "get_backend",
]


def get_backend() -> AudioBackend:
    """sys.platform == 'darwin' -> macos, 'linux' -> linux, else NullBackend."""
    platform = sys.platform
    if platform == "darwin":
        try:
            from .macos import MacOSBackend

            return MacOSBackend()
        except Exception:
            return NullBackend()
    if platform.startswith("linux"):
        try:
            from .linux import LinuxBackend

            return LinuxBackend()
        except Exception:
            return NullBackend()
    return NullBackend()