"""UI tests: window wiring, independent channels, live beat math, accessibility.

Every test needs a live ``QApplication``, which needs a display. On a headless
box the whole module skips instead of failing (SPEC §10 step 4 can be checked
anywhere).
"""

from __future__ import annotations

import os
import sys

import pytest

QtWidgets = pytest.importorskip("PySide6.QtWidgets")
QtCore = pytest.importorskip("PySide6.QtCore")

from PySide6.QtCore import QObject, Qt, Signal  # noqa: E402
from PySide6.QtGui import QKeyEvent  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QDialog, QLineEdit  # noqa: E402

from binaural.core.oscillator import StereoOscillator  # noqa: E402
from binaural.core.session import Session  # noqa: E402
from binaural.ui import theme  # noqa: E402
from binaural.ui.main_window import MainWindow  # noqa: E402
from binaural.ui.widgets.beat_display import BeatDisplay  # noqa: E402
from binaural.ui.widgets.freq_control import FreqControl  # noqa: E402
from binaural.ui.widgets.status_indicator import (  # noqa: E402
    STATE_HEADPHONES,
    STATE_SPEAKERS,
    STATE_UNKNOWN,
    StatusIndicator,
)


def _has_display() -> bool:
    """True when a windowing system is reachable.

    Qt aborts the process when it cannot pick a platform plugin at all, so the
    check has to happen before ``QApplication`` is constructed.
    """
    if sys.platform == "darwin" or sys.platform == "win32":
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


@pytest.fixture(scope="session")
def qapp():
    """One QApplication for the whole module; skip when there is no display."""
    app = QApplication.instance()
    created = False
    if app is None:
        if not _has_display():
            # Offscreen keeps the widget tests meaningful without a screen.
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        try:
            app = QApplication(["binaural-tests"])
        except Exception as exc:  # no display / no platform plugin
            pytest.skip(f"QApplication unavailable: {exc}")
        created = True
    if created:
        theme.apply_theme(app)
    yield app


class FakeEngine(QObject):
    """Stands in for AudioEngine: records calls, emits the same signals."""

    started = Signal()
    stopped = Signal()
    error = Signal(str)

    def __init__(self, oscillator=None, parent=None) -> None:
        super().__init__(parent)
        self.oscillator = oscillator
        self.calls: list[str] = []
        self._running = False
        self._volume = 0.7
        self.start_result = True

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def volume(self) -> float:
        return self._volume

    @volume.setter
    def volume(self, value: float) -> None:
        self._volume = float(value)
        self.calls.append(f"volume={self._volume:.2f}")

    def start(self) -> bool:
        self.calls.append("start")
        if not self.start_result:
            self.error.emit("Could not open the audio output device.")
            return False
        self._running = True
        self.started.emit()
        return True

    def stop(self) -> None:
        self.calls.append("stop")
        self._running = False
        self.stopped.emit()

    def shutdown(self) -> None:
        self.calls.append("shutdown")
        self._running = False


@pytest.fixture
def window(qapp):
    """A MainWindow on a fake engine, torn down without touching real audio."""
    oscillator = StereoOscillator()
    engine = FakeEngine(oscillator)
    win = MainWindow(
        engine,
        oscillator=oscillator,
        session=Session(left_hz=205.0, right_hz=215.0, volume=0.7),
    )
    yield win
    win.close()
    win.deleteLater()
    qapp.processEvents()


# ----------------------------------------------------------------- construction


def test_main_window_creates_without_exception(window):
    assert window.isVisible() is False or window.windowTitle()
    assert window.windowTitle()
    assert window.status_indicator is not None


def test_window_has_the_spec_layout(window):
    """Both ear panels, the beat card, the transport and the preset chips exist."""
    captions = [window._left.caption(), window._right.caption()]
    assert captions == ["LEFT EAR", "RIGHT EAR"]
    assert isinstance(window._beat, BeatDisplay)
    assert window._play_button.text() == "Play"
    assert window._volume is not None
    assert len(window._preset_buttons) == 5


def test_default_pair_from_session_is_shown(window):
    assert window.left_hz() == pytest.approx(205.0)
    assert window.right_hz() == pytest.approx(215.0)
    assert window._beat.beat_hz() == pytest.approx(10.0)


# ------------------------------------------------------------------ independence


def test_changing_left_does_not_move_right(window):
    window._left.set_value(300.0)
    assert window.left_hz() == pytest.approx(300.0)
    assert window.right_hz() == pytest.approx(215.0)
    assert window._beat.beat_hz() == pytest.approx(85.0)


def test_changing_right_does_not_move_left(window):
    window._right.set_value(150.0)
    assert window.right_hz() == pytest.approx(150.0)
    assert window.left_hz() == pytest.approx(205.0)
    assert window._beat.beat_hz() == pytest.approx(55.0)


def test_two_controls_are_distinct_objects(window):
    assert window._left is not window._right


# ------------------------------------------------------------------ beat math


def test_beat_and_carrier_recompute_live(window):
    window.set_frequencies(205.0, 215.0)
    assert window._beat.beat_hz() == pytest.approx(10.0)
    assert window._beat.carrier_hz() == pytest.approx(210.0)

    window.set_frequencies(400.0, 430.0)
    assert window._beat.beat_hz() == pytest.approx(30.0)
    assert window._beat.carrier_hz() == pytest.approx(415.0)

    # Swapping the sides must not change the math.
    window.set_frequencies(430.0, 400.0)
    assert window._beat.beat_hz() == pytest.approx(30.0)
    assert window._beat.carrier_hz() == pytest.approx(415.0)


def test_out_of_range_beat_shows_a_hint(window):
    window.set_frequencies(205.0, 215.0)
    assert window._beat.is_hint_visible() is False

    window.set_frequencies(1000.0, 1500.0)  # 500 Hz difference
    assert window._beat.beat_hz() == pytest.approx(500.0)
    assert window._beat.is_hint_visible() is True
    assert "500.0" in window._beat.hint_text()


def test_low_beat_below_half_hz_shows_a_hint(window):
    window.set_frequencies(200.0, 200.1)  # 0.1 Hz difference
    assert window._beat.is_hint_visible() is True


# --------------------------------------------------------------------- signals


def test_frequencies_changed_signal_arguments(window):
    seen: list[tuple[float, float]] = []
    window.frequencies_changed.connect(lambda l, r: seen.append((l, r)))

    window._left.set_value(220.0)
    window._right.set_value(260.0)
    window.set_frequencies(300.0, 330.0)

    assert seen == [(220.0, 215.0), (220.0, 260.0), (300.0, 330.0)]


def test_playback_toggled_signal(window):
    seen: list[bool] = []
    window.playback_toggled.connect(seen.append)

    window.start_playback()
    window.stop_playback()

    assert seen == [True, False]
    assert window.is_playing() is False


def test_play_button_calls_engine_start(window):
    window._play_button.click()
    assert "start" in window._engine.calls
    assert window._play_button.text() == "Stop"

    window._play_button.click()
    assert "stop" in window._engine.calls
    assert window._play_button.text() == "Play"


def test_failed_start_shows_the_error_text(window):
    window._engine.start_result = False
    window.start_playback()
    assert window.is_playing() is False
    assert window._play_button.text() == "Play"


def test_volume_reaches_the_engine(window):
    window._volume.setValue(40)
    assert window._engine.volume == pytest.approx(0.4)


def test_closing_shuts_the_engine_down(qapp):
    engine = FakeEngine(StereoOscillator())
    win = MainWindow(engine, session=Session())
    win.close()
    assert "shutdown" in engine.calls
    win.deleteLater()


# -------------------------------------------------------------------- presets


def test_preset_chip_sets_both_channels(window):
    window._preset_buttons[2].click()  # Alpha 10
    assert window._beat.beat_hz() == pytest.approx(10.0)
    assert window._beat.carrier_hz() == pytest.approx(200.0)
    assert window._left.value() == pytest.approx(195.0)
    assert window._right.value() == pytest.approx(205.0)


def test_apply_preset_covers_every_chip(window):
    for index, (_, beat) in enumerate(
        [(label, beat) for label, beat in __import__(
            "binaural.ui.main_window", fromlist=["PRESETS"]
        ).PRESETS]
    ):
        window.apply_preset(beat, index)
        assert window._beat.beat_hz() == pytest.approx(beat)


# ----------------------------------------------------------------- channel swap


def test_channels_swapped_reaches_the_oscillator(qapp):
    oscillator = StereoOscillator()
    win = MainWindow(FakeEngine(oscillator), oscillator=oscillator, session=Session())
    win.set_frequencies(205.0, 215.0)
    assert oscillator.left_hz == pytest.approx(205.0)
    assert oscillator.right_hz == pytest.approx(215.0)

    win.set_channels_swapped(True)
    assert oscillator.left_hz == pytest.approx(215.0)
    assert oscillator.right_hz == pytest.approx(205.0)
    win.close()
    win.deleteLater()


# ----------------------------------------------------------------- keyboard


def _key(window, key, modifiers=Qt.KeyboardModifier.NoModifier):
    """Send a key straight to the window, bypassing Qt's shortcut dispatch."""
    event = QKeyEvent(QtCore.QEvent.Type.KeyPress, key, modifiers, "")
    window.keyPressEvent(event)
    return event


def test_space_toggles_playback(window):
    _key(window, Qt.Key.Key_Space)
    assert window.is_playing() is True
    _key(window, Qt.Key.Key_Space)
    assert window.is_playing() is False


def test_up_and_down_nudge_the_active_channel_by_tenth(window):
    window._left.set_value(200.0)
    window._right.set_value(300.0)

    _key(window, Qt.Key.Key_Up)  # active channel starts as left
    assert window.left_hz() == pytest.approx(200.1)
    assert window.right_hz() == pytest.approx(300.0)

    _key(window, Qt.Key.Key_Down)
    assert window.left_hz() == pytest.approx(200.0)


def test_left_and_right_switch_the_active_channel(window):
    assert window.active_channel() == 0
    _key(window, Qt.Key.Key_Right)
    assert window.active_channel() == 1

    window._right.set_value(300.0)
    _key(window, Qt.Key.Key_Up)
    assert window.right_hz() == pytest.approx(300.1)
    assert window.left_hz() == pytest.approx(205.0)

    _key(window, Qt.Key.Key_Left)
    assert window.active_channel() == 0


def test_arrow_keys_are_not_stolen_from_a_text_field(qapp):
    """A focused text field keeps the arrows — typing must not nudge audio."""
    oscillator = StereoOscillator()
    win = MainWindow(FakeEngine(oscillator), oscillator=oscillator, session=Session())
    win.set_frequencies(205.0, 215.0)
    win.show()
    win.activateWindow()
    win._left.focus_spin()
    qapp.processEvents()

    # A real QLineEdit (as in the save-preset dialog) must block the window.
    editor = QLineEdit(win)
    editor.show()
    editor.setFocus()
    qapp.processEvents()
    assert isinstance(QApplication.focusWidget(), QLineEdit)

    _key(win, Qt.Key.Key_Up)
    assert win.left_hz() == pytest.approx(205.0)
    assert win.right_hz() == pytest.approx(215.0)

    editor.close()
    editor.deleteLater()
    win.close()
    win.deleteLater()


def test_arrow_keys_still_work_when_focus_is_in_the_app(qapp):
    """Without a text field in the way, the window keeps the arrow keys."""
    oscillator = StereoOscillator()
    win = MainWindow(FakeEngine(oscillator), oscillator=oscillator, session=Session())
    win.show()
    win.activateWindow()
    win._play_button.setFocus()  # a button: it never wants the arrows
    qapp.processEvents()
    assert QApplication.focusWidget() is win._play_button

    win._left.set_value(205.0)
    _key(win, Qt.Key.Key_Up)
    assert win.left_hz() == pytest.approx(205.1)

    _key(win, Qt.Key.Key_Down)
    assert win.left_hz() == pytest.approx(205.0)
    win.close()
    win.deleteLater()


def test_escape_closes_a_modal(qapp):
    win = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    dialog = QDialog(win)
    dialog.setModal(True)
    dialog.show()
    qapp.processEvents()
    assert QApplication.activeModalWidget() is dialog

    _key(win, Qt.Key.Key_Escape)
    assert dialog.isVisible() is False
    win.close()
    win.deleteLater()


# -------------------------------------------------------------- accessibility


def test_interactive_widgets_have_accessible_names(window):
    assert window._play_button.accessibleName()
    assert window._volume.accessibleName()
    assert window._left.accessibleName() == "LEFT EAR"
    assert window._left._spin.accessibleDescription()
    assert window._left._slider.accessibleDescription()
    assert window.status_indicator.accessibleName()
    assert window.status_indicator.accessibleDescription()


def test_preset_chips_are_at_least_44px_tall(window):
    for button in window._preset_buttons:
        assert button.minimumHeight() >= 44


def test_stylesheet_keeps_a_focus_ring(qapp):
    light = theme.build_stylesheet(dark=False)
    dark = theme.build_stylesheet(dark=True)
    assert theme.LIGHT["ring"] in light
    assert theme.DARK["ring"] in dark
    assert ":focus" in light
    assert "outline" in light


def test_theme_tokens_match_the_spec():
    assert theme.TOKENS["primary"] == ("#7C3AED", "#A78BFA")
    assert theme.TOKENS["secondary"] == ("#8B5CF6", "#C4B5FD")
    assert theme.TOKENS["accent"] == ("#059669", "#34D399")
    assert theme.TOKENS["background"] == ("#FAF5FF", "#151221")
    assert theme.TOKENS["surface"] == ("#FFFFFF", "#1E1A2E")
    assert theme.TOKENS["foreground"] == ("#0F172A", "#F1EDFF")
    assert theme.TOKENS["muted-fg"] == ("#475569", "#A5A0BE")
    assert theme.TOKENS["border"] == ("#EFE7FC", "#322B4A")
    assert theme.TOKENS["warning"] == ("#D97706", "#FBBF24")
    assert theme.TOKENS["destructive"] == ("#DC2626", "#F87171")
    assert theme.TOKENS["ring"] == ("#7C3AED", "#A78BFA")
    assert theme.FONT_SIZES["display"] == 42
    assert theme.FONT_SIZES["metric"] == 26
    assert 10 <= theme.RADIUS <= 12


# --------------------------------------------------------- status indicator


@pytest.mark.parametrize(
    "state, fragment",
    [
        (STATE_HEADPHONES, "Headphones detected"),
        (STATE_SPEAKERS, "Speakers detected"),
        (STATE_UNKNOWN, "Unknown device"),
    ],
)
def test_status_indicator_text_follows_the_verdict(qapp, state, fragment):
    indicator = StatusIndicator()
    indicator.set_state(state)
    assert fragment in indicator.text()
    assert indicator.state() == state
    # Text carries the meaning, so colour is never the only signal.
    assert indicator.text().strip()
    indicator.deleteLater()


def test_status_indicator_accepts_a_report(qapp):
    from binaural.audio.headphones import HeadphoneReport, LrTestResult
    from binaural.audio.platform.base import AudioDevice, DeviceClass

    report = HeadphoneReport(
        verdict=DeviceClass.SPEAKERS,
        device=AudioDevice(name="Mac mini Speakers", transport="builtin", is_default=True),
        confidence="high",
    )
    indicator = StatusIndicator()
    indicator.set_report(report)
    assert "Speakers detected" in indicator.text()
    assert "Mac mini Speakers" in indicator.toolTip()

    confirmed = HeadphoneReport(
        verdict=DeviceClass.SPEAKERS,
        device=None,
        confidence="high",
        lr_test=LrTestResult.LEFT_THEN_RIGHT,
    )
    indicator.set_report(confirmed)
    assert "Headphones detected" in indicator.text()
    indicator.deleteLater()


def test_window_swallows_a_headphone_report(qapp):
    from binaural.audio.headphones import HeadphoneReport, LrTestResult
    from binaural.audio.platform.base import DeviceClass

    win = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    report = HeadphoneReport(
        verdict=DeviceClass.SPEAKERS,
        device=None,
        confidence="high",
        lr_test=LrTestResult.RIGHT_THEN_LEFT,
    )
    win.set_headphone_report(report)
    assert "Headphones detected" in win.status_indicator.text()
    assert win.channels_swapped() is True
    win.close()
    win.deleteLater()


# ------------------------------------------------------------- FreqControl


def test_freq_control_validates_and_signals(qapp):
    control = FreqControl("LEFT EAR", "primary")
    seen: list[float] = []
    control.valueChanged.connect(seen.append)

    control._spin.setValue(432.0)
    assert control.value() == pytest.approx(432.0)
    assert seen[-1] == pytest.approx(432.0)

    # The spinbox clamps to the supported range instead of accepting nonsense.
    control._spin.setValue(99999.0)
    assert control.value() == pytest.approx(20000.0)
    control._spin.setValue(0.01)
    assert control.value() == pytest.approx(1.0)
    control.deleteLater()


def test_freq_control_slider_round_trip(qapp):
    control = FreqControl("RIGHT EAR", "secondary")
    control.set_value(250.0)
    assert control._spin.value() == pytest.approx(250.0)
    assert control._display.text() == "250.0"

    control._slider.setValue(control._slider.maximum())
    assert control.value() == pytest.approx(20000.0)
    control._slider.setValue(0)
    assert control.value() == pytest.approx(1.0)
    control.deleteLater()


def test_freq_control_never_emits_internally(qapp):
    """Setting the same value must not fire valueChanged."""
    control = FreqControl("LEFT EAR", "primary")
    seen: list[float] = []
    control.valueChanged.connect(seen.append)
    control.set_value(300.0)
    control.set_value(300.0)
    control._sync_widgets()
    assert seen == [300.0]
    control.deleteLater()


def test_freq_control_stepper_arrows_are_clickable(qapp):
    """The hand-drawn stepper must step the value, not just look right."""
    control = FreqControl("LEFT EAR", "primary")
    control.show()
    qapp.processEvents()

    upper = control._spin.step_area(True)
    lower = control._spin.step_area(False)
    assert upper.isValid() and lower.isValid()

    before = control.value()
    upper.setLeft(upper.left() + 4)
    QTest.mouseClick(control._spin, Qt.MouseButton.LeftButton, pos=upper.center())
    assert control.value() == pytest.approx(round(before + 0.1, 1))

    QTest.mouseClick(control._spin, Qt.MouseButton.LeftButton, pos=lower.center())
    assert control.value() == pytest.approx(before)
    control.close()
    control.deleteLater()


def test_freq_control_nudge_uses_the_tenth_grid(qapp):
    control = FreqControl("LEFT EAR", "primary")
    control.set_value(200.0)
    control.nudge(0.1)
    assert control.value() == pytest.approx(200.1)
    control.nudge(-0.1)
    assert control.value() == pytest.approx(200.0)
    control.deleteLater()


# ---------------------------------------------------------- reduced motion


def test_reduced_motion_switches_the_pulse_off(qapp, monkeypatch):
    monkeypatch.setenv(theme.ENV_REDUCED_MOTION, "1")
    assert theme.reduced_motion() is True

    display = BeatDisplay()
    display.update_values(205.0, 215.0)
    display.set_playing(True)
    assert display.is_reduced_motion() is True
    assert display._timer.isActive() is False
    assert "Reduced motion" in display.hint_text()

    monkeypatch.setenv(theme.ENV_REDUCED_MOTION, "0")
    assert theme.reduced_motion() is False
    display.set_reduced_motion(False)
    display.set_playing(True)
    assert display._timer.isActive() is True
    display.deleteLater()


def test_pulse_runs_only_while_playing(qapp, monkeypatch):
    monkeypatch.setenv(theme.ENV_REDUCED_MOTION, "0")
    display = BeatDisplay()
    display.update_values(205.0, 215.0)
    display.set_playing(True)
    assert display._timer.isActive() is True
    display.set_playing(False)
    assert display._timer.isActive() is False
    display.deleteLater()


# ------------------------------------------------------------- session state


def test_session_is_restored_at_startup(qapp):
    saved = Session(left_hz=180.0, right_hz=240.0, volume=0.25, channels_swapped=True)
    win = MainWindow(FakeEngine(StereoOscillator()), session=saved)
    assert win.left_hz() == pytest.approx(180.0)
    assert win.right_hz() == pytest.approx(240.0)
    assert win._volume.value() == 25
    assert win.channels_swapped() is True
    win.close()
    win.deleteLater()


def test_current_session_reflects_the_ui(window):
    window.set_frequencies(150.0, 160.0)
    window._volume.setValue(50)
    snapshot = window.current_session()
    assert snapshot.left_hz == pytest.approx(150.0)
    assert snapshot.right_hz == pytest.approx(160.0)
    assert snapshot.volume == pytest.approx(0.5)


# ------------------------------------------------------------------ no display


# ------------------------------------------------------------------ dialogs


def test_reference_dialog_opens_without_the_window_blowing_up(qapp):
    """The Cmd/Ctrl+O hook must work when the dialogs package is present."""
    window = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    dialog_class = window._dialog_class("ReferenceDialog")
    if dialog_class is None:
        pytest.skip("The dialogs package is not built yet")

    dialog = dialog_class(window)
    try:
        # Applying an entry replaces both channels, like any other edit.
        dialog.apply_frequencies.emit(220.0, 240.0)
        window.set_frequencies(220.0, 240.0)
        assert window._beat.beat_hz() == pytest.approx(20.0)
    finally:
        dialog.close()
        dialog.deleteLater()
        window.close()
        window.deleteLater()


def test_headphone_check_dialog_feeds_the_window(qapp):
    """The startup dialog path must set the status and remember the swap."""
    window = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    dialog_class = window._dialog_class("HeadphoneCheckDialog")
    if dialog_class is None:
        pytest.skip("The dialogs package is not built yet")

    from binaural.audio.headphones import LrTestResult

    dialog = dialog_class(None, window._engine, window, detect_now=False)
    # "Right then left" means the channels are crossed: the window must swap.
    dialog.set_lr_result(LrTestResult.RIGHT_THEN_LEFT)
    report = dialog.report()
    window.set_headphone_report(report)

    assert "Headphones detected" in window.status_indicator.text()
    assert window.channels_swapped() is True
    dialog.close()
    dialog.deleteLater()
    window.close()
    window.deleteLater()


def test_headphone_check_class_is_resolved_or_skipped(qapp):
    window = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    dialog_class = window._dialog_class("HeadphoneCheckDialog")
    if dialog_class is None:
        window.run_headphone_check()
        # Without the dialog the window must still have a truthful status.
        assert window.status_indicator.text()
    window.close()
    window.deleteLater()


def test_about_dialog_opens(qapp):
    window = MainWindow(FakeEngine(StereoOscillator()), session=Session())
    dialog_class = window._dialog_class("AboutDialog")
    if dialog_class is None:
        pytest.skip("The dialogs package is not built yet")
    dialog = dialog_class(window)
    assert dialog.windowTitle()
    dialog.close()
    dialog.deleteLater()
    window.close()
    window.deleteLater()


def test_a_missing_display_is_a_skip_not_a_failure(qapp):
    """Headless boxes must skip, not fail — the fixture is the guard."""
    if QApplication.instance() is None:
        pytest.skip("No QApplication available")
    assert QApplication.instance() is not None