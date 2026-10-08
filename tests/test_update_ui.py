"""The update check as the user meets it: the launch check, the About button, the install.

Mirrors ``apple/Tests/MacTests/UpdateCheckTests.swift`` — the same rules, the Python
spelling. The checker, downloader, installer, the result dialog and the thread
runner are all injected, so the whole sequence runs without the network, without the
real prefix and without a modal loop: the scripted dialogs answer immediately
instead of spinning ``exec()``.

What is verified is the app's behaviour — which dialog appears for which answer, what
the user's answer leads to, and what gets remembered.
"""

from __future__ import annotations

import json
import os
import tarfile
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication, QDialog  # noqa: E402

from binaural import i18n  # noqa: E402
from binaural.core.session import Session  # noqa: E402
from binaural.core.update_checker import (  # noqa: E402
    AppVersion,
    UpdateChecker,
    UpdateTransportError,
)
from binaural.core.update_downloader import UpdateDownloadError, UpdateDownloader  # noqa: E402
from binaural.core.update_installer import (  # noqa: E402
    UpdateInstaller,
    version_from_name,
)
from binaural.ui.dialogs.update import (  # noqa: E402
    Choice,
    UpdateDialog,
    UpdateProgressDialog,
    update_available_text,
)
from binaural.ui.update_coordinator import SessionTarget, UpdateCoordinator  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance()
    if app is None:
        try:
            app = QApplication(["binaural-update-tests"])
        except Exception as exc:  # pragma: no cover - depends on the machine
            pytest.skip(f"No usable Qt display: {exc}")
    yield app


@pytest.fixture(autouse=True)
def english():
    """The suite asserts English captions, so every test starts from ``en``."""
    previous = i18n.language()
    i18n.set_language("en")
    yield
    i18n.set_language(previous)


# --------------------------------------------------------------------------
# Fakes: the injected seams
# --------------------------------------------------------------------------


class TargetSpy:
    """The session's memory of the skipped release."""

    def __init__(self, skipped: str | None = None) -> None:
        self.skipped = skipped
        self.persisted: list[str | None] = []

    def skipped_update_version(self) -> str | None:
        return self.skipped

    def persist_skipped_update_version(self, version: str | None) -> None:
        self.skipped = version
        self.persisted.append(version)


def synchronous(work, job) -> None:
    """A runner that runs the job where the caller stands.

    The default runs it on a thread, which is right for an app and untestable for a
    dialog-driven sequence; this one keeps the same signal plumbing but drops the
    thread.
    """
    try:
        result = work()
    except Exception as exc:
        job.failed.emit(exc)
        return
    job.finished.emit(result)


def release_json(tag: str = "v0.2.0") -> str:
    """A release document carrying the Linux archive for the architecture under test."""
    name = f"binaural-{tag.lstrip('v')}-linux-x64.tar.gz"
    return json.dumps(
        {
            "tag_name": tag,
            "name": tag.lstrip("v"),
            "html_url": f"https://github.com/zeroscrypt/binaural/releases/tag/{tag}",
            "draft": False,
            "prerelease": False,
            "assets": [
                {
                    "name": name,
                    "size": 2_400_000,
                    "browser_download_url": (
                        f"https://github.com/zeroscrypt/binaural/releases/download/{tag}/{name}"
                    ),
                    "content_type": "application/gzip",
                }
            ],
        }
    )


def checker(tag: str = "v0.2.0") -> UpdateChecker:
    document = release_json(tag)
    return UpdateChecker(fetch=lambda _url: document)


def write_archive(destination, version: AppVersion) -> None:
    """A real release archive, laid out the way ``build_linux.sh`` packs one."""
    staging = destination.parent / f"staging-{version}"
    tree = staging / f"binaural-{version}-linux-x64"
    bundle = tree / "Binaural"
    bundle.mkdir(parents=True)
    binary = bundle / "binaural"
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o755)
    with tarfile.open(destination, "w:gz") as tar:
        tar.add(tree, arcname=tree.name)


def failing_checker() -> UpdateChecker:
    return UpdateChecker(fetch=lambda _url: _offline())


def _offline():
    raise UpdateTransportError("offline")


def downloader(tmp_path, events=None) -> UpdateDownloader:
    """A loader that writes a *valid* release archive and reports the whole range.

    The installer extracts before it replaces, so the mock has to be a real archive:
    a file of junk would fail in ``extract`` and never reach the replace and relaunch
    under test. The archive carries the version of the release being offered, so the
    installer's own version check passes.
    """

    def load(url, progress):
        if events is not None:
            events.append("download")
        progress(0.5)
        progress(1.0)
        destination = tmp_path / url.rsplit("/", 1)[-1]
        write_archive(destination, version_from_name(url.rsplit("/", 1)[-1]))
        return destination

    return UpdateDownloader(load=load)


def installed_prefix(tmp_path) -> Path:
    """A prefix with a release in it, the way ``install.sh`` leaves one.

    The installer refuses to replace a prefix that holds no release — an app running
    from source has nothing to update — so the sequence under test needs one.
    """
    prefix = tmp_path / ".binaural"
    app = prefix / "app"
    app.mkdir(parents=True, exist_ok=True)
    tree = app / "binaural-0.1.0-linux-x64"
    bundle = tree / "Binaural"
    bundle.mkdir(parents=True, exist_ok=True)
    binary = bundle / "binaural"
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o755)
    return prefix


def installer(events, prefix) -> UpdateInstaller:
    """An installer that records what it was asked to do instead of doing it."""
    return UpdateInstaller(
        replace=lambda new, current: events.append("replace"),
        relauncher=lambda entry: events.append("relaunch"),
        install_root=prefix,
    )


class ScriptedDialog(QDialog):
    """A result dialog that answers immediately instead of opening a modal loop.

    The message is built the way the real dialog builds it, so a test can assert on
    the wording without opening a window.
    """

    #: What the user answers when the dialog opens.
    action: Choice | None = None
    #: Every dialog this class was asked to build, in order.
    shown: list["ScriptedDialog"] = []

    def __init__(self, parent=None, *, release=None, message=None) -> None:
        super().__init__(parent)
        self.release = release
        self.message = (
            message
            if message is not None
            else (update_available_text(release) if release is not None else "")
        )
        self.choice = Choice.LATER
        type(self).shown.append(self)

    def exec(self) -> int:  # noqa: A003 - Qt virtual
        if type(self).action is not None:
            self.choice = type(self).action
        return 0

    @classmethod
    def reset(cls, action: Choice | None = None) -> None:
        cls.action = action
        cls.shown = []

    @classmethod
    def last(cls) -> "ScriptedDialog":
        """The dialog the coordinator built last."""
        return cls.shown[-1]


class ScriptedProgress(QDialog):
    """A progress window that records the fractions it was given."""

    #: Every window this class was asked to build, in order.
    built: list["ScriptedProgress"] = []

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.fractions: list[float] = []
        self.closed = False
        type(self).built.append(self)

    def show(self) -> None:  # noqa: D102 - Qt virtual
        pass

    def set_progress(self, fraction: float) -> None:
        self.fractions.append(fraction)

    def close_window(self) -> None:
        self.closed = True

    @classmethod
    def reset(cls) -> None:
        cls.built = []


def make_coordinator(
    qapp,
    tmp_path,
    *,
    tag: str = "v0.2.0",
    current: str = "0.1.0",
    target=None,
    events=None,
    confirm_install=None,
    checker_override=None,
):
    events = [] if events is None else events
    return UpdateCoordinator(
        checker=checker_override if checker_override is not None else checker(tag),
        downloader=downloader(tmp_path, events),
        installer=installer(events, installed_prefix(tmp_path)),
        target=target if target is not None else TargetSpy(),
        current_version=lambda: AppVersion(current),
        confirm_install=(lambda: True) if confirm_install is None else confirm_install,
        dialog_class=ScriptedDialog,
        progress_class=ScriptedProgress,
        runner=synchronous,
    )


@pytest.fixture(autouse=True)
def scripted_dialogs():
    """Fresh scripted dialogs per test; the classes are stateful by design."""
    ScriptedDialog.reset()
    ScriptedProgress.reset()
    yield
    ScriptedDialog.reset()
    ScriptedProgress.reset()


# --------------------------------------------------------------------------
# The launch check
# --------------------------------------------------------------------------


def test_launch_check_is_silent_when_up_to_date(qapp, tmp_path):
    coordinator = make_coordinator(qapp, tmp_path, tag="v0.1.0")
    coordinator.run_at_launch()
    assert ScriptedDialog.shown == [], "up to date is silence at launch"


def test_launch_check_is_silent_when_the_check_fails(qapp, tmp_path):
    coordinator = make_coordinator(
        qapp, tmp_path, checker_override=failing_checker()
    )
    coordinator.run_at_launch()
    assert ScriptedDialog.shown == [], "a failed check is silence at launch"


def test_launch_check_is_silent_when_the_version_is_skipped(qapp, tmp_path):
    coordinator = make_coordinator(qapp, tmp_path, target=TargetSpy(skipped="0.2.0"))
    coordinator.run_at_launch()
    assert ScriptedDialog.shown == [], "a skipped version is silence at launch"


def test_launch_check_offers_the_update(qapp, tmp_path):
    coordinator = make_coordinator(qapp, tmp_path)
    coordinator.run_at_launch()
    dialog = ScriptedDialog.last()
    assert dialog.release is not None
    assert dialog.release.version == AppVersion("0.2.0")


def test_the_launch_check_is_reported_as_checked(qapp, tmp_path):
    """The signal is how the About button leaves its busy state."""
    seen: list[object] = []
    coordinator = make_coordinator(qapp, tmp_path)
    coordinator.checked.connect(seen.append)
    coordinator.run_at_launch()
    assert len(seen) == 1


def test_a_second_launch_check_does_not_stack(qapp, tmp_path):
    """A second check while one is in flight is refused, not queued."""
    coordinator = make_coordinator(qapp, tmp_path)
    pending: list = []

    def defer(work, job):
        pending.append((work, job))

    coordinator._runner = defer
    coordinator.run_at_launch()
    coordinator.run_at_launch()
    assert len(pending) == 1
    # The first check's answer is delivered after the second was refused.
    work, job = pending[0]
    job.finished.emit(work())


# --------------------------------------------------------------------------
# The About button
# --------------------------------------------------------------------------


def test_about_check_reports_up_to_date(qapp, tmp_path):
    coordinator = make_coordinator(qapp, tmp_path, tag="v0.1.0")
    coordinator.check_from_about()
    dialog = ScriptedDialog.last()
    assert dialog.message == "You are up to date"
    assert dialog.release is None


def test_about_check_reports_the_update(qapp, tmp_path):
    coordinator = make_coordinator(qapp, tmp_path)
    coordinator.check_from_about()
    dialog = ScriptedDialog.last()
    assert dialog.release is not None
    assert dialog.release.tag_name == "v0.2.0"


def test_about_check_reports_a_failure(qapp, tmp_path):
    coordinator = make_coordinator(
        qapp, tmp_path, checker_override=failing_checker()
    )
    coordinator.check_from_about()
    assert ScriptedDialog.last().message == "Could not check for updates"


def test_about_check_reports_a_release_with_no_linux_archive(qapp, tmp_path):
    """Nothing to install is a sentence, not a silent no-op."""
    document = json.dumps(
        {
            "tag_name": "v0.2.0",
            "assets": [
                {
                    "name": "binaural-0.2.0-macos-arm64.tar.gz",
                    "browser_download_url": "https://example.invalid/a.tar.gz",
                }
            ],
        }
    )
    coordinator = make_coordinator(
        qapp,
        tmp_path,
        checker_override=UpdateChecker(fetch=lambda _url: document),
    )
    coordinator.check_from_about()
    assert ScriptedDialog.last().message == "Version 0.2.0 is available"
    coordinator.download_and_install()
    assert ScriptedDialog.last().message == "Could not check for updates"


# --------------------------------------------------------------------------
# The user's answer
# --------------------------------------------------------------------------


def test_download_and_install_runs_the_sequence(qapp, tmp_path):
    events: list[str] = []
    ScriptedDialog.reset(Choice.DOWNLOAD)
    coordinator = make_coordinator(qapp, tmp_path, events=events)
    coordinator.check_from_about()
    assert events == ["download", "replace", "relaunch"]


def test_declining_the_restart_confirmation_installs_nothing(qapp, tmp_path):
    events: list[str] = []
    ScriptedDialog.reset(Choice.DOWNLOAD)
    coordinator = make_coordinator(
        qapp, tmp_path, events=events, confirm_install=lambda: False
    )
    coordinator.check_from_about()
    assert events == ["download"], "nothing is installed when the user declines"


def test_skip_remembers_the_version(qapp, tmp_path):
    target = TargetSpy()
    ScriptedDialog.reset(Choice.SKIP)
    coordinator = make_coordinator(qapp, tmp_path, target=target)
    coordinator.check_from_about()
    assert target.skipped == "0.2.0"
    assert target.persisted == ["0.2.0"]

    # The next launch check with the same release is silent.
    ScriptedDialog.reset()
    launch = make_coordinator(qapp, tmp_path, target=target)
    launch.run_at_launch()
    assert ScriptedDialog.shown == [], "the skipped version stays silent at launch"


def test_later_installs_nothing_and_remembers_nothing(qapp, tmp_path):
    events: list[str] = []
    target = TargetSpy()
    ScriptedDialog.reset(Choice.LATER)
    coordinator = make_coordinator(qapp, tmp_path, target=target, events=events)
    coordinator.check_from_about()
    assert events == []
    assert target.skipped is None
    assert target.persisted == []


def test_the_user_can_ask_about_a_skipped_version(qapp, tmp_path):
    """"Skipped" is not "hidden": the About button still reports the release."""
    target = TargetSpy(skipped="0.2.0")
    coordinator = make_coordinator(qapp, tmp_path, target=target)
    coordinator.check_from_about()
    dialog = ScriptedDialog.last()
    assert dialog.release is not None
    assert dialog.release.version == AppVersion("0.2.0")


def test_a_failed_download_is_reported_and_installs_nothing(qapp, tmp_path):
    events: list[str] = []
    ScriptedDialog.reset(Choice.DOWNLOAD)

    def explode(_url, _progress):
        raise UpdateDownloadError("the download answered 404")

    coordinator = make_coordinator(qapp, tmp_path, events=events)
    coordinator._downloader = UpdateDownloader(load=explode)
    coordinator.check_from_about()
    assert events == []
    assert ScriptedDialog.last().message == "Could not download the update."


def test_a_failed_install_is_reported(qapp, tmp_path):
    ScriptedDialog.reset(Choice.DOWNLOAD)

    def refuse(_new_root, _current):
        from binaural.core.update_installer import ReplaceFailed

        raise ReplaceFailed("nothing is installed")

    coordinator = make_coordinator(qapp, tmp_path)
    coordinator._installer = UpdateInstaller(replace=refuse, relauncher=lambda _e: None)
    coordinator.check_from_about()
    assert ScriptedDialog.last().message == "Could not install the update."


def test_the_progress_window_shows_the_whole_range(qapp, tmp_path):
    ScriptedDialog.reset(Choice.DOWNLOAD)
    coordinator = make_coordinator(qapp, tmp_path)
    coordinator.check_from_about()
    window = ScriptedProgress.built[-1]
    assert window.fractions == [0.5, 1.0]
    assert window.closed is True, "the window closes itself when the download ends"


# --------------------------------------------------------------------------
# The dialogs, in the real widgets
# --------------------------------------------------------------------------


def test_the_result_dialog_offers_the_update(qapp):
    release = checker().latest_release()
    dialog = UpdateDialog(release=release)
    try:
        assert dialog.message_text == "Version 0.2.0 is available"
        assert dialog.is_download_visible() is True
        assert dialog.is_skip_visible() is True
        assert dialog.dismiss_text() == "Later"
        assert dialog.choice is Choice.LATER
    finally:
        dialog.deleteLater()


def test_the_result_dialog_reports_up_to_date(qapp):
    dialog = UpdateDialog(message="You are up to date")
    try:
        assert dialog.is_download_visible() is False
        assert dialog.is_skip_visible() is False
        assert dialog.dismiss_text() == "Close"
    finally:
        dialog.deleteLater()


def test_the_result_dialog_records_the_answer(qapp):
    release = checker().latest_release()
    for choice, press in (
        (Choice.DOWNLOAD, "click_download"),
        (Choice.SKIP, "click_skip"),
        (Choice.LATER, "click_dismiss"),
    ):
        dialog = UpdateDialog(release=release)
        try:
            getattr(dialog, press)()
            assert dialog.choice is choice
        finally:
            dialog.deleteLater()


def test_the_result_dialog_follows_the_language(qapp):
    release = checker().latest_release()
    i18n.set_language("ru")
    try:
        dialog = UpdateDialog(release=release)
        try:
            assert dialog.message_text == "Доступна версия 0.2.0"
            assert dialog.dismiss_text() == "Позже"
        finally:
            dialog.deleteLater()
        up_to_date = UpdateDialog(message="You are up to date")
        try:
            # The message is passed in translated by the caller; the *buttons* are
            # the dialog's own and follow the language.
            assert up_to_date.dismiss_text() == "Закрыть"
        finally:
            up_to_date.deleteLater()
    finally:
        i18n.set_language("en")


def test_the_release_page_button_opens_the_release(qapp, monkeypatch):
    release = checker().latest_release()
    opened: list[str] = []
    monkeypatch.setattr(
        "binaural.ui.dialogs.update.open_url", lambda url: opened.append(url) or True
    )
    dialog = UpdateDialog(release=release)
    try:
        assert not dialog._release_page_button.isHidden()
        dialog._release_page_button.click()
        assert opened == [release.html_url]
    finally:
        dialog.deleteLater()


def test_a_release_with_no_page_hides_the_release_button(qapp):
    release = checker().latest_release()
    without_page = type(release)(
        tag_name=release.tag_name, assets=release.assets
    )
    dialog = UpdateDialog(release=without_page)
    try:
        assert dialog._release_page_button.isHidden()
    finally:
        dialog.deleteLater()


def test_the_progress_window_reports_progress(qapp):
    progress = UpdateProgressDialog()
    try:
        assert progress.message_text == "Downloading update…"
        progress.set_progress(0.5)
        assert progress.progress == 50
        progress.set_progress(1.5)
        assert progress.progress == 100, "progress cannot run past the end"
        progress.set_progress(-1)
        assert progress.progress == 0, "progress cannot go backwards below zero"
    finally:
        progress.close_window()
        progress.deleteLater()


def test_the_about_dialog_carries_the_check_button(qapp):
    from binaural.ui.dialogs.about import AboutDialog

    dialog = AboutDialog()
    try:
        assert dialog.check_for_updates_text == "Check for updates"
        dialog.set_checking(True)
        assert dialog.check_for_updates_text == "Checking for updates…"
        dialog.set_checking(False)
        assert dialog.check_for_updates_text == "Check for updates"
    finally:
        dialog.deleteLater()


def test_the_about_button_runs_the_injected_coordinator(qapp):
    """The button is wired to the app's coordinator, not to one of its own."""
    from PySide6.QtCore import QObject, Signal

    from binaural.ui.dialogs.about import AboutDialog

    class Spy(QObject):
        checked = Signal(object)

        def __init__(self) -> None:
            super().__init__()
            self.parents: list[object] = []

        def check_from_about(self, parent=None) -> None:
            self.parents.append(parent)
            self.checked.emit(None)

    spy = Spy()
    dialog = AboutDialog(updates=spy)
    try:
        dialog.click_check_for_updates()
        assert spy.parents == [dialog]
        # The button says what it is and says what it is doing.
        assert dialog.check_for_updates_text == "Check for updates"
    finally:
        dialog.deleteLater()


def test_the_about_button_says_it_is_checking(qapp):
    """The busy state is real: the button reports the check and refuses a second one."""
    from PySide6.QtCore import QObject, Signal

    from binaural.ui.dialogs.about import AboutDialog

    class Silent(QObject):
        checked = Signal(object)

        def check_from_about(self, parent=None) -> None:
            return  # never finishes: the button stays busy, as it would over a network

    dialog = AboutDialog(updates=Silent())
    try:
        dialog.click_check_for_updates()
        assert dialog.check_for_updates_text == "Checking for updates…"
        assert dialog._check_updates_button.isEnabled() is False
        dialog.set_checking(False)
        assert dialog._check_updates_button.isEnabled() is True
    finally:
        dialog.deleteLater()


# --------------------------------------------------------------------------
# The launch sequence in app.py
# --------------------------------------------------------------------------


def test_the_launch_check_is_scheduled_after_the_window_is_up(qapp, monkeypatch, tmp_path):
    """Deferred like the headphone check, and after it: the two never open at once."""
    from binaural import app as binaural_app

    # ``main()`` persists the language choice; keep that out of the real settings.
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    scheduled: list[tuple[int, object]] = []
    monkeypatch.setattr(
        binaural_app.QTimer,
        "singleShot",
        lambda ms, callback: scheduled.append((ms, callback)),
    )

    class _Window:
        def run_launch_update_check(self) -> None:
            scheduled.append((0, "ran"))

        def show(self) -> None:
            pass

    class _Tray:
        def is_available(self) -> bool:
            return False

        def dispose(self) -> None:
            pass

    monkeypatch.setattr(binaural_app, "MainWindow", lambda *a, **k: _Window())
    monkeypatch.setattr(binaural_app, "TrayController", lambda *a, **k: _Tray())
    binaural_app.main(["binaural"])

    delays = [ms for ms, callback in scheduled if ms > 0]
    assert binaural_app.UPDATE_CHECK_DELAY_MS in delays
    assert delays.index(binaural_app.UPDATE_CHECK_DELAY_MS) == len(delays) - 1, (
        "the update check is the last thing scheduled: after the headphone check"
    )


def test_the_launch_check_never_fails_a_launch(qapp):
    """A broken coordinator must not take the window down with it."""
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    class _Engine:
        started = None
        stopped = None
        error = None

        def start(self) -> bool:
            return False

        def stop(self) -> None:
            pass

        def shutdown(self) -> None:
            pass

    class Broken:
        def run_at_launch(self) -> None:
            raise RuntimeError("no network stack at all")

    window = MainWindow(_Engine(), oscillator=StereoOscillator(), session=Session())
    window._updates = Broken()
    try:
        window.run_launch_update_check()  # must not raise
    finally:
        window.deleteLater()


# --------------------------------------------------------------------------
# The session-backed target
# --------------------------------------------------------------------------


def test_the_session_target_reads_and_writes_the_live_session(qapp):
    """The window saves the session wholesale, so the target holds that very object."""
    session = Session()
    target = SessionTarget(session)
    assert target.skipped_update_version() is None
    target.persist_skipped_update_version("0.2.0")
    assert session.skipped_update_version == "0.2.0"
    assert target.skipped_update_version() == "0.2.0"


def test_the_main_window_is_the_target(qapp):
    """``MainWindow.skipped_update_version`` is what the coordinator asks."""
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    class _Engine:
        started = None
        stopped = None
        error = None

        def start(self) -> bool:
            return False

        def stop(self) -> None:
            pass

        def shutdown(self) -> None:
            pass

    window = MainWindow(_Engine(), oscillator=StereoOscillator(), session=Session())
    try:
        assert window.skipped_update_version() is None
        window.persist_skipped_update_version("0.2.0")
        assert window.skipped_update_version() == "0.2.0"
        # And the snapshot the window saves carries it, so the next save cannot
        # silently forget a skipped release.
        assert window.current_session().skipped_update_version == "0.2.0"
    finally:
        window.deleteLater()