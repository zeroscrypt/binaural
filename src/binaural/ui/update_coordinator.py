"""The update check's orchestration: check, offer, download, install.

The counterpart of ``apple/Sources/macOS/UpdateCheckCoordinator.swift``. Two
entry points, one implementation:

* :meth:`UpdateCoordinator.run_at_launch` — a silent background check. Nothing is
  shown unless a newer release exists; a failure is silence, not a dialog, and a
  skipped version stays skipped.
* :meth:`UpdateCoordinator.check_from_about` — the About button. Whatever the
  answer — up to date, an update, a failure — it is reported.

When an update is offered the user confirms each step: *Download and install*
starts the download (progress in its own window), and the install — which
restarts the app — is confirmed on its own. *Skip this version* remembers the
release in the session and stays silent about it until a newer one exists.

The checker, downloader and installer are injected, and so is the thread runner,
so the whole sequence is testable without the network, without the real
filesystem and without a modal loop.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Callable, Protocol

from PySide6.QtCore import QObject, Signal
from PySide6.QtWidgets import QMessageBox, QWidget

from ..core.session import Session, load as load_session, save as save_session
from ..core.update_checker import (
    AppVersion,
    UpdateAvailability,
    UpdateChecker,
    UpdateError,
    UpdateMissingArchive,
    running_version,
)
from ..core.update_downloader import UpdateDownloadError, UpdateDownloader
from ..core.update_installer import UpdateInstallError, UpdateInstaller
from .dialogs.update import Choice, UpdateDialog, UpdateProgressDialog

__all__ = ["SessionTarget", "UpdateCoordinator"]


class Target(Protocol):
    """Where the check reads and writes the release the user skipped.

    :class:`~binaural.ui.main_window.MainWindow` implements it, because the window
    owns the session; the tests pass a spy.
    """

    def skipped_update_version(self) -> str | None:  # pragma: no cover - protocol
        ...

    def persist_skipped_update_version(self, version: str | None) -> None:  # pragma: no cover
        ...


class SessionTarget:
    """:class:`Target` over a live :class:`~binaural.core.session.Session`.

    The object the window holds, not a copy: the window saves the session wholesale
    from that very object, so a target holding a copy of its own would have its
    answer overwritten by the next save.
    """

    def __init__(self, session: Session | None = None) -> None:
        self._session = session if session is not None else load_session()

    def skipped_update_version(self) -> str | None:
        return self._session.skipped_update_version

    def persist_skipped_update_version(self, version: str | None) -> None:
        self._session.skipped_update_version = version
        try:
            save_session(self._session)
        except Exception:
            pass  # persistence is a convenience, never a blocker


class _Job(QObject):
    """Carries one background job's result back to the UI thread.

    A Qt signal emitted from a worker thread is delivered queued to the main
    thread, which is what lets the coordinator do the network and the filesystem
    work off the UI thread and still touch widgets safely afterwards.
    """

    #: The work finished; carries whatever the job produced.
    finished = Signal(object)
    #: The work failed; carries the exception.
    failed = Signal(object)
    #: How far along the work is, 0..1.
    progressed = Signal(float)


class UpdateCoordinator(QObject):
    """Checks GitHub for a newer release and walks the user through installing it."""

    #: Emitted whenever a check finishes, so the About button can leave its busy
    #: state even when nothing is shown. Carries the availability or ``None``.
    checked = Signal(object)

    def __init__(
        self,
        parent: QObject | None = None,
        *,
        checker: UpdateChecker | None = None,
        downloader: UpdateDownloader | None = None,
        installer: UpdateInstaller | None = None,
        target: Target | None = None,
        current_version: Callable[[], AppVersion | None] | None = None,
        confirm_install: Callable[[], bool] | None = None,
        dialog_class: type = UpdateDialog,
        progress_class: type = UpdateProgressDialog,
        runner: Callable[[Callable[[], object]], None] | None = None,
    ) -> None:
        super().__init__(parent)
        self._checker = checker if checker is not None else UpdateChecker()
        self._downloader = downloader if downloader is not None else UpdateDownloader()
        self._installer = installer if installer is not None else UpdateInstaller()
        self._target = target
        self._current_version = current_version or running_version
        self._confirm_install = confirm_install or self._ask_to_install
        self._dialog_class = dialog_class
        self._progress_class = progress_class
        self._runner = runner or self._run_in_background

        #: The last check's answer, for the dialogs and the tests to read.
        self.availability: UpdateAvailability | None = None
        self._parent: QWidget | None = None
        #: The job in flight, held so the worker thread's result has a live sender to
        #: deliver through: a ``_Job`` that went out of scope could take its own queued
        #: signal with it.
        self._job: _Job | None = None
        self._busy = False

    # ------------------------------------------------------------ entry points

    def run_at_launch(self) -> None:
        """The launch check: silent unless there is an update to offer."""
        # Nothing to sit a dialog on: the About dialog of a previous check, if there
        # was one, is long gone by the time a launch check runs.
        self._parent = None
        self._start_check(quiet=True)

    def check_from_about(self, parent: QWidget | None = None) -> None:
        """The About button: check and report whatever the answer is."""
        self._parent = parent
        self._start_check(quiet=False)

    def _start_check(self, *, quiet: bool) -> None:
        """Run the check off the UI thread and act on the answer on it.

        ``quiet`` is the launch check: only an update worth telling about may
        interrupt; a failure, an up-to-date answer and a skipped version are all
        silence.
        """
        if self._busy:
            # A second modal dialog over the first is a dialog over nothing.
            return
        self._busy = True
        current = self._current_version()
        if current is None:
            # Nothing to compare against, which is a failure of the check rather
            # than of the network: the same sentence, and silence at launch.
            self._on_check_failed(RuntimeError("the running app has no version"), quiet)
            return
        skipped = AppVersion.parse(
            self._target.skipped_update_version() if self._target is not None else None
        )

        job = _Job()
        job.finished.connect(lambda result: self._on_checked(result, quiet))
        job.failed.connect(lambda error: self._on_check_failed(error, quiet))

        def work() -> object:
            return self._checker.check(current_version=current, skipping=skipped)

        self._job = job
        self._runner(work, job)

    # ----------------------------------------------------------- check results

    def _on_checked(self, availability: object, quiet: bool) -> None:
        if not isinstance(availability, UpdateAvailability):
            self._on_check_failed(RuntimeError("the check produced no answer"), quiet)
            return
        self.availability = availability
        # Only an update worth telling about interrupts the launch.
        if not (quiet and not availability.is_worth_telling):
            self._present(availability)
        self._finish(availability)

    def _on_check_failed(self, error: object, quiet: bool) -> None:
        self.availability = None
        self._finish(None)
        if quiet:
            return  # a failed check is silence at launch
        self._present_failure(_message_for(error))

    def _finish(self, availability: UpdateAvailability | None) -> None:
        """Release the busy state and tell the About button the check is over."""
        self._busy = False
        self.checked.emit(availability)

    # ---------------------------------------------------------- the result box

    def _present(self, availability: UpdateAvailability) -> None:
        """Show the result and act on the user's answer."""
        release = availability.release
        parent = self._parent_widget()
        if release is None:
            dialog = self._dialog_class(parent, message=self._up_to_date_text())
        else:
            dialog = self._dialog_class(parent, release=release)
        dialog.exec()
        choice = getattr(dialog, "choice", Choice.LATER)
        dialog.deleteLater()
        if choice is Choice.DOWNLOAD:
            self.download_and_install()
        elif choice is Choice.SKIP:
            # Remembered, and the launch check stays silent about this release
            # until a newer one exists.
            if self._target is not None and release is not None:
                self._target.persist_skipped_update_version(
                    str(release.version) if release.version is not None else None
                )
        # Choice.LATER: nothing happens and nothing is remembered.

    def _present_failure(self, message: str) -> None:
        """A failure the user asked about, in words rather than an exception."""
        dialog = self._dialog_class(self._parent_widget(), message=message)
        dialog.exec()
        dialog.deleteLater()

    @staticmethod
    def _up_to_date_text() -> str:
        from .dialogs import tr

        return tr("You are up to date")

    # ----------------------------------------------------- download and install

    def download_and_install(self) -> None:
        """Download the offered release and install it, with the user's confirmation.

        The progress window is non-modal: the download runs while it is open and it
        closes itself when the download ends. The install is the dangerous step, so
        it is confirmed on its own and only then runs.
        """
        availability = self.availability
        release = availability.release if availability is not None else None
        version = release.version if release is not None else None
        asset = release.linux_archive() if release is not None else None
        if release is None or version is None or asset is None:
            self._present_failure(_message_for(UpdateMissingArchive()))
            return

        progress = self._progress_class(self._parent_widget())
        progress.show()
        job = _Job()
        job.progressed.connect(progress.set_progress)
        job.finished.connect(
            lambda path: self._on_downloaded(progress, Path(str(path)), version)
        )
        job.failed.connect(lambda error: self._on_download_failed(progress, error))

        def work() -> object:
            return self._downloader.download(asset.url, job.progressed.emit)

        self._job = job
        self._runner(work, job)

    def _on_downloaded(
        self, progress: UpdateProgressDialog, archive: Path, version: AppVersion
    ) -> None:
        progress.close_window()
        if not self._confirm_install():
            # Declining the restart leaves the app exactly as it was, and the
            # archive is the only thing spent.
            return
        try:
            self._installer.install_archive(archive, expected_version=version)
        except Exception as exc:
            self._present_failure(_message_for(exc))

    def _on_download_failed(self, progress: UpdateProgressDialog, error: object) -> None:
        progress.close_window()
        self._present_failure(_message_for(error))

    def _parent_widget(self) -> QWidget | None:
        """The widget a dialog should sit on, or ``None`` when there is none.

        The About dialog when the check came from its button; nothing at launch, where
        the main window is the one thing already on screen.
        """
        return self._parent if isinstance(self._parent, QWidget) else None

    def _ask_to_install(self) -> bool:
        """The "the app will restart" confirmation.

        A :class:`QMessageBox`, which is the Qt counterpart of the macOS alert: the
        install restarts the application, so it is confirmed on its own rather than
        riding on the *Download and install* click.
        """
        from .dialogs import tr

        box = QMessageBox(self._parent_widget())
        box.setIcon(QMessageBox.Icon.Question)
        box.setWindowTitle(tr("Check for updates"))
        box.setText(tr("Binaural will restart to finish the update."))
        install = box.addButton(
            tr("Install and restart"), QMessageBox.ButtonRole.AcceptRole
        )
        later = box.addButton(tr("Later"), QMessageBox.ButtonRole.RejectRole)
        # Later is the default: an install restarts the app, so the safe answer is
        # the one a stray Return lands on.
        box.setDefaultButton(later)
        box.exec()
        return box.clickedButton() is install

    # ------------------------------------------------------------------ threads

    @staticmethod
    def _run_in_background(work: Callable[[], object], job: _Job) -> None:
        """Run ``work`` on a daemon thread and report the outcome through ``job``.

        A daemon thread, so an update check cannot keep a closing app alive; the
        result arrives as a signal, which is what puts the dialog back on the UI
        thread.
        """

        def run() -> None:
            try:
                result = work()
            except Exception as exc:
                job.failed.emit(exc)
                return
            job.finished.emit(result)

        thread = threading.Thread(target=run, name="binaural-update", daemon=True)
        thread.start()


def _message_for(error: object) -> str:
    """An error as a sentence the user can read.

    The app never shows a raw HTTP body or a traceback: every failure the update
    flow can produce is one of these. A check failure is one sentence, a download
    failure and an install failure are different ones, because the user's next move
    is different in each.
    """
    from .dialogs import tr

    if isinstance(error, UpdateError):
        return tr("Could not check for updates")
    # The installer raises for its own reasons — a stale archive, a replace that
    # could not be undone — and all of them mean the same thing to the user.
    if isinstance(error, UpdateInstallError):
        return tr("Could not install the update.")
    if isinstance(error, UpdateDownloadError):
        return tr("Could not download the update.")
    return tr("Could not check for updates")