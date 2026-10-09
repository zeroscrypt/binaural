"""Help -> About: version, project link, full disclaimer and licence (SPEC §6.13, §7).

The disclaimer is a single English text kept here so that both the About dialog
and the frequency reference always show exactly the same wording.
"""

from __future__ import annotations

import platform
from typing import TYPE_CHECKING

from PySide6 import __version__ as _pyside_version
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QDialog, QFrame, QScrollArea, QVBoxLayout, QWidget

from binaural import __version__

if TYPE_CHECKING:  # pragma: no cover - the annotation only, the import is lazy
    from ..update_coordinator import UpdateCoordinator

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
    "sections",
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
LICENSE_HOLDER = "@zeroscrypt"
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

# --------------------------------------------------------------------------
# The four sections of SPEC §7 item 6.
#
# Same English sentences as ``AboutContent.swift``, one key each: two
# implementations, one contract (CONTRACT rule 9). A sentence shared between the
# two dialogs has to be the *same* key, or the two drift and nobody notices.
# --------------------------------------------------------------------------

_WHO_MADE_IT_TITLE = "Who made it"
_HOW_IT_WORKS_TITLE = "How it works"
_WHAT_IT_IS_FOR_TITLE = "What it is and what it is for"
_TECHNICAL_TITLE = "Technical details"

# «Кто создал». Two handles, a name, a year and the repository — nothing else.
# A biography, a company and a contact address would all be invented.
_CREDITS_LINE = (
    "Written by @zeroscrypt, with special thanks to @hakatao."
)
_CREDITS_WHERE = "The project lives at github.com/zeroscrypt/binaural. Released in 2026."

# «Как это работает». Part 1 names the third tone before the two terms arrive, so
# the reader has the whole idea before `beat` and `carrier` are used.
_MECHANISM_LINE = (
    "Two sine tones of different frequency, one sent to each ear, and the brain hears "
    "a third tone that is not there. That third tone is the difference between the two "
    "frequencies, and it is called the beat."
)
_TERMS_LINE = (
    "The beat is the difference between the two frequencies. The carrier is their "
    "average — the tone you actually hear in each ear, with the beat pulsing inside it."
)
# Why the check in `_WHAT_IT_NEEDS` can fail at all: the part a reader without that
# paragraph would be missing.
_HEADPHONES_WHY_LINE = (
    "Headphones are not a preference but a physical requirement: the two frequencies "
    "have to reach your ears separately, and only headphones do that. On speakers "
    "they mix in the air first, and there is nothing left to fuse."
)
_APP_DOES_LINE = (
    "The application itself does the plain part: two independent frequencies you set, "
    "play and stop, volume, a timer, presets, the frequency reference and a headphone "
    "check. Nothing is added to the sound and nothing is sent anywhere."
)

# «Что это и зачем». Part 2 turns on the three words SPEC §6.13 turns on and then
# points at the disclaimer panel: a disclaimer quoted twice is two texts to keep in
# step, and the short one softens first.
_SCOPE_LINE = (
    "Binaural is a desktop generator of binaural beats. It makes a sound and shows "
    "you what is known about the frequencies it can play."
)
_NOT_MEDICAL_LINE = (
    "It is not a medical device and makes no health claim. It does not diagnose, treat "
    "or prevent anything, and it does not promise an effect. The disclaimer below is "
    "the full version of that sentence."
)

# «Технические детали». The version line is *not* repeated: `version_line()` already
# shows it once. Platform and stack are the two lines that differ per implementation —
# `apple/` is a separate product (SPEC §3) — the same split `_APP_TAGLINE` has.
_PLATFORM_LICENCE_LINE = (
    "Platform: macOS and Linux. Licence: MIT — use it, change it, ship it."
)
_STACK_LINE = (
    "Built with Python 3.10 or newer and PySide6. Two applications are built from this "
    "repository; they share their frequency arithmetic, not their code."
)
_UNSIGNED_LINE = (
    "The macOS app is unsigned: no Apple Developer identity is available, so it runs "
    "for whoever built it and Gatekeeper blocks it for anyone else. Right-click, then "
    "Open, gets past it. GitHub releases carry source only."
)

def sections() -> list[tuple[str, list[str]]]:
    """The four sections of SPEC §7 item 6, translated, in the order shown.

    ``(heading, body lines)``. Translated here rather than through a tuple of keys
    because ``test_no_orphan_catalogue_entries`` finds a key by walking the AST for
    ``tr(NAME)`` calls, and a table of keys read with a subscript gives it nothing to
    match — which would let a key sit in ``ru.py`` that no dialog shows.
    """
    return [
        (tr(_WHO_MADE_IT_TITLE), [tr(_CREDITS_LINE), tr(_CREDITS_WHERE)]),
        (tr(_HOW_IT_WORKS_TITLE), [
            tr(_MECHANISM_LINE), tr(_TERMS_LINE), tr(_HEADPHONES_WHY_LINE),
            tr(_APP_DOES_LINE),
        ]),
        (tr(_WHAT_IT_IS_FOR_TITLE), [tr(_SCOPE_LINE), tr(_NOT_MEDICAL_LINE)]),
        (tr(_TECHNICAL_TITLE), [
            tr(_PLATFORM_LICENCE_LINE), tr(_STACK_LINE), tr(_UNSIGNED_LINE),
        ]),
    ]


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
    """Application information: version, project page, disclaimer, licence.

    ``updates`` is the app's :class:`~binaural.ui.update_coordinator.UpdateCoordinator`,
    injected rather than built here so the About button and the launch check are
    the same check. Left out, the button builds its own coordinator on the first
    press — the dialog must still be usable on its own, which is how every dialog
    test constructs it.
    """

    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        updates: "UpdateCoordinator | None" = None,
    ) -> None:
        super().__init__(parent)
        self._updates = updates
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

        for heading, body in sections():
            content.addWidget(self._build_section(heading, body))

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
        # The update check, in the dialog it belongs to: the same check the app runs
        # at launch, on request. It is a secondary action, so it sits left of Close
        # and Close keeps the primary variant and the focus.
        self._check_updates_button = make_button(
            tr("Check for updates"),
            on_click=self._check_for_updates,
            min_width=180,
            accessible_name=tr("Check for updates"),
        )
        row = button_row()
        row.addWidget(self._check_updates_button)
        row.addStretch(1)
        row.addWidget(close)
        root.addLayout(row)

        style_dialog(self)

    def _check_for_updates(self) -> None:
        """*Check for updates* — the same check the app runs at launch, on request.

        Built lazily when the dialog was constructed without one: the import is
        inside the handler so ``dialogs`` does not import ``ui.update_coordinator``
        at module load, which would be a cycle.
        """
        coordinator = self._updates
        if coordinator is None:
            from ..update_coordinator import UpdateCoordinator

            coordinator = UpdateCoordinator()
            self._updates = coordinator
        self.set_checking(True)
        # Connected before the check starts, because a check that finishes instantly
        # emits before this method returns; the button's busy state is the
        # coordinator's signal rather than this call's own end.
        coordinator.checked.connect(self._on_update_checked)
        try:
            coordinator.check_from_about(self)
        except Exception:
            # The coordinator reports its own failures; an exception here would be a
            # bug in the wiring, and the button must not stay stuck on "Checking".
            coordinator.checked.disconnect(self._on_update_checked)
            self.set_checking(False)

    def _on_update_checked(self, _availability) -> None:
        """The check is over: put the button back whatever the answer was."""
        coordinator = self._updates
        if coordinator is not None:
            try:
                coordinator.checked.disconnect(self._on_update_checked)
            except (RuntimeError, TypeError):  # pragma: no cover - already gone
                pass
        self.set_checking(False)

    def set_checking(self, checking: bool) -> None:
        """Show that a check is running, and take the button out of the way.

        The button says what is happening instead of going blank, and is disabled
        while the check is in flight: a second check would be a second modal dialog
        over the first.
        """
        self._check_updates_button.setEnabled(not checking)
        self._check_updates_button.setText(
            tr("Checking for updates…") if checking else tr("Check for updates")
        )

    def showEvent(self, event) -> None:  # noqa: N802 - Qt virtual
        super().showEvent(event)
        # Focus on the only action instead of the read-only text, so Tab does not
        # walk through paragraphs and the focus ring is obvious.
        self._close_button.setFocus(Qt.FocusReason.OtherFocusReason)

    # ------------------------------------------------------------------ build

    def _build_section(self, heading: str, body: list[str]) -> QWidget:
        """One titled block: a heading and its body lines, as a plain panel.

        Not ``_build_disclaimer``'s bordered panel: these sections have no legal
        text to set off, and four more borders would turn the dialog into a stack
        of boxes. Word wrap on every label is what keeps long sentences readable at
        any width — the body scrolls, so nothing may rely on a fixed height.
        """
        panel = make_panel()
        panel.setAccessibleName(heading)
        layout = panel_layout(panel, spacing=SPACE_SM, margins=0)
        layout.addWidget(make_label(heading, role="heading"))
        for line in body:
            layout.addWidget(make_label(line, word_wrap=True, selectable=True))
        return panel

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

    @property
    def check_for_updates_text(self) -> str:
        """The caption of the update-check button, in the current language."""
        return self._check_updates_button.text()

    def click_check_for_updates(self) -> None:
        """Press *Check for updates* — the tests drive the button through this."""
        self._check_updates_button.click()
