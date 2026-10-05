"""Pure sine generation for the binaural pair.

No Qt import here on purpose: this module is pure math and is unit-tested
without any GUI or audio backend.
"""

from __future__ import annotations

import math

DEFAULT_CARRIER_HZ: float = 200.0
MIN_FREQ_HZ: float = 1.0
MAX_FREQ_HZ: float = 20000.0
MAX_BEAT_HZ: float = 100.0  # outside this range it is a hint, not an error
RECOMMENDED_BEAT_HZ: tuple[float, float] = (0.5, 100.0)

DEFAULT_RAMP_SECONDS: float = 0.03

_TAU = math.tau


def _validate_hz(value: float, name: str = "frequency") -> float:
    """Accept only frequencies inside the supported audible range."""
    try:
        hz = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a number, got {value!r}") from exc
    if math.isnan(hz) or math.isinf(hz):
        raise ValueError(f"{name} must be finite, got {value!r}")
    if hz < MIN_FREQ_HZ or hz > MAX_FREQ_HZ:
        raise ValueError(
            f"{name} must be within [{MIN_FREQ_HZ}, {MAX_FREQ_HZ}] Hz, got {hz}"
        )
    return hz


def beat_frequency(left_hz: float, right_hz: float) -> float:
    """|fL - fR|."""
    return abs(float(left_hz) - float(right_hz))


def carrier_frequency(left_hz: float, right_hz: float) -> float:
    """(fL + fR) / 2."""
    return (float(left_hz) + float(right_hz)) / 2.0


def pair_from_beat(
    beat_hz: float, carrier_hz: float = DEFAULT_CARRIER_HZ
) -> tuple[float, float]:
    """(fL, fR) giving the requested difference around the carrier.

    fL = c - b/2, fR = c + b/2.
    """
    beat = float(beat_hz)
    carrier = float(carrier_hz)
    if beat < 0.0:
        raise ValueError(f"beat must be >= 0, got {beat_hz!r}")
    half = beat / 2.0
    return _validate_hz(carrier - half, "left_hz"), _validate_hz(
        carrier + half, "right_hz"
    )


class StereoOscillator:
    """Two sine oscillators with independent frequencies and continuous phase."""

    def __init__(self, sample_rate: int = 48000) -> None:
        rate = int(sample_rate)
        if rate <= 0:
            raise ValueError(f"sample_rate must be > 0, got {sample_rate!r}")
        self._sample_rate = rate
        self._left_hz = DEFAULT_CARRIER_HZ
        self._right_hz = DEFAULT_CARRIER_HZ
        # Phase is kept as a fraction of a cycle so it never grows large.
        self._phase_l = 0.0
        self._phase_r = 0.0
        self._gain = 0.0
        self._target_gain = 0.0
        self._alpha = 0.0
        self._ramp_seconds = DEFAULT_RAMP_SECONDS
        # Per-channel amplitude, used to hard-pan the L/R headphone test.
        self._pan_l = 1.0
        self._pan_r = 1.0
        self.set_fade(0.0, DEFAULT_RAMP_SECONDS)

    # ------------------------------------------------------------------ state

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    @property
    def left_hz(self) -> float:
        return self._left_hz

    @property
    def right_hz(self) -> float:
        return self._right_hz

    @property
    def phase(self) -> tuple[float, float]:
        """Current fractional phase of both oscillators (for tests/diagnostics)."""
        return self._phase_l, self._phase_r

    @property
    def gain(self) -> float:
        """Current amplitude, in 0..1."""
        return self._gain

    @property
    def target_gain(self) -> float:
        return self._target_gain

    def set_frequencies(self, left_hz: float, right_hz: float) -> None:
        """Apply a new frequency without breaking the phase."""
        left = _validate_hz(left_hz, "left_hz")
        right = _validate_hz(right_hz, "right_hz")
        self._left_hz = left
        self._right_hz = right

    def set_sample_rate(self, sample_rate: int) -> None:
        """Adopt a device sample rate.

        Phases are stored as fractions of a cycle, so only the increments and
        the ramp coefficient change -- no click is introduced.
        """
        rate = int(sample_rate)
        if rate <= 0:
            raise ValueError(f"sample_rate must be > 0, got {sample_rate!r}")
        self._sample_rate = rate
        if self._target_gain != self._gain:
            self._recompute_alpha(self._ramp_seconds)

    def set_fade(self, gain: float, ramp_seconds: float = DEFAULT_RAMP_SECONDS) -> None:
        """Target amplitude in 0..1, reached smoothly within ramp_seconds."""
        try:
            target = float(gain)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"gain must be a number, got {gain!r}") from exc
        self._target_gain = min(1.0, max(0.0, target))
        ramp = float(ramp_seconds)
        self._ramp_seconds = max(0.0, ramp)
        if ramp <= 0.0:
            # Still one sample of ramp: an instantaneous jump is a click.
            self._alpha = 1.0
            return
        self._recompute_alpha(self._ramp_seconds)

    def _recompute_alpha(self, ramp_seconds: float) -> None:
        # First-order approach: after ramp_seconds the remaining error is 1/e.
        self._alpha = 1.0 - math.exp(-1.0 / (ramp_seconds * self._sample_rate))

    @property
    def pan(self) -> tuple[float, float]:
        """Per-channel amplitude as (left, right), each in 0..1."""
        return self._pan_l, self._pan_r

    def set_pan(self, left: float = 1.0, right: float = 1.0) -> None:
        """Per-channel amplitude in 0..1. (1, 0) silences the right ear."""
        self._pan_l = min(1.0, max(0.0, float(left)))
        self._pan_r = min(1.0, max(0.0, float(right)))

    # ----------------------------------------------------------------- render

    def render(self, frames: int) -> tuple[list[float], list[float]]:
        """Render ``frames`` samples per channel and advance both phases.

        Never raises, never logs: called from the audio callback.
        """
        count = int(frames)
        if count <= 0:
            return [], []

        left: list[float] = [0.0] * count
        right: list[float] = [0.0] * count

        inv_rate = 1.0 / self._sample_rate
        step_l = self._left_hz * inv_rate
        step_r = self._right_hz * inv_rate

        alpha = self._alpha
        gain = self._gain
        target = self._target_gain
        pan_l = self._pan_l
        pan_r = self._pan_r
        phase_l = self._phase_l
        phase_r = self._phase_r
        tau = _TAU

        for i in range(count):
            # phase already carries the frequency via its increment (f / sample_rate),
            # so the argument is 2*pi*phase only.
            left[i] = gain * pan_l * math.sin(tau * phase_l)
            right[i] = gain * pan_r * math.sin(tau * phase_r)
            phase_l += step_l
            phase_r += step_r
            if phase_l >= 1.0:
                phase_l %= 1.0
            if phase_r >= 1.0:
                phase_r %= 1.0
            if gain != target:
                gain += (target - gain) * alpha
                if abs(target - gain) < 1e-6:
                    gain = target

        self._phase_l = phase_l
        self._phase_r = phase_r
        self._gain = gain
        return left, right