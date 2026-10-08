"""The update check's result dialog and its download progress window.

The counterpart of ``apple/Sources/macOS/UpdateDialogController.swift`` and
``UpdateProgressController.swift``: one dialog for every answer the check can
give, so the About button and the launch check show the same wording in the same
order. The wording is the shared ``tr()`` keys of ``ru.py``, one per sentence —
the same keys ``AboutContent.swift`` holds (CONTRACT rule 9).

The buttons are the user's confirmation and nothing more: nothing downloads or
installs from this dialog alone, the coordinator acts on the answer afterwards.
That is why the dialog records a :class:`Choice` instead of doing the work — a
test (and the coordinator) can read what the user answered without a modal loop.
"""

from __future__ import annotations

from enum import Enum

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QProgressBar,
    QVBoxLayout,
    QWidget,
)

from ...core.update_checker import GitHubRelease
from . import (
    SPACE_LG,
    SPACE_MD,
    button_row,
    make_button,
    make_label,
    open_url,
    style_dialog,
    tr,
)

__all__ = ["Choice", "UpdateDialog", "UpdateProgressDialog", "update_available_text"]


def update_available_text(release: GitHubRelease) -> str:
    """``Version 0.2.0 is available``, in the current language.

    A module function rather than a line inside the dialog so the wording is one
    shared key wherever it is built. An unreadable tag falls back to the tag itself
    rather than to nothing.
    """
    version = release.version
    return tr("Version {version} is available").format(
        version=str(version) if version is not None else release.tag_name
    )


class Choice(Enum):
    """What the user answered in the result dialog."""

    #: *Download and install* — download the offered release and install it.
    DOWNLOAD = "download"
    #: *Skip this version* — stay silent about this release until a newer one exists.
    SKIP = "skip"
    #: *Later* (or *Close*, when there is nothing to act on) — nothing happens.
    LATER = "later"


class UpdateDialog(QDialog):
    """What the check concluded: up to date, an update to offer, or a failure."""

    def __init__(
        self,
        parent: QWidget | None = None,
        *,
        release: GitHubRelease | None = None,
        message: str | None = None,
    ) -> None:
        """Build the dialog for one answer.

        :param release: the release to offer. ``None`` means there is nothing to
            install, so the download and skip buttons are not shown — the same
            wording in the same order as the macOS dialog.
        :param message: the text to show. Required when there is no ``release``:
            "You are up to date" or the reason the check failed.
        """
        super().__init__(parent)
        self._release = release
        self._choice = Choice.LATER
        self.setModal(True)
        self.resize(520, 220)
        self.setMinimumSize(420, 200)

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        self._message_label = make_label(
            message or self._default_message(), word_wrap=True, selectable=True
        )
        root.addWidget(self._message_label)

        # The release page is a link, like the project link in About: the release
        # notes are the one thing worth reading before installing.
        self._release_page_button = make_button(
            tr("Open the release page"),
            variant="ghost",
            accessible_name=tr("Open the release page"),
        )
        self._release_page_button.clicked.connect(self._open_release_page)
        root.addWidget(self._release_page_button)
        root.addStretch(1)

        self._download_button = make_button(
            tr("Download and install"),
            variant="primary",
            accessible_name=tr("Download and install"),
        )
        self._download_button.clicked.connect(lambda: self._choose(Choice.DOWNLOAD))
        self._skip_button = make_button(
            tr("Skip this version"),
            accessible_name=tr("Skip this version"),
        )
        self._skip_button.clicked.connect(lambda: self._choose(Choice.SKIP))
        self._dismiss_button = make_button(
            tr("Later"),
            accessible_name=tr("Later"),
        )
        self._dismiss_button.clicked.connect(lambda: self._choose(Choice.LATER))

        row = button_row(self._download_button, self._skip_button)
        row.addStretch(1)
        row.addWidget(self._dismiss_button)
        root.addLayout(row)

        self._apply_mode()
        style_dialog(self)

    # ------------------------------------------------------------------- build

    def _default_message(self) -> str:
        """The wording for the mode this dialog was built in.

        The dialog owns it rather than the coordinator, for the same reason the
        macOS controller does: one place builds the text for an answer, so the launch
        check and the About button cannot word it differently.
        """
        return update_available_text(self._release) if self._release is not None else ""

    def _apply_mode(self) -> None:
        """Show or hide the buttons that have nothing to act on.

        One dialog for every answer, so the button row changes and the wording does
        not: an up-to-date answer has nothing to download and nothing to skip.
        """
        offering = self._release is not None
        self._download_button.setVisible(offering)
        self._skip_button.setVisible(offering)
        self._release_page_button.setVisible(
            offering and bool(self._release.html_url)  # type: ignore[union-attr]
        )
        # *Later* when there is an update to put off, *Close* when there is nothing
        # to act on — the same answer either way.
        self._dismiss_button.setText(tr("Later") if offering else tr("Close"))
        self.setWindowTitle(
            tr("Check for updates") if offering else self._message_label.text()
        )
        self.setAccessibleName(self._message_label.text())
        self.setAccessibleDescription(self._message_label.text())
        # Focus on the only action, so Tab does not walk a row of buttons that are
        # mostly not there.
        focus = self._download_button if offering else self._dismiss_button
        focus.setDefault(True)
        focus.setFocus(Qt.FocusReason.OtherFocusReason)

    def _open_release_page(self) -> None:
        url = self._release.html_url if self._release is not None else None
        if url:
            open_url(url)

    def _choose(self, choice: Choice) -> None:
        self._choice = choice
        self.accept()

    # ------------------------------------------------------------------ public

    @property
    def choice(self) -> Choice:
        """What the user answered; :attr:`Choice.LATER` until they answer."""
        return self._choice

    @property
    def message_text(self) -> str:
        return self._message_label.text()

    @property
    def release(self) -> GitHubRelease | None:
        """The release this dialog is offering, or ``None``."""
        return self._release

    def is_download_visible(self) -> bool:  # noqa: D102 - the tests read this
        return not self._download_button.isHidden()

    def is_skip_visible(self) -> bool:  # noqa: D102
        return not self._skip_button.isHidden()

    def dismiss_text(self) -> str:  # noqa: D102
        return self._dismiss_button.text()

    def click_download(self) -> None:  # noqa: D102 - the tests press it
        self._download_button.click()

    def click_skip(self) -> None:  # noqa: D102
        self._skip_button.click()

    def click_dismiss(self) -> None:  # noqa: D102
        self._dismiss_button.click()


class UpdateProgressDialog(QDialog):
    """A progress window shown while the update downloads.

    Non-modal on purpose: the download runs while it is open and the window closes
    itself when the download ends. A modal dialog here would mean running the
    download inside the nested loop the rest of the app's dialogs never have.
    """

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setModal(False)
        self.setWindowTitle(tr("Downloading update…"))
        self.setAccessibleName(tr("Downloading update…"))
        self.resize(400, 160)
        self.setMinimumSize(360, 140)

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        self._message_label = make_label(
            tr("Downloading update…"), word_wrap=True, selectable=True
        )
        root.addWidget(self._message_label)

        self._progress_bar = QProgressBar()
        self._progress_bar.setRange(0, 100)
        self._progress_bar.setValue(0)
        self._progress_bar.setAccessibleName(tr("Downloading update…"))
        root.addWidget(self._progress_bar)

        style_dialog(self)

    def set_progress(self, fraction: float) -> None:
        """How much of the download has arrived, 0..1. Clamped.

        Called from the download thread, so the value is set rather than animated:
        a queued Qt signal already puts the repaint on the UI thread, and an
        animation here would tick at its own speed instead of the download's.
        """
        self._progress_bar.setValue(int(round(min(max(float(fraction), 0.0), 1.0) * 100)))

    @property
    def progress(self) -> int:
        """The progress in percent, 0..100."""
        return self._progress_bar.value()

    @property
    def message_text(self) -> str:
        return self._message_label.text()

    def close_window(self) -> None:
        """Take the window down without ending the session that owns it."""
        self.close()