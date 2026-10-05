"""AudioEngine tests. Skipped when QtMultimedia or a device is missing."""

from __future__ import annotations

import pytest

QtCore = pytest.importorskip("PySide6.QtCore")
QtWidgets = pytest.importorskip("PySide6.QtWidgets")

from binaural.core.engine import HAVE_QT_MULTIMEDIA, AudioEngine  # noqa: E402
from binaural.core.oscillator import StereoOscillator  # noqa: E402

if not HAVE_QT_MULTIMEDIA:
    pytest.skip("QtMultimedia is not available", allow_module_level=True)


@pytest.fixture(scope="module")
def app():
    instance = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield instance


@pytest.fixture
def outputs(app):
    from PySide6.QtMultimedia import QMediaDevices

    devices = QMediaDevices.audioOutputs()
    if not devices:
        pytest.skip("no audio device")
    return devices


@pytest.fixture
def engine(app, outputs):
    osc = StereoOscillator()
    osc.set_frequencies(205.0, 215.0)
    engine = AudioEngine(osc)
    yield engine
    engine.shutdown()


def _pump(app, ms: int = 60):
    loop = QtCore.QEventLoop()
    QtCore.QTimer.singleShot(ms, loop.quit)
    loop.exec()


def test_start_emits_started(engine, app):
    errors: list[str] = []
    engine.error.connect(errors.append)
    assert engine.start() is True
    _pump(app)
    assert engine.is_running is True
    assert errors == []
    engine.stop()
    _pump(app)
    assert engine.is_running is False


def test_start_twice_is_idempotent(engine, app):
    assert engine.start() is True
    _pump(app)
    assert engine.start() is True
    assert engine.is_running is True
    engine.stop()
    _pump(app)


def test_stop_emits_stopped(engine, app):
    seen: list[bool] = []
    engine.stopped.connect(lambda: seen.append(True))
    engine.start()
    _pump(app)
    engine.stop()
    assert seen == [True]


def test_volume_is_clamped_and_applied(engine, app):
    engine.volume = 0.5
    assert engine.volume == 0.5
    engine.volume = 5.0
    assert engine.volume == 1.0
    engine.volume = -1.0
    assert engine.volume == 0.0
    engine.volume = 0.4
    engine.start()
    _pump(app)
    assert engine.volume == pytest.approx(0.4)
    engine.stop()
    _pump(app)


def test_sample_rate_comes_from_device(engine, app):
    from PySide6.QtMultimedia import QMediaDevices

    device = QMediaDevices.defaultAudioOutput()
    preferred = device.preferredFormat()
    engine.start()
    _pump(app)
    assert engine.sample_rate == int(preferred.sampleRate())
    assert engine.sample_rate > 0
    engine.stop()
    _pump(app)


def test_shutdown_is_safe_and_repeatable(app, outputs):
    osc = StereoOscillator()
    engine = AudioEngine(osc)
    engine.start()
    _pump(app, 30)
    engine.shutdown()
    engine.shutdown()
    assert engine.is_running is False


def test_stop_without_start_is_noop(engine):
    engine.stop()
    assert engine.is_running is False


def test_sink_pulls_frames_and_oscillator_advances(engine, app):
    engine.oscillator.set_fade(1.0, 0.01)
    engine.start()
    _pump(app, 150)
    phase_l, phase_r = engine.oscillator.phase
    assert phase_l != 0.0 or phase_r != 0.0
    assert 0.0 <= phase_l < 1.0
    assert 0.0 <= phase_r < 1.0
    engine.stop()
    _pump(app)
    assert engine.is_running is False


def test_error_signal_when_no_device(monkeypatch, app):
    """A broken device must produce error(str) and start() == False."""
    from PySide6.QtMultimedia import QMediaDevices

    monkeypatch.setattr(QMediaDevices, "defaultAudioOutput", staticmethod(lambda: None))
    engine = AudioEngine(StereoOscillator())
    errors: list[str] = []
    engine.error.connect(errors.append)
    assert engine.start() is False
    assert len(errors) == 1
    assert isinstance(errors[0], str) and errors[0]
    assert engine.is_running is False