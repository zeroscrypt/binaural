"""Persisted user state, stored through QSettings."""

from __future__ import annotations

from dataclasses import asdict, dataclass

from PySide6.QtCore import QSettings

ORGANIZATION = "binaural"
APPLICATION = "binaural"


@dataclass
class Session:
    left_hz: float = 205.0
    right_hz: float = 215.0
    volume: float = 0.7
    channels_swapped: bool = False
    headphone_check_acknowledged: bool = False
    last_preset: str | None = None


def _settings() -> QSettings:
    return QSettings(ORGANIZATION, APPLICATION)


def save(session: Session) -> None:
    """Persist the session. Failures are non-fatal: state is a convenience."""
    data = asdict(session)
    settings = _settings()
    for key, value in data.items():
        settings.setValue(f"session/{key}", value)
    settings.sync()


def load() -> Session:
    """Read the session back, falling back to defaults for missing keys."""
    settings = _settings()
    defaults = Session()

    def _float(key: str, fallback: float) -> float:
        raw = settings.value(f"session/{key}")
        try:
            return float(raw)
        except (TypeError, ValueError):
            return fallback

    def _bool(key: str, fallback: bool) -> bool:
        raw = settings.value(f"session/{key}")
        if raw is None:
            return fallback
        if isinstance(raw, bool):
            return raw
        text = str(raw).strip().lower()
        if text in {"true", "1", "yes", "on"}:
            return True
        if text in {"false", "0", "no", "off"}:
            return False
        return fallback

    preset = settings.value("session/last_preset")
    return Session(
        left_hz=_float("left_hz", defaults.left_hz),
        right_hz=_float("right_hz", defaults.right_hz),
        volume=min(1.0, max(0.0, _float("volume", defaults.volume))),
        channels_swapped=_bool("channels_swapped", defaults.channels_swapped),
        headphone_check_acknowledged=_bool(
            "headphone_check_acknowledged", defaults.headphone_check_acknowledged
        ),
        last_preset=None if preset is None else str(preset),
    )