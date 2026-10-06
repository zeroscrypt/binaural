"""Persisted user state, stored through QSettings."""

from __future__ import annotations

from dataclasses import asdict, dataclass

from PySide6.QtCore import QSettings

ORGANIZATION = "binaural"
APPLICATION = "binaural"


#: Playback timer in minutes; 0 means "no timer — play until stopped".
TIMER_OFF: int = 0
#: SPEC §2.1: studies stimulate for 5–15 minutes, so 15 is the default session.
DEFAULT_TIMER_MINUTES: int = 15
#: Preset durations offered in the timer control (minutes; 0 = off).
TIMER_CHOICES: tuple[int, ...] = (0, 5, 10, 15, 20, 30, 45, 60, 90, 120)
#: SPEC §5 F3: the preset category a fresh session starts on, and the one the preset
#: chips select. One value for both, so the default cannot drift into two.
DEFAULT_PRESET_CATEGORY: str = "relaxation"


@dataclass
class Session:
    left_hz: float = 205.0
    right_hz: float = 215.0
    volume: float = 0.7
    channels_swapped: bool = False
    headphone_check_acknowledged: bool = False
    last_preset: str | None = None
    #: Minutes before playback stops by itself; 0 = play indefinitely.
    timer_minutes: int = DEFAULT_TIMER_MINUTES
    #: Preset category id, persisted for the two-level preset picker (SPEC §5 F3).
    #: The allowed values live in `ui/presets.py` (the F3 registry), which `ui` imports —
    #: `core` must not import back, so load() keeps whatever string was stored instead of
    #: discarding it, and the chips fall back to the default for an unknown value.
    preset_category: str = DEFAULT_PRESET_CATEGORY
    #: SPEC §7's "Lock difference" checkbox: while ticked, editing one channel moves the
    #: other so the signed difference stays put. **Only the flag is stored** — the
    #: difference itself is re-derived from `right_hz - left_hz` on load, so a document can
    #: never hold a lock that contradicts the pair beside it. Additive: a session written
    #: before the field existed loads as `False`.
    difference_locked: bool = False


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
    category = settings.value("session/preset_category")

    def _int(key: str, fallback: int) -> int:
        raw = settings.value(key)
        try:
            return int(round(float(raw)))
        except (TypeError, ValueError):
            return fallback

    return Session(
        left_hz=_float("left_hz", defaults.left_hz),
        right_hz=_float("right_hz", defaults.right_hz),
        volume=min(1.0, max(0.0, _float("volume", defaults.volume))),
        channels_swapped=_bool("channels_swapped", defaults.channels_swapped),
        headphone_check_acknowledged=_bool(
            "headphone_check_acknowledged", defaults.headphone_check_acknowledged
        ),
        last_preset=None if preset is None else str(preset),
        # A timer longer than a day is a typo in the settings file, not a wish.
        timer_minutes=max(0, min(1440, _int("session/timer_minutes", defaults.timer_minutes))),
        preset_category=str(category) if category else defaults.preset_category,
        # Additive, so a settings file written before SPEC §7's checkbox has no key here
        # and reads as the default rather than failing.
        difference_locked=_bool("difference_locked", defaults.difference_locked),
    )