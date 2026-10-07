"""Help -> About: version, project link, full disclaimer and licence (SPEC §6.13, §7).

The disclaimer is a single English text kept here so that both the About dialog
and the frequency reference always show exactly the same wording.
"""

from __future__ import annotations

import platform

from PySide6 import __version__ as _pyside_version
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QDialog, QFrame, QScrollArea, QVBoxLayout, QWidget

from binaural import __version__

from . import (
    SPACE_LG,
    SPACE_MD,
    SPACE_SM,
    button_row,
    make_button,
    make_label,
    make_panel,
    open_link_label,
    panel_layout,
    style_dialog,
    tr,
)

__all__ = [
    "AboutDialog",
    "DISCLAIMER_TITLE",
    "DISCLAIMER_EN",
    "disclaimer_text",
    "LICENSE_NAME",
    "LICENSE_HOLDER",
    "LICENSE_YEAR",
    "LICENSE_SUMMARY_EN",
    "license_text",
    "PROJECT_URL",
    "version_line",
]

PROJECT_URL = "https://github.com/zeroscrypt/binaural"

DISCLAIMER_TITLE = "Disclaimer"

#: SPEC §6.13, translated to English. The meaning is preserved on purpose: not a
#: medical device, no diagnosis / treatment / prevention, ask a doctor with
#: epilepsy, a pacemaker, pregnancy or photosensitivity, keep the volume sane, and
#: beats are sound rather than a substance — nothing here treats dependence.
DISCLAIMER_EN = (
    "These frequencies and the descriptions of their effects come from research, "
    "and also from esoteric, energy and alternative practices. This application is "
    "not a medical device and is not intended for the diagnosis, treatment or "
    "prevention of any disease. Do not use it if you have epilepsy or a pacemaker, "
    "during pregnancy, or if you are photosensitive, without consulting a doctor. "
    "Do not turn the volume above a comfortable level. "
    "Binaural beats are sound, not a substance, and they do not replace one. "
    "Nothing here helps with withdrawal, craving, tolerance or relapse, and this "
    "app does not treat dependence of any kind. Dependence is a medical condition "
    "with risks of its own: withdrawal from alcohol and from sedatives can be "
    "dangerous. If you are dependent on something, or want to use less of it, that "
    "is a question for a doctor or a specialist service, not for a tone generator."
)

LICENSE_NAME = "MIT License"
LICENSE_HOLDER = "Dmitriy Solontsov"
LICENSE_YEAR = "2026"
LICENSE_SUMMARY_EN = (
    "Permission is hereby granted, free of charge, to any person obtaining a copy of "
    'this software and associated documentation files (the "Software"), to deal in '
    "the Software without restriction, including without limitation the rights to use, "
    "copy, modify, merge, publish, distribute, sublicense and/or sell copies of the "
    "Software, and to permit persons to whom the Software is furnished to do so, "
    "subject to the conditions of the MIT licence. The software is provided \"as is\", "
    "without warranty of any kind, express or implied."
)

_APP_TAGLINE = "Binaural beats for macOS and Linux"
_WHAT_IT_IS = (
    "Two sine tones of different frequency are sent to the left and the right ear. "
    "Your brain fuses them into a third tone that has no sound source: the difference "
    "between the two frequencies. That phantom tone is the binaural beat."
)
_WHAT_IT_NEEDS = (
    "Headphones are a physical requirement, not a recommendation: on speakers both "
    "frequencies mix in the air before they reach your ears, and the effect is gone. "
    "The application checks the audio output on every start and reports what it found."
)
_EVIDENCE_NOTE = (
    "The frequency reference keeps every record it has — from peer-reviewed EEG "
    "literature to esoteric traditions — each marked with how well it is studied."
)


def disclaimer_text() -> str:
    """The disclaimer as shown to the user (SPEC §6.13)."""
    return tr(DISCLAIMER_EN, DISCLAIMER_TITLE)


def license_text() -> str:
    return tr(LICENSE_SUMMARY_EN, LICENSE_NAME)


def version_line() -> str:
    """``Version 0.1.0 · Python 3.12 · 6.11.2``."""
    return tr("Version {version} · Python {python} · PySide6 {qt}").format(
        version=__version__,
        python=platform.python_version(),
        qt=_pyside_version,
    )


class AboutDialog(QDialog):
    """Application information: version, project page, disclaimer, licence."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("About Binaural"))
        self.setAccessibleName(tr("About Binaural"))
        self.setModal(True)
        self.resize(580, 660)
        self.setMinimumSize(460, 420)

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        # The disclaimer and licence must never be clipped, so the whole body
        # scrolls instead of being cut off at the window edge.
        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setFrameShape(QFrame.Shape.NoFrame)
        root.addWidget(self._scroll, 1)

        body = QWidget()
        content = QVBoxLayout(body)
        content.setContentsMargins(0, 0, SPACE_SM, 0)
        content.setSpacing(SPACE_MD)
        self._scroll.setWidget(body)

        content.addWidget(make_label(tr("Binaural"), role="heading"))
        self._version_label = make_label(version_line(), role="caption", selectable=True)
        content.addWidget(self._version_label)
        content.addWidget(make_label(tr(_APP_TAGLINE), role="muted", word_wrap=True))
        content.addWidget(make_label(tr(_WHAT_IT_IS), word_wrap=True))
        content.addWidget(make_label(tr(_WHAT_IT_NEEDS), word_wrap=True))
        content.addWidget(make_label(tr(_EVIDENCE_NOTE), role="muted", word_wrap=True))

        self._link_row = open_link_label(PROJECT_URL, PROJECT_URL)
        content.addWidget(self._link_row)

        self._disclaimer_panel = self._build_disclaimer()
        content.addWidget(self._disclaimer_panel)

        self._license_panel = self._build_license()
        content.addWidget(self._license_panel)
        content.addStretch(1)

        close = make_button(
            tr("Close"),
            variant="primary",
            on_click=self.accept,
            min_width=120,
            accessible_name=tr("Close the About dialog"),
        )
        close.setDefault(True)
        close.setAutoDefault(True)
        self._close_button = close
        row = button_row()
        row.addStretch(1)
        row.addWidget(close)
        root.addLayout(row)

        style_dialog(self)

    def showEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        super().showEvent(event)
        # Focus on the only action instead of the read-only text, so Tab does not
        # walk through paragraphs and the focus ring is obvious.
        self._close_button.setFocus(Qt.FocusReason.OtherFocusReason)

    # ------------------------------------------------------------------ build

    def _build_disclaimer(self) -> QWidget:
        panel = make_panel(object_name="disclaimer")
        panel.setAccessibleName(tr(DISCLAIMER_TITLE))
        layout = panel_layout(panel, spacing=SPACE_SM)
        layout.addWidget(make_label(tr(DISCLAIMER_TITLE), role="heading"))
        self._disclaimer_label = make_label(
            disclaimer_text(),
            word_wrap=True,
            selectable=True,
            tooltip=tr("Medical disclaimer — read it before using the application."),
        )
        layout.addWidget(self._disclaimer_label)
        self.setAccessibleDescription(disclaimer_text())
        return panel

    def _build_license(self) -> QWidget:
        panel = make_panel()
        panel.setAccessibleName(tr(LICENSE_NAME))
        layout = panel_layout(panel, spacing=SPACE_SM)
        layout.addWidget(make_label(tr(LICENSE_NAME), role="heading"))
        self._copyright_label = make_label(
            tr("Copyright (c) {year} {holder}").format(
                year=LICENSE_YEAR, holder=LICENSE_HOLDER
            ),
            role="caption",
            selectable=True,
        )
        layout.addWidget(self._copyright_label)
        self._license_label = make_label(
            license_text(), role="caption", word_wrap=True, selectable=True
        )
        layout.addWidget(self._license_label)
        return panel

    # ----------------------------------------------------------------- public

    @property
    def version(self) -> str:
        """The application version, taken from ``binaural.__version__``."""
        return __version__

    @property
    def version_text(self) -> str:
        """The version line, always containing ``binaural.__version__``."""
        return self._version_label.text()

    @property
    def project_url(self) -> str:
        return PROJECT_URL

    @property
    def disclaimer_text(self) -> str:
        return self._disclaimer_label.text()

    @property
    def license_text(self) -> str:
        return self._license_label.text()
