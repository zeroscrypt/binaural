"""Headphone detection scenario (CONTRACT.md §4).

Two levels, both platform independent:
  1. :func:`detect` — heuristics only, no sound, no questions.
  2. :class:`LrTestSequence` — the perceptual L/R test: a short tone hard in
     the left channel, a short pause, a short tone hard in the right channel.
     The user answer is collected by the UI, this module only produces the
     sequence and holds the state.

Nothing here raises and nothing here talks to a specific audio backend.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from enum import Enum

from PySide6.QtCore import QObject, QTimer, Signal

from .devices import classify_confidence, current_verdict
from .platform.base import AudioDevice, DeviceClass

__all__ = [
    "HeadphoneReport",
    "LrTestResult",
    "LrTestSequence",
    "LR_TEST_FREQ_HZ",
    "LR_TEST_TONE_SECONDS",
    "LR_TEST_GAP_SECONDS",
    "STEP_IDLE",
    "STEP_LEFT",
    "STEP_PAUSE",
    "STEP_RIGHT",
    "STEP_ANSWER",
    "detect",
    "run_lr_test",
    "swap_channels",
    "with_lr_result",
]

# Perceptual test parameters (SPEC.md §4.2).
LR_TEST_FREQ_HZ: float = 440.0
LR_TEST_TONE_SECONDS: float = 1.5
LR_TEST_GAP_SECONDS: float = 0.3

# Machine-readable step ids. The UI maps them to its own tr() strings.
STEP_IDLE = "idle"
STEP_LEFT = "left"
STEP_PAUSE = "pause"
STEP_RIGHT = "right"
STEP_ANSWER = "answer"

CONFIDENCE_HIGH = "high"
CONFIDENCE_MEDIUM = "medium"
CONFIDENCE_LOW = "low"


class LrTestResult(Enum):
    LEFT_THEN_RIGHT = "left_then_right"  # channels are correct
    RIGHT_THEN_LEFT = "right_then_left"  # channels are swapped
    INDETERMINATE = "indeterminate"  # speakers / mono mixer


@dataclass(frozen=True)
class HeadphoneReport:
    verdict: DeviceClass
    device: AudioDevice | None
    confidence: str  # "high" | "medium" | "low"
    lr_test: LrTestResult | None = None

    @property
    def is_headphones(self) -> bool:
        if self.verdict is DeviceClass.HEADPHONES:
            return True
        # A positive perceptual result overrides a pessimistic guess.
        return self.lr_test in (LrTestResult.LEFT_THEN_RIGHT, LrTestResult.RIGHT_THEN_LEFT)

    @property
    def channels_swapped(self) -> bool:
        return self.lr_test is LrTestResult.RIGHT_THEN_LEFT


def detect(report: HeadphoneReport | None = None) -> HeadphoneReport:
    """Heuristic verdict for the default output device.

    If ``report`` is given (typically the stored session state) its L/R test
    result is preserved and combined with the fresh heuristic verdict.
    """
    previous_lr = report.lr_test if report is not None else None
    try:
        verdict, device = current_verdict()
    except Exception:
        verdict, device = DeviceClass.UNKNOWN, None

    if verdict is not DeviceClass.UNKNOWN and device is not None:
        confidence = classify_confidence(device.name, device.transport)
    else:
        confidence = CONFIDENCE_LOW

    fresh = HeadphoneReport(
        verdict=verdict,
        device=device,
        confidence=confidence,
        lr_test=previous_lr,
    )
    if previous_lr is not None:
        return _apply_lr_result(fresh, previous_lr)
    return fresh


def _apply_lr_result(
    report: HeadphoneReport, result: LrTestResult
) -> HeadphoneReport:
    """The perceptual test is definitive: it can override the heuristic."""
    if result is LrTestResult.INDETERMINATE:
        if report.verdict is DeviceClass.HEADPHONES:
            # Confirmed speakers despite a name/transport hint.
            return replace(
                report, verdict=DeviceClass.SPEAKERS, confidence=CONFIDENCE_HIGH
            )
        return report
    # LEFT_THEN_RIGHT / RIGHT_THEN_LEFT -> real headphones, high confidence.
    return replace(report, verdict=DeviceClass.HEADPHONES, confidence=CONFIDENCE_HIGH)


def with_lr_result(report: HeadphoneReport, result: LrTestResult) -> HeadphoneReport:
    """Returns a copy of ``report`` updated with the user's L/R answer."""
    return replace(_apply_lr_result(report, result), lr_test=result)


def swap_channels(
    left_hz: float, right_hz: float, swapped: bool
) -> tuple[float, float]:
    """Applies the channel swap decision before generating the signal."""
    if swapped:
        return right_hz, left_hz
    return left_hz, right_hz


class _EnginePlayer:
    """Plays hard-panned test tones through an AudioEngine.

    Duck-typed on purpose: the engine may expose a per-channel helper, or only
    an oscillator. Anything missing degrades to "no sound", never an
    exception, because a broken test must not break the app.
    """

    def __init__(self, engine: object | None) -> None:
        self._engine = engine

    def _oscillator(self) -> object | None:
        return getattr(self._engine, "oscillator", None)

    def play_left(self, freq_hz: float, seconds: float) -> None:
        self._play("left", freq_hz, seconds)

    def play_right(self, freq_hz: float, seconds: float) -> None:
        self._play("right", freq_hz, seconds)

    def _play(self, channel: str, freq_hz: float, seconds: float) -> None:
        engine = self._engine
        if engine is None:
            return
        try:
            # Preferred: engine knows how to render a single channel.
            helper = getattr(engine, f"play_{channel}_tone", None)
            if callable(helper):
                helper(freq_hz, seconds)
                start = getattr(engine, "start", None)
                if callable(start):
                    start()
                return

            oscillator = self._oscillator()
            if oscillator is None:
                return
            set_frequencies = getattr(oscillator, "set_frequencies", None)
            set_fade = getattr(oscillator, "set_fade", None)
            set_pan = getattr(oscillator, "set_pan", None)
            if callable(set_frequencies):
                set_frequencies(freq_hz, freq_hz)
            if callable(set_pan):
                # Hard pan: the tone reaches exactly one ear. Without this
                # both channels would play and the test would be useless.
                if channel == "left":
                    set_pan(1.0, 0.0)
                else:
                    set_pan(0.0, 1.0)
            if callable(set_fade):
                set_fade(1.0)
            start = getattr(engine, "start", None)
            if callable(start):
                start()
        except Exception:
            return

    def stop(self) -> None:
        engine = self._engine
        if engine is None:
            return
        try:
            oscillator = self._oscillator()
            set_fade = getattr(oscillator, "set_fade", None)
            set_pan = getattr(oscillator, "set_pan", None)
            if callable(set_fade):
                set_fade(0.0)
            stop = getattr(engine, "stop", None)
            if callable(stop):
                stop()
        except Exception:
            return


class LrTestSequence(QObject):
    """Drives the perceptual L/R test and holds its state.

    Usage from the UI::

        seq = LrTestSequence(engine, parent=self)
        seq.step_changed.connect(self._on_step)      # update the hint text
        seq.finished.connect(self._on_answer)        # user answered
        seq.begin()
        ...
        seq.answer(LrTestResult.RIGHT_THEN_LEFT)
    """

    step_changed = Signal(str)  # STEP_LEFT / STEP_PAUSE / STEP_RIGHT / STEP_ANSWER / STEP_IDLE
    finished = Signal(object)  # LrTestResult

    def __init__(
        self,
        engine: object | None = None,
        parent: QObject | None = None,
        freq_hz: float = LR_TEST_FREQ_HZ,
        tone_seconds: float = LR_TEST_TONE_SECONDS,
        gap_seconds: float = LR_TEST_GAP_SECONDS,
    ) -> None:
        super().__init__(parent)
        self._player = _EnginePlayer(engine)
        self._freq_hz = freq_hz
        self._tone_ms = max(1, int(tone_seconds * 1000))
        self._gap_ms = max(1, int(gap_seconds * 1000))
        self._step = STEP_IDLE
        self._result: LrTestResult | None = None
        # One owned timer rather than three `QTimer.singleShot` calls.
        #
        # `singleShot` with a bound method registers a connection that outlives the object
        # it points at: when the dialog closes while a tone is still pending, the receiver
        # is destroyed with it and shiboken aborts the whole interpreter with
        # `Fatal Python error: none_dealloc: deallocating None` — a hard crash of `pytest`,
        # not a test failure, and one that only showed up on Python 3.10.
        #
        # A `QTimer` parented to this object has no such problem: it is a child, so Qt
        # destroys it with its parent, and ``stop()`` cancels what is pending in the normal
        # case, long before that happens.
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._on_timeout)
        #: What ``_on_timeout`` should call, set by whichever step armed the timer.
        self._pending: object | None = None

    # -- state --------------------------------------------------------------

    @property
    def step(self) -> str:
        return self._step

    @property
    def result(self) -> LrTestResult | None:
        return self._result

    @property
    def freq_hz(self) -> float:
        return self._freq_hz

    # -- flow ---------------------------------------------------------------

    def _arm(self, delay_ms: int, callback: object) -> None:
        """Fire ``callback`` after ``delay_ms``, replacing any pending one."""
        self._timer.stop()
        self._pending = callback
        self._timer.start(delay_ms)

    def _on_timeout(self) -> None:
        callback = self._pending
        self._pending = None
        if callable(callback):
            callback()

    def begin(self) -> None:
        """Starts the sequence: left tone, pause, right tone, then the question."""
        if self._step not in (STEP_IDLE, STEP_ANSWER):
            return
        self._result = None
        self._goto(STEP_LEFT)
        self._player.play_left(self._freq_hz, self._tone_ms / 1000.0)
        self._arm(self._tone_ms, self._after_left)

    def _after_left(self) -> None:
        if self._step not in (STEP_LEFT,):
            return
        self._goto(STEP_PAUSE)
        self._player.stop()
        self._arm(self._gap_ms, self._after_pause)

    def _after_pause(self) -> None:
        if self._step not in (STEP_PAUSE,):
            return
        self._goto(STEP_RIGHT)
        self._player.play_right(self._freq_hz, self._tone_ms / 1000.0)
        self._arm(self._tone_ms, self._ask)

    def _ask(self) -> None:
        if self._step not in (STEP_RIGHT,):
            return
        self._player.stop()
        self._goto(STEP_ANSWER)

    def answer(self, result: LrTestResult | str) -> None:
        """Feeds the user's answer in. Accepts a LrTestResult or its value.

        Accepted at any point of the sequence: the UI normally waits for the
        STEP_ANSWER signal, but an early click must not be silently lost.
        """
        if not isinstance(result, LrTestResult):
            try:
                result = LrTestResult(result)
            except ValueError:
                result = LrTestResult.INDETERMINATE
        self._result = result
        self._timer.stop()
        self._pending = None
        self._player.stop()
        self._goto(STEP_IDLE)
        self.finished.emit(result)

    def stop(self) -> None:
        """Aborts playback and returns to the idle step."""
        # Cancel what is pending first: the next scheduled step would otherwise fire into a
        # sequence that has already been stopped, and a timer left running past this point is
        # the thing that used to abort the interpreter when its owner was destroyed.
        self._timer.stop()
        self._pending = None
        self._player.stop()
        self._goto(STEP_IDLE)

    def _goto(self, step: str) -> None:
        if step == self._step:
            return
        self._step = step
        self.step_changed.emit(step)


def run_lr_test(
    engine: object | None = None,
    callback: object | None = None,
    parent: QObject | None = None,
) -> LrTestSequence:
    """Plays the L/R test and returns the running sequence.

    The user answer cannot be known synchronously (the UI collects it), so the
    result is delivered through ``LrTestSequence.finished`` — and to
    ``callback(result)`` when one is supplied. This is the contract's
    "returns the answer" path adapted to an asynchronous UI.
    """
    sequence = LrTestSequence(engine, parent=parent)
    if callable(callback):
        sequence.finished.connect(callback)
    sequence.begin()
    return sequence