"""Headphone / speaker status indicator for the status bar (SPEC §4.3, §7.2).

Always icon **and** text: colour is never the only carrier of meaning, and the
icon is painted with QPainter instead of being an emoji, because this is UI
chrome, not reference data (SPEC §7.3).
"""

from __future__ import annotations

from PySide6.QtCore import QRectF, QSize, Qt
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QHBoxLayout, QLabel, QSizePolicy, QWidget

from .. import theme

__all__ = ["StatusIndicator", "STATE_HEADPHONES", "STATE_SPEAKERS", "STATE_UNKNOWN"]

_CONTEXT = "StatusIndicator"

STATE_HEADPHONES = "headphones"
STATE_SPEAKERS = "speakers"
STATE_UNKNOWN = "unknown"


def tr(text: str) -> str:
    from ...i18n import tr as _tr

    return _tr(text, context=_CONTEXT)


def state_for_verdict(verdict: object) -> str:
    """Map a ``DeviceClass`` (or anything with ``.value``/``.name``) to a state.

    Duck-typed on purpose: the UI must not crash when the audio layer returns
    something unexpected — it degrades to "unknown".
    """
    value = str(getattr(verdict, "value", verdict) or "").lower()
    name = str(getattr(verdict, "name", "") or "").lower()
    for needle, state in (
        ("headphones", STATE_HEADPHONES),
        ("speakers", STATE_SPEAKERS),
        ("virtual", STATE_UNKNOWN),
        ("unknown", STATE_UNKNOWN),
    ):
        if needle in value or needle in name:
            return state
    return STATE_UNKNOWN


class _StatusGlyph(QWidget):
    """A small painted glyph: check, warning triangle or question mark."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._color = QColor(theme.color("muted-fg"))
        self._kind = STATE_UNKNOWN
        self.setFixedSize(QSize(20, 20))
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def set_status(self, kind: str, color: str) -> None:
        self._kind = kind
        self._color = QColor(color)
        self.setAccessibleName("")
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.translate(0.5, 0.5)
        side = min(self.width(), self.height()) - 1.0
        box = QRectF(0.0, 0.0, side, side)
        colour = self._color
        pen = QPen(colour, 1.8)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)

        if self._kind == STATE_HEADPHONES:
            # Filled disc + tick: an unambiguous "yes".
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(colour)
            painter.drawEllipse(box)
            tick = QPainterPath()
            tick.moveTo(box.left() + box.width() * 0.28, box.center().y())
            tick.lineTo(box.left() + box.width() * 0.45, box.bottom() - box.height() * 0.30)
            tick.lineTo(box.right() - box.width() * 0.26, box.top() + box.height() * 0.30)
            painter.setPen(QPen(QColor("#FFFFFF"), 2.0, Qt.PenStyle.SolidLine,
                                Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawPath(tick)
        elif self._kind == STATE_SPEAKERS:
            # Warning triangle with an exclamation mark.
            path = QPainterPath()
            path.moveTo(box.center().x(), box.top() + 1.5)
            path.lineTo(box.right() - 1.0, box.bottom() - 1.0)
            path.lineTo(box.left() + 1.0, box.bottom() - 1.0)
            path.closeSubpath()
            painter.setBrush(colour)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.drawPath(path)
            painter.setPen(QPen(QColor("#FFFFFF"), 1.7, Qt.PenStyle.SolidLine,
                                Qt.PenCapStyle.RoundCap))
            painter.drawLine(
                int(box.center().x()), int(box.top() + box.height() * 0.38),
                int(box.center().x()), int(box.top() + box.height() * 0.66),
            )
            painter.drawPoint(int(box.center().x()), int(box.top() + box.height() * 0.80))
        else:
            # Question mark in a ring.
            painter.setPen(pen)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawEllipse(box.adjusted(1.0, 1.0, -1.0, -1.0))
            font = self.font()
            font.setPixelSize(13)
            font.setBold(True)
            painter.setFont(font)
            painter.setPen(colour)
            painter.drawText(box, Qt.AlignmentFlag.AlignCenter, "?")


class StatusIndicator(QWidget):
    """Icon + text showing which kind of output device is in use."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._state = STATE_UNKNOWN
        self._device_name = ""

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(theme.SPACE_SM)

        self._glyph = _StatusGlyph(self)
        self._label = QLabel(self)
        self._label.setFont(theme.font("body"))
        self._label.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred
        )

        layout.addWidget(self._glyph)
        layout.addWidget(self._label)

        self.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        self.setAccessibleName(tr("Audio output status"))
        self.set_state(STATE_UNKNOWN)  # also installs the tooltip

    # ------------------------------------------------------------------ state

    def state(self) -> str:
        """Current state: ``headphones``/``speakers``/``unknown``."""
        return self._state

    def text(self) -> str:
        """The visible text, exposed for tests and for the status message."""
        return self._label.text()

    def retranslate(self) -> None:
        """Re-read the label and tooltip after a language switch."""
        self.setAccessibleName(tr("Audio output status"))
        self.set_state(self._state, self._device_name)

    def set_state(self, state: str, device_name: str | None = None) -> None:
        state = state if state in (STATE_HEADPHONES, STATE_SPEAKERS) else STATE_UNKNOWN
        self._state = state
        self._device_name = str(device_name or "")

        if state == STATE_HEADPHONES:
            label = tr("Headphones detected")
            token = "accent-strong"
            description = tr("Binaural beats are rendered correctly.")
        elif state == STATE_SPEAKERS:
            label = tr("Speakers detected — binaural beats need headphones")
            token = "warning-text"
            description = tr(
                "On speakers the two tones mix in the air, so the beat disappears. "
                "Use headphones for the effect."
            )
        else:
            label = tr("Unknown device")
            token = "muted-fg"
            description = tr("Could not identify the audio output device.")

        self._label.setText(label)
        colour = theme.color(token)
        self._label.setStyleSheet(f"color: {colour};")
        self._glyph.set_status(state, colour)
        self.setToolTip(self._tooltip())
        self.setAccessibleDescription(f"{label}. {description}")

    def set_report(self, report: object | None) -> None:
        """Update straight from a ``HeadphoneReport`` (or ``None``)."""
        if report is None:
            self.set_state(STATE_UNKNOWN)
            return
        verdict = getattr(report, "verdict", report)
        device = getattr(report, "device", None)
        name = getattr(device, "name", "") if device is not None else ""
        state = state_for_verdict(verdict)
        # A positive perceptual L/R answer beats a pessimistic guess.
        if bool(getattr(report, "is_headphones", False)):
            state = STATE_HEADPHONES
        self.set_state(state, name)

    # ----------------------------------------------------------------- private

    def _tooltip(self) -> str:
        base = self._label.text() if self._label.text() else self._state
        if self._device_name:
            return f"{base} — {self._device_name}"
        return base