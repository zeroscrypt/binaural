"""Perceptual left/right channel test (SPEC §4.2).

The dialog owns the *question*, the audio device owns the sound: it drives
:class:`~binaural.audio.headphones.LrTestSequence`, shows the current step and
collects the answer as an :class:`LrTestResult`.

Design notes:

* ``RIGHT_THEN_LEFT`` is the important answer — it means the channels are
  swapped and the caller must remember that (``HeadphoneReport.channels_swapped``).
* The sequence is always stopped when the dialog closes, so no tone can outlive
  the dialog.
* A missing or broken engine never crashes the test: it degrades to a written
  error message plus a still-usable answer.
* Nothing here animates. The status is static text with a wording, which is the
  reduced-motion behaviour of SPEC §7.2 by construction.
"""

from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import QDialog, QVBoxLayout, QWidget

from binaural.audio.headphones import (
    LR_TEST_FREQ_HZ,
    LR_TEST_GAP_SECONDS,
    LR_TEST_TONE_SECONDS,
    STEP_ANSWER,
    STEP_IDLE,
    STEP_LEFT,
    STEP_PAUSE,
    STEP_RIGHT,
    LrTestResult,
    LrTestSequence,
)

from . import (
    SPACE_LG,
    SPACE_MD,
    SPACE_SM,
    button_row,
    make_button,
    make_label,
    make_panel,
    panel_layout,
    refresh_style,
    set_role,
    style_dialog,
    tr,
)

__all__ = ["LrTestDialog", "STEP_TEXT"]

_INSTRUCTION = (
    "You will hear a tone in one ear, then a pause, then a tone in the other ear. "
    "Tell us what you heard."
)
_QUESTION = "What did you hear?"
_READY = 'Ready. Press "Play test" and listen.'
_ANSWERED = "Answer recorded."

#: Machine-readable step id -> (user text, label role, status detail).
#: The status carries an icon and words, never colour alone (SPEC §7.2).
STEP_TEXT: dict[str, tuple[str, str, str]] = {
    STEP_IDLE: (_READY, "muted", "\u25cb"),
    STEP_LEFT: ("Playing in LEFT ear\u2026", "heading", "\u25c0"),
    STEP_PAUSE: ("Pause\u2026", "muted", "\u2014"),
    STEP_RIGHT: ("Playing in RIGHT ear\u2026", "heading", "\u25b6"),
    STEP_ANSWER: (_QUESTION, "heading", "?"),
}

#: The three answers of SPEC §4.2 with a one-line explanation for the tooltip.
_ANSWER_TEXTS: dict[LrTestResult, tuple[str, str]] = {
    LrTestResult.LEFT_THEN_RIGHT: (
        "Left \u2192 Right",
        "The first tone came from the left ear: the channels are correct.",
    ),
    LrTestResult.RIGHT_THEN_LEFT: (
        "Right \u2192 Left",
        "The channels are swapped. The application will swap them for you.",
    ),
    LrTestResult.INDETERMINATE: (
        "Both at once / Can't tell",
        "Sounds like speakers or a mono mixer, where no beat can be perceived.",
    ),
}

_CONFIRMATIONS: dict[LrTestResult, tuple[str, str]] = {
    LrTestResult.LEFT_THEN_RIGHT: ("Headphones confirmed, the channels are correct.", "ok"),
    LrTestResult.RIGHT_THEN_LEFT: (
        "Headphones confirmed, but the channels are swapped. Binaural will swap them "
        "so the beat stays on the side you expect.",
        "warning",
    ),
    LrTestResult.INDETERMINATE: (
        "No clear answer. This usually means speakers or a mono mixer.",
        "danger",
    ),
}

_NO_ENGINE_ERROR = (
    "No audio output is available, so the test cannot be played. Check your sound "
    "settings and try again."
)
_ENGINE_IDLE_WARNING = (
    "The audio output did not start. Check the volume and the selected output device."
)
_UNKNOWN_ERROR = "Unknown audio error."


def _coerce(result: object) -> LrTestResult:
    """Accept a LrTestResult, its value, or anything else at all."""
    if isinstance(result, LrTestResult):
        return result
    try:
        return LrTestResult(result)
    except (ValueError, TypeError):
        return LrTestResult.INDETERMINATE


class LrTestDialog(QDialog):
    """Plays the test sequence and asks the question of SPEC §4.2."""

    #: Emitted once with the user's answer, just before the dialog closes.
    answered = Signal(object)

    def __init__(
        self,
        engine: object | None = None,
        parent: QWidget | None = None,
        *,
        tone_seconds: float = LR_TEST_TONE_SECONDS,
        gap_seconds: float = LR_TEST_GAP_SECONDS,
        freq_hz: float = LR_TEST_FREQ_HZ,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("Left / right channel test"))
        self.setAccessibleName(tr("Left / right channel test"))
        self.setModal(True)
        self.resize(520, 480)

        self._engine = engine
        self._tone_seconds = tone_seconds
        self._gap_seconds = gap_seconds
        self._freq_hz = freq_hz
        self._sequence: LrTestSequence | None = None
        self._result: LrTestResult | None = None
        self._error = ""
        self._finished = False

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        root.addWidget(make_label(tr("Left / right channel test"), role="heading"))
        self._instruction_label = make_label(tr(_INSTRUCTION), word_wrap=True)
        root.addWidget(self._instruction_label)

        self._status_panel = make_panel()
        status_layout = panel_layout(self._status_panel, spacing=SPACE_SM)
        # The status line reads as "now playing" plus what the buttons mean, so
        # the progress is worded rather than animated (reduced-motion, SPEC §7.2).
        self._step_label = make_label(role="heading", word_wrap=True)
        status_layout.addWidget(self._step_label)
        self._tone_label = make_label(role="caption")
        status_layout.addWidget(self._tone_label)
        root.addWidget(self._status_panel)

        self._error_label = make_label(role="danger", word_wrap=True)
        self._error_label.setVisible(False)
        root.addWidget(self._error_label)

        self._confirmation_label = make_label(role="muted", word_wrap=True)
        self._confirmation_label.setVisible(False)
        root.addWidget(self._confirmation_label)

        self._answer_panel = make_panel()
        self._answer_panel.setVisible(False)
        answer_layout = panel_layout(self._answer_panel, spacing=SPACE_SM)
        self._answer_buttons: dict[LrTestResult, QWidget] = {}
        for result in (
            LrTestResult.LEFT_THEN_RIGHT,
            LrTestResult.RIGHT_THEN_LEFT,
            LrTestResult.INDETERMINATE,
        ):
            button = self._build_answer_button(result)
            self._answer_buttons[result] = button
            answer_layout.addWidget(button)
        # The question sits with the buttons it belongs to, so the answer panel
        # reads as one block when it appears.
        self._answer_panel.setAccessibleName(tr(_QUESTION))
        root.addWidget(self._answer_panel)

        self._play_button = make_button(
            tr("Play test"),
            variant="primary",
            on_click=self.start_test,
            min_width=160,
            accessible_name=tr("Play the left/right test sequence"),
            tooltip=tr("A short tone in the left ear, a pause, then the right ear."),
        )
        self._play_button.setDefault(True)

        self._close_button = make_button(
            tr("Close"),
            on_click=self.reject,
            min_width=120,
            accessible_name=tr("Close the test without answering"),
        )

        row = button_row()
        row.addWidget(self._play_button)
        row.addStretch(1)
        row.addWidget(self._close_button)
        root.addLayout(row)

        # Tab order: search-like flow does not apply here, the primary action
        # comes first and the answer buttons follow once they exist.
        self.setTabOrder(self._play_button, self._close_button)

        self._set_step(STEP_IDLE)
        self._connect_engine_errors()
        style_dialog(self)
        self._play_button.setFocus()

    # ------------------------------------------------------------------ build

    def _build_answer_button(self, result: LrTestResult) -> QWidget:
        text, hint = _ANSWER_TEXTS[result]
        button = make_button(
            tr(text),
            variant="channel" if result is not LrTestResult.INDETERMINATE else None,
            on_click=self._answer_click_handler(result),
            min_width=280,
            tooltip=tr(hint),
            accessible_name=tr("{answer}. {hint}").format(answer=tr(text), hint=tr(hint)),
        )
        button.setVisible(False)
        return button

    def _answer_click_handler(self, result: LrTestResult):
        def handler() -> None:
            self.answer(result)

        return handler

    def _connect_engine_errors(self) -> None:
        """Surface engine failures as text; a broken engine never crashes us."""
        signal = getattr(self._engine, "error", None)
        if signal is None:
            return
        try:
            signal.connect(self._on_engine_error)
        except Exception:  # pragma: no cover - exotic engine stubs
            return

    def _on_engine_error(self, message: str) -> None:
        self._show_error(str(message).strip() or tr(_UNKNOWN_ERROR))

    # ----------------------------------------------------------------- public

    @property
    def sequence(self) -> LrTestSequence | None:
        """The test sequence; kept after ``stop()`` so callers can inspect it."""
        return self._sequence

    @property
    def lr_result(self) -> LrTestResult | None:
        """The user's answer, ``None`` until they answered.

        Named ``lr_result`` and not ``result`` on purpose: ``result()`` is the
        standard QDialog method and must keep working for the caller.
        """
        return self._result

    @property
    def channels_swapped(self) -> bool:
        """True for "Right -> Left": the app must swap the channels."""
        return self._result is LrTestResult.RIGHT_THEN_LEFT

    @property
    def is_headphones(self) -> bool:
        return self._result in (LrTestResult.LEFT_THEN_RIGHT, LrTestResult.RIGHT_THEN_LEFT)

    @property
    def error_text(self) -> str:
        return self._error

    @property
    def has_error(self) -> bool:
        return bool(self._error)

    @property
    def step_text(self) -> str:
        return self._step_label.text()

    @property
    def asking(self) -> bool:
        """True while the question and its three answers are on screen.

        ``isHidden`` reports the explicit state, which stays correct even when
        the dialog has not been shown yet (tests, embedding).
        """
        return not self._answer_panel.isHidden()

    def answer_button(self, result: object) -> QWidget:
        """The button reporting ``result`` — handy for keyboard-driven tests."""
        return self._answer_buttons[_coerce(result)]

    def start_test(self) -> None:
        """Play the sequence: left tone, pause, right tone, then the question."""
        self._clear_error()
        if self._engine is None:
            self._show_error(tr(_NO_ENGINE_ERROR))
            return
        sequence = self._ensure_sequence()
        if sequence is None:
            self._show_error(tr(_NO_ENGINE_ERROR))
            return
        try:
            sequence.begin()
        except Exception as exc:  # pragma: no cover - defensive
            self._show_error(tr("Could not start the test: {error}").format(error=exc))
            return
        self._set_step(sequence.step)
        if getattr(self._engine, "is_running", True) is False:
            # The engine took the call but produced no sound: say so in words.
            self._show_error(tr(_ENGINE_IDLE_WARNING))

    def answer(self, result: object) -> None:
        """Feed the answer in (enum, value or button click) and finish."""
        if self._finished:
            return
        value = _coerce(result)
        if self._sequence is not None:
            try:
                # answer() emits finished() -> _on_sequence_finished() -> _finish().
                self._sequence.answer(value)
                return
            except Exception:  # pragma: no cover - defensive
                pass
        self._finish(value)

    def stop(self) -> None:
        """Stop playback without answering; safe to call repeatedly."""
        sequence = self._sequence
        if sequence is None:
            return
        try:
            sequence.stop()
        except Exception:  # pragma: no cover - defensive
            return

    # ------------------------------------------------------------- life cycle

    def reject(self) -> None:
        self.stop()
        super().reject()

    def accept(self) -> None:
        self.stop()
        super().accept()

    def closeEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        # Escape, the window close button and Close must all stop the sound.
        self.stop()
        super().closeEvent(event)

    # ---------------------------------------------------------------- private

    def _ensure_sequence(self) -> LrTestSequence | None:
        if self._sequence is not None:
            return self._sequence
        try:
            sequence = LrTestSequence(
                self._engine,
                parent=self,
                freq_hz=self._freq_hz,
                tone_seconds=self._tone_seconds,
                gap_seconds=self._gap_seconds,
            )
        except Exception:  # pragma: no cover - defensive
            return None
        sequence.step_changed.connect(self._on_step_changed)
        sequence.finished.connect(self._on_sequence_finished)
        self._sequence = sequence
        return sequence

    def _on_step_changed(self, step: str) -> None:
        self._set_step(step)

    def _on_sequence_finished(self, result: object) -> None:
        self._finish(_coerce(result))

    def _set_step(self, step: str) -> None:
        text, role, icon = STEP_TEXT.get(step, STEP_TEXT[STEP_IDLE])
        self._step_label.setText(f"{icon}  {tr(text, 'LrTestStep')}")
        set_role(self._step_label, role)
        refresh_style(self._step_label)

        self._tone_label.setText(
            tr("Tone: {freq} Hz — one channel at a time, no beat").format(
                freq=f"{self._freq_hz:g}"
            )
        )

        asking = step == STEP_ANSWER
        self._answer_panel.setVisible(asking)
        for button in self._answer_buttons.values():
            button.setVisible(asking)
            button.setEnabled(True)
        self._play_button.setText(tr("Play test again") if asking else tr("Play test"))
        if asking:
            self._answer_buttons[LrTestResult.LEFT_THEN_RIGHT].setFocus()

    def _show_error(self, message: str) -> None:
        self._error = message
        self._error_label.setText(message)
        self._error_label.setVisible(True)

    def _clear_error(self) -> None:
        self._error = ""
        self._error_label.setVisible(False)

    def _finish(self, result: LrTestResult) -> None:
        if self._finished:
            return
        self._finished = True
        self._result = result
        self.stop()

        for button in self._answer_buttons.values():
            button.setEnabled(False)
        self._answer_panel.setVisible(False)

        text, role = _CONFIRMATIONS[result]
        self._confirmation_label.setText(tr(text, "LrTestResult"))
        set_role(self._confirmation_label, role)
        refresh_style(self._confirmation_label)
        self._confirmation_label.setVisible(True)

        self._step_label.setText(f"\u2713  {tr(_ANSWERED, 'LrTestStep')}")
        set_role(self._step_label, "ok")
        refresh_style(self._step_label)

        self.answered.emit(result)
        self.accept()
