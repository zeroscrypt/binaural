"""Main window (CONTRACT §6, SPEC §7 "Главное окно").

Layout: status bar with the headphone indicator, two independent ear panels,
the BEAT/CARRIER card in the middle, the transport row, and the preset chips.

The window owns no audio logic: it pushes frequencies and the play state into
the engine and reacts to the engine's signals.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QAction, QActionGroup, QCloseEvent, QKeyEvent
from PySide6.QtWidgets import (
    QAbstractSpinBox,
    QApplication,
    QButtonGroup,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QSlider,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .. import i18n
from ..audio.headphones import HeadphoneReport, detect, swap_channels
from ..core.oscillator import DEFAULT_CARRIER_HZ, pair_from_beat
from ..core.session import Session, load as load_session, save as save_session
from . import theme
from .widgets.beat_display import BeatDisplay
from .widgets.freq_control import FreqControl
from .widgets.status_indicator import StatusIndicator

__all__ = ["MainWindow", "PRESETS"]

_CONTEXT = "MainWindow"

#: (label, beat Hz, short description key) — the built-in band chips.
PRESETS: tuple[tuple[str, float], ...] = (
    ("Delta 2", 2.0),
    ("Theta 6", 6.0),
    ("Alpha 10", 10.0),
    ("Beta 20", 20.0),
    ("Gamma 40", 40.0),
)

NUDGE_HZ = 0.1
SLIDER_STEPS = 100
VOLUME_STEPS = 100

#: Ear captions as catalogue keys — the strings live in one place so
#: ``retranslate()`` can put them back after a language switch.
LEFT_EAR = "LEFT EAR"
RIGHT_EAR = "RIGHT EAR"

#: Free-text fields own the arrow keys; the window must not steal them.
_FREE_TEXT_INPUTS = (QLineEdit, QTextEdit, QPlainTextEdit)
#: Numeric fields: Space/arrows are only intercepted when the user is not typing.
_TEXT_INPUTS = _FREE_TEXT_INPUTS + (QAbstractSpinBox,)


def tr(text: str, *args: str) -> str:
    from ..i18n import tr as _tr

    return _tr(text, *args, context=_CONTEXT)


class MainWindow(QMainWindow):
    """The single window of the app."""

    frequencies_changed = Signal(float, float)  # left Hz, right Hz
    playback_toggled = Signal(bool)

    def __init__(
        self,
        engine,
        oscillator=None,
        parent: QWidget | None = None,
        session: Session | None = None,
    ) -> None:
        super().__init__(parent)
        self._engine = engine
        self._oscillator = oscillator if oscillator is not None else getattr(engine, "oscillator", None)
        self._session = session or load_session()
        self._channels_swapped = bool(self._session.channels_swapped)
        self._playing = False
        self._suppress = False
        self._active = 0  # 0 = left, 1 = right

        self.setWindowTitle(tr("Binaural"))
        self.setMinimumSize(720, 620)

        central = QWidget(self)
        central_layout = QVBoxLayout(central)
        central_layout.setContentsMargins(
            theme.SPACE_XL, theme.SPACE_XL, theme.SPACE_XL, theme.SPACE_LG
        )
        central_layout.setSpacing(theme.SPACE_LG)
        self.setCentralWidget(central)

        # --- ear panels ---------------------------------------------------
        ears = QHBoxLayout()
        ears.setSpacing(theme.SPACE_LG)
        self._left = FreqControl(tr(LEFT_EAR), "primary")
        self._right = FreqControl(tr(RIGHT_EAR), "secondary")
        ears.addWidget(self._left, 1)
        ears.addWidget(self._right, 1)
        central_layout.addLayout(ears)

        self._left.valueChanged.connect(self._on_left_changed)
        self._right.valueChanged.connect(self._on_right_changed)

        # --- beat card ----------------------------------------------------
        self._beat = BeatDisplay(self)
        central_layout.addWidget(self._beat)

        # --- transport ----------------------------------------------------
        central_layout.addLayout(self._build_transport())

        # --- presets ------------------------------------------------------
        central_layout.addStretch(1)
        central_layout.addLayout(self._build_presets())

        self._build_status_bar()
        self._build_menu()
        self._connect_engine()

        self._restore_session()
        self._apply_channels()
        self._beat.set_reduced_motion(theme.reduced_motion())

        # The window outlives every language change, so it re-reads its own
        # captions whenever i18n reports a new one. Qt drops the connection
        # when this window is destroyed, so no explicit cleanup is needed.
        i18n.language_changed.connect(self._on_language_changed)

    # ------------------------------------------------------------------ build

    def _build_transport(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(theme.SPACE_MD)

        self._play_button = QPushButton(tr("Play"), self)
        self._play_button.setObjectName("primary")
        self._play_button.setMinimumHeight(48)
        self._play_button.setMinimumWidth(140)
        self._play_button.setAccessibleName(tr("Play or stop the binaural tone"))
        self._play_button.setAccessibleDescription(
            tr("Starts or stops playback. The keyboard shortcut is Space.")
        )
        self._play_button.setShortcut("Space")
        self._play_button.clicked.connect(self.toggle_playback)
        row.addWidget(self._play_button)

        row.addSpacing(theme.SPACE_LG)

        self._volume_caption = QLabel(tr("Volume"), self)
        self._volume_caption.setFont(theme.font("body"))
        row.addWidget(self._volume_caption)

        self._volume = QSlider(Qt.Orientation.Horizontal, self)
        self._volume.setRange(0, VOLUME_STEPS)
        self._volume.setMinimumWidth(160)
        self._volume.setMinimumHeight(44)
        self._volume.setAccessibleName(tr("Volume"))
        self._volume.setAccessibleDescription(
            tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )
        self._volume.valueChanged.connect(self._on_volume_changed)
        row.addWidget(self._volume)

        self._volume_value = QLabel("70%", self)
        self._volume_value.setFont(theme.font("body"))
        self._volume_value.setMinimumWidth(44)
        self._volume_value.setStyleSheet(f"color: {theme.color('muted-fg')};")
        row.addWidget(self._volume_value)

        row.addStretch(1)

        self._save_preset_button = QPushButton(tr("Save preset"), self)
        self._save_preset_button.setMinimumHeight(48)
        self._save_preset_button.setAccessibleName(tr("Save preset"))
        self._save_preset_button.setAccessibleDescription(
            tr("Saves the current pair of frequencies for the next run.")
        )
        self._save_preset_button.clicked.connect(self.save_preset)
        row.addWidget(self._save_preset_button)

        return row

    def _build_presets(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(theme.SPACE_SM)

        self._presets_caption = QLabel(tr("Presets"), self)
        self._presets_caption.setFont(theme.font("body"))
        self._presets_caption.setStyleSheet(f"color: {theme.color('muted-fg')};")
        row.addWidget(self._presets_caption)
        row.addSpacing(theme.SPACE_SM)

        self._preset_group = QButtonGroup(self)
        self._preset_group.setExclusive(True)
        self._preset_buttons: list[QPushButton] = []

        for index, (label, beat_hz) in enumerate(PRESETS):
            button = QPushButton(label, self)
            button.setObjectName("chip")
            button.setCheckable(True)
            button.setMinimumHeight(44)
            button.setAccessibleName(label)
            button.setAccessibleDescription(self._preset_description(beat_hz))
            button.clicked.connect(lambda _c, b=beat_hz, i=index: self.apply_preset(b, i))
            self._preset_group.addButton(button, index)
            row.addWidget(button)
            self._preset_buttons.append(button)

        row.addStretch(1)
        return row

    @staticmethod
    def _preset_description(beat_hz: float) -> str:
        """Accessible description of one band chip, in the current language."""
        return tr(
            "Sets both channels around a %1 Hz carrier so the difference is %2 Hz.",
            _format_hz(DEFAULT_CARRIER_HZ),
            _format_hz(beat_hz),
        )

    def _build_status_bar(self) -> None:
        bar = self.statusBar()
        self.status_indicator = StatusIndicator(bar)
        bar.addPermanentWidget(self.status_indicator, 1)

        self._error_label = QLabel(self)
        self._error_label.setFont(theme.font("caption"))
        self._error_label.setStyleSheet(f"color: {theme.color('destructive')};")
        self._error_label.setVisible(False)
        self._error_label.setAccessibleName(tr("Error"))
        bar.addWidget(self._error_label, 1)

    def _build_menu(self) -> None:
        menu_bar = self.menuBar()

        self._view_menu = menu_bar.addMenu(tr("&View"))
        self._language_menu = self._view_menu.addMenu(tr("Language"))
        self._language_group = QActionGroup(self)
        self._language_group.setExclusive(True)
        self._language_actions: dict[str, QAction] = {}
        # Language names stay native ("English", "Русский") in both languages —
        # a user must be able to find their own language in the list.
        for code, name in i18n.languages().items():
            action = QAction(name, self)
            action.setCheckable(True)
            action.setData(code)
            action.setChecked(code == i18n.language())
            action.triggered.connect(lambda _checked=False, c=code: self.set_language(c))
            self._language_group.addAction(action)
            self._language_menu.addAction(action)
            self._language_actions[code] = action

        self._help_menu = menu_bar.addMenu(tr("&Help"))

        self._reference_action = QAction(tr("Frequency &reference…"), self)
        self._reference_action.setShortcut("Ctrl+O")
        self._reference_action.setShortcutContext(
            Qt.ShortcutContext.ApplicationShortcut
        )
        self._reference_action.triggered.connect(self.open_reference)
        self._help_menu.addAction(self._reference_action)

        self._check_action = QAction(tr("&Check headphones…"), self)
        self._check_action.setShortcut("Ctrl+Shift+H")
        self._check_action.triggered.connect(self.run_headphone_check)
        self._help_menu.addAction(self._check_action)

        self._about_action = QAction(tr("&About"), self)
        self._about_action.setShortcut("Ctrl+Shift+I")
        self._about_action.triggered.connect(self.show_about)
        self._help_menu.addAction(self._about_action)

    def set_language(self, code: str) -> str:
        """Switch the UI language from the View menu. Returns the active code."""
        return i18n.set_language(code)

    def _on_language_changed(self, code: str) -> None:
        """Language changed: mark the new item and re-read every caption."""
        action = self._language_actions.get(code)
        if action is not None:
            action.setChecked(True)
        self.retranslate()

    # ----------------------------------------------------------- retranslate

    def retranslate(self) -> None:
        """Re-read every visible string in the current language (SPEC §7).

        The window is built once and lives for the whole session, so widget
        captions cannot simply be re-created: every label, accessible name,
        tooltip and menu title is stored as a reference and overwritten here.
        Dialogs are the opposite case — they are rebuilt on each open and read
        the language themselves.
        """
        self.setWindowTitle(tr("Binaural"))

        self._left.retranslate(tr(LEFT_EAR))
        self._right.retranslate(tr(RIGHT_EAR))
        self._beat.retranslate()
        self.status_indicator.retranslate()

        playing = self._playing
        self._play_button.setText(tr("Stop") if playing else tr("Play"))
        self._play_button.setAccessibleName(
            tr("Stop the binaural tone") if playing else tr("Play the binaural tone")
        )
        self._play_button.setAccessibleDescription(
            tr("Starts or stops playback. The keyboard shortcut is Space.")
        )

        self._volume_caption.setText(tr("Volume"))
        self._volume.setAccessibleName(tr("Volume"))
        self._volume.setAccessibleDescription(
            tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )

        self._save_preset_button.setText(tr("Save preset"))
        self._save_preset_button.setAccessibleName(tr("Save preset"))
        self._save_preset_button.setAccessibleDescription(
            tr("Saves the current pair of frequencies for the next run.")
        )

        self._presets_caption.setText(tr("Presets"))
        for button, (_label, beat_hz) in zip(self._preset_buttons, PRESETS):
            button.setAccessibleDescription(self._preset_description(beat_hz))

        self._error_label.setAccessibleName(tr("Error"))
        # The message arrived from the engine as a plain string. Re-running it
        # through tr() translates the texts that are still catalogue keys and
        # leaves the rest (an interpolated "…: {}" message) untouched rather
        # than dropping the error the user needs to see.
        message = tr(self._error_label.text())
        self._error_label.setText(message)
        self._error_label.setToolTip(message)

        self._view_menu.setTitle(tr("&View"))
        self._language_menu.setTitle(tr("Language"))
        self._help_menu.setTitle(tr("&Help"))
        self._reference_action.setText(tr("Frequency &reference…"))
        self._check_action.setText(tr("&Check headphones…"))
        self._about_action.setText(tr("&About"))

    def _connect_engine(self) -> None:
        for signal, slot in (
            ("started", self._on_engine_started),
            ("stopped", self._on_engine_stopped),
            ("error", self._on_engine_error),
        ):
            emitter = getattr(self._engine, signal, None)
            if emitter is not None and hasattr(emitter, "connect"):
                emitter.connect(slot)

    # ---------------------------------------------------------------- session

    def headphone_check_acknowledged(self) -> bool:
        """True when the user already confirmed the startup check."""
        return bool(self._session.headphone_check_acknowledged)

    def _restore_session(self) -> None:
        """Show the stored frequencies, volume and swap flag (SPEC F5)."""
        self._suppress = True
        try:
            self._left.set_value(self._session.left_hz, emit=False)
            self._right.set_value(self._session.right_hz, emit=False)
            self._volume.setValue(int(round(self._session.volume * VOLUME_STEPS)))
        finally:
            self._suppress = False
        self._on_channels_changed()

    def current_session(self) -> Session:
        """A :class:`Session` snapshot of the current UI state."""
        return Session(
            left_hz=self._left.value(),
            right_hz=self._right.value(),
            volume=self._volume.value() / VOLUME_STEPS,
            channels_swapped=self._channels_swapped,
            headphone_check_acknowledged=self._session.headphone_check_acknowledged,
            last_preset=self._session.last_preset,
        )

    def save_session(self) -> None:
        """Store the current state so the next start restores it."""
        self._session = self.current_session()
        try:
            save_session(self._session)
        except Exception:
            pass  # persistence is a convenience, never a blocker

    def save_preset(self) -> None:
        """Ask for a name and remember the current pair."""
        box = QMessageBox(self)
        box.setWindowTitle(tr("Save preset"))
        box.setIcon(QMessageBox.Icon.Question)
        box.setText(
            tr(
                "Current frequencies: left %1, right %2.",
                _format_hz(self._left.value()),
                _format_hz(self._right.value()),
            )
        )
        edit = QLineEdit(box)
        edit.setPlaceholderText(tr("Preset name"))
        edit.setAccessibleName(tr("Preset name"))
        edit.setText(self._session.last_preset or "")
        box.setInformativeText(
            tr("This preset is remembered for the next start.") + "\n" + tr("Name:")
        )
        box.setTextEdit(edit)
        box.setStandardButtons(
            QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Cancel
        )
        box.setDefaultButton(QMessageBox.StandardButton.Save)
        if box.exec() == QMessageBox.StandardButton.Save:
            name = edit.text().strip()
            self._session.last_preset = name or None
            self.save_session()

    # -------------------------------------------------------------- frequencies

    def left_hz(self) -> float:
        return self._left.value()

    def right_hz(self) -> float:
        return self._right.value()

    def active_channel(self) -> int:
        """0 = left, 1 = right."""
        return self._active

    def set_frequencies(self, left_hz: float, right_hz: float) -> None:
        """Set both channels programmatically."""
        self._suppress = True
        try:
            self._left.set_value(left_hz, emit=False)
            self._right.set_value(right_hz, emit=False)
        finally:
            self._suppress = False
        self._on_channels_changed()

    def apply_preset(self, beat_hz: float, index: int | None = None) -> None:
        """One click sets both channels so the difference is ``beat_hz``."""
        left, right = pair_from_beat(float(beat_hz), DEFAULT_CARRIER_HZ)
        self.set_frequencies(left, right)
        if index is not None and 0 <= index < len(self._preset_buttons):
            self._preset_buttons[index].setChecked(True)
        label = PRESETS[index][0] if index is not None and index < len(PRESETS) else None
        self._session.last_preset = label
        self.statusBar().showMessage(
            tr("Preset applied: difference %1 Hz", _format_hz(float(beat_hz))), 3000
        )

    def _on_left_changed(self, hz: float) -> None:
        if not self._suppress:
            self._on_channels_changed()

    def _on_right_changed(self, hz: float) -> None:
        if not self._suppress:
            self._on_channels_changed()

    def _on_channels_changed(self) -> None:
        left, right = self._left.value(), self._right.value()
        self._beat.update_values(left, right)
        self._apply_channels()
        self.frequencies_changed.emit(left, right)

    def _apply_channels(self) -> None:
        """Push frequencies to the oscillator, honouring a channel swap."""
        left, right = swap_channels(
            self._left.value(), self._right.value(), self._channels_swapped
        )
        if self._oscillator is not None:
            setter = getattr(self._oscillator, "set_frequencies", None)
            if callable(setter):
                try:
                    setter(left, right)
                except Exception:
                    pass

    def set_channels_swapped(self, swapped: bool) -> None:
        """Apply a channel swap coming from the L/R perceptual test (SPEC §4.2)."""
        self._channels_swapped = bool(swapped)
        self._apply_channels()

    def channels_swapped(self) -> bool:
        return self._channels_swapped

    # ----------------------------------------------------------------- playback

    def is_playing(self) -> bool:
        return self._playing

    def toggle_playback(self) -> None:
        if self._playing:
            self.stop_playback()
        else:
            self.start_playback()

    def start_playback(self) -> None:
        starter = getattr(self._engine, "start", None)
        if not callable(starter):
            return
        # The oscillator starts muted (gain 0) so the app never blasts audio on
        # launch; Play must explicitly open the amplitude or there is silence.
        if self._oscillator is not None:
            fade = getattr(self._oscillator, "set_fade", None)
            if callable(fade):
                try:
                    fade(1.0)
                except Exception:
                    pass
            pan = getattr(self._oscillator, "set_pan", None)
            if callable(pan):
                try:
                    pan(1.0, 1.0)  # restore full stereo after an L/R test
                except Exception:
                    pass
        try:
            ok = starter()
        except Exception as exc:
            self._on_engine_error(str(exc))
            return
        if ok is False:
            self._on_engine_error(tr("Could not start audio output."))
            return
        self._set_playing(True)

    def stop_playback(self) -> None:
        if self._oscillator is not None:
            fade = getattr(self._oscillator, "set_fade", None)
            if callable(fade):
                try:
                    fade(0.0)
                except Exception:
                    pass
        stopper = getattr(self._engine, "stop", None)
        if callable(stopper):
            try:
                stopper()
            except Exception:
                pass
        self._set_playing(False)

    def _on_engine_started(self) -> None:
        self._set_playing(True)

    def _on_engine_stopped(self) -> None:
        self._set_playing(False)

    def _on_engine_error(self, message: str) -> None:
        self._set_playing(False)
        self._error_label.setText(str(message))
        self._error_label.setToolTip(str(message))
        self._error_label.setVisible(bool(message))

    def _set_playing(self, playing: bool) -> None:
        playing = bool(playing)
        if playing == self._playing:
            return
        self._playing = playing
        self._play_button.setText(tr("Stop") if playing else tr("Play"))
        self._play_button.setAccessibleName(
            tr("Stop the binaural tone") if playing else tr("Play the binaural tone")
        )
        self._beat.set_playing(playing)
        self.playback_toggled.emit(playing)
        if not playing:
            self._error_label.setVisible(False)

    def _on_volume_changed(self, value: int) -> None:
        level = max(0.0, min(1.0, value / VOLUME_STEPS))
        self._volume_value.setText(f"{int(round(level * 100))}%")
        try:
            self._engine.volume = level
        except Exception:
            pass

    # -------------------------------------------------------------- headphone

    def set_headphone_report(self, report: HeadphoneReport | None) -> None:
        """Feed the status indicator and the channel-swap decision."""
        self.status_indicator.set_report(report)
        if report is not None:
            self.set_channels_swapped(bool(getattr(report, "channels_swapped", False)))

    def run_headphone_check(self) -> None:
        """Re-run the detection dialog (SPEC §4.3). Reachable from Help."""
        dialog_class = self._dialog_class("HeadphoneCheckDialog")
        if dialog_class is None:
            # No dialogs layer: keep the status bar truthful with the heuristic.
            self.set_headphone_report(detect())
            return
        dialog = dialog_class(None, self._engine, self)
        dialog.exec()
        report = dialog.report()
        if isinstance(report, HeadphoneReport):
            self.set_headphone_report(report)
            # §4.3: the check must not be repeated on every start.
            self._session.headphone_check_acknowledged = bool(dialog.acknowledged())
            self.save_session()

    # ------------------------------------------------------------------ dialogs

    @staticmethod
    def _dialog_class(name: str):
        """Resolve a dialog class from the dialogs package, or ``None``.

        The dialogs package is optional: without it the app must still run.
        """
        try:
            from . import dialogs
        except Exception:
            return None
        return getattr(dialogs, name, None)

    def open_reference(self) -> None:
        """Cmd/Ctrl+O — the full frequency reference (SPEC §6)."""
        dialog_class = self._dialog_class("ReferenceDialog")
        if dialog_class is None:
            QMessageBox.information(
                self,
                tr("Frequency reference"),
                tr("The frequency reference is not available in this build."),
            )
            return
        dialog = dialog_class(self)
        # An applied entry replaces both channels at once.
        dialog.apply_frequencies.connect(self.set_frequencies)
        dialog.exec()

    def show_about(self) -> None:
        """About + the mandatory disclaimer (SPEC §6.13)."""
        dialog_class = self._dialog_class("AboutDialog")
        if dialog_class is not None:
            dialog_class(self).exec()
            return
        from .. import __version__

        QMessageBox.about(
            self,
            tr("About Binaural"),
            tr(
                "<b>Binaural %1</b><br><br>"
                "Two independent frequencies, one perceived difference.<br><br>"
                "These frequencies and effect descriptions come from research as well "
                "as esoteric, energy and alternative practices. This app is not a medical "
                "device and is not intended for diagnosis, treatment or prevention of any "
                "disease. Do not use it with epilepsy, a pacemaker, during pregnancy, or "
                "with photosensitivity without consulting a doctor. Do not raise the volume."
            ).replace("%1", __version__),
        )

    # ------------------------------------------------------------- keyboard

    def keyPressEvent(self, event: QKeyEvent) -> None:  # noqa: N802 - Qt virtual
        """Space / arrows / Cmd-O, unless a text field is using the arrow keys."""
        key = event.key()
        modifiers = event.modifiers()

        if key in (Qt.Key.Key_Up, Qt.Key.Key_Down, Qt.Key.Key_Left, Qt.Key.Key_Right):
            if self._arrows_belong_to_focus():
                super().keyPressEvent(event)
                return
            if key in (Qt.Key.Key_Left, Qt.Key.Key_Right):
                self._set_active(1 - self._active)
                event.accept()
                return
            delta = NUDGE_HZ if key == Qt.Key.Key_Up else -NUDGE_HZ
            if self._active == 0:
                self._left.nudge(delta)
            else:
                self._right.nudge(delta)
            event.accept()
            return

        if key == Qt.Key.Key_Space:
            focus = self.focusWidget() or QApplication.focusWidget()
            if isinstance(focus, _TEXT_INPUTS) or modifiers not in (
                Qt.KeyboardModifier.NoModifier,
            ):
                super().keyPressEvent(event)
                return
            self.toggle_playback()
            event.accept()
            return

        if key == Qt.Key.Key_Escape:
            if self.close_modal():
                event.accept()
                return

        if key == Qt.Key.Key_O and modifiers & Qt.KeyboardModifier.ControlModifier:
            self.open_reference()
            event.accept()
            return

        super().keyPressEvent(event)

    def _arrows_belong_to_focus(self) -> bool:
        """True when the focused widget must keep the arrow keys.

        Only free-text fields qualify. A focused ``QDoubleSpinBox`` steps by
        exactly the same 0.1 Hz as the window shortcut, so intercepting it
        changes nothing for the user and avoids focus-order surprises.
        """
        focus = self.focusWidget() or QApplication.focusWidget()
        return isinstance(focus, _FREE_TEXT_INPUTS)

    def _set_active(self, index: int) -> None:
        self._active = 1 if index else 0
        (self._left if self._active == 0 else self._right).focus_spin()
        self.statusBar().showMessage(
            tr("Active channel: %1", self._left.caption() if self._active == 0
               else self._right.caption()),
            2000,
        )

    def close_modal(self) -> bool:
        """Escape closes the top modal dialog. True if something was closed."""
        modal = QApplication.activeModalWidget()
        if modal is not None:
            modal.close()
            return True
        return False

    

    # ------------------------------------------------------------------ closing

    def closeEvent(self, event: QCloseEvent) -> None:  # noqa: N802 - Qt virtual
        self.save_session()
        shutdown = getattr(self._engine, "shutdown", None)
        if callable(shutdown):
            try:
                shutdown()
            except Exception:
                pass
        super().closeEvent(event)


def _format_hz(value: float) -> str:
    """Frequency text without a pointless ``.0`` on whole numbers."""
    value = float(value)
    if abs(value - round(value)) < 0.05:
        return f"{int(round(value))}"
    return f"{value:.1f}"