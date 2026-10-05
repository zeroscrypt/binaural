"""Headphone detection scenario tests (CONTRACT.md §4).

No sound is played and no audio device is required.
"""

from __future__ import annotations

import pytest

from binaural.audio.headphones import (
    HeadphoneReport,
    LrTestResult,
    LrTestSequence,
    detect,
    run_lr_test,
    swap_channels,
    with_lr_result,
)
from binaural.audio.platform.base import AudioDevice, DeviceClass

HP_DEVICE = AudioDevice(name="AirPods Pro", transport="bluetooth", is_default=True)
SPK_DEVICE = AudioDevice(name="Динамики Mac mini", transport="builtin", is_default=True)


# --------------------------------------------------------------------------
# LrTestResult
# --------------------------------------------------------------------------


def test_lr_test_result_values():
    assert LrTestResult.LEFT_THEN_RIGHT.value == "left_then_right"
    assert LrTestResult.RIGHT_THEN_LEFT.value == "right_then_left"
    assert LrTestResult.INDETERMINATE.value == "indeterminate"


# --------------------------------------------------------------------------
# HeadphoneReport
# --------------------------------------------------------------------------


def test_report_is_headphones_by_verdict():
    report = HeadphoneReport(DeviceClass.HEADPHONES, HP_DEVICE, "high")
    assert report.is_headphones is True
    assert report.channels_swapped is False


def test_report_speakers():
    report = HeadphoneReport(DeviceClass.SPEAKERS, SPK_DEVICE, "high")
    assert report.is_headphones is False


def test_report_unknown_without_lr_test():
    report = HeadphoneReport(DeviceClass.UNKNOWN, None, "low")
    assert report.is_headphones is False


@pytest.mark.parametrize(
    "result, is_hp, swapped",
    [
        (LrTestResult.LEFT_THEN_RIGHT, True, False),
        (LrTestResult.RIGHT_THEN_LEFT, True, True),
        (LrTestResult.INDETERMINATE, False, False),
    ],
)
def test_report_lr_test_drives_result(result, is_hp, swapped):
    report = HeadphoneReport(
        DeviceClass.UNKNOWN, None, "low", lr_test=result
    )
    assert report.is_headphones is is_hp
    assert report.channels_swapped is swapped


def test_report_is_frozen():
    report = HeadphoneReport(DeviceClass.UNKNOWN, None, "low")
    with pytest.raises(Exception):
        report.verdict = DeviceClass.HEADPHONES


# --------------------------------------------------------------------------
# swap_channels
# --------------------------------------------------------------------------


def test_swap_channels_no_swap():
    assert swap_channels(205.0, 215.0, False) == (205.0, 215.0)


def test_swap_channels_swapped():
    assert swap_channels(205.0, 215.0, True) == (215.0, 205.0)


def test_swap_channels_is_symmetric():
    assert swap_channels(*swap_channels(200.0, 220.0, True), swapped=True) == (200.0, 220.0)


# --------------------------------------------------------------------------
# detect()
# --------------------------------------------------------------------------


def test_detect_does_not_raise_on_real_machine():
    report = detect()
    assert isinstance(report.verdict, DeviceClass)
    assert report.confidence in ("high", "medium", "low")
    if report.device is not None:
        assert isinstance(report.device, AudioDevice)


def test_detect_keeps_previous_lr_result():
    previous = HeadphoneReport(
        DeviceClass.UNKNOWN, None, "low", lr_test=LrTestResult.RIGHT_THEN_LEFT
    )
    report = detect(previous)
    assert report.lr_test is LrTestResult.RIGHT_THEN_LEFT
    assert report.is_headphones is True
    assert report.channels_swapped is True


def test_with_lr_result_overrides_optimistic_guess():
    report = HeadphoneReport(DeviceClass.HEADPHONES, HP_DEVICE, "high")
    updated = with_lr_result(report, LrTestResult.INDETERMINATE)
    assert updated.verdict is DeviceClass.SPEAKERS
    assert updated.is_headphones is False
    # original untouched
    assert report.verdict is DeviceClass.HEADPHONES


def test_with_lr_result_promotes_unknown_to_headphones():
    report = HeadphoneReport(DeviceClass.UNKNOWN, None, "low")
    updated = with_lr_result(report, LrTestResult.LEFT_THEN_RIGHT)
    assert updated.verdict is DeviceClass.HEADPHONES
    assert updated.confidence == "high"
    assert updated.channels_swapped is False


# --------------------------------------------------------------------------
# L/R test sequence
# --------------------------------------------------------------------------


def test_sequence_starts_at_idle():
    sequence = LrTestSequence(None)
    assert sequence.step == "idle"
    assert sequence.result is None


def test_begin_plays_left_step():
    sequence = LrTestSequence(None)
    steps: list[str] = []
    sequence.step_changed.connect(steps.append)
    sequence.begin()
    assert sequence.step == "left"
    assert steps == ["left"]


def test_answer_accepts_enum_and_value():
    sequence = LrTestSequence(None)
    results: list[object] = []
    sequence.finished.connect(results.append)
    sequence.begin()
    sequence.answer(LrTestResult.RIGHT_THEN_LEFT)
    assert sequence.result is LrTestResult.RIGHT_THEN_LEFT
    assert results == [LrTestResult.RIGHT_THEN_LEFT]

    sequence.answer("left_then_right")
    assert sequence.result is LrTestResult.LEFT_THEN_RIGHT


def test_answer_with_garbage_is_indeterminate():
    sequence = LrTestSequence(None)
    sequence.begin()
    sequence.answer("nonsense")
    assert sequence.result is LrTestResult.INDETERMINATE


def test_stop_returns_to_idle():
    sequence = LrTestSequence(None)
    sequence.begin()
    sequence.stop()
    assert sequence.step == "idle"


def test_run_lr_test_returns_sequence():
    sequence = run_lr_test(None)
    assert isinstance(sequence, LrTestSequence)
    assert sequence.step == "left"


def test_run_lr_test_with_callback():
    seen: list[object] = []
    sequence = run_lr_test(None, callback=seen.append)
    sequence.answer(LrTestResult.LEFT_THEN_RIGHT)
    assert seen == [LrTestResult.LEFT_THEN_RIGHT]


def test_sequence_survives_broken_engine():
    class Broken:
        oscillator = None

        def start(self):
            raise RuntimeError("no device")

        def stop(self):
            raise RuntimeError("no device")

    sequence = LrTestSequence(Broken())
    sequence.begin()  # must not raise
    sequence.stop()
    assert sequence.step == "idle"