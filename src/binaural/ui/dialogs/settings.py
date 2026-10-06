"""Settings (SPEC §7, dialog #4): language, session timer, volume, headphone check.

SPEC §7 names four things this dialog must offer — language (alongside the *View →
Language* menu), the timer, the volume, and a way to run the headphone check — and they
are the four rows here. Nothing else was invented.

**No OK button, because there is nothing to apply.** Every control writes through to the
live window, which is what owns the state:

| Row | Writes to | Live effect |
|---|---|---|
| Language | :func:`binaural.i18n.set_language` — the same call the *View → Language* menu makes | the whole app, this dialog included (SPEC §7.4) |
| Timer | :meth:`~binaural.ui.main_window.MainWindow.select_timer_minutes` | a running session re-arms with the new duration |
| Volume | :meth:`~binaural.ui.main_window.MainWindow.set_volume` | the engine's gain, persisted by the window's own save |
| Headphones | :meth:`~binaural.ui.main_window.MainWindow.run_headphone_check` | the §4.3 dialog, and the verdict comes back into this row |

So the dialog emits signals and holds no copy of the state: a value changed here and a
value changed in the window go through identical code and identical saving. That is also
why the caller is the one that builds the wiring (:meth:`MainWindow.open_settings`).

The durations come from ``Session.TIMER_CHOICES`` — the same data the window offers. A
settings dialog offering a different set would be a second source of truth for a value
that already has one.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QHBoxLayout,
    QSlider,
    QVBoxLayout,
    QWidget,
)

from ... import i18n
from ...audio.headphones import HeadphoneReport
from ...audio.platform.base import DeviceClass
from ...core.session import TIMER_CHOICES, TIMER_OFF
from .headphone_check import (
    _CONFIDENCE_LABEL,
    _VERDICT_LABEL,
    VERDICT_TEXT,
    _UNKNOWN_DEVICE,
)
from . import (
    MIN_CONTRAST,
    SPACE_LG,
    SPACE_MD,
    SPACE_SM,
    button_row,
    ensure_contrast,
    make_button,
    make_label,
    make_panel,
    panel_layout,
    resolve_theme,
    set_role,
    style_dialog,
    tr,
)

__all__ = ["SettingsDialog"]

#: Volume steps; the same 0..100 scale the window's slider uses.
VOLUME_STEPS = 100


class SettingsDialog(QDialog):
    """The four settings of SPEC §7, each writing straight through to the window."""

    #: The user picked a language code (``"en"`` / ``"ru"``).
    language_selected = Signal(str)
    #: The user picked a session duration in minutes; ``0`` = off.
    timer_selected = Signal(int)
    #: The output level moved, 0..1.
    volume_changed = Signal(float)
    #: The user asked to run the headphone check again (SPEC §4).
    headphone_check_requested = Signal()

    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        language: str | None = None,
        timer_minutes: int = TIMER_OFF,
        volume: float = 0.7,
        headphone_report: HeadphoneReport | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("Settings"))
        self.setAccessibleName(tr("Settings"))
        self.setModal(True)
        self.resize(520, 420)
        self.setMinimumWidth(460)

        # The language as it was when the dialog opened. With no OK button there is no
        # commit, so rejecting puts it back rather than leaving a silent switch.
        self._initial_language = language or i18n.language()
        self._timer_minutes = int(timer_minutes)
        self._report = headphone_report

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        root.addLayout(self._language_row())
        root.addLayout(self._timer_row())
        root.addLayout(self._volume_row())
        # Set after the row is built, with signals blocked: showing the stored level is
        # not the user changing it, so opening Settings must not write anything back.
        self._volume_slider.blockSignals(True)
        try:
            self._volume_slider.setValue(
                int(round(max(0.0, min(1.0, float(volume))) * VOLUME_STEPS))
            )
        finally:
            self._volume_slider.blockSignals(False)
        self._update_volume_label()

        self._headphone_panel = make_panel()
        # The panel's own layout is created by ``_headphone_box``; only the panel goes
        # into the dialog layout — adding both would give one layout two parents.
        self._headphone_box()
        root.addWidget(self._headphone_panel)

        root.addStretch(1)
        self._close_button = make_button(
            tr("Close"),
            on_click=self.accept,
            min_width=140,
            accessible_name=tr("Close the settings"),
        )
        self._close_button.setDefault(True)
        root.addLayout(button_row(self._close_button))

        self.setTabOrder(self._language_combo, self._timer_combo)
        self.setTabOrder(self._timer_combo, self._volume_slider)
        self.setTabOrder(self._volume_slider, self._check_button)
        self.setTabOrder(self._check_button, self._close_button)

        self._retranslate()
        style_dialog(self)

        # SPEC §7.4: the dialog reads the language itself, and this is what lets a switch
        # made from the *View* menu reach it while it is open. Qt drops the connection
        # when this dialog is destroyed, so there is nothing to disconnect by hand.
        i18n.language_changed.connect(self._on_language_changed)

    # ------------------------------------------------------------------ build

    def _language_row(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(SPACE_MD)
        self._language_caption = make_label()
        row.addWidget(self._language_caption, 1)

        self._language_combo = QComboBox(self)
        self._language_combo.setMinimumHeight(44)
        self._language_combo.setAccessibleName(tr("Language"))
        self._language_combo.setAccessibleDescription(
            tr("Switch the interface language straight away.")
        )
        self._language_combo.activated.connect(self._on_language_activated)
        # Native names in both languages, exactly as the View menu does it: a user has
        # to be able to find their own language in the list.
        for code, name in i18n.languages().items():
            self._language_combo.addItem(name)
            self._language_combo.setItemData(
                self._language_combo.count() - 1, code, Qt.ItemDataRole.UserRole
            )
        row.addWidget(self._language_combo)
        return row

    def _timer_row(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(SPACE_MD)
        self._timer_caption = make_label()
        row.addWidget(self._timer_caption, 1)

        self._timer_combo = QComboBox(self)
        self._timer_combo.setMinimumHeight(44)
        self._timer_combo.setAccessibleName(tr("Timer"))
        self._timer_combo.setAccessibleDescription(
            tr("How long a new session plays before it stops by itself.")
        )
        self._timer_combo.activated.connect(self._on_timer_activated)
        self._fill_timer_choices()
        row.addWidget(self._timer_combo)
        return row

    def _fill_timer_choices(self) -> None:
        """Refill the duration picker from ``TIMER_CHOICES``, keeping the selection.

        Rebuilt rather than patched: the captions are translated, so a language switch
        changes every one of them and the selection has to survive that.
        """
        from ..main_window import timer_choice_title

        self._timer_combo.blockSignals(True)
        try:
            self._timer_combo.clear()
            for choice in TIMER_CHOICES:
                self._timer_combo.addItem(timer_choice_title(choice))
                self._timer_combo.setItemData(
                    self._timer_combo.count() - 1, choice, Qt.ItemDataRole.UserRole
                )
            index = self._timer_combo.findData(self._timer_minutes, Qt.ItemDataRole.UserRole)
            self._timer_combo.setCurrentIndex(index if index >= 0 else 0)
        finally:
            self._timer_combo.blockSignals(False)

    def _volume_row(self) -> QHBoxLayout:
        row = QHBoxLayout()
        row.setSpacing(SPACE_MD)
        self._volume_caption = make_label()
        row.addWidget(self._volume_caption, 1)

        self._volume_slider = QSlider(Qt.Orientation.Horizontal, self)
        self._volume_slider.setRange(0, VOLUME_STEPS)
        self._volume_slider.setMinimumWidth(200)
        self._volume_slider.setMinimumHeight(44)
        self._volume_slider.valueChanged.connect(self._on_volume_moved)
        row.addWidget(self._volume_slider)

        self._volume_value = make_label(role="muted")
        self._volume_value.setMinimumWidth(44)
        self._volume_value.setAlignment(
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
        )
        self._update_volume_label()
        row.addWidget(self._volume_value)
        return row

    def _headphone_box(self) -> QVBoxLayout:
        """Fill the headphone panel: the verdict, and a button that re-runs the check.

        SPEC §4: the same dialog the Help menu and the window's own button open, not a
        second check that could disagree with them.
        """
        layout = panel_layout(self._headphone_panel, spacing=SPACE_SM)

        self._headphone_caption = make_label(role="heading")
        layout.addWidget(self._headphone_caption)

        self._headphone_status = make_label()
        layout.addWidget(self._headphone_status)

        self._headphone_detail = make_label(role="caption", word_wrap=True)
        layout.addWidget(self._headphone_detail)

        # SPEC §4: the same dialog the Help menu and the window's own button open, not a
        # second check that could disagree with them.
        self._check_button = make_button(
            tr("Check headphones…"),
            on_click=self.request_headphone_check,
            min_width=220,
            accessible_name=tr("Run the headphone check again"),
            tooltip=tr("Re-reads the default audio output device and offers the L/R test."),
        )
        layout.addWidget(self._check_button)
        return layout

    # ---------------------------------------------------------------- actions

    def _on_language_activated(self, index: int) -> None:
        raw = self._language_combo.itemData(index, Qt.ItemDataRole.UserRole)
        if not raw:
            return
        code = str(raw)
        # The same call the View menu makes; i18n re-reads the window and this dialog.
        i18n.set_language(code)
        self.language_selected.emit(code)

    def _on_timer_activated(self, index: int) -> None:
        raw = self._timer_combo.itemData(index, Qt.ItemDataRole.UserRole)
        if raw is None:
            return
        self._timer_minutes = int(raw)
        self.timer_selected.emit(self._timer_minutes)

    def _on_volume_moved(self, value: int) -> None:
        self._update_volume_label()
        self.volume_changed.emit(max(0.0, min(1.0, value / VOLUME_STEPS)))

    def _update_volume_label(self) -> None:
        self._volume_value.setText(f"{int(round(self._volume_slider.value()))}%")

    def request_headphone_check(self) -> None:
        """Ask the window to run §4 again; the verdict comes back through
        :meth:`set_headphone_report`."""
        self.headphone_check_requested.emit()

    def reject(self) -> None:
        """Closing without a commit must not leave a silent language switch behind."""
        if i18n.language() != self._initial_language:
            i18n.set_language(self._initial_language)
            self.language_selected.emit(self._initial_language)
        super().reject()

    # ----------------------------------------------------------------- values

    def set_headphone_report(self, report: HeadphoneReport | None) -> None:
        """Show the verdict the app is currently acting on.

        Shown so the row states the truth rather than implying the check has never run.
        """
        self._report = report
        self._refresh_headphone()

    def headphone_report(self) -> HeadphoneReport | None:
        return self._report

    def _refresh_headphone(self) -> None:
        report = self._report
        if report is None:
            icon, status, role = "?", tr("Unknown device"), "muted"
            self._headphone_detail.setText("")
        else:
            icon, status, role = VERDICT_TEXT.get(
                report.verdict, VERDICT_TEXT[DeviceClass.UNKNOWN]
            )
            status = tr(status, "HeadphoneCheckVerdict")
            device = getattr(report.device, "name", "") or ""
            verdict = tr(
                _VERDICT_LABEL.get(report.verdict, _VERDICT_LABEL[DeviceClass.UNKNOWN]),
                "HeadphoneCheckVerdict",
            )
            confidence = tr(
                _CONFIDENCE_LABEL.get(str(report.confidence).lower(), "Low"),
                "HeadphoneCheckConfidence",
            )
            name = device if str(device).strip() else tr(_UNKNOWN_DEVICE, "HeadphoneCheck")
            self._headphone_detail.setText(
                f"{tr('Device', 'HeadphoneCheck')}: {name}   ·   "
                f"{tr('Verdict', 'HeadphoneCheck')}: {verdict}   ·   "
                f"{tr('Confidence', 'HeadphoneCheck')}: {confidence}"
            )
        # Icon **and** words: colour is never the only signal (SPEC §7.2).
        self._headphone_status.setText(f"{icon}  {status}")
        set_role(self._headphone_status, role)
        self._headphone_status.setStyleSheet(
            f"color: {ensure_contrast(_role_color(role, self), resolve_theme(self).background)};"
        )

    # ------------------------------------------------------------- language

    def _on_language_changed(self, _code: str) -> None:
        """The app was switched to another language while this dialog is open."""
        self._retranslate()

    def _retranslate(self) -> None:
        self.setWindowTitle(tr("Settings"))
        self.setAccessibleName(tr("Settings"))

        self._language_caption.setText(tr("Language"))
        self._language_combo.setAccessibleName(tr("Language"))
        self._language_combo.setAccessibleDescription(
            tr("Switch the interface language straight away.")
        )
        code = i18n.language()
        index = self._language_combo.findData(code, Qt.ItemDataRole.UserRole)
        if index < 0:
            index = self._language_combo.findData(self._initial_language, Qt.ItemDataRole.UserRole)
        if index >= 0:
            self._language_combo.setCurrentIndex(index)

        self._timer_caption.setText(tr("Timer"))
        self._timer_combo.setAccessibleName(tr("Timer"))
        self._timer_combo.setAccessibleDescription(
            tr("How long a new session plays before it stops by itself.")
        )
        self._fill_timer_choices()

        self._volume_caption.setText(tr("Volume"))
        self._volume_slider.setAccessibleName(tr("Volume"))
        self._volume_slider.setAccessibleDescription(
            tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )

        self._headphone_caption.setText(tr("Headphones"))
        self._check_button.setText(tr("Check headphones…"))
        self._check_button.setAccessibleName(tr("Run the headphone check again"))
        self._check_button.setAccessibleDescription(
            tr("Re-reads the default audio output device and offers the L/R test.")
        )
        self._close_button.setText(tr("Close"))
        self._close_button.setAccessibleName(tr("Close the settings"))
        self._refresh_headphone()

    # ------------------------------------------------- state the tests read

    def language_titles(self) -> list[str]:
        """The language names in the list, in order."""
        return [self._language_combo.itemText(i) for i in range(self._language_combo.count())]

    def timer_titles(self) -> list[str]:
        """The offered durations as captions — what the user can pick."""
        return [self._timer_combo.itemText(i) for i in range(self._timer_combo.count())]

    def selected_language(self) -> str:
        raw = self._language_combo.currentData(Qt.ItemDataRole.UserRole)
        return str(raw) if raw else i18n.language()

    def selected_timer_minutes(self) -> int:
        raw = self._timer_combo.currentData(Qt.ItemDataRole.UserRole)
        return int(raw) if raw is not None else TIMER_OFF

    def volume_level(self) -> float:
        return self._volume_slider.value() / VOLUME_STEPS

    def volume_title(self) -> str:
        return self._volume_value.text()

    def headphone_status_text(self) -> str:
        return self._headphone_status.text()

    def headphone_detail_text(self) -> str:
        return self._headphone_detail.text()

    # ------------------------------------------------------- test entry points

    def choose_language(self, code: str) -> str:
        """Pick a language as the combo would, through ``i18n.set_language``."""
        index = self._language_combo.findData(code, Qt.ItemDataRole.UserRole)
        if index < 0:
            return self.selected_language()
        self._language_combo.setCurrentIndex(index)
        self._on_language_activated(index)
        return self.selected_language()

    def choose_timer_minutes(self, minutes: int) -> int:
        """Pick a duration as the combo would."""
        index = self._timer_combo.findData(minutes, Qt.ItemDataRole.UserRole)
        if index < 0:
            return self.selected_timer_minutes()
        self._timer_combo.setCurrentIndex(index)
        self._on_timer_activated(index)
        return self.selected_timer_minutes()

    def set_volume(self, level: float) -> float:
        """Move the slider as the user would."""
        self._volume_slider.setValue(int(round(max(0.0, min(1.0, float(level))) * VOLUME_STEPS)))
        return self.volume_level()

    def tap_check_headphones(self) -> None:
        """Press the button as a click does."""
        self.request_headphone_check()


def _role_color(role: str, widget: QWidget) -> str:
    """The token colour behind a status role, contrast already guaranteed."""
    tokens = resolve_theme(widget)
    if role == "ok":
        return ensure_contrast(tokens.accent, tokens.background, MIN_CONTRAST)
    if role == "danger":
        return ensure_contrast(tokens.destructive, tokens.background, MIN_CONTRAST)
    if role == "warning":
        return ensure_contrast(tokens.warning, tokens.background, MIN_CONTRAST)
    return tokens.muted
