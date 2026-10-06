"""The "Lock difference" arithmetic of SPEC §7, on its own.

These are pure numbers, so they are checked without Qt (CONTRACT rule 5): the window
tests in ``test_difference_lock_window.py`` prove the checkbox is wired to this, and
these prove the following is right. The same cases are stated in
``apple/Tests/CoreTests/DifferenceLockTests.swift`` — one contract, two suites.
"""

from __future__ import annotations

import pytest

from binaural.core.difference_lock import Channel, DifferenceLock, quantized
from binaural.core.oscillator import MAX_FREQ_HZ, MIN_FREQ_HZ


def _locked(left: float, right: float) -> DifferenceLock:
    lock = DifferenceLock()
    lock.capture(left_hz=left, right_hz=right)
    return lock


# --------------------------------------------------------------------------- capture


def test_unlocked_by_default():
    lock = DifferenceLock()
    assert lock.is_locked is False
    assert lock.signed_difference_hz == 0.0


def test_capture_takes_the_current_signed_difference():
    """Capture, do not edit: the box locks whatever the difference is at that moment."""
    assert _locked(200, 260).signed_difference_hz == pytest.approx(60.0)
    # fR < fL is a real state (the right ear can be the lower one) and must survive.
    assert _locked(260, 200).signed_difference_hz == pytest.approx(-60.0)
    assert _locked(205, 205).signed_difference_hz == pytest.approx(0.0)


def test_capture_quantises_to_the_grid():
    """The two controls are already on the 0.1 Hz grid: no invisible difference."""
    assert _locked(205.0, 215.1).signed_difference_hz == pytest.approx(10.1)


def test_unlock_forgets_the_difference():
    lock = _locked(200, 260)
    lock.unlock()
    assert lock.is_locked is False
    assert lock.signed_difference_hz == 0.0


def test_quantized_clamps_and_ignores_non_finite():
    assert quantized(0.1) == MIN_FREQ_HZ
    assert quantized(30000.0) == MAX_FREQ_HZ
    assert quantized(205.44) == 205.4
    # Any non-finite value collapses to the bottom of the range, exactly as on the Swift
    # side (`FrequencyGrid.quantized`): a half-typed field is not a legal frequency.
    assert quantized(float("nan")) == MIN_FREQ_HZ
    assert quantized(float("inf")) == MIN_FREQ_HZ
    assert quantized(float("-inf")) == MIN_FREQ_HZ


# ------------------------------------------------------------------------- following


def test_untouched_channel_follows():
    """The two worked examples from the spec note, on both ears."""
    positive = _locked(200, 260)
    moved = positive.resolve(Channel.LEFT, 250)
    assert moved is not None
    assert moved.left_hz == pytest.approx(250.0)
    assert moved.right_hz == pytest.approx(310.0)

    other = _locked(260, 200).resolve(Channel.RIGHT, 150)
    assert other is not None
    assert other.right_hz == pytest.approx(150.0)
    assert other.left_hz == pytest.approx(210.0)


@pytest.mark.parametrize(
    ("left", "right"),
    [(200.0, 260.0), (260.0, 200.0), (205.0, 205.0), (7.83, 432.0)],
)
def test_following_preserves_the_signed_difference_exactly(left, right):
    lock = _locked(left, right)
    for edited in (Channel.LEFT, Channel.RIGHT):
        for target in (12.0, 199.9, 480.0, 1500.0):
            resolution = lock.resolve(edited, target)
            assert resolution is not None, f"no resolution for {edited} {target}"
            difference = resolution.right_hz - resolution.left_hz
            assert difference == pytest.approx(lock.signed_difference_hz), (
                f"{left}/{right} editing {edited} to {target}"
            )


@pytest.mark.parametrize("target", [1.0, 2.05, 33.33, 19_999.9, 20_000.0])
def test_result_stays_on_the_grid_and_in_range(target):
    lock = _locked(205.0, 215.1)
    for edited in (Channel.LEFT, Channel.RIGHT):
        resolution = lock.resolve(edited, target)
        assert resolution is not None
        for hz in (resolution.left_hz, resolution.right_hz):
            assert MIN_FREQ_HZ <= hz <= MAX_FREQ_HZ
            assert hz == pytest.approx(quantized(hz)), "off the 0.1 Hz grid"


def test_unlocked_resolves_to_nothing():
    lock = DifferenceLock()
    assert lock.resolve(Channel.LEFT, 250) is None
    assert lock.resolve(Channel.RIGHT, 250) is None


# ---------------------------------------------------------------------- boundary


def test_edited_channel_stops_at_the_top_of_the_range():
    """SPEC §7: a +10 Hz difference, so the left channel is the lower one."""
    lock = _locked(205, 215)
    resolution = lock.resolve(Channel.LEFT, 20_000)
    assert resolution is not None
    assert resolution.right_hz == pytest.approx(20_000.0)
    assert resolution.left_hz == pytest.approx(19_990.0)
    assert resolution.is_at_boundary is True
    # The lock itself is untouched — the difference is still exactly +10.
    assert resolution.right_hz - resolution.left_hz == pytest.approx(10.0)
    assert lock.is_locked is True


def test_edited_channel_stops_at_the_bottom_of_the_range():
    """A **positive** difference means the left channel is the lower one, so pushing the
    right one below 11 Hz would ask a non-positive frequency of the left: the right one
    stops at 11."""
    lock = _locked(205, 215)
    resolution = lock.resolve(Channel.RIGHT, 1)
    assert resolution is not None
    assert resolution.right_hz == pytest.approx(11.0)
    assert resolution.left_hz == pytest.approx(1.0)
    assert resolution.is_at_boundary is True
    assert resolution.right_hz - resolution.left_hz == pytest.approx(10.0)


def test_a_negative_difference_pushes_the_left_channel_to_the_bottom():
    """The sign decides which channel stops where — the case the Swift side had wrong
    before it was fixed."""
    lock = _locked(215, 205)
    resolution = lock.resolve(Channel.LEFT, 1)
    assert resolution is not None
    assert resolution.left_hz == pytest.approx(11.0)
    assert resolution.right_hz == pytest.approx(1.0)
    assert resolution.is_at_boundary is True
    assert resolution.right_hz - resolution.left_hz == pytest.approx(-10.0)


def test_an_accepted_step_is_not_reported_as_the_boundary():
    lock = _locked(205, 215)
    resolution = lock.resolve(Channel.LEFT, 205.4)
    assert resolution is not None
    assert resolution.is_at_boundary is False
    assert resolution.left_hz == pytest.approx(205.4)
    assert resolution.right_hz == pytest.approx(215.4)


def test_the_widest_possible_difference_still_resolves():
    """A difference as wide as the whole range leaves exactly one legal pair, and both
    channels pin to it rather than producing an illegal frequency."""
    lock = _locked(1, 20_000)
    resolution = lock.resolve(Channel.LEFT, 500)
    assert resolution is not None
    assert resolution.left_hz == pytest.approx(1.0)
    assert resolution.right_hz == pytest.approx(20_000.0)
    assert resolution.is_at_boundary is True


def test_a_difference_wider_than_the_range_resolves_to_nothing():
    """A corrupt caller must not get an illegal frequency out of the lock."""
    lock = DifferenceLock(is_locked=True, signed_difference_hz=25_000.0)
    assert lock.resolve(Channel.LEFT, 500) is None
    assert lock.resolve(Channel.RIGHT, 500) is None