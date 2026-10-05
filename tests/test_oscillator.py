"""Pure-math tests for the stereo oscillator."""

from __future__ import annotations

import math

import pytest

from binaural.core.oscillator import (
    DEFAULT_CARRIER_HZ,
    MAX_FREQ_HZ,
    MIN_FREQ_HZ,
    RECOMMENDED_BEAT_HZ,
    StereoOscillator,
    beat_frequency,
    carrier_frequency,
    pair_from_beat,
)

RATE = 48000


def test_beat_frequency_is_absolute_difference():
    assert beat_frequency(205.0, 215.0) == pytest.approx(10.0)
    assert beat_frequency(215.0, 205.0) == pytest.approx(10.0)
    assert beat_frequency(200.0, 200.0) == pytest.approx(0.0)


def test_carrier_frequency_is_mean():
    assert carrier_frequency(205.0, 215.0) == pytest.approx(210.0)
    assert carrier_frequency(200.0, 240.0) == pytest.approx(220.0)


def test_pair_from_beat_roundtrip():
    left, right = pair_from_beat(10.0, 210.0)
    assert (left, right) == pytest.approx((205.0, 215.0))
    assert beat_frequency(left, right) == pytest.approx(10.0)
    assert carrier_frequency(left, right) == pytest.approx(210.0)


def test_pair_from_beat_defaults_to_default_carrier():
    left, right = pair_from_beat(6.0)
    assert carrier_frequency(left, right) == pytest.approx(DEFAULT_CARRIER_HZ)
    assert beat_frequency(left, right) == pytest.approx(6.0)


def test_constants_match_contract():
    assert (MIN_FREQ_HZ, MAX_FREQ_HZ) == (1.0, 20000.0)
    assert RECOMMENDED_BEAT_HZ == (0.5, 100.0)


def test_initial_state():
    osc = StereoOscillator(RATE)
    assert osc.sample_rate == RATE
    assert osc.left_hz == DEFAULT_CARRIER_HZ
    assert osc.right_hz == DEFAULT_CARRIER_HZ
    assert osc.gain == 0.0


def test_render_returns_requested_length():
    osc = StereoOscillator(RATE)
    osc.set_fade(1.0, 0.0)
    for frames in (1, 64, 1024):
        left, right = osc.render(frames)
        assert len(left) == frames
        assert len(right) == frames


def test_render_zero_frames():
    osc = StereoOscillator(RATE)
    assert osc.render(0) == ([], [])


def test_render_samples_match_analytic_sine():
    """With a slow ramp disabled the block must equal the closed-form sine."""
    osc = StereoOscillator(RATE)
    osc.set_frequencies(1000.0, 1000.0)
    osc.set_fade(1.0, 0.0)
    left, right = osc.render(256)
    for n, (l, r) in enumerate(zip(left, right)):
        expected = math.sin(math.tau * 1000.0 * n / RATE)
        assert l == pytest.approx(expected, abs=1e-12)
        assert r == pytest.approx(expected, abs=1e-12)


def test_channels_are_independent():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(200.0, 300.0)
    osc.set_fade(1.0, 0.0)
    left, right = osc.render(512)
    assert left != right
    assert max(abs(v) for v in left) == pytest.approx(1.0, abs=1e-3)
    assert max(abs(v) for v in right) == pytest.approx(1.0, abs=1e-3)


def test_phase_survives_frequency_change():
    """No click: the step between consecutive blocks stays small."""
    osc = StereoOscillator(RATE)
    osc.set_frequencies(205.0, 215.0)
    osc.set_fade(1.0, 0.0)

    first, _ = osc.render(1000)
    osc.set_frequencies(210.0, 210.0)  # jump, phase must continue
    second, _ = osc.render(1000)

    assert abs(second[0] - first[-1]) < 0.1

    # A phase reset would restart at 0.0 and produce a large jump here.
    phase_l, phase_r = osc.phase
    assert 0.0 <= phase_l < 1.0
    assert 0.0 <= phase_r < 1.0
    assert phase_l != 0.0 or phase_r != 0.0


def test_phase_stays_normalised_over_long_run():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(20000.0, 19999.5)
    osc.set_fade(1.0, 0.0)
    for _ in range(50):
        osc.render(4096)
    phase_l, phase_r = osc.phase
    assert 0.0 <= phase_l < 1.0
    assert 0.0 <= phase_r < 1.0


def test_fade_ramps_from_zero_to_one():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(200.0, 200.0)
    osc.set_fade(0.0, 0.05)
    quiet, _ = osc.render(1024)
    assert max(abs(v) for v in quiet) == 0.0

    osc.set_fade(1.0, 0.05)
    block, _ = osc.render(1024)
    first_peak = max(abs(v) for v in block)
    assert 0.0 < first_peak < 1.0  # smooth, not instant

    last = 0.0
    for _ in range(20):
        block, _ = osc.render(1024)
        last = max(abs(v) for v in block)
    assert last == pytest.approx(1.0, abs=1e-3)


def test_fade_is_independent_of_block_size():
    """Accumulation happens per sample, so block size must not change the curve."""
    def run(chunk: int) -> list[float]:
        osc = StereoOscillator(RATE)
        osc.set_frequencies(200.0, 200.0)
        osc.set_fade(1.0, 0.02)
        out: list[float] = []
        for _ in range(2000 // chunk):
            block, _ = osc.render(chunk)
            out.extend(block)
        return out

    a = run(100)
    b = run(10)
    assert len(a) == len(b)
    assert max(abs(x - y) for x, y in zip(a, b)) < 1e-12


def test_fade_down_to_zero():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(200.0, 200.0)
    osc.set_fade(1.0, 0.0)
    osc.render(2048)
    assert osc.gain == pytest.approx(1.0)

    osc.set_fade(0.0, 0.01)
    for _ in range(20):
        osc.render(1024)
    block, _ = osc.render(1024)
    assert max(abs(v) for v in block) < 0.01
    assert osc.gain == pytest.approx(0.0, abs=1e-6)


def test_gain_is_clamped():
    osc = StereoOscillator(RATE)
    osc.set_fade(5.0, 0.0)
    assert osc.target_gain == 1.0
    osc.set_fade(-3.0, 0.0)
    assert osc.target_gain == 0.0


def test_set_sample_rate_keeps_phase():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(300.0, 300.0)
    osc.set_fade(1.0, 0.03)
    osc.render(500)
    before = osc.phase
    osc.set_sample_rate(44100)
    assert osc.sample_rate == 44100
    assert osc.phase == pytest.approx(before)


@pytest.mark.parametrize("bad", [0.5, 0.0, -100.0, 20000.1, 30000.0, float("nan")])
def test_out_of_range_frequencies_raise(bad):
    osc = StereoOscillator(RATE)
    with pytest.raises(ValueError):
        osc.set_frequencies(bad, 200.0)
    with pytest.raises(ValueError):
        osc.set_frequencies(200.0, bad)


def test_non_numeric_frequency_raises():
    osc = StereoOscillator(RATE)
    with pytest.raises(ValueError):
        osc.set_frequencies("abc", 200.0)  # type: ignore[arg-type]


def test_boundary_frequencies_accepted():
    osc = StereoOscillator(RATE)
    osc.set_frequencies(MIN_FREQ_HZ, MAX_FREQ_HZ)
    assert osc.left_hz == MIN_FREQ_HZ
    assert osc.right_hz == MAX_FREQ_HZ


def test_invalid_pair_from_beat_raises():
    with pytest.raises(ValueError):
        pair_from_beat(10.0, 5.0)  # would push the left channel below MIN
    with pytest.raises(ValueError):
        pair_from_beat(-1.0, 200.0)


def test_invalid_sample_rate_raises():
    with pytest.raises(ValueError):
        StereoOscillator(0)