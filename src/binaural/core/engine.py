"""Stereo output via QtMultimedia (QAudioSink).

Qt lives here only. The pull model is used: QAudioSink pulls interleaved
float32 frames from a QIODevice, so no extra thread and no timing drift.
"""

from __future__ import annotations

import struct

from PySide6.QtCore import (
    QCoreApplication,
    QDeadlineTimer,
    QEventLoop,
    QIODevice,
    QObject,
    QTimer,
    Signal,
)

# PySide6 6.11 dropped the module-level ``tr``; this wrapper keeps the call
# sites identical and gives lupdate a stable context to extract from.
_CONTEXT = "AudioEngine"


def tr(text: str) -> str:
    from ..i18n import tr as _tr

    return _tr(text, context=_CONTEXT)


from .oscillator import StereoOscillator

try:  # QtMultimedia is an Addon; report it at runtime instead of crashing on import.
    from PySide6.QtMultimedia import (
        QAudioFormat,
        QAudioSink,
        QMediaDevices,
        QtAudio,
    )

    HAVE_QT_MULTIMEDIA = True
except ImportError:  # pragma: no cover - depends on the installed PySide6 flavour
    QAudioFormat = QAudioSink = QMediaDevices = QtAudio = None  # type: ignore[assignment]
    HAVE_QT_MULTIMEDIA = False

FALLBACK_SAMPLE_RATE = 48000
CHANNELS = 2
POLL_INTERVAL_MS = 100
START_TIMEOUT_MS = 250
STOP_RAMP_SECONDS = 0.03
START_RAMP_SECONDS = 0.05

#: Error code -> English source text. Kept untranslated on purpose: the text
#: must be translated when it is *shown*, not when this module is imported —
#: a dict built by calling ``tr()`` at import time would freeze whatever
#: language happened to be active then (see ``_error_text``).
_ERROR_SOURCES: dict[int, str] = {
    0: "Audio is working.",
    1: "Could not open the audio output device.",
    2: "Audio device I/O error while writing samples.",
    3: "Audio device underrun: the buffer ran dry.",
    4: "Fatal audio error. Please restart the application.",
}


def _enum_value(value) -> int:
    """QAudio enums are not int-convertible in PySide6; read .value instead."""
    return int(getattr(value, "value", value))


_error_code = _enum_value

# Underrun recovers on its own, so it must not tear the engine down.
_BENIGN_ERRORS: frozenset[int] = (
    frozenset({_enum_value(QtAudio.Error.NoError), _enum_value(QtAudio.Error.UnderrunError)})
    if HAVE_QT_MULTIMEDIA
    else frozenset({0})
)


def _error_text(code: int) -> str:
    """Translated text for a ``QAudioSink`` error code.

    Translated on every call so that switching the language updates the audio
    error messages too.
    """
    source = _ERROR_SOURCES.get(int(code))
    return tr(source) if source is not None else tr("Unknown audio error.")


class _RenderSource(QIODevice):
    """Feeds QAudioSink with interleaved float32 stereo frames.

    ``isSequential`` and ``bytesAvailable`` must be overridden: the sink treats
    a non-sequential device as seekable and stops pulling from it.
    """

    def __init__(self, oscillator: StereoOscillator, parent: QObject | None = None):
        super().__init__(parent)
        self._oscillator = oscillator
        self._interleave = struct.Struct("<ff")
        self._read_only_bytes = 1 << 18

    def isSequential(self) -> bool:  # noqa: N802 - Qt virtual
        return True

    def bytesAvailable(self) -> int:  # noqa: N802 - Qt virtual
        # Endless stream: the sink keeps pulling as long as bytes are reported.
        return self._read_only_bytes

    def readData(self, max_size: int) -> bytes:  # noqa: N802 - Qt virtual
        frames = max_size // (self._interleave.size * CHANNELS)
        if frames <= 0:
            return b""
        left, right = self._oscillator.render(frames)
        pack = self._interleave.pack
        return b"".join(map(pack, left, right))


class AudioEngine(QObject):
    """Stereo signal output. QtMultimedia (QAudioSink) implementation."""

    started = Signal()
    stopped = Signal()
    error = Signal(str)  # user-facing text

    def __init__(self, oscillator: StereoOscillator, parent: QObject | None = None):
        super().__init__(parent)
        self._oscillator = oscillator
        self._sink = None
        self._source: _RenderSource | None = None
        self._volume = 0.7
        self._sample_rate = FALLBACK_SAMPLE_RATE
        self._running = False
        # QAudioSink.error is a getter and its stateChanged signal cannot be
        # converted in PySide6, so a timer polls the sink instead.
        self._poll = QTimer(self)
        self._poll.setInterval(POLL_INTERVAL_MS)
        self._poll.timeout.connect(self._poll_sink)

    # ----------------------------------------------------------------- state

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def volume(self) -> float:
        return self._volume

    @volume.setter
    def volume(self, value: float) -> None:
        try:
            level = float(value)
        except (TypeError, ValueError):
            return
        self._volume = min(1.0, max(0.0, level))
        if self._sink is not None:
            self._sink.setVolume(self._volume)

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    @property
    def oscillator(self) -> StereoOscillator:
        return self._oscillator

    # ------------------------------------------------------------ life cycle

    def start(self) -> bool:
        """Start playback. False plus error signal if no device is available."""
        if self._running:
            return True

        if not HAVE_QT_MULTIMEDIA:
            self.error.emit(tr("Audio output is not available in this build."))
            return False

        device = QMediaDevices.defaultAudioOutput()
        if device is None:
            self.error.emit(tr("No audio output device found."))
            return False

        preferred = device.preferredFormat()
        sample_rate = int(preferred.sampleRate()) if preferred.isValid() else 0
        if sample_rate <= 0:
            sample_rate = FALLBACK_SAMPLE_RATE
        self._sample_rate = sample_rate
        self._oscillator.set_sample_rate(sample_rate)

        audio_format = QAudioFormat()
        audio_format.setSampleRate(sample_rate)
        audio_format.setChannelCount(CHANNELS)
        audio_format.setSampleFormat(QAudioFormat.SampleFormat.Float)

        source = _RenderSource(self._oscillator, self)
        source.open(QIODevice.OpenModeFlag.ReadOnly)

        try:
            sink = QAudioSink(device, audio_format, self)
        except Exception as exc:  # pragma: no cover - driver specific
            source.close()
            self.error.emit(tr("Could not create the audio sink: {}").format(exc))
            return False

        sink.setVolume(self._volume)
        sink.start(source)

        self._sink = sink
        self._source = source

        if not self._wait_for_active(sink):
            self.error.emit(_error_text(_error_code(sink.error())))
            self._release()
            return False

        self._running = True
        self._poll.start()
        self.started.emit()
        return True

    def stop(self) -> None:
        """Stop playback; the amplitude ramps down so the next start is clean."""
        if not self._running:
            self._oscillator.set_pan(1.0, 1.0)
            self._release()
            return
        self._oscillator.set_fade(0.0, STOP_RAMP_SECONDS)
        self._oscillator.set_pan(1.0, 1.0)
        self._release()
        self.stopped.emit()

    # -- single-ear test tones (headphone check) ----------------------------

    def play_left_tone(self, freq_hz: float, seconds: float) -> bool:
        """Play ``freq_hz`` in the left ear only. Used by the L/R test."""
        return self._play_tone(freq_hz, pan=(1.0, 0.0))

    def play_right_tone(self, freq_hz: float, seconds: float) -> bool:
        """Play ``freq_hz`` in the right ear only. Used by the L/R test."""
        return self._play_tone(freq_hz, pan=(0.0, 1.0))

    def _play_tone(self, freq_hz: float, pan: tuple[float, float]) -> bool:
        """Hard-panned tone: one oscillator, one audible ear."""
        osc = self._oscillator
        osc.set_frequencies(freq_hz, freq_hz)
        osc.set_pan(*pan)
        osc.set_fade(1.0, START_RAMP_SECONDS)
        return self.start()

    def shutdown(self) -> None:
        """Always stops and frees the device, safe to call more than once."""
        self.stop()
        self._release()

    # --------------------------------------------------------------- private

    @staticmethod
    def _wait_for_active(sink, timeout_ms: int = START_TIMEOUT_MS) -> bool:
        """Wait until the sink is active or reports a real error."""
        deadline = QDeadlineTimer(timeout_ms)
        while sink.state() != QtAudio.State.ActiveState:
            if _error_code(sink.error()) not in _BENIGN_ERRORS:
                return False
            if deadline.hasExpired():
                return False
            app = QCoreApplication.instance()
            if app is None:
                break
            app.processEvents(QEventLoop.ProcessEventsFlag.AllEvents, 5)
        return True

    def _poll_sink(self) -> None:
        """Watchdog for device loss while playing."""
        sink = self._sink
        if sink is None or not self._running:
            return
        code = _error_code(sink.error())
        if code in _BENIGN_ERRORS:
            return
        self._running = False
        self._poll.stop()
        self.error.emit(_error_text(code))
        self._release()

    def _release(self) -> None:
        self._poll.stop()
        sink, self._sink = self._sink, None
        source, self._source = self._source, None
        if sink is not None:
            try:
                sink.stop()
                sink.deleteLater()
            except RuntimeError:  # pragma: no cover - already deleted by Qt
                pass
        if source is not None:
            source.close()
            source.deleteLater()
        self._running = False