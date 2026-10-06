"""The startup headphone check (SPEC §4.3).

The decision §4.3 now states: **detection runs on every start, the dialog does
not.** It opens while the warning has not been confirmed — the first launch, and
again only when the user asks for it (*Settings*, *Help → Check headphones…*).

The sequence in ``app.py`` is exercised against a real window with the two things
it touches — ``detect()`` and the dialog class — replaced, so the branch is tested
without a modal loop and without touching real audio hardware.
"""

from __future__ import annotations

import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QObject, Signal  # noqa: E402
from PySide6.QtWidgets import QApplication, QDialog  # noqa: E402

from binaural import app as binaural_app  # noqa: E402
from binaural.audio.headphones import HeadphoneReport  # noqa: E402
from binaural.audio.platform.base import AudioDevice, DeviceClass  # noqa: E402
from binaural.core.oscillator import StereoOscillator  # noqa: E402
from binaural.core.session import Session  # noqa: E402
from binaural.ui.main_window import MainWindow  # noqa: E402

SPEAKERS = HeadphoneReport(
    DeviceClass.SPEAKERS, AudioDevice("Динамики Mac mini", "builtin", True), "high"
)
HEADPHONES = HeadphoneReport(
    DeviceClass.HEADPHONES, AudioDevice("AirPods Pro", "bluetooth", True), "high"
)


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance()
    if app is None:
        try:
            app = QApplication(["binaural-startup-tests"])
        except Exception as exc:  # pragma: no cover - depends on the machine
            pytest.skip(f"No usable Qt display: {exc}")
    yield app


class FakeEngine(QObject):
    started = Signal()
    stopped = Signal()
    error = Signal(str)

    def __init__(self, oscillator=None, parent=None) -> None:
        super().__init__(parent)
        self.oscillator = oscillator

    def start(self) -> bool:
        return True

    def stop(self) -> None:
        pass

    def shutdown(self) -> None:
        pass


class FakeCheckDialog(QDialog):
    """Stands in for §4.3: a verdict, and the user's decision to continue."""

    shown = 0

    def __init__(self, report=None, engine=None, parent=None, *, detect_now=True) -> None:
        super().__init__(parent)
        type(self).shown += 1
        self._report = report or SPEAKERS
        self._acknowledged = False

    def exec(self) -> int:  # noqa: A003 - Qt virtual
        self.accept()
        return 1

    def accept(self) -> None:  # noqa: A003 - Qt virtual
        self._acknowledged = True

    def report(self) -> HeadphoneReport:
        return self._report

    def acknowledged(self) -> bool:
        return self._acknowledged


@pytest.fixture
def launch(qapp, monkeypatch):
    """Run the startup sequence with `report` as the detection result."""

    def run(report: HeadphoneReport, acknowledged: bool = False) -> MainWindow:
        FakeCheckDialog.shown = 0
        engine = FakeEngine(StereoOscillator())
        window = MainWindow(
            engine,
            oscillator=engine.oscillator,
            session=Session(headphone_check_acknowledged=acknowledged),
        )
        monkeypatch.setattr(binaural_app, "detect", lambda: report)
        monkeypatch.setattr(
            window, "_dialog_class", lambda name: FakeCheckDialog if "Headphone" in name else None
        )
        binaural_app._run_headphone_check(window)
        return window

    created: list[MainWindow] = []

    def _run(report, acknowledged=False):
        window = run(report, acknowledged)
        created.append(window)
        return window

    yield _run
    for window in created:
        window.close()
        window.deleteLater()
    qapp.processEvents()


def test_the_first_launch_warns(launch):
    """Speakers, nothing confirmed yet: the dialog opens and the warning sticks."""
    window = launch(SPEAKERS)
    assert FakeCheckDialog.shown == 1
    assert "Speakers detected" in window.status_indicator.text()
    assert window.headphone_check_acknowledged() is True


def test_the_dialog_does_not_come_back_on_the_next_launch(launch):
    """§4.3: once confirmed, no dialog on every start — but the status still tells."""
    window = launch(SPEAKERS, acknowledged=True)
    assert FakeCheckDialog.shown == 0
    assert "Speakers detected" in window.status_indicator.text()


def test_headphones_need_no_dialog_and_silence_the_warning(launch):
    window = launch(HEADPHONES)
    assert FakeCheckDialog.shown == 0
    assert "Headphones detected" in window.status_indicator.text()
    # Nothing to warn about any more, so the flag is set without asking anyone.
    assert window.headphone_check_acknowledged() is True


def test_detection_always_updates_the_indicator(launch):
    """Plugging headphones in after the warning was confirmed clears the status."""
    window = launch(HEADPHONES, acknowledged=True)
    assert FakeCheckDialog.shown == 0
    assert "Headphones detected" in window.status_indicator.text()
    assert window.headphone_report().is_headphones is True


def test_a_missing_dialog_layer_is_not_fatal(launch, monkeypatch):
    window = launch(SPEAKERS)
    monkeypatch.setattr(window, "_dialog_class", lambda name: None)
    # Second pass with no dialogs package: the status stays truthful.
    binaural_app._run_headphone_check(window)
    assert "Speakers detected" in window.status_indicator.text()


def test_failing_detection_never_stops_the_launch(launch, monkeypatch):
    def boom():
        raise RuntimeError("CoreAudio is unavailable")

    window = launch(SPEAKERS)
    monkeypatch.setattr(binaural_app, "detect", boom)
    binaural_app._run_headphone_check(window)  # must not raise
    assert window.status_indicator.text()
