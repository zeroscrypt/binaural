"""System tray / menu-bar control (SPEC §7 "Интерфейс", §8 "Архитектура").

The icon next to the clock is the remote control of the app: the window can be
closed while the tone keeps playing, so Play/Stop, the frequency reference and
Quit have to stay reachable. On macOS that is the status item in the top bar, on
Linux the notification area — one ``QSystemTrayIcon`` covers both.

Three rules shape the code:

* **Never fatal.** Headless CI, a Qt build without tray support and a desktop
  session without a notification area all resolve to "no tray". The controller
  then keeps its state and every method stays a safe no-op, because a missing
  tray must not stop the app from starting.
* **No hard dependency on :class:`~binaural.ui.main_window.MainWindow`.** The
  window is probed through ``getattr``/``callable`` helpers, so the controller
  also drives a stub and survives a change of the window API.
* **The window stays the single source of truth.** Frequencies and the play
  state are mirrored from its signals; the tray never talks to the audio
  engine directly.

The icon itself prefers a shipped file (``packaging/linux/binaural.png`` and
friends, or the copy PyInstaller puts next to the bundle) and falls back to a
painted ``primary`` disc with a sine wave across it, so the module works in a
fresh checkout that has no artwork yet.
"""

from __future__ import annotations

import math
import os
import sys
from functools import lru_cache
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QPointF, QRectF, Qt
from PySide6.QtGui import (
    QAction,
    QColor,
    QIcon,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from . import theme

try:  # The i18n layer is written in parallel; the tray must work without it.
    from ..i18n import tr
except Exception:  # pragma: no cover - only hit when binaural.i18n is broken

    def tr(text: str, *args: str, **kw: Any) -> str:  # type: ignore[misc]
        """English fallback that still substitutes ``%1``..``%n``."""
        for index, value in enumerate(args, start=1):
            text = text.replace(f"%{index}", str(value))
        return text


__all__ = [
    "TrayController",
    "SystemTray",
    "app_icon",
    "find_icon_path",
    "tray_available",
]

#: Tooltip templates. Kept as whole sentences so a catalogue can reorder them.
PLAYING_TOOLTIP = "▶ %1 / %2 Hz — beat %3 Hz"
IDLE_TOOLTIP = "⏹ %1 / %2 Hz"

#: Shown until the window reports its own pair (a stub, or a window that is
#: still being built). The values match ``core.session.Session`` defaults.
_FALLBACK_LEFT_HZ = 205.0
_FALLBACK_RIGHT_HZ = 215.0

#: On macOS a left click on the status item already pops the context menu up, so
#: toggling the window there would hide the app right after the user opened the
#: menu. There a click only raises the window; on Windows/Linux the menu lives on
#: the right button and the left click is free to toggle.
_TOGGLE_ON_CLICK = sys.platform != "darwin"

#: Artwork file names, most preferred first. A raster file is what loads on
#: every machine: SVG needs the QtSvg image plugin, which may be absent.
_ICON_NAMES = ("binaural.png", "binaural.svg", "binaural.icns", "icon.png", "icon.icns")

#: Where an icon may sit relative to a search root, see :func:`_search_roots`.
_ICON_SUBDIRS = (
    "",
    "data",
    "packaging/linux",
    "packaging/macos",
    "share/icons/hicolor/256x256/apps",
    "share/icons/hicolor/scalable/apps",
    "share/pixmaps",
    "icons/hicolor/256x256/apps",
    "pixmaps",
)

#: Sizes the icon is pre-rendered at. The platform scales whatever it is given,
#: and a 16px wave blown up on a HiDPI panel turns into mush.
_ICON_SIZES = (16, 22, 32, 44, 64, 128)

#: The artwork is drawn on a fixed grid and scaled, so every size stays identical.
_CANVAS = 64.0


# --------------------------------------------------------------------------- #
# Icon
# --------------------------------------------------------------------------- #


def _wave_path(scale: float) -> QPainterPath:
    """One full sine period, centred, in the 64px design grid."""
    left, right, middle, amplitude = 12.0, 52.0, 32.0, 9.0
    steps = 48
    path = QPainterPath()
    for step in range(steps + 1):
        x = left + (right - left) * step / steps
        y = middle + amplitude * math.sin(2.0 * math.pi * step / steps)
        if step == 0:
            path.moveTo(QPointF(x * scale, y * scale))
        else:
            path.lineTo(QPointF(x * scale, y * scale))
    return path


def _painted_icon() -> QIcon:
    """The app icon, drawn from the theme tokens (SPEC §7.3 — no emoji chrome).

    A ``primary`` disc with one sine crossing it: the two ears, one wave. The
    wave uses ``surface``, which is the colour that keeps its contrast against
    the lavender disc in both colour schemes.
    """
    icon = QIcon()
    for size in _ICON_SIZES:
        scale = size / _CANVAS
        pixmap = QPixmap(size, size)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        try:
            painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
            margin = 2.0 * scale
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor(theme.color("primary")))
            painter.drawEllipse(
                QRectF(margin, margin, size - 2 * margin, size - 2 * margin)
            )
            painter.setBrush(Qt.BrushStyle.NoBrush)
            pen = QPen(QColor(theme.color("surface")), 3.5 * scale)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            painter.setPen(pen)
            painter.drawPath(_wave_path(scale))
        finally:
            painter.end()  # a live painter would leak the pixmap's device
        icon.addPixmap(pixmap)
    return icon


def _search_roots() -> list[Path]:
    """Directories that may hold the icon: source tree, frozen bundle, XDG.

    A PyInstaller bundle unpacks its data files into ``sys._MEIPASS`` on Windows
    and next to the executable on macOS/Linux, so all three layouts are probed
    instead of one hard-coded path.
    """
    package_dir = Path(__file__).resolve().parent.parent
    roots: list[Path] = []

    meipass = getattr(sys, "_MEIPASS", None)
    if isinstance(meipass, str) and meipass:
        roots.append(Path(meipass))
    if getattr(sys, "frozen", False):
        executable = Path(sys.executable).resolve()
        roots.append(executable.parent)  # Contents/MacOS
        roots.append(executable.parent.parent / "Resources")  # Contents/Resources
        roots.append(executable.parent.parent.parent)  # Binaural.app/
    roots.append(package_dir)  # src/binaural
    roots.append(package_dir.parent)  # src/
    roots.append(package_dir.parent.parent)  # repository root

    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    roots.append(Path(data_home) / "icons")
    roots.append(Path("/usr/share/icons"))
    roots.append(Path("/usr/share/pixmaps"))
    return roots


def _icon_from_file(path: Path) -> QIcon:
    """Load one artwork file; an empty icon when Qt cannot read it."""
    try:
        return QIcon(str(path))
    except Exception:
        return QIcon()


@lru_cache(maxsize=1)
def find_icon_path() -> Path | None:
    """The first artwork file that exists **and** loads, else ``None``.

    Existence is not enough: an unreadable or unsupported file yields a null
    ``QIcon``, which would put a blank entry in the panel.
    """
    seen: set[Path] = set()
    for root in _search_roots():
        for subdir in _ICON_SUBDIRS:
            base = root / subdir if subdir else root
            for name in _ICON_NAMES:
                candidate = base / name
                if candidate in seen:
                    continue
                seen.add(candidate)
                try:
                    if not candidate.is_file():
                        continue
                except OSError:  # pragma: no cover - unreadable mount
                    continue
                if not _icon_from_file(candidate).isNull():
                    return candidate
    return None


@lru_cache(maxsize=1)
def app_icon() -> QIcon:
    """The app icon: the shipped artwork when there is one, painted otherwise."""
    path = find_icon_path()
    if path is not None:
        icon = _icon_from_file(path)
        if not icon.isNull():
            return icon
    return _painted_icon()


def tray_available() -> bool:
    """True when the platform has a place for the icon. Never raises.

    The check needs a live ``QApplication``: it talks to the platform plugin,
    which is not there yet while a test is still building its fixtures.
    """
    if QApplication.instance() is None:
        return False
    probe = getattr(QSystemTrayIcon, "isSystemTrayAvailable", None)
    if not callable(probe):
        return False
    try:
        return bool(probe())
    except Exception:  # pragma: no cover - depends on the platform plugin
        return False


# --------------------------------------------------------------------------- #
# Controller
# --------------------------------------------------------------------------- #


class TrayController(QObject):
    """Menu-bar/tray icon wired to the main window.

    Usage from ``app.py`` is one line::

        tray = TrayController(window, parent=app)

    The parent keeps the controller alive for the whole run; without it the
    caller must hold on to the object itself.

    The window is duck-typed: ``is_playing()``, ``left_hz()``, ``right_hz()``,
    ``isVisible()``, ``show()``, ``raise_()``, ``activateWindow()``, ``hide()``,
    ``toggle_playback()``, ``open_reference()``, ``run_headphone_check()`` and
    ``close()`` are used when present, and the ``playback_toggled`` /
    ``frequencies_changed`` signals drive the status. Missing parts disable the
    matching menu entry instead of raising.
    """

    #: English source strings, keyed the way a translation catalogue stores
    #: them. Kept in one place so :meth:`refresh` cannot forget a label.
    SOURCES: dict[str, str] = {
        "show": "Show Binaural",
        "hide": "Hide Binaural",
        "play": "Play",
        "stop": "Stop",
        "reference": "Frequency reference…",
        "headphones": "Check headphones…",
        "quit": "Quit",
    }

    def __init__(self, window: Any, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._window = window
        self._available = tray_available()
        self._disposed = False
        self._connections: list[tuple[Any, Any]] = []
        self._language_changed: Any = None

        self._left_hz, self._right_hz = self._read_frequencies() or (
            _FALLBACK_LEFT_HZ,
            _FALLBACK_RIGHT_HZ,
        )
        self._playing = bool(self._call("is_playing", False))

        # The icon object and the menu are always built: they cost nothing, and
        # keeping them alive means the labels stay inspectable (and testable)
        # even where no tray exists. Only ``show()`` talks to the platform.
        self._icon = QSystemTrayIcon(app_icon(), self)
        self._menu = QMenu()
        self._build_menu()
        self._icon.setContextMenu(self._menu)
        self._icon.activated.connect(self._on_activated)
        self._icon.setToolTip(self.tooltip_text())

        self._connect_window()
        self._connect_language()

        self.refresh()
        self.show()

    # ------------------------------------------------------------------ build

    def _add_action(self, slot: Any) -> QAction:
        """A menu entry; its text is filled in by :meth:`refresh`."""
        action = QAction(self._menu)
        action.triggered.connect(slot)
        self._menu.addAction(action)
        return action

    def _build_menu(self) -> None:
        """Show/Hide, Play/Stop, reference, headphone check, Quit."""
        self.show_action = self._add_action(self.toggle_window)
        self.play_action = self._add_action(self.toggle_playback)
        self._menu.addSeparator()
        self.reference_action = self._add_action(
            lambda: self._call("open_reference")
        )
        self.headphones_action = self._add_action(
            lambda: self._call("run_headphone_check")
        )
        self._menu.addSeparator()
        self.quit_action = self._add_action(self.quit_application)

    def _connect_window(self) -> None:
        """Mirror the window's state signals. A window without them is fine."""
        for name, slot in (
            ("playback_toggled", self._on_playback_toggled),
            ("frequencies_changed", self._on_frequencies_changed),
        ):
            signal = getattr(self._window, name, None)
            if signal is None or not hasattr(signal, "connect"):
                continue
            try:
                signal.connect(slot)
            except Exception:
                continue
            self._connections.append((signal, slot))

    def _connect_language(self) -> None:
        """Re-translate the menu when the UI language changes.

        Imported lazily: the i18n module is owned by another part of the app
        and the tray must keep working if it is missing.
        """
        try:
            from .. import i18n

            signal = getattr(i18n, "language_changed", None)
        except Exception:
            signal = None
        if signal is None or not hasattr(signal, "connect"):
            return
        try:
            signal.connect(self.refresh)
        except Exception:
            return
        self._language_changed = signal

    # ------------------------------------------------------------------ state

    def _call(self, name: str, default: Any = None, *args: Any) -> Any:
        """Call ``window.<name>(*args)`` when it exists, else return ``default``.

        A window slot that raises is treated as a missing slot: a click in the
        tray must never take the app down.
        """
        method = getattr(self._window, name, None)
        if not callable(method):
            return default
        try:
            return method(*args)
        except Exception:
            return default

    def _window_visible(self) -> bool:
        return bool(self._call("isVisible", False))

    def _read_frequencies(self) -> tuple[float, float] | None:
        """The pair the window shows, or ``None`` when it exposes no getter.

        ``None`` keeps whatever ``frequencies_changed`` last delivered instead of
        overwriting it with a fallback pair the window never asked for.
        """
        left = self._call("left_hz")
        right = self._call("right_hz")
        if left is None or right is None:
            return None
        try:
            return float(left), float(right)
        except (TypeError, ValueError):
            return None

    def tooltip_text(self) -> str:
        """Status line for the icon: playing state plus the current pair."""
        left = _format_hz(self._left_hz)
        right = _format_hz(self._right_hz)
        if self._playing:
            beat = _format_hz(abs(self._left_hz - self._right_hz))
            return tr(PLAYING_TOOLTIP, left, right, beat)
        return tr(IDLE_TOOLTIP, left, right)

    @property
    def tooltip(self) -> str:
        """The text currently shown as the icon's tooltip."""
        return self.tooltip_text()

    @property
    def window(self) -> Any:
        """The window this controller drives."""
        return self._window

    def is_available(self) -> bool:
        """True when the platform provides a tray (SPEC §8: no tray, no icon)."""
        return self._available

    def is_visible(self) -> bool:
        """True when the icon really sits in the panel."""
        return bool(self._available and not self._disposed and self._icon.isVisible())

    def icon(self) -> QSystemTrayIcon:
        """The underlying ``QSystemTrayIcon`` (shown only when available)."""
        return self._icon

    def menu(self) -> QMenu:
        """The context menu, e.g. for a test or for embedding elsewhere."""
        return self._menu

    # ---------------------------------------------------------------- actions

    def show_window(self) -> None:
        """Bring the main window to the front."""
        self._call("show")
        self._call("raise_")
        self._call("activateWindow")
        self.refresh()

    def hide_window(self) -> None:
        """Hide the main window; the tray keeps the app running."""
        self._call("hide")
        self.refresh()

    def toggle_window(self) -> None:
        """Show the window when it is hidden, hide it when it is on screen."""
        if self._window_visible():
            self.hide_window()
        else:
            self.show_window()

    def toggle_playback(self) -> None:
        """Mirror the window transport.

        The window emits ``playback_toggled``, which refreshes the labels; a
        window that stays silent is refreshed right here instead, so the tray
        never shows a stale state.
        """
        self._call("toggle_playback")
        self.refresh()

    def quit_application(self) -> None:
        """Close the window cleanly, then quit.

        ``MainWindow.closeEvent`` saves the session and releases the audio
        device, which a bare ``QApplication.quit()`` would skip.
        """
        self._call("close")
        self.refresh()
        try:
            QApplication.quit()
        except Exception:  # pragma: no cover - Qt never fails to quit
            pass

    # --------------------------------------------------------------- signals

    def _on_playback_toggled(self, playing: bool) -> None:
        self._playing = bool(playing)
        self.refresh()

    def _on_frequencies_changed(self, left_hz: float, right_hz: float) -> None:
        try:
            self._left_hz = float(left_hz)
            self._right_hz = float(right_hz)
        except (TypeError, ValueError):
            return  # a malformed emission must not break the signal chain
        self.refresh()

    def _on_activated(self, reason: Any) -> None:
        """Mouse on the icon.

        ``Context`` is ignored: Qt opens the menu itself on that one.
        """
        try:
            reason = QSystemTrayIcon.ActivationReason(reason)
        except ValueError:  # pragma: no cover - a future Qt adds a reason
            return
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            self.show_window()
        elif reason == QSystemTrayIcon.ActivationReason.MiddleClick:
            self.toggle_playback()
        elif reason == QSystemTrayIcon.ActivationReason.Trigger:
            # See _TOGGLE_ON_CLICK: on macOS the click already opened the menu.
            self.toggle_window() if _TOGGLE_ON_CLICK else self.show_window()

    # ---------------------------------------------------------------- labels

    def refresh(self) -> None:
        """Re-read the window and update every label, tooltip and enabled flag.

        Also the ``i18n.language_changed`` slot: it recomputes the labels from
        the catalogue, so a language switch reaches the tray like it reaches
        the window.
        """
        if self._disposed:
            return
        self._playing = bool(self._call("is_playing", self._playing))
        pair = self._read_frequencies()
        if pair is not None:
            self._left_hz, self._right_hz = pair

        sources = self.SOURCES
        on_screen = self._window_visible()
        self.show_action.setText(tr(sources["hide"] if on_screen else sources["show"]))
        self.show_action.setEnabled(True)
        self.play_action.setText(
            tr(sources["stop"] if self._playing else sources["play"])
        )
        # Never disabled while playing: the same entry stops the tone.
        self.play_action.setEnabled(
            callable(getattr(self._window, "toggle_playback", None))
        )
        self.reference_action.setText(tr(sources["reference"]))
        self.reference_action.setEnabled(
            callable(getattr(self._window, "open_reference", None))
        )
        self.headphones_action.setText(tr(sources["headphones"]))
        self.headphones_action.setEnabled(
            callable(getattr(self._window, "run_headphone_check", None))
        )
        self.quit_action.setText(tr(sources["quit"]))
        self.quit_action.setEnabled(True)
        self._icon.setToolTip(self.tooltip_text())

    # ---------------------------------------------------------------- visibility

    def set_visible(self, visible: bool) -> None:
        """Show or hide the icon itself. A no-op where there is no tray."""
        if self._disposed or not self._available:
            return
        self._icon.setVisible(bool(visible))

    def show(self) -> None:
        """Put the icon into the panel (the default state)."""
        self.set_visible(True)

    def hide(self) -> None:
        """Take the icon out of the panel without destroying the controller."""
        self.set_visible(False)

    def dispose(self) -> None:
        """Remove the icon and drop every connection. Idempotent.

        Called on shutdown so the icon does not linger in the panel after the
        engine has already been released.
        """
        if self._disposed:
            return
        self.set_visible(False)
        self._disposed = True
        try:
            self._icon.setContextMenu(None)
        except Exception:  # pragma: no cover - defensive
            pass
        for signal, slot in self._connections:
            try:
                signal.disconnect(slot)
            except Exception:  # pragma: no cover - already gone
                pass
        self._connections.clear()
        if self._language_changed is not None:
            try:
                self._language_changed.disconnect(self.refresh)
            except Exception:  # pragma: no cover - already gone
                pass
            self._language_changed = None


#: Alias for callers that prefer the platform name.
SystemTray = TrayController


def _format_hz(value: float) -> str:
    """``205`` instead of ``205.0``; the tray has room for one decimal at most.

    Deliberately a copy of the window's own formatter: importing a private
    helper from another module would couple the tray to the window's internals.
    """
    value = float(value)
    if abs(value - round(value)) < 0.05:
        return f"{int(round(value))}"
    return f"{value:.1f}"