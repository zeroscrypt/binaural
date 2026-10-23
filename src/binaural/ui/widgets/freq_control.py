"""Per-ear frequency control (SPEC F1).

One reusable widget drives either channel: caption, big display number, a
0.1 Hz ``QDoubleSpinBox`` for exact entry and a logarithmic slider for coarse
sweeps. The two channels are fully independent — nothing here reads or writes
the other side.
"""

from __future__ import annotations

import math

from PySide6.QtCore import QLocale, Qt, Signal
from PySide6.QtGui import QColor, QPainter
from PySide6.QtWidgets import (
    QAbstractSpinBox,
    QDoubleSpinBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QSlider,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ...core.oscillator import MAX_FREQ_HZ, MIN_FREQ_HZ
from .. import theme

__all__ = ["FreqControl", "SLIDER_STEPS"]

_CONTEXT = "FreqControl"

#: Slider resolution. 1000 steps over 4.3 decades keeps 0.1 Hz usable down to
#: ~200 Hz and still reaches 20 kHz.
SLIDER_STEPS = 1000

_LOG_MIN = math.log10(MIN_FREQ_HZ)
_LOG_SPAN = math.log10(MAX_FREQ_HZ) - _LOG_MIN


def tr(text: str) -> str:
    from ...i18n import tr as _tr

    return _tr(text, context=_CONTEXT)


def _slider_to_hz(position: int) -> float:
    return 10.0 ** (_LOG_MIN + (_LOG_SPAN * position / SLIDER_STEPS))


def _hz_to_slider(hz: float) -> int:
    ratio = (math.log10(max(hz, MIN_FREQ_HZ)) - _LOG_MIN) / _LOG_SPAN
    return int(round(min(1.0, max(0.0, ratio)) * SLIDER_STEPS))


class _FreqSpinBox(QDoubleSpinBox):
    """The exact-entry field of one ear.

    The step buttons are controls of their own and stand to the left and the
    right of this field — the same composition the macOS build uses — so the
    spinbox itself is Qt's plain one: it keeps the keyboard steps (arrow keys,
    0.1 at a time) and the `C` locale for the dot.
    """


class _ChannelSwatch(QWidget):
    """The small colour chip that ties a panel to its channel token."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._color = QColor(theme.color("primary"))
        self.setFixedSize(10, 10)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def set_color(self, color: str) -> None:
        self._color = QColor(color)
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(self._color)
        painter.drawEllipse(0, 0, self.width() - 1, self.height() - 1)


class FreqControl(QFrame):
    """One ear's frequency: caption, big number, spinbox and slider.

    ``valueChanged`` carries the new frequency in Hz and fires only on real user
    changes plus explicit :meth:`set_value` calls, never on internal syncing.
    """

    valueChanged = Signal(float)

    def __init__(
        self,
        caption: str = "",
        accent: str = "primary",
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setObjectName("panel")
        self.setProperty("role", "panel")
        self._accent = accent
        self._hz = MIN_FREQ_HZ
        self._syncing = False

        layout = QVBoxLayout(self)
        layout.setContentsMargins(
            theme.SPACE_LG, theme.SPACE_LG, theme.SPACE_LG, theme.SPACE_LG
        )
        layout.setSpacing(theme.SPACE_SM)

        # Caption row: colour chip + channel name + range hint.
        head = QHBoxLayout()
        head.setSpacing(theme.SPACE_SM)
        self._swatch = _ChannelSwatch(self)
        self._caption = QLabel(self)
        self._caption.setFont(theme.font("title"))
        self._caption.setText(caption)
        self._range_hint = QLabel(self)
        self._range_hint.setFont(theme.font("caption"))
        self._range_hint.setText(tr("1 – 20000 Hz"))
        self._range_hint.setAlignment(
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
        )
        head.addWidget(self._swatch)
        head.addWidget(self._caption)
        head.addStretch(1)
        head.addWidget(self._range_hint)
        layout.addLayout(head)

        # Big number, then the exact-entry spinbox.
        self._display = QLabel(self)
        self._display.setProperty("role", "display")
        self._display.setFont(theme.font("display"))
        self._display.setText("0.0")
        self._display.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )
        self._display.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        layout.addWidget(self._display)

        self._spin = _FreqSpinBox(self)
        self._spin.setRange(MIN_FREQ_HZ, MAX_FREQ_HZ)
        self._spin.setDecimals(1)
        self._spin.setSingleStep(0.1)
        self._spin.setSuffix(" Hz")
        self._spin.setKeyboardTracking(False)
        # Frequencies are always written with a dot, whatever the OS locale is.
        self._spin.setLocale(QLocale.c())
        self._spin.setAlignment(Qt.AlignmentFlag.AlignLeft)
        self._spin.setFont(theme.font("title"))
        self._spin.setMinimumHeight(44)

        # The step buttons stand to the left and the right of the number — a stepper
        # the field sits between, the same one the macOS build draws. Holding one
        # repeats, which is what makes a wide sweep bearable at 0.1 hertz a step.
        self._lower = QToolButton(self)
        self._lower.setText("\u2212")
        self._lower.setAutoRaise(True)
        self._lower.setAutoRepeat(True)
        self._lower.setFont(theme.font("title"))
        self._lower.setAccessibleName(tr("Lower the frequency"))
        self._lower.setAccessibleDescription(
            tr("Lowers the frequency by 0.1 hertz. Keep it held down to repeat.")
        )
        self._lower.clicked.connect(lambda: self.nudge(-0.1))

        self._raise = QToolButton(self)
        self._raise.setText("+")
        self._raise.setAutoRaise(True)
        self._raise.setAutoRepeat(True)
        self._raise.setFont(theme.font("title"))
        self._raise.setAccessibleName(tr("Raise the frequency"))
        self._raise.setAccessibleDescription(
            tr("Raises the frequency by 0.1 hertz. Keep it held down to repeat.")
        )
        self._raise.clicked.connect(lambda: self.nudge(0.1))

        for button in (self._lower, self._raise):
            button.setMinimumSize(28, 28)

        entry_row = QHBoxLayout()
        entry_row.setSpacing(theme.SPACE_XS)
        entry_row.addWidget(self._lower)
        entry_row.addWidget(self._spin, 1)
        entry_row.addWidget(self._raise)
        layout.addLayout(entry_row)

        self._slider = QSlider(Qt.Orientation.Horizontal, self)
        self._slider.setRange(0, SLIDER_STEPS)
        self._slider.setMinimumHeight(44)
        layout.addWidget(self._slider)

        self._spin.valueChanged.connect(self._on_spin_changed)
        self._slider.valueChanged.connect(self._on_slider_changed)

        self.set_accent(accent)
        self.setCaption(caption)
        self.set_value(MIN_FREQ_HZ)
        self._sync_widgets()

    # ------------------------------------------------------------------ state

    def value(self) -> float:
        """Current frequency in Hz."""
        return self._hz

    #: Qt-style alias so ``spin.valueChanged`` style code keeps working.
    def setValue(self, hz: float) -> None:  # noqa: N802 - Qt naming
        self.set_value(hz)

    def set_value(self, hz: float, emit: bool = True) -> None:
        """Set the frequency. ``emit=False`` for programmatic syncing."""
        try:
            value = float(hz)
        except (TypeError, ValueError):
            return
        if math.isnan(value) or math.isinf(value):
            return
        value = min(MAX_FREQ_HZ, max(MIN_FREQ_HZ, round(value, 1)))
        if value == self._hz:
            self._sync_widgets()
            return
        self._hz = value
        self._sync_widgets()
        if emit:
            self.valueChanged.emit(value)

    def caption(self) -> str:
        return self._caption.text()

    def setCaption(self, text: str) -> None:  # noqa: N802 - Qt naming
        """Rename the channel and refresh the accessibility strings."""
        self._caption.setText(text)
        self.setAccessibleName(text)
        self._range_hint.setText(tr("1 – 20000 Hz"))
        self.setAccessibleDescription(
            tr("Frequency for %1, from 1 to 20000 hertz. Use the arrow keys for 0.1 hertz steps.")
            .replace("%1", text)
        )
        self._spin.setAccessibleName(tr("%1 frequency in hertz").replace("%1", text))
        self._spin.setAccessibleDescription(
            tr("Type an exact value between 1 and 20000, in steps of 0.1 hertz.")
        )
        self._slider.setAccessibleName(tr("%1 frequency slider").replace("%1", text))
        self._slider.setAccessibleDescription(
            tr("Sweeps the frequency from 1 to 20000 hertz.")
        )

    def retranslate(self, caption: str) -> None:
        """Re-read every caption after a language switch (SPEC §7).

        ``caption`` arrives already translated: the owner (MainWindow) knows
        which ear this widget drives, so it owns the source string too.
        """
        self.setCaption(caption)

    def set_accent(self, token: str) -> None:
        """Colour token for this channel: ``left`` = left ear, ``secondary`` = right ear."""
        self._accent = token
        colour = theme.color(token)
        table = theme.DARK if theme.chosen_dark() else theme.LIGHT
        # Captions are 16px body text and need 4.5:1; only the 42px number is
        # allowed the weaker SPEC shade.
        text_colour = table.get(f"{token}-text", colour)
        self._swatch.set_color(colour)
        self._caption.setStyleSheet(f"color: {text_colour};")
        for button in (self._lower, self._raise):
            button.setStyleSheet(f"QToolButton {{ color: {colour}; }}")
        self._display.setStyleSheet(f"color: {colour};")
        self._slider.setStyleSheet(
            f"QSlider::sub-page:horizontal {{ background: {colour}; }}"
            f" QSlider::handle:horizontal {{ border: 2px solid {colour}; }}"
        )
        # The panel's own edge is tinted too. It used to come from the global `border`
        # token, so both ears were outlined in the same pale grey and the only thing
        # telling them apart was the caption — which is the one thing the colour was
        # supposed to be saving the reader from. An inline sheet is set on the frame
        # itself and touches nothing else, so the themed background and radius stay.
        self.setStyleSheet(f"QFrame#panel {{ border: 1px solid {colour}; }}")

    def restyle(self) -> None:
        """Re-read the theme tokens after a theme change (SPEC §7.1).

        Every colour this widget bakes in at build time goes through
        :meth:`set_accent`, so restyling *is* re-accenting.
        """
        self.set_accent(self._accent)

    def set_slider_from_value(self, hz: float) -> None:
        self._slider.setValue(_hz_to_slider(hz))

    def nudge(self, delta: float) -> None:
        """Move by ``delta`` Hz, rounded to the 0.1 grid."""
        self.set_value(round(self._hz + float(delta), 1))

    def focus_spin(self) -> None:
        """Move keyboard focus into the numeric field (channel switch)."""
        self._spin.setFocus(Qt.FocusReason.OtherFocusReason)

    def focusSlider(self) -> None:  # noqa: N802 - Qt naming
        self._slider.setFocus(Qt.FocusReason.OtherFocusReason)

    # ----------------------------------------------------------------- private

    def _sync_widgets(self) -> None:
        """Push ``self._hz`` into the widgets without re-entering the handlers."""
        self._syncing = True
        try:
            self._display.setText(f"{self._hz:.1f}")
            if abs(self._spin.value() - self._hz) > 1e-9:
                self._spin.setValue(self._hz)
            if self._slider.value() != _hz_to_slider(self._hz):
                self._slider.setValue(_hz_to_slider(self._hz))
        finally:
            self._syncing = False
        self._display.setAccessibleDescription(f"{self._hz:.1f} hertz")

    def _on_spin_changed(self, value: float) -> None:
        if self._syncing:
            return
        self.set_value(value)

    def _on_slider_changed(self, position: int) -> None:
        if self._syncing:
            return
        # Snap to the 0.1 grid so the text never disagrees with the slider.
        self.set_value(round(_slider_to_hz(position), 1))