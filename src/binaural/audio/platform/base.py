"""Platform-agnostic audio backend contract.

No platform logic here: only the data types (CONTRACT.md §3) plus the shared,
pure heuristics that turn a device name/transport pair into a DeviceClass.
Those heuristics are pure functions so they can be unit-tested without any
audio hardware, ctypes or subprocess.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Protocol, runtime_checkable

__all__ = [
    "DeviceClass",
    "AudioDevice",
    "AudioBackend",
    "NullBackend",
    "classify_device",
    "classify_confidence",
    "CONFIDENCE_HIGH",
    "CONFIDENCE_MEDIUM",
    "CONFIDENCE_LOW",
]

CONFIDENCE_HIGH = "high"
CONFIDENCE_MEDIUM = "medium"
CONFIDENCE_LOW = "low"


class DeviceClass(Enum):
    HEADPHONES = "headphones"  # definitely headphones
    SPEAKERS = "speakers"
    VIRTUAL = "virtual"  # BlackHole, Loopback, monitor, aggregate
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class AudioDevice:
    name: str
    transport: str  # "bluetooth" | "usb" | "builtin" | "hdmi" | "displayport"
    #               | "airplay" | "pci" | "virtual" | "unknown"
    is_default: bool = False
    identifier: str = ""


@runtime_checkable
class AudioBackend(Protocol):
    def list_outputs(self) -> list[AudioDevice]: ...

    def default_output(self) -> AudioDevice | None: ...

    def classify(self, device: AudioDevice) -> DeviceClass: ...

    def heuristic_verdict(self) -> tuple[DeviceClass, AudioDevice | None]:
        """Verdict for the default device: (class, device)."""
        ...


# --------------------------------------------------------------------------
# Shared heuristics (SPEC.md §4.1)
# --------------------------------------------------------------------------

_HEADPHONE_NAME_HINTS = (
    "airpods",
    "headset",
    "headphone",
    "earphone",
    "buds",
    "earbuds",
)

_VIRTUAL_NAME_HINTS = (
    "blackhole",
    "loopback",
    "aggregate",
    "multi-output",
    "virtual",
    "udio",  # "Audio" plug-ins and null sinks (macOS "Динамики" is builtin)
)

# Transport spellings that must be treated as the same thing: normalized names
# plus the FourCC codes CoreAudio reports.
_TRANSPORT_ALIASES: dict[str, str] = {
    "bluetooth": "bluetooth",
    "bluetoothle": "bluetooth",
    "bluetooth_le": "bluetooth",
    "blue": "bluetooth",
    "blth": "bluetooth",
    "blea": "bluetooth",
    "blet": "bluetooth",
    "builtin": "builtin",
    "built_in": "builtin",
    "bltn": "builtin",
    "buit": "builtin",
    "usb": "usb",
    "usb_": "usb",
    "hdmi": "hdmi",
    "displayport": "hdmi",
    "dprt": "hdmi",
    "dp": "hdmi",
    "airplay": "hdmi",
    "airp": "hdmi",
    "virtual": "virtual",
    "virt": "virtual",
    "aggregate": "virtual",
    "grup": "virtual",
    "pci": "virtual",
    "pci_": "virtual",
}

_BLUETOOTH_TRANSPORTS = frozenset({"bluetooth"})
_SPEAKER_TRANSPORTS = frozenset({"hdmi"})
_VIRTUAL_TRANSPORTS = frozenset({"virtual"})


def _norm(value: str | None) -> str:
    return (value or "").strip().lower()


def _norm_transport(value: str | None) -> str:
    raw = _norm(value)
    return _TRANSPORT_ALIASES.get(raw, raw)


def _heuristic(name: str | None, transport: str | None) -> tuple[DeviceClass, str]:
    """Returns (verdict, confidence) for a raw name/transport pair.

    Confidence is "high" when the verdict came from the transport alone and
    "medium" when it came from the device name.
    """
    name_l = _norm(name)
    transport_l = _norm_transport(transport)

    # Transport is the strongest signal: wireless audio is essentially never a
    # pair of speakers you can hear a beat with.
    if transport_l in _BLUETOOTH_TRANSPORTS:
        return DeviceClass.HEADPHONES, CONFIDENCE_HIGH

    # Name hints (works for USB wired headsets, which have no jack detection
    # available on macOS).
    if any(hint in name_l for hint in _HEADPHONE_NAME_HINTS):
        return DeviceClass.HEADPHONES, CONFIDENCE_MEDIUM

    # Virtual devices: routing helpers and null sinks must not be mistaken for
    # speakers, they tell us nothing about the physical setup.
    if transport_l in _VIRTUAL_TRANSPORTS:
        return DeviceClass.VIRTUAL, CONFIDENCE_HIGH
    if any(hint in name_l for hint in _VIRTUAL_NAME_HINTS):
        return DeviceClass.VIRTUAL, CONFIDENCE_MEDIUM

    # Display/TV outputs are monitors with built-in speakers.
    if transport_l in _SPEAKER_TRANSPORTS:
        return DeviceClass.SPEAKERS, CONFIDENCE_HIGH

    # Built-in audio is the machine's own speaker. Headphone names were
    # already handled above, so anything left on the built-in transport is a
    # speaker even when the name is just "Built-in Output".
    if transport_l == "builtin":
        return DeviceClass.SPEAKERS, CONFIDENCE_MEDIUM

    # USB without any name hint: could be anything, defer to the perceptual test.
    if transport_l == "usb":
        return DeviceClass.UNKNOWN, CONFIDENCE_LOW

    return DeviceClass.UNKNOWN, CONFIDENCE_LOW


def classify_device(name: str | None, transport: str | None) -> DeviceClass:
    """Pure classifier: no audio, no ctypes, no subprocess."""
    return _heuristic(name, transport)[0]


def classify_confidence(name: str | None, transport: str | None) -> str:
    """Confidence for the verdict produced by :func:`classify_device`."""
    return _heuristic(name, transport)[1]


class NullBackend:
    """Fallback backend: nothing is known, nothing raises."""

    def list_outputs(self) -> list[AudioDevice]:
        return []

    def default_output(self) -> AudioDevice | None:
        return None

    def classify(self, device: AudioDevice) -> DeviceClass:
        return DeviceClass.UNKNOWN

    def heuristic_verdict(self) -> tuple[DeviceClass, AudioDevice | None]:
        return DeviceClass.UNKNOWN, None