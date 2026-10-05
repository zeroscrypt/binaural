"""Per-ear frequency control (SPEC F1).

One reusable widget drives either channel: caption, big display number, a
0.1 Hz ``QDoubleSpinBox`` for exact entry and a logarithmic slider for coarse
sweeps. The two channels are fully independent — nothing here reads or writes
the other side.
"""

from __future__ import annotations

import math

from PySide6.QtCore import QLocale, QPoint, QRect, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPen, QPolygonF
from PySide6.QtWidgets import (
    QAbstractSpinBox,
    QDoubleSpinBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QSlider,
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


STEPPER_WIDTH = 26


class _FreqSpinBox(QDoubleSpinBox):
    """A spinbox that paints its own stepper.

    Qt's native stepper arrows turn into unreadable blobs once the widget has a
    custom background, so the two triangles are drawn here. Clicking and
    auto-repeat keep working through the built-in stepBySlot behaviour.
    """

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.NoButtons)
        self._arrow_color = QColor(theme.color("muted-fg"))
        self._arrow_hover = QColor(theme.color("foreground"))
        self._hover_step = 0  # 0 none, 1 up, 2 down
        self.setMouseTracking(True)

    def set_arrow_color(self, color: str) -> None:
        self._arrow_color = QColor(color)
        self.update()

    def step_area(self, up: bool) -> QRect:
        """Hit rect of one half of the stepper, in widget coordinates."""
        width = min(STEPPER_WIDTH, max(24, self.width() // 6))
        box = QRect(
            self.width() - width - 1, 1, width, self.height() - 2
        )
        if up:
            box.setHeight(box.height() // 2)
        else:
            box.setTop(box.top() + box.height() // 2)
        return box

    def mouseMoveEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        self._hover_step = 0
        if self.step_area(True).contains(event.position().toPoint()):
            self._hover_step = 1
        elif self.step_area(False).contains(event.position().toPoint()):
            self._hover_step = 2
        self.update()
        super().mouseMoveEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        self._hover_step = 0
        self.update()
        super().leaveEvent(event)

    def mousePressEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        point = event.position().toPoint()
        if event.button() == Qt.MouseButton.LeftButton:
            if self.step_area(True).contains(point):
                self.stepBy(1)
                event.accept()
                return
            if self.step_area(False).contains(point):
                self.stepBy(-1)
                event.accept()
                return
        super().mousePressEvent(event)

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        super().paintEvent(event)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        colour = self._arrow_hover if self._hover_step else self._arrow_color

        def triangle(box: QRect, up: bool) -> None:
            width = 9
            height = 5
            cx = box.center().x()
            cy = box.center().y()
            if up:
                points = [
                    QPoint(cx, cy - height),
                    QPoint(cx - width, cy + height - 1),
                    QPoint(cx + width, cy + height - 1),
                ]
            else:
                points = [
                    QPoint(cx, cy + height),
                    QPoint(cx - width, cy - height + 1),
                    QPoint(cx + width, cy - height + 1),
                ]
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(colour)
            painter.drawPolygon(QPolygonF(points))

        if self.isEnabled():
            triangle(self.step_area(True), True)
            triangle(self.step_area(False), False)

        # A hairline separates the stepper from the text, matching the QSS edge.
        pen = QPen(QColor(theme.color("border")))
        pen.setWidthF(1.0)
        painter.setPen(pen)
        top = self.step_area(True)
        painter.drawLine(top.left(), top.bottom(), top.right(), top.bottom())
        painter.drawLine(
            top.right(), top.top() - 1, top.right(), self.height() - 1
        )


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
        # Room for the hand-drawn stepper on the right.
        self._spin.setStyleSheet(
            f"padding-right: {STEPPER_WIDTH + 6}px;"
        )
        self._spin.setAlignment(Qt.AlignmentFlag.AlignLeft)
        self._spin.setFont(theme.font("title"))
        self._spin.setMinimumHeight(44)
        layout.addWidget(self._spin)

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
        """Colour token for this channel: ``primary`` = left, ``secondary`` = right."""
        self._accent = token
        colour = theme.color(token)
        table = theme.DARK if theme.prefers_dark() else theme.LIGHT
        # Captions are 16px body text and need 4.5:1; only the 42px number is
        # allowed the weaker SPEC shade.
        text_colour = table.get(f"{token}-text", colour)
        self._swatch.set_color(colour)
        self._spin.set_arrow_color(colour)
        self._caption.setStyleSheet(f"color: {text_colour};")
        self._display.setStyleSheet(f"color: {colour};")
        self._slider.setStyleSheet(
            f"QSlider::sub-page:horizontal {{ background: {colour}; }}"
            f" QSlider::handle:horizontal {{ border: 2px solid {colour}; }}"
        )

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