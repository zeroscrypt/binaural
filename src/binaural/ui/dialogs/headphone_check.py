"""Startup headphone check (SPEC §4.3).

Shows the heuristic verdict, explains why headphones are a physical requirement
for binaural beats and offers the perceptual L/R test. It is a *dialog*, never
a wall: "Continue anyway" is always enabled (SPEC §4.3, CONTRACT §6), so a
failed or missing detection can never trap the user.

The caller keeps the outcome through three read-only properties:
``acknowledged``, ``report`` and ``lr_result``.
"""

from __future__ import annotations

from PySide6.QtWidgets import QDialog, QVBoxLayout, QWidget

from binaural.audio.headphones import (
    HeadphoneReport,
    LrTestResult,
    detect,
    with_lr_result,
)
from binaural.audio.platform.base import DeviceClass

from . import (
    SPACE_LG,
    SPACE_MD,
    SPACE_SM,
    SPACE_XS,
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
from .lr_test import LrTestDialog

__all__ = ["HeadphoneCheckDialog", "VERDICT_TEXT"]

_TITLE = "Headphones recommended"
_TITLE_OK = "Headphones detected"

_EXPLANATION = (
    "Binaural beats only work when each ear receives its own tone. On speakers the "
    "two frequencies mix in the air before reaching your ears, and the effect "
    "disappears. You can continue anyway — the app will keep showing a "
    "“Speakers detected” indicator in the status bar."
)
_HINT_RETRY = "This check can be repeated at any time from the Help menu."

#: DeviceClass -> (status icon, status text, label role). Colour is never the
#: only signal: every verdict carries an icon and words (SPEC §7.2).
VERDICT_TEXT: dict[DeviceClass, tuple[str, str, str]] = {
    DeviceClass.HEADPHONES: ("\u2713", "Headphones detected", "ok"),
    DeviceClass.SPEAKERS: ("\u26a0", "Speakers detected", "danger"),
    DeviceClass.VIRTUAL: ("\u25d0", "Virtual audio device — cannot tell what is playing", "warning"),
    DeviceClass.UNKNOWN: ("?", "Output device not recognised — run the L/R test", "warning"),
}

_VERDICT_LABEL: dict[DeviceClass, str] = {
    DeviceClass.HEADPHONES: "Headphones",
    DeviceClass.SPEAKERS: "Speakers",
    DeviceClass.VIRTUAL: "Virtual device",
    DeviceClass.UNKNOWN: "Unknown",
}

_CONFIDENCE_LABEL: dict[str, str] = {
    "high": "High",
    "medium": "Medium",
    "low": "Low",
}

_UNKNOWN_DEVICE = "Unknown output device"

_LR_RESULT_TEXT: dict[LrTestResult, tuple[str, str]] = {
    LrTestResult.LEFT_THEN_RIGHT: (
        "L/R test: Left \u2192 Right — headphones confirmed, channels correct.",
        "ok",
    ),
    LrTestResult.RIGHT_THEN_LEFT: (
        "L/R test: Right \u2192 Left — headphones confirmed, channels are swapped. "
        "Binaural will swap them when generating.",
        "warning",
    ),
    LrTestResult.INDETERMINATE: (
        "L/R test: both at once or unclear — this sounds like speakers or a mono mixer.",
        "danger",
    ),
}


def _unknown_report() -> HeadphoneReport:
    """Fallback when detection itself fails — never raise in the UI."""
    return HeadphoneReport(verdict=DeviceClass.UNKNOWN, device=None, confidence="low")


def _detect_safely() -> HeadphoneReport:
    try:
        return detect()
    except Exception:  # pragma: no cover - detection already swallows errors
        return _unknown_report()


class HeadphoneCheckDialog(QDialog):
    """Headphone check with a never-disabled "Continue anyway" (SPEC §4.3)."""

    def __init__(
        self,
        report: HeadphoneReport | None = None,
        engine: object | None = None,
        parent: QWidget | None = None,
        *,
        detect_now: bool = True,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr(_TITLE))
        self.setAccessibleName(tr(_TITLE))
        self.setModal(True)
        self.resize(560, 520)

        self._engine = engine
        self._acknowledged = False
        self._lr_result: LrTestResult | None = None

        if isinstance(report, HeadphoneReport):
            self._report = report
        elif detect_now:
            self._report = _detect_safely()
        else:
            self._report = _unknown_report()
        if self._report.lr_test is not None:
            self._lr_result = self._report.lr_test

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        self._headline_label = make_label(role="heading", word_wrap=True)
        root.addWidget(self._headline_label)

        self._status_panel = make_panel()
        status_layout = panel_layout(self._status_panel, spacing=SPACE_SM)
        self._status_label = make_label(word_wrap=True)
        status_layout.addWidget(self._status_label)
        self._detail_layout = QVBoxLayout()
        self._detail_layout.setContentsMargins(0, 0, 0, 0)
        self._detail_layout.setSpacing(SPACE_XS)
        status_layout.addLayout(self._detail_layout)
        root.addWidget(self._status_panel)

        self._explanation_label = make_label(tr(_EXPLANATION), word_wrap=True)
        root.addWidget(self._explanation_label)

        self._lr_label = make_label(word_wrap=True)
        self._lr_label.setVisible(False)
        root.addWidget(self._lr_label)

        self._lr_button = make_button(
            tr("Run L/R test"),
            variant="channel",
            on_click=self.run_lr_test,
            min_width=200,
            accessible_name=tr("Run the perceptual left/right channel test"),
            tooltip=tr("Plays a tone in the left ear, then the right ear, and asks what you heard."),
        )
        root.addWidget(self._lr_button)

        root.addWidget(make_label(tr(_HINT_RETRY), role="caption", word_wrap=True))

        self._retry_button = make_button(
            tr("Retry check"),
            on_click=self.retry,
            min_width=150,
            accessible_name=tr("Run the device check again"),
            tooltip=tr("Re-reads the default audio output device."),
        )

        # SPEC §4.3: "Continue anyway" works in every situation, so this button is
        # created enabled, never disabled and never used as a blocking gate.
        self._continue_button = make_button(
            tr("Continue anyway"),
            variant="primary",
            on_click=self._on_continue,
            min_width=200,
            accessible_name=tr("Continue anyway, even without confirmed headphones"),
            tooltip=tr("Nothing is blocked; the app will keep the speakers warning in the status bar."),
        )
        self._continue_button.setEnabled(True)
        self._continue_button.setDefault(True)
        self._continue_button.setAutoDefault(True)

        row = button_row()
        row.addWidget(self._retry_button)
        row.addStretch(1)
        row.addWidget(self._continue_button)
        root.addLayout(row)

        self.setTabOrder(self._lr_button, self._retry_button)
        self.setTabOrder(self._retry_button, self._continue_button)

        self._refresh()
        style_dialog(self)

    # ----------------------------------------------------------------- public

    @property
    def acknowledged(self) -> bool:
        """True when the user chose to continue (SPEC §4.3)."""
        return self._acknowledged

    def report(self) -> HeadphoneReport:
        """The current verdict, including the L/R test answer when present.

        A method, not a property, because the caller in ``main_window.py`` uses
        ``dialog.report()`` — and ``result()`` must keep its Qt meaning.
        """
        return self._report

    @property
    def headphone_report(self) -> HeadphoneReport:
        """Same as :meth:`report`, for attribute-style access."""
        return self._report

    @property
    def lr_result(self) -> LrTestResult | None:
        """The perceptual answer, ``None`` when the test was not run."""
        return self._lr_result

    @property
    def is_headphones(self) -> bool:
        return self._report.is_headphones

    @property
    def channels_swapped(self) -> bool:
        """True when the L/R test said "Right -> Left" (remember it!)."""
        return self._report.channels_swapped

    @property
    def status_text(self) -> str:
        """Icon + words of the current verdict — never colour alone."""
        return self._status_label.text()

    @property
    def continue_button_enabled(self) -> bool:
        """Exposed for the accessibility guarantee of SPEC §4.3."""
        return self._continue_button.isEnabled()

    def retry(self) -> HeadphoneReport:
        """Re-run the heuristic and refresh the verdict in place."""
        self._report = _detect_safely()
        if self._lr_result is not None:
            self._report = with_lr_result(self._report, self._lr_result)
        self._refresh()
        return self._report

    def set_lr_result(self, result: LrTestResult) -> HeadphoneReport:
        """Fold a perceptual answer into the report and refresh the view.

        Public so a caller can supply the answer it collected itself (for
        example from a test run or a restored session) without poking internals.
        """
        self._lr_result = _coerce_lr_result(result)
        self._report = with_lr_result(self._report, self._lr_result)
        self._refresh()
        return self._report

    def run_lr_test(self) -> LrTestResult | None:
        """Open the perceptual test (SPEC §4.2) and fold the answer in."""
        dialog = LrTestDialog(self._engine, self)
        dialog.exec()
        result = dialog.lr_result
        if isinstance(result, LrTestResult):
            self._lr_result = result
            self._report = with_lr_result(self._report, result)
            self._refresh()
        return result

    def accept(self) -> None:
        """Accepting the dialog counts as acknowledging the warning."""
        self._acknowledged = True
        super().accept()

    # ---------------------------------------------------------------- private

    def _on_continue(self) -> None:
        self._acknowledged = True
        self.accept()

    def _refresh(self) -> None:
        report = self._report
        icon, status, role = VERDICT_TEXT.get(
            report.verdict, VERDICT_TEXT[DeviceClass.UNKNOWN]
        )

        headline = _TITLE_OK if report.is_headphones else _TITLE
        self._headline_label.setText(tr(headline, "HeadphoneCheck"))
        self._headline_label.setAccessibleName(tr(headline, "HeadphoneCheck"))

        self._status_label.setText(f"{icon}  {tr(status, 'HeadphoneCheckVerdict')}")
        set_role(self._status_label, role)
        refresh_style(self._status_label)

        self._clear_details()
        self._add_detail(tr("Device"), _device_name(report))
        verdict_label = _VERDICT_LABEL.get(report.verdict, _VERDICT_LABEL[DeviceClass.UNKNOWN])
        self._add_detail(tr("Verdict"), tr(verdict_label, "HeadphoneCheckVerdict"))
        confidence = _CONFIDENCE_LABEL.get(str(report.confidence).lower(), "Low")
        self._add_detail(tr("Confidence"), tr(confidence, "HeadphoneCheckConfidence"))

        if self._lr_result is not None:
            text, lr_role = _LR_RESULT_TEXT[self._lr_result]
            self._lr_label.setText(tr(text, "HeadphoneCheckLrResult"))
            set_role(self._lr_label, lr_role)
            refresh_style(self._lr_label)
            self._lr_label.setVisible(True)
        else:
            self._lr_label.setVisible(False)

        # Never gate the user: the button stays usable in every state.
        self._continue_button.setEnabled(True)

    def _clear_details(self) -> None:
        while self._detail_layout.count():
            item = self._detail_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

    def _add_detail(self, key: str, value: str) -> None:
        self._detail_layout.addWidget(make_label(f"{key}: {value}", role="caption"))


def _coerce_lr_result(value: object) -> LrTestResult:
    """Accept a LrTestResult, its value, or anything else."""
    if isinstance(value, LrTestResult):
        return value
    try:
        return LrTestResult(value)
    except (ValueError, TypeError):
        return LrTestResult.INDETERMINATE


def _device_name(report: HeadphoneReport) -> str:
    device = report.device
    if device is None or not str(getattr(device, "name", "")).strip():
        return tr(_UNKNOWN_DEVICE, "HeadphoneCheck")
    return str(device.name)
