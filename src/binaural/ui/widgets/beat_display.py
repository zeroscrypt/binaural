"""The BEAT / CARRIER card (SPEC F1, §7 "Главное окно").

Live difference and mean, plus the beat visualisation: a ring that pulses at the
difference frequency. When the OS asks for reduced motion the ring stays at a
fixed size and opacity, and a static note appears instead (SPEC §7.2).
"""

from __future__ import annotations

import math

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import (
    QCheckBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from ...core.oscillator import RECOMMENDED_BEAT_HZ, beat_frequency, carrier_frequency
from .. import theme

__all__ = ["BeatDisplay"]

_CONTEXT = "BeatDisplay"

#: Below this the pulse is invisible; above it, too fast to be pleasant.
MIN_PULSE_HZ = 0.5
MAX_PULSE_HZ = 16.0
FRAME_MS = 33  # ~30 fps is plenty for a slow pulse


def tr(text: str, *args: str) -> str:
    """Translate then fill %1..%n, the lupdate-friendly Qt idiom."""
    from ...i18n import tr as _tr

    return _tr(text, *args, context=_CONTEXT)


def _fmt(hz: float) -> str:
    return f"{hz:.1f}"


class _BeatPulse(QWidget):
    """The pulsing ring; its phase is driven by :class:`BeatDisplay`."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._amplitude = 0.0
        self._static = True
        self._static_amplitude = 0.0
        self._base = QColor(theme.color("primary"))
        self._edge = QColor(theme.color("secondary"))
        self.setFixedSize(76, 76)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def set_colors(self, base: str, edge: str) -> None:
        self._base = QColor(theme.color(base))
        self._edge = QColor(theme.color(edge))
        self.update()

    def set_animated(self, animated: bool, playing: bool) -> None:
        """Switch between the animated and the static indicator."""
        self._static = not animated
        # Park at a readable middle size so the card still reads as "active".
        self._static_amplitude = 0.5 if playing else 0.0
        if self._static:
            self._amplitude = self._static_amplitude
        self.setAccessibleName(tr("Static beat indicator") if self._static else tr("Pulsing beat indicator"))
        self.update()

    def tick(self, phase: float) -> None:
        """One frame of the pulse; ``phase`` is a 0..1 fraction of a beat cycle."""
        self._amplitude = 0.5 - 0.5 * math.cos(math.tau * (phase % 1.0))
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.translate(0.5, 0.5)
        side = min(self.width(), self.height()) - 1.0
        cx, cy = side / 2.0, side / 2.0
        outer = side / 2.0 - 2.0
        inner = outer * 0.34

        painter.setBrush(Qt.BrushStyle.NoBrush)
        # Concentric arcs, primary/secondary alternating: two ear tones merging
        # into a single virtual tone.
        for index in range(3):
            fraction = (index + 1) / 3.0
            radius = inner + (outer - inner) * fraction
            pen = QPen(self._base if index % 2 == 0 else self._edge)
            pen.setWidthF(1.6)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            painter.setPen(pen)
            box = int(radius * 2)
            painter.drawArc(
                int(cx - radius), int(cy - radius), box, box,
                30 * 16 * (index + 1), -140 * 16,
            )

        amplitude = self._static_amplitude if self._static else self._amplitude
        core = inner + (outer - inner) * (0.15 + 0.85 * amplitude)
        pen = QPen(self._base)
        pen.setWidthF(3.0)
        painter.setPen(pen)
        painter.drawEllipse(int(cx - core), int(cy - core), int(core * 2), int(core * 2))

        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(self._edge)
        dot = core * 0.42
        painter.drawEllipse(int(cx - dot), int(cy - dot), int(dot * 2), int(dot * 2))


class BeatDisplay(QFrame):
    """Difference and carrier, live, with the out-of-range hint below.

    Also carries the SPEC §7 **Lock difference** checkbox. It sits next to the ``BEAT``
    read-out rather than in the transport row, because it belongs to the difference it
    protects — and the difference stays an *indicator*: the card has no editable field, so
    there is nowhere to type a difference that would contradict the pair.
    """

    #: The user ticked or cleared the box. Never sent by :meth:`set_locked`, so restoring a
    #: session stays silent — the same rule the frequency controls follow.
    lockToggled = Signal(bool)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("card")
        self.setProperty("role", "card")
        self._left_hz = 0.0
        self._right_hz = 0.0
        self._beat_hz = 0.0
        self._carrier_hz = 0.0
        self._phase = 0.0
        self._playing = False
        self._reduced = theme.reduced_motion()
        self._boundary_note: str | None = None
        self._syncing_lock = False

        layout = QHBoxLayout(self)
        layout.setContentsMargins(theme.SPACE_XL, theme.SPACE_LG, theme.SPACE_XL, theme.SPACE_LG)
        layout.setSpacing(theme.SPACE_XL)

        self._pulse = _BeatPulse(self)
        layout.addWidget(self._pulse, 0, Qt.AlignmentFlag.AlignVCenter)

        metrics = QVBoxLayout()
        metrics.setSpacing(theme.SPACE_SM)
        self._beat_value, self._beat_caption, self._beat_unit = self._metric_row(
            metrics, tr("BEAT"), "primary"
        )

        # SPEC §7's "Lock difference", between the difference it protects and the carrier.
        self._lock = QCheckBox(tr("Lock difference"), self)
        self._lock.setMinimumHeight(44)  # §7.2: a 44 px click target
        self._lock.toggled.connect(self._on_lock_toggled)
        self._lock.setAccessibleName(tr("Lock difference"))
        self._lock.setAccessibleDescription(
            tr(
                "Keeps the difference between the two frequencies. Changing one channel "
                "moves the other by the same amount, so the beat stays the same."
            )
        )
        metrics.addWidget(self._lock, 0, Qt.AlignmentFlag.AlignLeft)

        self._carrier_value, self._carrier_caption, self._carrier_unit = (
            self._metric_row(metrics, tr("CARRIER"), "secondary")
        )

        self._hint = QLabel(self)
        self._hint.setProperty("role", "caption")
        self._hint.setFont(theme.font("caption"))
        self._hint.setWordWrap(True)
        self._hint.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        metrics.addWidget(self._hint)
        metrics.addStretch(1)
        layout.addLayout(metrics, 1)

        self._timer = QTimer(self)
        self._timer.setInterval(FRAME_MS)
        self._timer.timeout.connect(self._on_tick)

        self.setAccessibleName(tr("Beat and carrier frequencies"))
        # Tall enough for the pulse, both metric rows, the §7 checkbox and the hint.
        self.setMinimumHeight(180)
        self.update_values(0.0, 0.0)
        self._apply_hint()

    # ------------------------------------------------------------------ state

    def beat_hz(self) -> float:
        """``|fL - fR|``."""
        return self._beat_hz

    def carrier_hz(self) -> float:
        """``(fL + fR) / 2``."""
        return self._carrier_hz

    def hint_text(self) -> str:
        return self._hint.text()

    def is_hint_visible(self) -> bool:
        """True when the difference is outside the typical perception range."""
        return not self._hint.isHidden()

    def is_reduced_motion(self) -> bool:
        return self._reduced

    # ------------------------------------------------- lock difference (SPEC §7)

    def is_locked(self) -> bool:
        """True while the box is ticked, as the user sees it."""
        return self._lock.isChecked()

    def lock_checkbox(self) -> QCheckBox:
        """The checkbox itself, so a test presses the control a user presses."""
        return self._lock

    def set_locked(self, locked: bool) -> None:
        """Tick or clear the box without telling anyone — used while restoring."""
        self._syncing_lock = True
        try:
            self._lock.setChecked(bool(locked))
        finally:
            self._syncing_lock = False

    def show_boundary_note(self, key: str | None) -> None:
        """Say, in the existing hint slot, that the lock stopped a channel at the limit.

        The same orange hint the §F1 out-of-range message uses: a user who cannot drag the
        slider further deserves the same kind of "here is why" as one whose beat is
        inaudible, and a second warning style for it would be worse. Pass ``None`` to go
        back to the ordinary §F1 rule.

        ``key`` is the **English source string**, not translated text: the card is built
        once and lives for the whole session, so ``retranslate()`` has to be able to
        render the note again in the new language (SPEC §7.4).
        """
        self._boundary_note = key
        self._apply_hint()

    def is_showing_boundary_note(self) -> bool:
        """True while the hint slot carries the boundary note rather than the §F1 text."""
        return self._boundary_note is not None

    def _on_lock_toggled(self, checked: bool) -> None:
        if self._syncing_lock:
            return
        self.lockToggled.emit(bool(checked))

    def set_reduced_motion(self, reduced: bool) -> None:
        """Reduced motion keeps a static indicator instead of a pulse (SPEC §7.2)."""
        self._reduced = bool(reduced)
        self._pulse.set_animated(not self._reduced and self._playing, self._playing)
        if self._playing and self._reduced:
            self._timer.stop()
            self._phase = 0.0
            self._pulse.tick(0.0)
        self._apply_hint()

    def retranslate(self) -> None:
        """Re-read every caption after a language switch (SPEC §7).

        The card is built once, so the labels only change when the runtime
        language does; ``update_values`` re-derives the accessible strings and
        ``_apply_hint`` the current hint.
        """
        self._beat_caption.setText(tr("BEAT"))
        self._carrier_caption.setText(tr("CARRIER"))
        for unit in (self._beat_unit, self._carrier_unit):
            unit.setText(tr("Hz"))
        self._lock.setText(tr("Lock difference"))
        self._lock.setAccessibleName(tr("Lock difference"))
        self._lock.setAccessibleDescription(
            tr(
                "Keeps the difference between the two frequencies. Changing one channel "
                "moves the other by the same amount, so the beat stays the same."
            )
        )
        self.setAccessibleName(tr("Beat and carrier frequencies"))
        self._pulse.set_animated(not self._reduced and self._playing, self._playing)
        self.update_values(self._left_hz, self._right_hz)

    def set_playing(self, playing: bool) -> None:
        """The pulse runs only while audio plays."""
        self._playing = bool(playing)
        self._pulse.set_animated(not self._reduced and self._playing, self._playing)
        if self._playing and not self._reduced:
            self._timer.start()
        else:
            self._timer.stop()
            self._phase = 0.0
            self._pulse.tick(0.0)
        self._apply_hint()

    def update_values(self, left_hz: float, right_hz: float) -> None:
        """Recompute and repaint from the two channel frequencies."""
        self._left_hz = float(left_hz)
        self._right_hz = float(right_hz)
        self._beat_hz = beat_frequency(self._left_hz, self._right_hz)
        self._carrier_hz = carrier_frequency(self._left_hz, self._right_hz)

        self._beat_value.setText(_fmt(self._beat_hz))
        self._carrier_value.setText(_fmt(self._carrier_hz))
        self._beat_value.setAccessibleDescription(
            tr("Difference between the channels: %1 hertz", _fmt(self._beat_hz))
        )
        self._carrier_value.setAccessibleDescription(
            tr("Mean of the two channels: %1 hertz", _fmt(self._carrier_hz))
        )
        self.setAccessibleDescription(
            tr(
                "Beat %1 hertz, carrier %2 hertz",
                _fmt(self._beat_hz),
                _fmt(self._carrier_hz),
            )
        )
        self._pulse.set_colors("primary", "secondary")
        self._apply_hint()

    # ----------------------------------------------------------------- private

    def _metric_row(
        self, parent_layout: QVBoxLayout, title: str, token: str
    ) -> tuple[QLabel, QLabel, QLabel]:
        """One metric line: ``(value, caption, unit)`` labels, kept for retranslate."""
        table = theme.DARK if theme.prefers_dark() else theme.LIGHT
        row = QHBoxLayout()
        row.setSpacing(theme.SPACE_SM)
        caption = QLabel(self)
        caption.setFont(theme.font("title"))
        caption.setText(title)
        caption.setMinimumWidth(96)
        value = QLabel(self)
        value.setProperty("role", "metric")
        value.setFont(theme.font("metric"))
        value.setText("0.0")
        value.setStyleSheet(f"color: {theme.color(token)};")
        unit = QLabel(self)
        unit.setFont(theme.font("body"))
        unit.setText(tr("Hz"))
        unit.setStyleSheet(f"color: {theme.color('muted-fg')};")
        # "BEAT"/"CARRIER" are body-size captions: they need the 4.5:1 shade.
        caption_colour = table.get(f"{token}-text", theme.color(token))
        caption.setStyleSheet(f"color: {caption_colour};")
        row.addWidget(caption, 0, Qt.AlignmentFlag.AlignBottom)
        row.addWidget(value, 0, Qt.AlignmentFlag.AlignBottom)
        row.addWidget(unit, 0, Qt.AlignmentFlag.AlignBottom)
        row.addStretch(1)
        parent_layout.addLayout(row)
        return value, caption, unit

    def _beat_out_of_range(self) -> bool:
        low, high = RECOMMENDED_BEAT_HZ
        return not (low <= self._beat_hz <= high)

    def _apply_hint(self) -> None:
        # A boundary stop is news from this very edit, so it wins over the standing §F1
        # hint: the user is dragging *right now* and needs to know why the slider stopped.
        # Both are the same kind of message, so both use the same slot.
        if self._boundary_note is not None:
            self._hint.setText(tr(self._boundary_note))
            self._hint.setStyleSheet(f"color: {theme.color('warning-text')};")
            self._hint.setAccessibleName(tr("Warning"))
            self._hint.setVisible(True)
            return
        if self._playing and self._reduced:
            self._hint.setText(
                tr("Reduced motion is on — the beat indicator stays still.")
            )
            self._hint.setStyleSheet(f"color: {theme.color('muted-fg')};")
            self._hint.setAccessibleName(tr("Note"))
            self._hint.setVisible(True)
            return
        if not self._beat_out_of_range():
            self._hint.setVisible(False)
            return
        low, high = RECOMMENDED_BEAT_HZ
        self._hint.setText(
            tr(
                "Difference is %1 Hz — outside the %2–%3 Hz range the ear usually "
                "perceives as a beat.",
                _fmt(self._beat_hz),
                _fmt(low),
                _fmt(high),
            )
        )
        self._hint.setStyleSheet(f"color: {theme.color('warning-text')};")
        self._hint.setAccessibleName(tr("Warning"))
        self._hint.setVisible(True)

    def _on_tick(self) -> None:
        beat = self._beat_hz
        if beat < MIN_PULSE_HZ:
            # Below the perceptible floor: hold a static ring.
            self._pulse.tick(0.25)
            return
        rate = min(beat, MAX_PULSE_HZ)
        self._phase = (self._phase + rate * FRAME_MS / 1000.0) % 1.0
        self._pulse.tick(self._phase)