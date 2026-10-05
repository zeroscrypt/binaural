"""System tray tests (SPEC §7, §8).

The suite runs on the offscreen platform plugin, where the platform reports no
tray at all. That is the interesting case: the controller has to build itself,
keep its labels and survive every call without a tray. The tests therefore never
require ``QSystemTrayIcon.isSystemTrayAvailable()`` to be true.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QObject, Signal  # noqa: E402
from PySide6.QtGui import QIcon  # noqa: E402
from PySide6.QtWidgets import QApplication, QSystemTrayIcon  # noqa: E402

from binaural.ui import tray as tray_module  # noqa: E402
from binaural.ui.tray import TrayController  # noqa: E402

try:  # The i18n layer is owned by another part of the app.
    from binaural import i18n
except Exception:  # pragma: no cover - only when binaural.i18n is broken
    i18n = None

try:
    from binaural import locales
except Exception:  # pragma: no cover
    locales = None


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        try:
            app = QApplication(["binaural-tray-tests"])
        except Exception as exc:  # pragma: no cover - depends on the machine
            pytest.skip(f"No usable Qt display: {exc}")
    yield app


def _pin_language(monkeypatch, code: str) -> bool:
    """Force the UI language without persisting anything.

    False when the i18n layer no longer keeps a module-level flag, so a caller
    can fall back to its public setter instead of silently testing nothing.
    """
    if i18n is None or not hasattr(i18n, "_current"):
        return False
    monkeypatch.setattr(i18n, "_current", code)
    return True


@pytest.fixture(autouse=True)
def english_ui(monkeypatch, qapp):
    """Pin the UI language to English.

    The labels are compared against the English source strings, so the tests
    must not depend on which language happens to be active. The private flag is
    patched instead of ``set_language()`` so a test run never writes a language
    preference into the user's real settings.
    """
    if i18n is None or _pin_language(monkeypatch, "en"):
        return
    try:  # pragma: no cover - only if binaural.i18n changes shape
        i18n.set_language("en")
    except Exception:
        pass


@pytest.fixture(autouse=True)
def fresh_icon_cache():
    """The icon builders are memoised; keep one test from feeding the next."""
    # Captured now: a test that patches a builder replaces the module attribute,
    # and the undo may happen after this fixture is finalised.
    builders = (tray_module.app_icon, tray_module.find_icon_path)

    def clear() -> None:
        for builder in builders:
            drop = getattr(builder, "cache_clear", None)
            if callable(drop):
                drop()

    clear()
    yield
    clear()


class SpyWindow(QObject):
    """Duck-typed MainWindow stand-in: records every call the tray makes.

    Not a QWidget on purpose — the controller has to work through the small
    ``getattr``/``callable`` probes, and a plain object makes the recorded calls
    easy to assert on.
    """

    playback_toggled = Signal(bool)
    frequencies_changed = Signal(float, float)

    def __init__(
        self,
        left_hz: float = 205.0,
        right_hz: float = 215.0,
        playing: bool = False,
    ) -> None:
        super().__init__()
        self.calls: list[str] = []
        self.left = float(left_hz)
        self.right = float(right_hz)
        self.playing = bool(playing)
        self.visible = False

    # --- state the tray reads ------------------------------------------
    def is_playing(self) -> bool:
        return self.playing

    def left_hz(self) -> float:
        return self.left

    def right_hz(self) -> float:
        return self.right

    def isVisible(self) -> bool:  # noqa: N802 - mirrors the Qt API
        return self.visible

    # --- actions the tray triggers --------------------------------------
    def show(self) -> None:
        self.calls.append("show")
        self.visible = True

    def hide(self) -> None:
        self.calls.append("hide")
        self.visible = False

    def raise_(self) -> None:
        self.calls.append("raise_")

    def activateWindow(self) -> None:  # noqa: N802 - mirrors the Qt API
        self.calls.append("activate_window")

    def close(self) -> None:
        self.calls.append("close")
        self.visible = False

    def toggle_playback(self) -> None:
        self.calls.append("toggle_playback")
        self.playing = not self.playing
        self.playback_toggled.emit(self.playing)

    def open_reference(self) -> None:
        self.calls.append("open_reference")

    def run_headphone_check(self) -> None:
        self.calls.append("run_headphone_check")

    # --- helpers for the tests ------------------------------------------
    def emit_frequencies(self, left_hz: float, right_hz: float) -> None:
        self.left, self.right = float(left_hz), float(right_hz)
        self.frequencies_changed.emit(float(left_hz), float(right_hz))

    def emit_playback(self, playing: bool) -> None:
        self.playing = bool(playing)
        self.playback_toggled.emit(bool(playing))


class BareWindow(QObject):
    """A window with nothing but the two state signals."""

    playback_toggled = Signal(bool)
    frequencies_changed = Signal(float, float)


@pytest.fixture
def window():
    return SpyWindow()


@pytest.fixture
def tray(qapp, window):
    controller = TrayController(window, parent=qapp)
    yield controller
    controller.dispose()
    window.deleteLater()
    qapp.processEvents()


# --------------------------------------------------------------------------
# Construction
# --------------------------------------------------------------------------


def test_controller_builds_without_a_system_tray(qapp, monkeypatch):
    """No tray must not raise: the whole method surface stays callable."""
    monkeypatch.setattr(tray_module, "tray_available", lambda: False)
    win = SpyWindow()
    controller = TrayController(win, parent=qapp)

    assert controller.is_available() is False
    assert controller.is_visible() is False
    # Every one of these is a no-op without a tray, none of them raises.
    controller.show()
    controller.hide()
    controller.set_visible(True)
    controller.refresh()
    assert controller.show_action.text() == "Show Binaural"
    controller.dispose()
    win.deleteLater()


def test_availability_matches_the_platform(qapp, window):
    controller = TrayController(window, parent=qapp)
    try:
        assert controller.is_available() == bool(
            QSystemTrayIcon.isSystemTrayAvailable()
        )
    finally:
        controller.dispose()


def test_menu_lists_every_entry(window, tray):
    """Show/Hide, Play/Stop, reference, headphones, Quit — in that order."""
    labels = [
        action.text() for action in tray.menu().actions() if not action.isSeparator()
    ]
    assert labels == [
        "Show Binaural",
        "Play",
        "Frequency reference…",
        "Check headphones…",
        "Quit",
    ]
    separators = [a for a in tray.menu().actions() if a.isSeparator()]
    assert len(separators) == 2
    # Source strings, not translated look-alikes: the catalogue keys on them.
    assert set(labels) <= set(TrayController.SOURCES.values())


def test_entries_the_window_cannot_serve_are_disabled(qapp):
    """A window without a transport or dialogs still gets a working tray."""
    bare = BareWindow()
    controller = TrayController(bare, parent=qapp)
    try:
        assert controller.play_action.isEnabled() is False
        assert controller.reference_action.isEnabled() is False
        assert controller.headphones_action.isEnabled() is False
        assert controller.show_action.isEnabled() is True
        assert controller.quit_action.isEnabled() is True
    finally:
        controller.dispose()
        bare.deleteLater()


def test_signal_frequencies_survive_a_window_without_getters(qapp):
    """A window with no ``left_hz()`` must not drag the status back to defaults."""
    bare = BareWindow()
    controller = TrayController(bare, parent=qapp)
    try:
        bare.frequencies_changed.emit(180.0, 186.0)
        controller.refresh()
        assert controller.tooltip_text() == "⏹ 180 / 186 Hz"
    finally:
        controller.dispose()
        bare.deleteLater()


# --------------------------------------------------------------------------
# Status
# --------------------------------------------------------------------------


def test_tooltip_starts_with_the_stopped_pair(window, tray):
    assert tray.tooltip_text() == "⏹ 205 / 215 Hz"
    assert tray.tooltip == "⏹ 205 / 215 Hz"
    assert tray.icon().toolTip() == "⏹ 205 / 215 Hz"


def test_tooltip_follows_playback_and_frequencies(window, tray):
    window.emit_frequencies(210.0, 230.5)
    assert tray.tooltip_text() == "⏹ 210 / 230.5 Hz"

    window.emit_playback(True)
    assert tray.tooltip_text() == "▶ 210 / 230.5 Hz — beat 20.5 Hz"
    assert tray.icon().toolTip() == "▶ 210 / 230.5 Hz — beat 20.5 Hz"

    window.emit_playback(False)
    assert tray.tooltip_text() == "⏹ 210 / 230.5 Hz"


def test_whole_beat_keeps_the_integer_form(window, tray):
    window.emit_frequencies(200.0, 210.0)
    window.emit_playback(True)
    assert tray.tooltip_text() == "▶ 200 / 210 Hz — beat 10 Hz"


def test_a_malformed_frequency_emission_is_ignored(window, tray):
    window.emit_frequencies(180.0, 190.0)
    window.frequencies_changed.emit("not a number", None)  # type: ignore[arg-type]
    assert tray.tooltip_text() == "⏹ 180 / 190 Hz"


# --------------------------------------------------------------------------
# Menu actions
# --------------------------------------------------------------------------


def test_play_action_mirrors_the_window(window, tray):
    assert tray.play_action.text() == "Play"

    tray.play_action.trigger()
    assert "toggle_playback" in window.calls
    assert window.playing is True
    assert tray.play_action.text() == "Stop"

    tray.play_action.trigger()
    assert window.playing is False
    assert tray.play_action.text() == "Play"


def test_play_action_stays_enabled_while_playing(window, tray):
    """One entry both starts and stops the tone, so it can never be disabled."""
    window.emit_playback(True)
    assert tray.play_action.text() == "Stop"
    assert tray.play_action.isEnabled() is True


def test_show_action_toggles_the_window(window, tray):
    assert tray.show_action.text() == "Show Binaural"

    tray.show_action.trigger()
    assert window.calls == ["show", "raise_", "activate_window"]
    assert window.visible is True
    assert tray.show_action.text() == "Hide Binaural"

    window.calls.clear()
    tray.show_action.trigger()
    assert window.calls == ["hide"]
    assert window.visible is False
    assert tray.show_action.text() == "Show Binaural"


def test_reference_action_is_forwarded(window, tray):
    tray.reference_action.trigger()
    assert window.calls == ["open_reference"]


def test_headphone_action_is_forwarded(window, tray):
    tray.headphones_action.trigger()
    assert window.calls == ["run_headphone_check"]


def test_quit_action_closes_the_window_and_quits(window, tray, monkeypatch):
    calls: list[int] = []
    monkeypatch.setattr(
        QApplication, "quit", staticmethod(lambda: calls.append(1))
    )

    tray.quit_action.trigger()
    # MainWindow.closeEvent saves the session and releases the audio device, so
    # Quit goes through close() instead of pulling the rug from under it.
    assert "close" in window.calls
    assert calls == [1]


# --------------------------------------------------------------------------
# Mouse on the icon
# --------------------------------------------------------------------------


def test_double_click_raises_the_window(window, tray):
    tray.icon().activated.emit(QSystemTrayIcon.ActivationReason.DoubleClick)
    assert window.visible is True
    assert window.calls == ["show", "raise_", "activate_window"]


def test_middle_click_toggles_playback(window, tray):
    tray.icon().activated.emit(QSystemTrayIcon.ActivationReason.MiddleClick)
    assert window.playing is True
    assert "toggle_playback" in window.calls


def test_single_click_follows_the_platform_convention(window, tray):
    """macOS opens the menu on a left click, so there it may not hide the app."""
    trigger = QSystemTrayIcon.ActivationReason.Trigger
    tray.icon().activated.emit(trigger)
    assert window.visible is True

    window.calls.clear()
    tray.icon().activated.emit(trigger)
    if sys.platform == "darwin":
        assert window.visible is True
        assert window.calls[:1] == ["show"]
    else:
        assert window.visible is False
        assert window.calls == ["hide"]


def test_context_activation_only_opens_the_menu(window, tray):
    tray.icon().activated.emit(QSystemTrayIcon.ActivationReason.Context)
    assert window.calls == []


# --------------------------------------------------------------------------
# Language
# --------------------------------------------------------------------------


def test_language_change_retranslates_the_menu(window, tray, monkeypatch):
    window.emit_playback(True)
    assert tray.play_action.text() == "Stop"
    assert tray.tooltip_text() == "▶ 205 / 215 Hz — beat 10 Hz"

    if locales is None:  # pragma: no cover
        pytest.skip("the translation catalogues are not available")
    # A tiny fake catalogue, so the assertion does not depend on how complete
    # the shipped Russian catalogue happens to be.
    if not _pin_language(monkeypatch, "ru"):  # pragma: no cover
        pytest.skip("the i18n layer does not expose the active language")
    monkeypatch.setattr(
        locales,
        "catalog",
        lambda: {
            "ru": {
                "Play": "Пуск",
                "Stop": "Стоп",
                "Quit": "Выход",
                "Show Binaural": "Показать Binaural",
                tray_module.PLAYING_TOOLTIP: "▶ %1 / %2 Гц — бит %3 Гц",
            }
        },
    )

    i18n.language_changed.emit("ru")

    assert tray.play_action.text() == "Стоп"  # still playing
    assert tray.quit_action.text() == "Выход"
    assert tray.show_action.text() == "Показать Binaural"
    assert tray.tooltip_text() == "▶ 205 / 215 Гц — бит 10 Гц"
    assert tray.icon().toolTip() == tray.tooltip_text()

    window.emit_playback(False)
    assert tray.play_action.text() == "Пуск"


def test_a_language_change_after_dispose_does_not_raise(window, tray):
    if i18n is None:  # pragma: no cover
        pytest.skip("the i18n layer is not available")
    tray.dispose()
    i18n.language_changed.emit("ru")  # must be a silent no-op


# --------------------------------------------------------------------------
# Visibility and disposal
# --------------------------------------------------------------------------


def test_hide_and_show_toggle_the_icon(window, tray):
    tray.hide()
    assert tray.is_visible() is False
    tray.show()
    assert tray.is_visible() == tray.is_available()


def test_dispose_hides_the_icon_and_stops_listening(window, tray):
    tray.dispose()
    assert tray.is_visible() is False

    # The window no longer drives the tray.
    window.emit_frequencies(100.0, 120.0)
    window.emit_playback(True)
    assert tray.tooltip_text() == "⏹ 205 / 215 Hz"

    tray.refresh()  # ignored after disposal
    assert tray.play_action.text() == "Play"


def test_dispose_is_idempotent(window, tray):
    tray.dispose()
    tray.dispose()
    assert tray.is_visible() is False


# --------------------------------------------------------------------------
# Icon
# --------------------------------------------------------------------------


def test_find_icon_path_returns_a_loadable_file_or_nothing(qapp):
    path = tray_module.find_icon_path()
    if path is None:
        pytest.skip("the repository ships no artwork yet")
    assert isinstance(path, Path)
    assert path.is_file()
    assert not QIcon(str(path)).isNull()


def test_app_icon_is_painted_when_there_is_no_artwork(qapp, monkeypatch):
    monkeypatch.setattr(tray_module, "find_icon_path", lambda: None)
    tray_module.app_icon.cache_clear()

    icon = tray_module.app_icon()
    assert not icon.isNull()
    # Not just a null icon: several pixmaps for the sizes the panel asks for.
    assert len(icon.availableSizes()) >= 3


def test_app_icon_prefers_a_shipped_file(qapp, monkeypatch, tmp_path):
    artwork = tmp_path / "binaural.png"
    # Any valid PNG will do: the point is that the file wins over the painting.
    tray_module._painted_icon().pixmap(64, 64).save(str(artwork), "PNG")
    assert artwork.is_file()

    monkeypatch.setattr(tray_module, "_search_roots", lambda: [tmp_path])
    tray_module.find_icon_path.cache_clear()
    tray_module.app_icon.cache_clear()

    assert tray_module.find_icon_path() == artwork
    assert not tray_module.app_icon().isNull()


# --------------------------------------------------------------------------
# Integration with the real MainWindow
# --------------------------------------------------------------------------


def test_works_with_the_real_main_window(qapp):
    """The wiring app.py uses: the window drives the labels, the tray the transport."""
    from binaural.core.oscillator import StereoOscillator
    from binaural.core.session import Session
    from binaural.ui.main_window import MainWindow

    class Engine(QObject):
        """Audio engine stand-in: no device, only the calls the window makes."""

        started = Signal()
        stopped = Signal()
        error = Signal(str)

        def __init__(self, oscillator=None) -> None:
            super().__init__()
            self.oscillator = oscillator
            self.running = False

        @property
        def is_running(self) -> bool:
            return self.running

        @property
        def volume(self) -> float:
            return 0.7

        @volume.setter
        def volume(self, value: float) -> None:
            pass

        def start(self) -> bool:
            self.running = True
            self.started.emit()
            return True

        def stop(self) -> None:
            self.running = False
            self.stopped.emit()

        def shutdown(self) -> None:
            self.running = False

    oscillator = StereoOscillator()
    win = MainWindow(
        Engine(oscillator),
        oscillator=oscillator,
        session=Session(left_hz=205.0, right_hz=215.0, volume=0.7),
    )
    controller = TrayController(win, parent=qapp)
    try:
        assert controller.tooltip_text() == "⏹ 205 / 215 Hz"

        # The window's own transport reaches the tray through the signal.
        win.toggle_playback()
        assert controller.play_action.text() == "Stop"
        assert controller.tooltip_text() == "▶ 205 / 215 Hz — beat 10 Hz"

        # ...and the tray drives the window's transport.
        controller.toggle_playback()
        assert win.is_playing() is False
        assert controller.play_action.text() == "Play"

        # A frequency change from the window re-renders the status.
        win.set_frequencies(200.0, 220.0)
        assert controller.tooltip_text() == "⏹ 200 / 220 Hz"
    finally:
        controller.dispose()
        win.close()
        win.deleteLater()
        qapp.processEvents()