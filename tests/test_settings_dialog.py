"""Settings dialog tests (SPEC §7, dialog #4).

The four rows SPEC §7 names — language, timer, volume, headphone check — and the
promise that makes them safe: each one writes through to the **live** window rather
than to a private copy, so there is no "apply" step and nothing to forget.
"""

from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QObject, Qt, Signal  # noqa: E402
from PySide6.QtWidgets import QApplication, QPushButton  # noqa: E402

from binaural import i18n  # noqa: E402
from binaural.audio.headphones import HeadphoneReport  # noqa: E402
from binaural.audio.platform.base import AudioDevice, DeviceClass  # noqa: E402
from binaural.core.oscillator import StereoOscillator  # noqa: E402
from binaural.core.session import DEFAULT_TIMER_MINUTES, TIMER_CHOICES, TIMER_OFF, Session  # noqa: E402
from binaural.locales.ru import MESSAGES as RU  # noqa: E402
from binaural.ui.dialogs import MIN_TOUCH_PX, SettingsDialog  # noqa: E402

HEADPHONES_DEVICE = AudioDevice("AirPods Pro", "bluetooth", True)
SPEAKERS_DEVICE = AudioDevice("Динамики Mac mini", "builtin", True)


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance()
    if app is None:
        try:
            app = QApplication(["binaural-settings-tests"])
        except Exception as exc:  # pragma: no cover - depends on the machine
            pytest.skip(f"No usable Qt display: {exc}")
    yield app


class FakeEngine(QObject):
    """Records what the window asks the engine to do."""

    started = Signal()
    stopped = Signal()
    error = Signal(str)

    def __init__(self, oscillator=None, parent=None) -> None:
        super().__init__(parent)
        self.oscillator = oscillator
        self.calls: list[str] = []
        self._volume = 0.7

    @property
    def volume(self) -> float:
        return self._volume

    @volume.setter
    def volume(self, value: float) -> None:
        self._volume = float(value)
        self.calls.append(f"volume={self._volume:.2f}")

    def start(self) -> bool:
        self.calls.append("start")
        return True

    def stop(self) -> None:
        self.calls.append("stop")

    def shutdown(self) -> None:
        pass


@pytest.fixture
def window(qapp):
    from binaural.ui.main_window import MainWindow

    engine = FakeEngine(StereoOscillator())
    win = MainWindow(engine, oscillator=engine.oscillator, session=Session())
    yield win
    win.close()
    win.deleteLater()
    qapp.processEvents()


@pytest.fixture
def dialog(qapp):
    made = SettingsDialog(timer_minutes=DEFAULT_TIMER_MINUTES, volume=0.7)
    yield made
    made.close()
    made.deleteLater()
    qapp.processEvents()


@pytest.fixture(autouse=True)
def english(qapp):
    """Every test starts and ends in English — the module default."""
    if i18n.language() != "en":
        i18n.set_language("en")
    yield
    i18n.set_language("en")


# ------------------------------------------------------------------ structure


def test_settings_dialog_creates(qapp, dialog):
    assert dialog.isModal() is True
    assert dialog.windowTitle() == "Settings"
    assert dialog.accessibleName() == "Settings"


def test_it_offers_the_four_rows_of_spec_7(qapp, dialog):
    """Language, timer, volume, and a button that re-runs the headphone check."""
    captions = [dialog._language_caption.text(), dialog._timer_caption.text(),
                dialog._volume_caption.text(), dialog._headphone_caption.text()]
    assert captions == ["Language", "Timer", "Volume", "Headphones"]
    assert dialog._check_button.text() == "Check headphones…"
    # No OK button: every control writes through, so there is nothing to apply.
    labels = [
        button.text()
        for button in dialog.findChildren(QPushButton)
        if button.text() in ("OK", "Apply", "Save")
    ]
    assert labels == []
    assert dialog._close_button.text() == "Close"


def test_the_language_names_stay_native_in_both_languages(qapp, dialog):
    """A user has to be able to find their own language in the list."""
    assert dialog.language_titles() == ["English", "Русский"]
    i18n.set_language("ru")
    assert dialog.language_titles() == ["English", "Русский"]


def test_the_timer_offers_exactly_the_contract_choices(qapp, dialog):
    """`Session.TIMER_CHOICES` — a settings dialog offering another set would be a
    second source of truth for a value that already has one."""
    assert dialog.timer_titles() == ["Off", "5 min", "10 min", "15 min", "20 min",
                                     "30 min", "45 min", "60 min", "90 min", "120 min"]
    assert dialog.selected_timer_minutes() == DEFAULT_TIMER_MINUTES
    assert TIMER_CHOICES[0] == TIMER_OFF


def test_controls_meet_the_touch_target_of_spec_7_2(qapp, dialog):
    for widget in (dialog._language_combo, dialog._timer_combo,
                   dialog._volume_slider, dialog._check_button, dialog._close_button):
        assert widget.minimumHeight() >= MIN_TOUCH_PX


# ------------------------------------------------------------------- values


def test_it_starts_from_the_values_it_was_given(qapp):
    dialog = SettingsDialog(language="en", timer_minutes=45, volume=0.25)
    try:
        assert dialog.selected_language() == "en"
        assert dialog.selected_timer_minutes() == 45
        assert dialog.volume_level() == pytest.approx(0.25)
        assert dialog.volume_title() == "25%"
    finally:
        dialog.close()
        dialog.deleteLater()


def test_opening_it_writes_nothing_back(qapp, window):
    """Showing the stored level is not the user changing it."""
    seen: list[float] = []
    dialog = window.make_settings_dialog()
    dialog.volume_changed.connect(seen.append)
    try:
        assert seen == []
        assert window.volume() == pytest.approx(0.7)
    finally:
        dialog.close()
        dialog.deleteLater()


def test_the_volume_row_reports_the_level(qapp, dialog):
    seen: list[float] = []
    dialog.volume_changed.connect(seen.append)
    assert dialog.set_volume(0.4) == pytest.approx(0.4)
    assert seen == [pytest.approx(0.4)]
    assert dialog.volume_title() == "40%"


def test_the_timer_row_reports_minutes(qapp, dialog):
    seen: list[int] = []
    dialog.timer_selected.connect(seen.append)
    assert dialog.choose_timer_minutes(30) == 30
    assert seen == [30]
    # TIMER_OFF is offered and reported as 0, not as "no choice".
    assert dialog.choose_timer_minutes(TIMER_OFF) == TIMER_OFF
    assert seen == [30, 0]


def test_an_unknown_duration_is_ignored_rather_than_reported(qapp, dialog):
    seen: list[int] = []
    dialog.timer_selected.connect(seen.append)
    assert dialog.choose_timer_minutes(17) == DEFAULT_TIMER_MINUTES
    assert seen == []


def test_the_headphone_button_asks_for_the_check(qapp, dialog):
    seen: list[bool] = []
    dialog.headphone_check_requested.connect(lambda: seen.append(True))
    dialog.tap_check_headphones()
    assert seen == [True]


def test_it_shows_the_verdict_the_app_is_acting_on(qapp, dialog):
    assert "Unknown device" in dialog.headphone_status_text()

    dialog.set_headphone_report(
        HeadphoneReport(DeviceClass.SPEAKERS, SPEAKERS_DEVICE, "high")
    )
    assert "Speakers detected" in dialog.headphone_status_text()
    assert "Динамики Mac mini" in dialog.headphone_detail_text()

    dialog.set_headphone_report(
        HeadphoneReport(DeviceClass.HEADPHONES, HEADPHONES_DEVICE, "high")
    )
    assert "Headphones detected" in dialog.headphone_status_text()


# ----------------------------------------------------------- written through


def test_the_volume_row_moves_the_window_and_the_engine(qapp, window):
    dialog = window.make_settings_dialog()
    try:
        dialog.set_volume(0.35)
        assert window.volume() == pytest.approx(0.35)
        assert window._engine.volume == pytest.approx(0.35)
        assert window.current_session().volume == pytest.approx(0.35)
    finally:
        dialog.close()
        dialog.deleteLater()


def test_the_timer_row_writes_the_session_and_rearms_playback(qapp, window):
    dialog = window.make_settings_dialog()
    try:
        window.start_playback()
        assert window.playback_timer().duration == DEFAULT_TIMER_MINUTES * 60

        dialog.choose_timer_minutes(45)
        assert window.timer_minutes() == 45
        assert window.current_session().timer_minutes == 45
        # A session already playing gets the new duration from now.
        assert window.playback_timer().duration == 2700.0
        assert window.countdown_text() == "45:00"
        window.stop_playback()
    finally:
        dialog.close()
        dialog.deleteLater()


def test_the_language_row_switches_the_whole_app(qapp, window):
    dialog = window.make_settings_dialog()
    try:
        dialog.choose_language("ru")
        assert i18n.language() == "ru"
        # The window, the menu and this dialog all re-read.
        assert window._timer_caption.text() == RU["Timer"]
        assert dialog.windowTitle() == RU["Settings"]
        assert dialog._volume_caption.text() == RU["Volume"]
        assert dialog._check_button.text() == RU["Check headphones…"]
    finally:
        dialog.reject()
        dialog.deleteLater()


def test_rejecting_restores_the_language(qapp, window):
    """With no OK button there is no commit, so Escape must not leave a silent switch."""
    dialog = window.make_settings_dialog()
    try:
        assert i18n.language() == "en"
        dialog.choose_language("ru")
        assert i18n.language() == "ru"
        dialog.reject()
        assert i18n.language() == "en"
        assert window._timer_caption.text() == "Timer"
        assert dialog.windowTitle() == "Settings"
    finally:
        dialog.close()
        dialog.deleteLater()


def test_accepting_keeps_the_language(qapp, window):
    dialog = window.make_settings_dialog()
    try:
        dialog.choose_language("ru")
        dialog.accept()
        assert i18n.language() == "ru"
    finally:
        dialog.reject()  # put the app back for the next test
        dialog.close()
        dialog.deleteLater()


def test_a_switch_made_from_the_view_menu_reaches_the_open_dialog(qapp, window):
    dialog = window.make_settings_dialog()
    try:
        window.set_language("ru")
        assert dialog.windowTitle() == RU["Settings"]
        assert dialog.timer_titles()[0] == RU["Off"]
        assert dialog._volume_caption.text() == RU["Volume"]
    finally:
        window.set_language("en")
        dialog.close()
        dialog.deleteLater()


def test_the_headphone_button_runs_the_real_check(qapp, window):
    """Settings offers the entry point; it must be the §4.3 dialog, not a second check."""
    dialog = window.make_settings_dialog()
    ran: list[bool] = []
    window.run_headphone_check = lambda: ran.append(True)  # type: ignore[method-assign]
    try:
        dialog.tap_check_headphones()
        assert ran == [True]
    finally:
        dialog.close()
        dialog.deleteLater()


def test_the_window_survives_a_missing_dialogs_package(qapp, window, monkeypatch):
    """The dialogs layer is optional: the app must still run without it."""
    monkeypatch.setattr(window, "_dialog_class", lambda name: None)
    assert window.make_settings_dialog() is None
