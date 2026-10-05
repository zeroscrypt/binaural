"""Audio device discovery and headphone detection."""

from __future__ import annotations

from .devices import (
    AudioDevice,
    DeviceClass,
    classify,
    current_verdict,
    default_output,
    get_backend,
    list_outputs,
)
from .headphones import (
    HeadphoneReport,
    LrTestResult,
    LrTestSequence,
    detect,
    run_lr_test,
    swap_channels,
)

__all__ = [
    "AudioDevice",
    "DeviceClass",
    "get_backend",
    "list_outputs",
    "default_output",
    "classify",
    "current_verdict",
    "HeadphoneReport",
    "LrTestResult",
    "LrTestSequence",
    "detect",
    "run_lr_test",
    "swap_channels",
]