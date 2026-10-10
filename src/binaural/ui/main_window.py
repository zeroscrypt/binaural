"""Main window (CONTRACT §6, SPEC §7 "Главное окно").

Layout: status bar with the headphone indicator, two independent ear panels,
the BEAT/CARRIER card in the middle, the transport row, and the preset chips.

The window owns no audio logic: it pushes frequencies and the play state into
the engine and reacts to the engine's signals.
"""

from __future__ import annotations

import time
from typing import TYPE_CHECKING

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QAction, QActionGroup, QCloseEvent, QKeyEvent
from PySide6.QtWidgets import (
    QAbstractSpinBox,
    QApplication,
    QButtonGroup,
    QComboBox,
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
from ..core.difference_lock import Channel, DifferenceLock
from ..core.oscillator import DEFAULT_CARRIER_HZ
from ..core.playback_timer import PlaybackTimer, closest_choice
from ..core.session import (
    TIMER_CHOICES,
    TIMER_OFF,
    Session,
    load as load_session,
    save as save_session,
)
from . import theme
from .presets import (
    PRESET_CATEGORIES,
    PRESETS,
    Preset,
    PresetCategory,
    frequencies_for,
    presets_in,
    resolved_category,
)
from .widgets.beat_display import BeatDisplay
from .widgets.freq_control import FreqControl
from .widgets.status_indicator import StatusIndicator

if TYPE_CHECKING:  # pragma: no cover - the annotation only, the import is lazy
    from .update_coordinator import UpdateCoordinator

__all__ = ["MainWindow", "PRESETS", "PRESET_CATEGORIES"]

_CONTEXT = "MainWindow"

NUDGE_HZ = 0.1
SLIDER_STEPS = 100
VOLUME_STEPS = 100
#: How often the countdown is refreshed. A second is what the label shows, so ticking
#: faster would burn CPU to redraw the same digits.
TICK_SECONDS_MS = 1000

#: SPEC §7's "Lock difference" notice, shown when a preset takes the difference away from
#: the lock. A checkbox that clears itself with no explanation looks like a bug, so the
#: window says so — once, briefly, in the status bar where the preset message already goes.
DIFFERENCE_UNLOCKED_NOTICE = "Difference lock turned off — a preset set its own difference."
#: Shown in the §F1 hint slot when the lock stopped the edited channel at 1–20000 Hz.
DIFFERENCE_BOUNDARY_NOTE = (
    "Stopped at the range limit: the difference is locked, so the other channel cannot "
    "follow any further."
)

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


def timer_choice_title(minutes: int) -> str:
    """The caption of one duration choice: "Off", or "15 min" in the current language.

    Shared by the window and the settings dialog: two controls offering two different
    wordings for the same value would be a second source of truth.
    """
    if minutes == TIMER_OFF:
        return tr("Off")
    return tr("%1 min", _format_hz(minutes))


def _now() -> float:
    """The clock the playback timer counts down against.

    A monotonic clock, not the wall clock: NTP stepping the system time backwards must
    not add minutes to a running session.
    """
    return time.monotonic()


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
        updates: "UpdateCoordinator | None" = None,
    ) -> None:
        super().__init__(parent)
        self._engine = engine
        # The update check. Injected by ``app.py`` so the launch check and the About
        # button are one object; built here on first use when it was not, because the
        # About dialog must still offer the button on its own.
        self._updates = updates
        self._oscillator = oscillator if oscillator is not None else getattr(engine, "oscillator", None)
        self._session = session or load_session()
        self._channels_swapped = bool(self._session.channels_swapped)
        self._playing = False
        self._suppress = False
        self._active = 0  # 0 = left, 1 = right
        # SPEC §5 F3: the stored category decides which presets the chips show; an
        # unknown one falls back to the default rather than emptying the row.
        self._selected_category = resolved_category(self._session.preset_category)
        # SPEC §7's lock. The captured difference is **not** restored from the session:
        # only the flag is stored, and the difference is captured again from the pair the
        # session restored — the same number by construction, and one that cannot contradict
        # the two frequencies stored beside it.
        self._lock = DifferenceLock(is_locked=bool(self._session.difference_locked))
        # SPEC §5 F5: the session's own duration, armed when playback starts.
        self._timer_minutes = closest_choice(self._session.timer_minutes)
        self._playback_timer = PlaybackTimer.off()
        self._ticker = QTimer(self)
        self._ticker.setInterval(TICK_SECONDS_MS)
        self._ticker.timeout.connect(self.tick_timer)
        self._headphone_report: HeadphoneReport | None = None
        # Kept so the settings dialog cannot outlive the window it edits.
        self._settings_dialog = None

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
        self._left = FreqControl(tr(LEFT_EAR), "left")
        self._right = FreqControl(tr(RIGHT_EAR), "secondary")
        ears.addWidget(self._left, 1)
        ears.addWidget(self._right, 1)
        central_layout.addLayout(ears)

        self._left.valueChanged.connect(self._on_left_changed)
        self._right.valueChanged.connect(self._on_right_changed)

        # --- beat card ----------------------------------------------------
        self._beat = BeatDisplay(self)
        self._beat.lockToggled.connect(self.set_difference_locked)
        central_layout.addWidget(self._beat)

        # --- transport ----------------------------------------------------
        central_layout.addLayout(self._build_transport())

        # --- playback timer (SPEC §5 F5) -----------------------------------
        central_layout.addLayout(self._build_timer())

        # --- presets ------------------------------------------------------
        central_layout.addStretch(1)
        central_layout.addWidget(self._build_presets())

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

    def _build_timer(self) -> QHBoxLayout:
        """The playback timer of SPEC §5 F5: a duration picker and a visible countdown.

        ``TIMER_CHOICES`` is the only source of the offered durations and ``0`` is off,
        so a session timer and a settings timer can never offer two different sets. The
        countdown is *text*, not a ring: SPEC §7.2 wants reduced-motion respected, and a
        label needs no animation at all. While the timer is off the label is empty and
        hidden rather than reading ``00:00``, which would look like a finished session.
        """
        row = QHBoxLayout()
        row.setSpacing(theme.SPACE_MD)

        self._timer_caption = QLabel(tr("Timer"), self)
        self._timer_caption.setFont(theme.font("body"))
        row.addWidget(self._timer_caption)

        self._timer_select = QComboBox(self)
        self._timer_select.setMinimumHeight(44)
        self._timer_select.setAccessibleName(tr("Timer"))
        self._timer_select.setAccessibleDescription(
            tr("How long a session plays before it stops by itself.")
        )
        self._timer_select.activated.connect(self._on_timer_activated)
        row.addWidget(self._timer_select)
        self._rebuild_timer_choices()

        self._countdown = QLabel("", self)
        self._countdown.setFont(theme.font("body"))
        self._countdown.setMinimumWidth(72)
        self._countdown.setAlignment(
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
        )
        self._countdown.setStyleSheet(f"color: {theme.color('muted-fg')};")
        self._countdown.setAccessibleName(tr("Time left"))
        self._countdown.setVisible(False)
        row.addWidget(self._countdown)

        row.addStretch(1)
        return row

    def _rebuild_timer_choices(self, *, select: int | None = None) -> None:
        """Refill the duration picker, keeping ``select`` minutes highlighted.

        Rebuilt rather than patched: every caption is translated, so a language switch
        changes all of them, and the selection has to survive that (SPEC §7.4).
        """
        wanted = self._timer_minutes if select is None else select
        self._timer_select.blockSignals(True)
        try:
            self._timer_select.clear()
            for choice in TIMER_CHOICES:
                self._timer_select.addItem(timer_choice_title(choice))
                self._timer_select.setItemData(
                    self._timer_select.count() - 1, choice, Qt.ItemDataRole.UserRole
                )
            index = self._timer_select.findData(wanted, Qt.ItemDataRole.UserRole)
            self._timer_select.setCurrentIndex(index if index >= 0 else 0)
        finally:
            self._timer_select.blockSignals(False)

    def _build_presets(self) -> QWidget:
        """The two-level preset control of SPEC §5 F3.

        Category chips on the first row, and inside the selected category the presets
        themselves on the second. Two levels rather than twenty chips in one row,
        because F3 makes the category part of the state: `Session.preset_category` is
        persisted, so the categories are a control the user picks rather than a heading.
        """
        box = QWidget(self)
        self._presets_box = box
        column = QVBoxLayout(box)
        column.setContentsMargins(0, 0, 0, 0)
        column.setSpacing(theme.SPACE_SM)

        self._presets_caption = QLabel(tr("Presets"), box)
        self._presets_caption.setFont(theme.font("body"))
        self._presets_caption.setStyleSheet(f"color: {theme.color('muted-fg')};")
        column.addWidget(self._presets_caption)

        # --- level 1: the category chips ------------------------------------
        category_row = QHBoxLayout()
        category_row.setSpacing(theme.SPACE_SM)
        self._category_group = QButtonGroup(self)
        self._category_group.setExclusive(True)
        self._category_buttons: dict[str, QPushButton] = {}
        for index, entry in enumerate(PRESET_CATEGORIES):
            button = self._make_chip(
                entry.localized_name(),
                self._category_description(entry),
                parent=box,
                level="category",
            )
            button.clicked.connect(
                lambda _checked=False, cid=entry.id: self.select_preset_category(cid)
            )
            self._category_group.addButton(button, index)
            category_row.addWidget(button)
            self._category_buttons[entry.id] = button
        category_row.addStretch(1)
        column.addLayout(category_row)

        # --- level 2: the presets of the selected category ------------------
        self._preset_row = QHBoxLayout()
        self._preset_row.setSpacing(theme.SPACE_SM)
        column.addLayout(self._preset_row)
        self._preset_group = QButtonGroup(self)
        self._preset_group.setExclusive(True)
        self._preset_buttons: list[QPushButton] = []
        self._rebuild_preset_chips()

        # A transient note under the preset block — SPEC §7's "short hint" that the lock
        # was turned off. It is a label of its own rather than the status bar, because the
        # status bar already carries the "Preset applied: …" message and the two have to be
        # visible at the same time for a few seconds.
        self._notice = QLabel("", box)
        self._notice.setFont(theme.font("caption"))
        self._notice.setStyleSheet(f"color: {theme.color('muted-fg')};")
        self._notice.setWordWrap(True)
        self._notice.setVisible(False)
        self._notice.setAccessibleName(tr("Note"))
        column.addWidget(self._notice)
        self._notice_key: str | None = None
        self._notice_timer = QTimer(self)
        self._notice_timer.setSingleShot(True)
        self._notice_timer.timeout.connect(self._hide_notice)

        return box

    def _make_chip(self, caption: str, description: str, parent: QWidget, *, level: str = "preset") -> QPushButton:
        """One chip with the shared metrics of SPEC §7.2 (44 px, focus ring).

        ``level`` is what tells the two rows of the preset bar apart: ``"category"`` is
        the top level of SPEC §5 F3 and is drawn heavier, ``"preset"`` is the choice inside
        it. They used to be the same object name, which left the bar looking like one
        undifferentiated list of buttons.
        """
        button = QPushButton(caption, parent)
        button.setObjectName("category" if level == "category" else "chip")
        button.setCheckable(True)
        button.setMinimumHeight(44)
        button.setAccessibleName(caption)
        button.setAccessibleDescription(description)
        return button

    def _rebuild_preset_chips(self) -> None:
        """Rebuild the second level for the selected category.

        Rebuilt rather than patched because the captions are localised data: a language
        switch changes every one of them, and the widths with them. Selecting a category
        never changes a frequency — only pressing a preset does (SPEC F3).
        """
        while self._preset_row.count():
            item = self._preset_row.takeAt(0)
            widget = item.widget()
            if widget is None:
                continue
            # No `removeButton` here, and that is deliberate.
            #
            # `QButtonGroup` already drops a button when the button is destroyed — it
            # listens to the button, it does not own it — so removing it first is
            # redundant work. It is also, on PySide6 with Python 3.10, a crash:
            # `removeButton(w)` followed by `w.deleteLater()` corrupts shiboken's
            # reference bookkeeping, and the interpreter dies during finalisation with
            # `Fatal Python error: none_dealloc: deallocating None`, after every test has
            # already passed. `deleteLater()` on its own does not. Deleting is enough:
            # the group forgets the button on its own, one line later.
            widget.setParent(None)
            widget.deleteLater()

        self._preset_buttons = []
        for index, preset in enumerate(presets_in(self._selected_category)):
            button = self._make_chip(
                preset.localized_title(),
                self._preset_description(preset.beat_hz),
                parent=self._presets_box,
            )
            button.clicked.connect(lambda _checked=False, p=preset: self.apply_preset(p))
            self._preset_group.addButton(button, index)
            self._preset_row.addWidget(button)
            self._preset_buttons.append(button)
        self._preset_row.addStretch(1)

    @staticmethod
    def _preset_description(beat_hz: float) -> str:
        """Accessible description of one preset chip, in the current language."""
        return tr(
            "Sets both channels around a %1 Hz carrier so the difference is %2 Hz.",
            _format_hz(DEFAULT_CARRIER_HZ),
            _format_hz(beat_hz),
        )

    @staticmethod
    def _category_description(entry: PresetCategory) -> str:
        """Accessible description of one category chip, in the current language."""
        beats = ", ".join(preset.beat_text for preset in entry.presets)
        return tr("Shows the %1 presets: %2.", entry.localized_name(), beats)

    # ------------------------------------------------------ preset categories

    def selected_preset_category(self) -> str:
        """The category id whose presets are on screen (SPEC §5 F3)."""
        return self._selected_category

    def select_preset_category(self, category_id: str) -> str:
        """Show the presets of one category. Returns the id actually selected.

        An unknown id — a hand-edited `preset_category` — falls back to the default
        rather than emptying the row, which is the whole point of a fallback.
        """
        wanted = resolved_category(category_id)
        if wanted != self._selected_category:
            self._selected_category = wanted
            self._rebuild_preset_chips()
            self._session.preset_category = wanted
        self._mark_category()
        return wanted

    def _mark_category(self) -> None:
        for cid, button in self._category_buttons.items():
            button.setChecked(cid == self._selected_category)

    def apply_preset(self, preset: Preset | float) -> None:
        """One click sets both channels so the difference is the preset's beat.

        Accepts a :class:`Preset` or a bare beat in Hz: a bare value is looked up in the
        selected category first and otherwise read as a Gamma-free registry entry, so a
        caller holding only a number still lands on a real preset.
        """
        if not isinstance(preset, Preset):
            preset = self._preset_for_beat(float(preset))
        left, right = frequencies_for(preset)
        self.set_frequencies(left, right)
        # F3: a preset sets its own difference, so the chip that produced it is the one
        # that stays highlighted.
        self.select_preset_category(preset.category_id)
        self._mark_preset(preset.id)
        self._session.last_preset = preset.id
        self.save_session()
        self.statusBar().showMessage(
            tr("Preset applied: difference %1 Hz", _format_hz(float(preset.beat_hz))), 3000
        )

    def _preset_for_beat(self, beat_hz: float) -> Preset:
        """The registry preset with this beat, in the selected category if it has one."""
        for preset in presets_in(self._selected_category):
            if abs(preset.beat_hz - beat_hz) < 0.05:
                return preset
        for preset in PRESETS:
            if abs(preset.beat_hz - beat_hz) < 0.05:
                return preset
        # No registry entry: synthesise one so a caller that typed a number of its own
        # still gets both channels set. Such a preset carries no band, hence no chip.
        return Preset(self._selected_category, beat_hz)

    def _show_notice(self, key: str, msec: int = 3000) -> None:
        """Show a short note under the preset block, then let it go.

        The **English key** is what gets stored, not the translated text: the window lives
        for the whole session, so ``retranslate()`` has to be able to render it again in
        the new language (SPEC §7.4).
        """
        self._notice_key = key
        self._notice.setText(tr(key))
        self._notice.setVisible(True)
        self._notice_timer.start(int(msec))

    def _hide_notice(self) -> None:
        self._notice_key = None
        self._notice.setText("")
        self._notice.setVisible(False)

    def difference_notice_key(self) -> str | None:
        """The English key behind the transient note, or ``None`` while none shows."""
        return self._notice_key

    def _mark_preset(self, preset_id: str | None) -> None:
        """Highlight the preset that produced the frequencies on screen, when it is one
        of the chips currently shown."""
        presets = presets_in(self._selected_category)
        for index, button in enumerate(self._preset_buttons):
            button.setChecked(index < len(presets) and presets[index].id == preset_id)

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

        # SPEC §7 dialog #4. On macOS the first menu is the application menu, so this is
        # where "Settings…" belongs; Cmd+, is also the convention on both platforms.
        self._settings_action = QAction(tr("&Settings…"), self)
        self._settings_action.setShortcut("Ctrl+,")
        self._settings_action.setShortcutContext(
            Qt.ShortcutContext.ApplicationShortcut
        )
        self._settings_action.triggered.connect(self.open_settings)
        self._view_menu.addSeparator()
        self._view_menu.addAction(self._settings_action)

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

        # SPEC §5 F5: the countdown is plain text, so a language switch re-reads it and
        # the choice captions; the selected duration has to survive both.
        self._timer_caption.setText(tr("Timer"))
        self._timer_select.setAccessibleName(tr("Timer"))
        self._timer_select.setAccessibleDescription(
            tr("How long a session plays before it stops by itself.")
        )
        self._countdown.setAccessibleName(tr("Time left"))
        self._rebuild_timer_choices()
        self._show_countdown()

        self._save_preset_button.setText(tr("Save preset"))
        self._save_preset_button.setAccessibleName(tr("Save preset"))
        self._save_preset_button.setAccessibleDescription(
            tr("Saves the current pair of frequencies for the next run.")
        )

        self._presets_caption.setText(tr("Presets"))
        self._notice.setAccessibleName(tr("Note"))
        # A transient note is stored as its English key, so a language switch has to
        # render it again rather than leave the old language's words on screen.
        if self._notice_key is not None:
            self._notice.setText(tr(self._notice_key))
        # Both chip levels carry localised captions, so both rows are rebuilt and the
        # category selection is put back (SPEC §7.4).
        for entry in PRESET_CATEGORIES:
            button = self._category_buttons.get(entry.id)
            if button is None:
                continue
            button.setText(entry.localized_name())
            button.setAccessibleName(entry.localized_name())
            button.setAccessibleDescription(self._category_description(entry))
        self._mark_category()
        self._rebuild_preset_chips()
        self._mark_preset(self._session.last_preset)

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
        self._settings_action.setText(tr("&Settings…"))

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

    def set_headphone_check_acknowledged(self, acknowledged: bool) -> None:
        """Remember that the §4.3 warning has been confirmed.

        §4.3: the dialog appears once, until it has been confirmed. Detection keeps
        running on every start; the dialog waits for the user to ask for it again.
        """
        acknowledged = bool(acknowledged)
        if acknowledged == self._session.headphone_check_acknowledged:
            return
        self._session.headphone_check_acknowledged = acknowledged
        self.save_session()

    def _restore_session(self) -> None:
        """Show the stored frequencies, volume, swap flag, timer and preset category.

        SPEC §5 F5: the last set of frequencies, the volume, the swap flag, **the timer**
        and the preset category all come back.
        """
        self._suppress = True
        try:
            self._left.set_value(self._session.left_hz, emit=False)
            self._right.set_value(self._session.right_hz, emit=False)
            self._volume.setValue(int(round(self._session.volume * VOLUME_STEPS)))
        finally:
            self._suppress = False
        self._timer_minutes = closest_choice(self._session.timer_minutes)
        self._rebuild_timer_choices()
        self.select_preset_category(self._session.preset_category)
        self._mark_preset(self._session.last_preset)
        # SPEC §7's lock comes back ticked, and its difference is captured from the pair just
        # restored: the stored flag alone would say "locked" without saying *what* is locked.
        self._beat.set_locked(self._lock.is_locked)
        if self._lock.is_locked:
            self._lock.capture(self._left.value(), self._right.value())
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
            timer_minutes=self._timer_minutes,
            # The chips show a resolved id, so that is what a save writes back: a stored
            # value the registry does not know must not survive as an unselectable row.
            preset_category=self._selected_category,
            difference_locked=self._lock.is_locked,
            # Carried through rather than dropped: the update check writes it, and a
            # snapshot that left it out would silently forget a skipped release on
            # the next save.
            skipped_update_version=self._session.skipped_update_version,
        )

    # ------------------------------------------------------- update check target

    @property
    def updates(self) -> "UpdateCoordinator":
        """The app's one update coordinator, built on first use.

        This window is its target: it owns the session, so it owns the skipped
        release. Building it here rather than in ``app.py`` means the About button
        works even in a build where nothing wired the launch check.
        """
        if self._updates is None:
            from .update_coordinator import UpdateCoordinator

            self._updates = UpdateCoordinator(parent=self, target=self)
        return self._updates

    def run_launch_update_check(self) -> None:
        """The silent background check of the launch sequence.

        A failure is silence and an up-to-date answer is silence; only a newer
        release may interrupt. Nothing here can raise into the event loop: the
        coordinator decides what a failure looks like.
        """
        try:
            self.updates.run_at_launch()
        except Exception:
            pass  # an update check is never a reason to fail a launch

    def skipped_update_version(self) -> str | None:
        """The release to stay silent about, or ``None`` for "ask about everything".

        One of the two halves of the update check's ``Target``: the window owns the
        session, so it owns this too, and the check never writes settings itself.
        """
        return self._session.skipped_update_version

    def persist_skipped_update_version(self, version: str | None) -> None:
        """Remember ``version`` as the release to skip; ``None`` forgets it.

        Written into the live session and saved immediately rather than at the next
        save: the user's answer to *Skip this version* has to survive the app closing
        seconds later, and nothing else would prompt another save.
        """
        self._session = self.current_session()
        self._session.skipped_update_version = version
        try:
            save_session(self._session)
        except Exception:
            pass  # persistence is a convenience, never a blocker

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
        """Set **both** channels at once, the way a preset and §6's *Apply* do.

        The pair entry point, and deliberately one edit: with the difference locked, two
        single edits would be two follower moves and the second would undo the first. A
        named pair from outside the window is the same kind of instruction a preset is, so
        it wins and unlocks, through the same path — which is why a locked window can never
        show the preset's pair half-applied.

        A one-channel programmatic change goes through ``_left``/``_right``'s
        ``set_value`` instead, and honours the lock like any other edit.
        """
        self._unlock_difference_for_pair()
        self._apply_locked_pair(left_hz, right_hz)
        self._beat.show_boundary_note(None)
        self._on_channels_changed()

    def _on_left_changed(self, hz: float) -> None:
        if not self._suppress:
            self._frequency_edited(Channel.LEFT)

    def _on_right_changed(self, hz: float) -> None:
        if not self._suppress:
            self._frequency_edited(Channel.RIGHT)

    # ------------------------------------------------------ lock difference (§7)

    def _frequency_edited(self, channel: Channel) -> None:
        """One channel moved. The single seam every frequency path goes through.

        The spin box, the slider, the ``↑``/``↓`` nudge and any programmatic
        ``set_value`` all end up in ``FreqControl.set_value``, which emits
        ``valueChanged`` — so the lock cannot be honoured by one route and quietly
        skipped by another. It has to know *which* channel moved: the difference is
        signed, so "the other one" is not a fixed ear.
        """
        requested = (
            self._left.value() if channel is Channel.LEFT else self._right.value()
        )
        resolution = self._lock.resolve(channel, requested)
        if resolution is None:
            # No lock, or no legal pair: the controls keep the value they already took.
            self._beat.show_boundary_note(None)
            self._on_channels_changed()
            return
        # `emit=False` on both: the pair is one edit, not two. A follower pushed through
        # `valueChanged` would read the lock again and move the channel back.
        self._apply_locked_pair(resolution.left_hz, resolution.right_hz)
        # The §F1 hint slot reports a refusal, so a slider that will not move further says
        # why instead of simply not moving. Cleared on the next accepted edit.
        self._beat.show_boundary_note(
            DIFFERENCE_BOUNDARY_NOTE if resolution.is_at_boundary else None
        )
        self._on_channels_changed()

    def _apply_locked_pair(self, left_hz: float, right_hz: float) -> None:
        """Write both channels without re-entering the edit path."""
        self._suppress = True
        try:
            self._left.set_value(left_hz, emit=False)
            self._right.set_value(right_hz, emit=False)
        finally:
            self._suppress = False

    def is_difference_locked(self) -> bool:
        """True while SPEC §7's "Lock difference" is ticked."""
        return self._lock.is_locked

    def locked_difference_hz(self) -> float:
        """The captured signed difference, ``fR - fL``. Zero while the lock is off."""
        return self._lock.signed_difference_hz if self._lock.is_locked else 0.0

    def set_difference_locked(self, locked: bool) -> None:
        """Tick or clear the box, as a click does.

        Ticking captures whatever the difference is *now* — there is no field for typing
        one. Clearing only stops the following; the frequencies stay where they are.
        """
        locked = bool(locked)
        if locked == self._lock.is_locked:
            return
        if locked:
            self._lock.capture(self._left.value(), self._right.value())
        else:
            self._lock.unlock()
            self._beat.show_boundary_note(None)
        self._beat.set_locked(self._lock.is_locked)
        self.save_session()

    def _unlock_difference_for_pair(self) -> bool:
        """A named pair from outside the window wins over the lock (SPEC §5 F3, §6).

        A preset and the frequency reference's *Apply* are the same kind of instruction —
        "use these two frequencies" — so the lock lets go rather than fighting it, and says
        so, because a checkbox that clears itself with no explanation looks like a bug.
        Returns True when there was a lock to clear, so the caller can add its own message.
        """
        if not self._lock.is_locked:
            return False
        self._lock.unlock()
        self._beat.set_locked(False)
        self._beat.show_boundary_note(None)
        self._show_notice(DIFFERENCE_UNLOCKED_NOTICE)
        return True

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
        self.arm_timer()

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
        # One place ends a session: the button, the keyboard and the timer expiry all
        # come through here, so the timer can never outlive the audio it was counting.
        self.disarm_timer()

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

    def set_volume(self, level: float) -> None:
        """Set the output level programmatically — what Settings and a test call.

        Goes through the same slider the user drags, so a value set here and a value set
        there end up in identical code and identical saving.
        """
        self._volume.blockSignals(True)
        try:
            self._volume.setValue(
                int(round(max(0.0, min(1.0, float(level))) * VOLUME_STEPS))
            )
        finally:
            self._volume.blockSignals(False)
        self._on_volume_changed(self._volume.value())
        self.save_session()

    def volume(self) -> float:
        """The current output level, 0..1."""
        return self._volume.value() / VOLUME_STEPS

    # ----------------------------------------------------------- playback timer

    def timer_minutes(self) -> int:
        """The duration a new session will run for; ``0`` = play until stopped."""
        return self._timer_minutes

    def select_timer_minutes(self, minutes: int) -> int:
        """Choose the session duration and re-arm a running session with it.

        Returns the value actually applied: a stored duration need not be one of
        ``TIMER_CHOICES`` (the session clamps to 0…1440, not to the offered set), and a
        control can only offer what it offers.
        """
        wanted = closest_choice(int(minutes))
        changed = wanted != self._timer_minutes
        self._timer_minutes = wanted
        # Only rebuild when the value really moved: a pick from the picker must not
        # clear the very widget that is delivering the signal.
        if changed:
            self._rebuild_timer_choices(select=wanted)
        if self._playing:
            self.arm_timer()
        else:
            self._show_countdown()
        self.save_session()
        return wanted

    def _on_timer_activated(self, index: int) -> None:
        """The user picked a duration in the picker."""
        raw = self._timer_select.itemData(index, Qt.ItemDataRole.UserRole)
        if raw is None:
            return
        self.select_timer_minutes(int(raw))

    def arm_timer(self, now: float | None = None) -> PlaybackTimer:
        """Arm the timer for the selected duration and start the countdown.

        ``TIMER_OFF`` minutes is "off": the countdown hides and nothing is scheduled, so
        "play until stopped" costs nothing. Returns the armed timer.
        """
        moment = _now() if now is None else float(now)
        self._playback_timer = PlaybackTimer.for_minutes(self._timer_minutes, started_at=moment)
        if self._playback_timer.is_enabled:
            self._ticker.start()
        self._show_countdown(moment)
        return self._playback_timer

    def disarm_timer(self) -> None:
        """Stop counting. The selected duration stays; only the countdown goes."""
        self._playback_timer = PlaybackTimer.off()
        self._ticker.stop()
        self._show_countdown()

    def playback_timer(self) -> PlaybackTimer:
        """The timer as it stands — what the countdown is derived from."""
        return self._playback_timer

    def tick_timer(self, now: float | None = None) -> None:
        """One tick of the countdown.

        The clock is a parameter rather than read inline, so expiry is testable to the
        second instead of by waiting a minute for it.
        """
        moment = _now() if now is None else float(now)
        if not self._playback_timer.is_enabled:
            return
        if self._playback_timer.has_expired(moment):
            # SPEC §7: the stop fades out, so the session does not end with a click.
            self.stop_playback()
            self.retranslate()
        else:
            self._show_countdown(moment)

    def _show_countdown(self, now: float | None = None) -> None:
        text = self._playback_timer.countdown_text(_now() if now is None else now)
        self._countdown.setText(text)
        self._countdown.setVisible(bool(text))
        self._countdown.setAccessibleDescription(
            tr("Time left: %1", text) if text else tr("The timer is off.")
        )

    def countdown_text(self) -> str:
        """What the countdown label currently reads; empty while the timer is off."""
        return self._countdown.text()

    # -------------------------------------------------------------- headphone

    def set_headphone_report(self, report: HeadphoneReport | None) -> None:
        """Feed the status indicator and the channel-swap decision."""
        self._headphone_report = report
        self.status_indicator.set_report(report)
        if report is not None:
            self.set_channels_swapped(bool(getattr(report, "channels_swapped", False)))

    def headphone_report(self) -> HeadphoneReport | None:
        """The verdict the app is currently acting on, or ``None``."""
        return self._headphone_report

    def run_headphone_check(self) -> None:
        """Re-run the detection dialog (SPEC §4.3).

        The one entry point for every manual re-check: the *Help* menu item and the
        settings dialog both land here, so they cannot drift apart.
        """
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
        # §4.3: the dialog is shown once, until it has been confirmed — a re-run from
        # Settings or from the menu is the user asking for it again.
        self.set_headphone_check_acknowledged(bool(dialog.acknowledged()))

    # ------------------------------------------------------------------ dialogs

    def open_settings(self) -> None:
        """Cmd/Ctrl+, — the settings dialog of SPEC §7.

        The wiring lives here rather than in the caller: this is the only place where
        "settings writes into the window" is decided, so the menu item and a test cannot
        end up with a dialog whose controls move nothing.
        """
        dialog = self.make_settings_dialog()
        if dialog is None:
            # No dialogs layer: say so and carry on. A modal box here would be a wall,
            # and the app must keep working without the optional dialogs package.
            self.statusBar().showMessage(
                tr("Settings are not available in this build."), 4000
            )
            return
        dialog.exec()

    def make_settings_dialog(self):
        """Build the settings dialog already wired to this window.

        Every control goes through the window's own entry points — ``set_volume``,
        ``select_timer_minutes``, ``run_headphone_check`` — so a value changed in
        Settings and a value changed in the window take identical code and identical
        saving. ``None`` when the dialogs package is unavailable.
        """
        dialog_class = self._dialog_class("SettingsDialog")
        if dialog_class is None:
            return None

        dialog = dialog_class(
            self,
            language=i18n.language(),
            timer_minutes=self._timer_minutes,
            volume=self.volume(),
            headphone_report=self._headphone_report,
        )
        dialog.volume_changed.connect(self.set_volume)
        dialog.timer_selected.connect(self.select_timer_minutes)
        dialog.headphone_check_requested.connect(self._check_headphones_from_settings)
        self._settings_dialog = dialog
        return dialog

    def _check_headphones_from_settings(self) -> None:
        """Settings asked for the check; feed the verdict back into its row."""
        self.run_headphone_check()
        dialog = self._settings_dialog
        if dialog is not None:
            dialog.set_headphone_report(self._headphone_report)

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
        """About + the mandatory disclaimer (SPEC §6.13).

        The dialog carries the update check, and this window is that check's target
        — the same object the launch check used, so *Skip this version* is
        remembered once and stays silent afterwards.
        """
        dialog_class = self._dialog_class("AboutDialog")
        if dialog_class is not None:
            try:
                dialog_class(self, updates=self.updates)
            except TypeError:
                # A dialog built without the update wiring is still usable: the
                # button builds its own coordinator on the first press.
                dialog_class(self)
            dialog.exec()
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