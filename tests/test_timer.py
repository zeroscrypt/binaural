"""The playback timer of SPEC §5 F5.

Two layers, tested apart on purpose:

* :class:`binaural.core.playback_timer.PlaybackTimer` is a pure value — the countdown
  text and the expiry test, with the clock injected so neither costs a real second;
* the window's control — the duration picker, the ticking and the stop on expiry —
  needs a display and skips without one, like the rest of the UI suite.
"""

from __future__ import annotations

import os
import sys

import pytest

from binaural.core.playback_timer import (  # noqa: E402
    PlaybackTimer,
    closest_choice,
    countdown_text,
)
from binaural.core.session import (  # noqa: E402
    DEFAULT_TIMER_MINUTES,
    TIMER_CHOICES,
    TIMER_OFF,
    Session,
)

# ---------------------------------------------------------------- the value


def test_off_means_no_timer():
    """``TIMER_OFF`` is "play until stopped" — it must never read as expired."""
    timer = PlaybackTimer.for_minutes(TIMER_OFF, started_at=1000.0)
    assert timer.is_enabled is False
    assert timer.has_expired(1e12) is False
    assert timer.remaining(1e12) == float("inf")
    assert timer.countdown_text(1e12) == ""


def test_a_session_timer_ends_after_its_minutes():
    timer = PlaybackTimer.for_minutes(15, started_at=0.0)
    assert timer.duration == 900.0
    assert timer.is_enabled is True
    assert timer.has_expired(899.0) is False
    assert timer.has_expired(900.0) is True
    assert timer.remaining(60.0) == 840.0


def test_an_unarmed_timer_has_no_deadline():
    timer = PlaybackTimer.for_minutes(15)
    assert timer.deadline is None
    assert timer.has_expired(0.0) is False
    assert timer.remaining(0.0) == float("inf")
    assert timer.countdown_text(0.0) == ""


def test_a_negative_duration_cannot_arrive_expired():
    """The session clamps to 0…1440, but a caller must not get a dead timer."""
    timer = PlaybackTimer.for_minutes(-5, started_at=100.0)
    assert timer.duration == 0.0
    assert timer.is_enabled is False
    assert timer.has_expired(100.0) is False


@pytest.mark.parametrize("nonsense", [float("nan"), float("inf"), float("-inf"), -60.0])
def test_nonsense_durations_degrade_to_off(nonsense):
    timer = PlaybackTimer(duration=nonsense, started_at=0.0)
    assert timer.duration == 0.0
    assert timer.is_enabled is False


def test_timer_for_a_session_reads_timer_minutes():
    assert PlaybackTimer.for_session(Session(timer_minutes=20)).duration == 1200.0
    assert PlaybackTimer.for_session(Session()).duration == DEFAULT_TIMER_MINUTES * 60


@pytest.mark.parametrize(
    "seconds, expected",
    [
        (0.0, "00:00"),
        (1.0, "00:01"),
        (9.1, "00:10"),
        (65.0, "01:05"),
        (599.0, "09:59"),
        (600.0, "10:00"),
        (900.0, "15:00"),
        (3600.0, "1:00:00"),
        (3661.0, "1:01:01"),
        (86399.0, "23:59:59"),
        (float("inf"), ""),
    ],
)
def test_countdown_text_format(seconds, expected):
    """``mm:ss`` below an hour, ``h:mm:ss`` above it; empty while off."""
    assert countdown_text(seconds) == expected


def test_countdown_counts_up_not_down_within_a_second():
    """A countdown that reads 00:00 while a minute is left would look broken."""
    assert countdown_text(0.4) == "00:01"


def test_closest_choice_snaps_to_what_can_be_offered():
    assert closest_choice(15) == 15
    assert closest_choice(17) == 20 or closest_choice(17) == 15
    assert closest_choice(0) == 0
    # Out of the offered range but inside the session's 0…1440 clamp.
    assert closest_choice(1440) == 120
    assert closest_choice(1) == 0


# ------------------------------------------------------------- the control


def _has_display() -> bool:
    if sys.platform in ("darwin", "win32"):
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


@pytest.fixture(scope="module")
def qapp():
    QtWidgets = pytest.importorskip("PySide6.QtWidgets")
    app = QtWidgets.QApplication.instance()
    if app is None:
        if not _has_display():
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        try:
            app = QtWidgets.QApplication(["binaural-timer-tests"])
        except Exception as exc:
            pytest.skip(f"QApplication unavailable: {exc}")
    yield app


class _Engine:
    """Records start/stop so expiry is observable without audio."""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self._volume = 0.7

    @property
    def volume(self) -> float:
        return self._volume

    @volume.setter
    def volume(self, value: float) -> None:
        self._volume = float(value)

    def start(self) -> bool:
        self.calls.append("start")
        return True

    def stop(self) -> None:
        self.calls.append("stop")

    def shutdown(self) -> None:
        pass


@pytest.fixture
def window(qapp):
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    engine = _Engine()
    win = MainWindow(engine, session=Session())
    yield win
    win.close()
    win.deleteLater()
    qapp.processEvents()


def test_the_window_offers_exactly_the_contract_choices(window):
    from PySide6.QtCore import Qt

    combo = window._timer_select
    shown = [
        combo.itemData(i, Qt.ItemDataRole.UserRole) for i in range(combo.count())
    ]
    assert shown == list(TIMER_CHOICES)
    assert window.timer_minutes() == DEFAULT_TIMER_MINUTES


def test_the_stored_timer_is_restored(qapp):
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    win = MainWindow(_Engine(), session=Session(timer_minutes=45))
    assert win.timer_minutes() == 45
    win.close()
    win.deleteLater()


def test_a_stored_duration_outside_the_offered_set_snaps(qapp):
    """The session clamps to 0…1440; the control can only show what it offers."""
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    win = MainWindow(_Engine(), session=Session(timer_minutes=17))
    assert win.timer_minutes() in TIMER_CHOICES
    assert win.timer_minutes() == closest_choice(17)
    win.close()
    win.deleteLater()


def test_the_session_snapshot_carries_the_timer(window):
    window.select_timer_minutes(30)
    assert window.current_session().timer_minutes == 30


def test_picking_a_duration_in_the_widget_applies_it(qapp, window):
    """The picker goes through the same entry point Settings uses."""
    from PySide6.QtCore import Qt

    combo = window._timer_select
    index = combo.findData(20, Qt.ItemDataRole.UserRole)
    assert index > 0
    combo.setCurrentIndex(index)
    window._on_timer_activated(index)
    assert window.timer_minutes() == 20
    assert combo.currentIndex() == index
    assert combo.count() == len(TIMER_CHOICES)


def test_choosing_a_timer_while_stopped_shows_no_countdown(window):
    window.select_timer_minutes(20)
    # The countdown is empty and hidden while nothing plays: `00:00` would read as a
    # session that had already ended.
    assert window.countdown_text() == ""
    assert window._countdown.isVisible() is False


def test_playing_arms_the_timer_and_shows_the_countdown(window):
    window.select_timer_minutes(5)
    window.start_playback()
    timer = window.playback_timer()
    assert timer.is_enabled is True
    assert window.countdown_text() == "05:00"
    window.tick_timer(now=timer.deadline - 65)
    assert window.countdown_text() == "01:05"
    window.stop_playback()


def test_an_off_timer_never_starts_playback_twice(window):
    window.select_timer_minutes(TIMER_OFF)
    window.start_playback()
    assert window.playback_timer().is_enabled is False
    assert window._ticker.isActive() is False
    assert window.countdown_text() == ""
    window.stop_playback()


def test_expiry_stops_playback(window):
    """SPEC §5 F5: the session stops by itself when the time is up."""
    window.select_timer_minutes(5)
    window.start_playback()
    engine = window._engine
    deadline = window.playback_timer().deadline
    window.tick_timer(now=deadline - 1)
    assert window.is_playing() is True
    window.tick_timer(now=deadline + 0.5)
    assert window.is_playing() is False
    assert "stop" in engine.calls
    assert window.countdown_text() == ""
    assert window._ticker.isActive() is False


def test_a_tick_while_the_timer_is_off_does_nothing(window):
    window.select_timer_minutes(TIMER_OFF)
    window.start_playback()
    window.tick_timer(now=0.0)
    assert window.is_playing() is True
    window.stop_playback()


def test_changing_the_timer_rearms_a_running_session(window):
    window.select_timer_minutes(60)
    window.start_playback()
    window.select_timer_minutes(5)
    assert window.playback_timer().duration == 300.0
    assert window.countdown_text() == "05:00"
    window.stop_playback()
    # The chosen duration survives the stop: only the countdown goes.
    assert window.timer_minutes() == 5


def test_stopping_by_hand_disarms_the_timer(window):
    window.select_timer_minutes(10)
    window.start_playback()
    window.stop_playback()
    assert window.playback_timer().is_enabled is False
    assert window._ticker.isActive() is False
    assert window.countdown_text() == ""


def test_a_long_timer_shows_hours(qapp):
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    win = MainWindow(_Engine(), session=Session(timer_minutes=120))
    win.start_playback()
    win.tick_timer(now=win.playback_timer().deadline - 3661)
    assert win.countdown_text() == "1:01:01"
    win.stop_playback()
    win.close()
    win.deleteLater()


def test_the_timer_captions_survive_a_language_change(window):
    from binaural import i18n
    from binaural.locales.ru import MESSAGES as RU

    assert window._timer_caption.text() == "Timer"
    i18n.set_language("ru")
    try:
        assert window._timer_caption.text() == RU["Timer"]
        # The selection is kept, and every caption is re-read.
        assert window.timer_minutes() == DEFAULT_TIMER_MINUTES
        assert window._timer_select.itemText(1) == RU["%1 min"].replace("%1", "5")
    finally:
        i18n.set_language("en")
    assert window._timer_caption.text() == "Timer"
