"""SPEC §7's "Lock difference" checkbox in the real window.

``test_difference_lock.py`` checks the arithmetic on its own; this file checks the wiring
— that the checkbox sits next to the beat read-out, that *every* path a frequency can
change through goes past the lock, and that a preset still wins. The same cases are stated
in ``apple/Tests/MacTests/DifferenceLockTests.swift``.
"""

from __future__ import annotations

import os
import sys

import pytest

QtWidgets = pytest.importorskip("PySide6.QtWidgets")
QtCore = pytest.importorskip("PySide6.QtCore")

from binaural import i18n  # noqa: E402
from binaural.core.oscillator import MAX_FREQ_HZ, StereoOscillator  # noqa: E402
from binaural.core.session import Session  # noqa: E402
from binaural.ui import theme  # noqa: E402
from binaural.ui.main_window import (  # noqa: E402
    DIFFERENCE_BOUNDARY_NOTE,
    DIFFERENCE_UNLOCKED_NOTICE,
    MainWindow,
)
from binaural.ui.widgets.beat_display import BeatDisplay  # noqa: E402
from binaural.ui.widgets.freq_control import FreqControl  # noqa: E402


def _has_display() -> bool:
    if sys.platform in ("darwin", "win32"):
        return True
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


@pytest.fixture(scope="session")
def qapp():
    """One QApplication for the module; skip when there is no display."""
    app = QtWidgets.QApplication.instance()
    created = False
    if app is None:
        if not _has_display():
            os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        try:
            app = QtWidgets.QApplication(["binaural-lock-tests"])
        except Exception as exc:  # no display / no platform plugin
            pytest.skip(f"QApplication unavailable: {exc}")
        created = True
    if created:
        theme.apply_theme(app)
    yield app


class _Engine(QtCore.QObject):
    """A window needs an engine; this one does nothing and never opens a device."""

    def start(self) -> bool:
        return False

    def stop(self) -> None:
        pass

    def shutdown(self) -> None:
        pass


@pytest.fixture
def make_window(qapp, tmp_path, monkeypatch):
    """Build windows on a throwaway settings file, and keep QSettings off the real one."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setenv("HOME", str(tmp_path))
    QtCore.QSettings.setDefaultFormat(QtCore.QSettings.Format.IniFormat)
    settings = QtCore.QSettings("binaural", "binaural")
    settings.clear()
    settings.sync()

    built: list[MainWindow] = []

    def factory(session: Session | None = None) -> MainWindow:
        """A window on ``session``; ``None`` means "start from the stored one"."""
        from binaural.core.session import load as load_session

        oscillator = StereoOscillator()
        win = MainWindow(
            _Engine(),
            oscillator=oscillator,
            session=load_session() if session is None else session,
        )
        built.append(win)
        return win

    yield factory
    for win in built:
        win.close()
        win.deleteLater()
    qapp.processEvents()


def _key(window, key):
    """Send a key straight to the window, bypassing Qt's shortcut dispatch."""
    from PySide6.QtGui import QKeyEvent

    window.keyPressEvent(QKeyEvent(QtCore.QEvent.Type.KeyPress, key, QtCore.Qt.KeyboardModifier.NoModifier, ""))


def _locked_window(make_window, left=200.0, right=260.0):
    """A window on the given pair with the box ticked, as a click does."""
    window = make_window(Session(left_hz=left, right_hz=right))
    window._beat.lock_checkbox().setChecked(True)  # the control a user presses
    assert window.is_difference_locked() is True
    return window


# --------------------------------------------------------------- the checkbox


def test_the_checkbox_sits_next_to_the_beat_display(make_window):
    """SPEC §7: the lock belongs beside the difference it protects."""
    window = make_window()
    assert window._beat.lock_checkbox().parent() is window._beat


def test_the_difference_stays_an_indicator(make_window):
    """Decision 1: capture, do not edit — there is no field for typing a difference."""
    window = make_window()
    for widget in window._beat.findChildren(QtWidgets.QAbstractSpinBox):
        pytest.fail("the beat card must not grow a numeric field")
    for widget in window._beat.findChildren(QtWidgets.QLineEdit):
        pytest.fail("the beat card must not grow a text field")
    # The beat is a QLabel, which is not editable.
    assert isinstance(window._beat._beat_value, QtWidgets.QLabel)


def test_the_checkbox_is_captioned_in_both_languages(make_window):
    window = make_window()
    assert window._beat.lock_checkbox().text() == "Lock difference"
    i18n.set_language("ru")
    try:
        assert window._beat.lock_checkbox().text() == "Зафиксировать"
    finally:
        i18n.set_language("en")


def test_the_checkbox_is_off_on_a_fresh_session(make_window):
    window = make_window()
    assert window.is_difference_locked() is False
    assert window._beat.lock_checkbox().isChecked() is False


def test_the_checkbox_is_reachable_and_named(make_window):
    """SPEC §7.2: a 44 px target and an accessible name, like every other control."""
    window = make_window()
    box = window._beat.lock_checkbox()
    assert box.minimumHeight() >= 44
    assert box.accessibleName()
    assert box.accessibleDescription()


# ------------------------------------------------- decision 1: capture, do not edit


def test_ticking_captures_the_current_difference(make_window):
    window = make_window(Session(left_hz=200.0, right_hz=260.0))
    window._beat.lock_checkbox().setChecked(True)

    assert window.is_difference_locked() is True
    assert window.locked_difference_hz() == pytest.approx(60.0)
    # Ticking moves nothing by itself.
    assert window.left_hz() == pytest.approx(200.0)
    assert window.right_hz() == pytest.approx(260.0)


# ------------------------------------------- decision 2: the untouched channel follows


def test_editing_left_moves_right(make_window):
    window = _locked_window(make_window)
    window._left.set_value(250.0)
    assert window.left_hz() == pytest.approx(250.0)
    assert window.right_hz() == pytest.approx(310.0)
    assert window._beat.beat_hz() == pytest.approx(60.0)


def test_editing_right_moves_left(make_window):
    window = _locked_window(make_window)
    window._right.set_value(210.0)
    assert window.right_hz() == pytest.approx(210.0)
    assert window.left_hz() == pytest.approx(150.0)


def test_a_negative_difference_is_kept_negative(make_window):
    """The right ear can be the lower one, and following must not flip the sign."""
    window = _locked_window(make_window, left=260.0, right=200.0)
    assert window.locked_difference_hz() == pytest.approx(-60.0)

    window._left.set_value(250.0)
    assert window.left_hz() == pytest.approx(250.0)
    assert window.right_hz() == pytest.approx(190.0)
    assert window.right_hz() - window.left_hz() == pytest.approx(-60.0)


def test_the_slider_follows_too(make_window):
    """A slider drag is a ``set_value`` like any other, so it takes the same path.

    The slider is logarithmic, so its last detent is 19940 Hz rather than exactly
    20000 — what matters is that the difference survives the drag.
    """
    window = _locked_window(make_window)
    window._left._slider.setValue(window._left._slider.maximum())
    assert window.left_hz() > 19_000.0
    assert window.right_hz() - window.left_hz() == pytest.approx(60.0)


def test_typed_entry_follows(make_window):
    """Exact keyboard entry is the same path the field's own action takes."""
    window = _locked_window(make_window)
    window._left.set_value(311.5)
    assert window.left_hz() == pytest.approx(311.5)
    assert window.right_hz() == pytest.approx(371.5)


def test_the_nudge_follows_as_well(make_window):
    """The ``↑``/``↓`` nudge is a ``set_value`` too."""
    window = _locked_window(make_window)
    _key(window, QtCore.Qt.Key.Key_Up)  # left is the active channel
    assert window.left_hz() == pytest.approx(200.1)
    assert window.right_hz() == pytest.approx(260.1)

    _key(window, QtCore.Qt.Key.Key_Right)  # switch to the right channel
    _key(window, QtCore.Qt.Key.Key_Up)
    assert window.right_hz() == pytest.approx(260.2)
    assert window.left_hz() == pytest.approx(200.2)


def test_unlocking_stops_following_and_keeps_the_frequencies(make_window):
    window = _locked_window(make_window)
    window._left.set_value(250.0)
    assert window.right_hz() == pytest.approx(310.0)

    window._beat.lock_checkbox().setChecked(False)
    assert window.is_difference_locked() is False

    window._left.set_value(300.0)
    assert window.left_hz() == pytest.approx(300.0)
    assert window.right_hz() == pytest.approx(310.0)


# ------------------------------------------- decision 3: a preset wins and unlocks


def test_a_preset_applies_its_own_beat_and_clears_the_lock(make_window):
    window = _locked_window(make_window)
    window.apply_preset(2.0)  # relaxation's first preset: 2 Hz

    assert window.is_difference_locked() is False
    assert window._beat.lock_checkbox().isChecked() is False
    assert window._beat.beat_hz() == pytest.approx(2.0)


def test_a_preset_shows_the_unlock_notice(make_window):
    """The user has to be told, or a checkbox that clears itself looks like a bug."""
    window = _locked_window(make_window)
    window.apply_preset(2.0)

    assert window.difference_notice_key() == DIFFERENCE_UNLOCKED_NOTICE
    assert window._notice.text() == "Difference lock turned off — a preset set its own difference."
    # `isHidden` rather than `isVisible`: the window itself is never shown in a test, and
    # a child of a hidden parent reports itself invisible whatever it asked for.
    assert window._notice.isHidden() is False

    i18n.set_language("ru")
    try:
        assert window._notice.text() == (
            "Фиксация разности выключена — пресет задал свою разность."
        )
    finally:
        i18n.set_language("en")


def test_a_preset_without_a_lock_shows_no_unlock_notice(make_window):
    window = make_window()
    window.apply_preset(2.0)
    assert window.difference_notice_key() is None


def test_the_notice_goes_away_on_its_own(make_window):
    window = _locked_window(make_window)
    window.apply_preset(2.0)
    assert window._notice_timer.isActive() is True
    window._notice_timer.setInterval(1)
    QtCore.QCoreApplication.processEvents()
    window._hide_notice()
    assert window.difference_notice_key() is None
    assert window._notice.isHidden() is True


def test_the_reference_dialog_wires_to_the_unlocking_pair_path(make_window, monkeypatch):
    """The dialog's signal must reach ``set_frequencies``, not a raw pair write.

    ``open_reference`` connects ``apply_frequencies`` to the pair entry point, so a named
    pair from §6 lands whole and unlocks — a stub dialog proves the connection rather
    than trusting the call site to stay that way.
    """
    window = _locked_window(make_window)
    emitted: list[tuple[float, float]] = []

    class _Stub(QtCore.QObject):
        apply_frequencies = QtCore.Signal(float, float)

        def exec(self):
            self.apply_frequencies.emit(174.0, 178.0)
            emitted.append((174.0, 178.0))
            return 0

    monkeypatch.setattr(
        MainWindow,
        "_dialog_class",
        staticmethod(lambda name: _Stub if name == "ReferenceDialog" else None),
    )
    window.open_reference()

    assert emitted == [(174.0, 178.0)], "the stub never emitted, so nothing was proven"
    assert window.left_hz() == pytest.approx(174.0)
    assert window.right_hz() == pytest.approx(178.0)
    assert window.is_difference_locked() is False


def test_a_reference_pair_wins_over_the_lock(make_window):
    """SPEC §6's *Apply* is the same kind of instruction as a preset — a named pair — so
    it wins too, rather than one channel yanking the other."""
    window = _locked_window(make_window)
    window.set_frequencies(174.0, 178.0)

    assert window.left_hz() == pytest.approx(174.0)
    assert window.right_hz() == pytest.approx(178.0)
    assert window.is_difference_locked() is False


# ----------------------------------------- decision 4: the edited channel stops


def test_the_edited_channel_stops_at_the_top_of_the_range(make_window):
    window = _locked_window(make_window, left=19_000.0, right=19_010.0)
    window._left.set_value(MAX_FREQ_HZ)

    assert window.right_hz() == pytest.approx(MAX_FREQ_HZ)
    assert window.left_hz() == pytest.approx(19_990.0)
    assert window._beat.is_hint_visible() is True
    assert "range limit" in window._beat.hint_text()
    assert window._beat.is_showing_boundary_note() is True
    # The lock itself was never violated and never dropped.
    assert window.is_difference_locked() is True
    assert window.locked_difference_hz() == pytest.approx(10.0)


def test_the_edited_channel_stops_at_the_bottom_of_the_range(make_window):
    """A positive difference makes the left channel the lower one, so dragging the
    *right* one down is what runs out of range."""
    window = _locked_window(make_window, left=1_010.0, right=1_020.0)
    window._right.set_value(1.0)

    assert window.right_hz() == pytest.approx(11.0)
    assert window.left_hz() == pytest.approx(1.0)
    assert window._beat.is_showing_boundary_note() is True
    assert window.is_difference_locked() is True
    assert window.locked_difference_hz() == pytest.approx(10.0)


def test_a_negative_difference_pushes_the_left_channel_to_the_bottom(make_window):
    """The sign decides which channel hits which edge — the case Swift got wrong first."""
    window = _locked_window(make_window, left=1_020.0, right=1_010.0)
    window._left.set_value(1.0)

    assert window.left_hz() == pytest.approx(11.0)
    assert window.right_hz() == pytest.approx(1.0)
    assert window.is_difference_locked() is True
    assert window.locked_difference_hz() == pytest.approx(-10.0)


def test_the_hint_returns_to_its_ordinary_rule_afterwards(make_window):
    window = _locked_window(make_window, left=19_000.0, right=19_010.0)
    window._left.set_value(MAX_FREQ_HZ)
    assert window._beat.is_showing_boundary_note() is True

    window._left.set_value(500.0)
    assert window._beat.is_showing_boundary_note() is False
    assert window._beat.is_hint_visible() is False  # a 10 Hz beat is inside the range


def test_unlocking_clears_the_boundary_note(make_window):
    window = _locked_window(make_window, left=19_000.0, right=19_010.0)
    window._left.set_value(MAX_FREQ_HZ)
    assert window._beat.is_showing_boundary_note() is True

    window._beat.lock_checkbox().setChecked(False)
    assert window._beat.is_showing_boundary_note() is False


def test_the_boundary_note_is_translated(make_window):
    window = _locked_window(make_window, left=19_000.0, right=19_010.0)
    window._left.set_value(MAX_FREQ_HZ)
    i18n.set_language("ru")
    try:
        window.retranslate()
        assert "границе диапазона" in window._beat.hint_text()
    finally:
        i18n.set_language("en")


def test_the_timer_does_not_disturb_the_lock(make_window):
    """The timer never writes a frequency, so it cannot bypass the lock."""
    window = _locked_window(make_window)
    window.select_timer_minutes(5)
    window.arm_timer(now=1_000.0)
    window.tick_timer(now=1_000.0 + 5 * 60 + 2)

    assert window.is_difference_locked() is True
    assert window.locked_difference_hz() == pytest.approx(60.0)
    assert window.left_hz() == pytest.approx(200.0)
    assert window.right_hz() == pytest.approx(260.0)


# ----------------------------------------------------- decision 5: persistence


def test_the_lock_survives_a_relaunch(make_window):
    window = _locked_window(make_window)
    window.save_session()

    reloaded = make_window()  # reads the same settings the first window wrote
    assert reloaded.is_difference_locked() is True
    assert reloaded.locked_difference_hz() == pytest.approx(60.0)
    assert reloaded._beat.lock_checkbox().isChecked() is True

    # And it keeps following after the relaunch.
    reloaded._left.set_value(250.0)
    assert reloaded.right_hz() == pytest.approx(310.0)


def test_only_the_flag_is_written_to_the_session(make_window):
    """A document can never hold a lock contradicting its own pair: there is nowhere to
    put a difference."""
    window = _locked_window(make_window)
    session = window.current_session()
    assert session.difference_locked is True
    stored = {f.name for f in session.__dataclass_fields__.values()}
    assert "difference_locked" in stored
    assert not any("difference" in name and name != "difference_locked" for name in stored)


def test_a_session_written_before_the_lock_existed_still_opens(make_window):
    """A document from before the field existed loads, and the box comes back off."""
    window = make_window(
        Session(
            left_hz=200.0,
            right_hz=260.0,
            volume=0.5,
            channels_swapped=False,
            headphone_check_acknowledged=True,
            timer_minutes=30,
            preset_category="sleep",
        )
    )
    window.save_session()
    settings = QtCore.QSettings("binaural", "binaural")
    settings.remove("session/difference_locked")
    settings.sync()

    reloaded = make_window()
    assert reloaded.left_hz() == pytest.approx(200.0)
    assert reloaded.right_hz() == pytest.approx(260.0)
    assert reloaded.timer_minutes() == 30
    assert reloaded.selected_preset_category() == "sleep"
    assert reloaded.is_difference_locked() is False


def test_an_unlocked_session_saves_it_unlocked(make_window):
    window = make_window()
    window.save_session()
    assert make_window().is_difference_locked() is False


def test_restoring_a_locked_session_does_not_report_an_edit(make_window):
    """Restoring writes both channels silently: the lock must not read it as a user edit
    that moves the other channel."""
    window = _locked_window(make_window)
    window.save_session()

    reloaded = make_window()
    assert reloaded.left_hz() == pytest.approx(200.0)
    assert reloaded.right_hz() == pytest.approx(260.0)
    assert reloaded.locked_difference_hz() == pytest.approx(60.0)


# ------------------------------------------------------------- the widget itself


def test_the_card_reports_the_locked_state(make_window):
    display = BeatDisplay()
    try:
        assert display.is_locked() is False
        seen: list[bool] = []
        display.lockToggled.connect(seen.append)

        display.lock_checkbox().setChecked(True)
        assert seen == [True]
        assert display.is_locked() is True

        # `set_locked` is the restoring path and stays silent.
        display.set_locked(True)
        assert seen == [True]

        display.lock_checkbox().setChecked(False)
        assert seen == [True, False]
    finally:
        display.deleteLater()


def test_a_control_on_its_own_does_not_know_about_the_lock(qapp):
    """``FreqControl`` stays the independent pair of SPEC F1 — the lock is window-level."""
    control = FreqControl("LEFT EAR", "primary")
    try:
        control.set_value(250.0)
        assert control.value() == pytest.approx(250.0)
        assert not hasattr(control, "lockToggled")
    finally:
        control.deleteLater()