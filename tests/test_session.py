"""Session persistence through QSettings."""

from __future__ import annotations

import pytest

QtCore = pytest.importorskip("PySide6.QtCore")

from binaural.core.session import (  # noqa: E402
    DEFAULT_PRESET_CATEGORY,
    DEFAULT_TIMER_MINUTES,
    Session,
    load,
    save,
)


@pytest.fixture(autouse=True)
def isolated_settings(tmp_path, monkeypatch):
    """Keep tests away from the real user settings file."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setenv("HOME", str(tmp_path))
    settings = QtCore.QSettings("binaural", "binaural")
    settings.clear()
    settings.sync()
    yield
    settings.clear()
    settings.sync()


def test_defaults_match_contract():
    session = Session()
    assert session.left_hz == 205.0
    assert session.right_hz == 215.0
    assert session.volume == 0.7
    assert session.channels_swapped is False
    assert session.headphone_check_acknowledged is False
    assert session.last_preset is None
    assert session.timer_minutes == DEFAULT_TIMER_MINUTES
    assert session.preset_category == DEFAULT_PRESET_CATEGORY
    assert session.difference_locked is False


def test_roundtrip_keeps_the_timer_and_the_preset_category():
    """SPEC §5 F5: the timer and the preset category survive a restart."""
    original = Session(timer_minutes=45, preset_category="work")
    save(original)
    restored = load()
    assert restored.timer_minutes == 45
    assert restored.preset_category == "work"


def test_timer_is_clamped_on_load():
    save(Session(timer_minutes=9999))
    assert load().timer_minutes == 1440
    save(Session(timer_minutes=-5))
    assert load().timer_minutes == 0


def test_load_without_saved_state_returns_defaults():
    assert load() == Session()


def test_roundtrip_preserves_all_fields():
    original = Session(
        left_hz=210.5,
        right_hz=198.25,
        volume=0.35,
        channels_swapped=True,
        headphone_check_acknowledged=True,
        last_preset="alpha-10",
        difference_locked=True,
    )
    save(original)
    assert load() == original


def test_roundtrip_with_none_preset():
    original = Session(last_preset=None)
    save(original)
    assert load().last_preset is None


def test_roundtrip_keeps_the_difference_lock():
    """SPEC §7: the checkbox state survives a restart, like the timer does."""
    save(Session(left_hz=200.0, right_hz=260.0, difference_locked=True))
    restored = load()
    assert restored.difference_locked is True
    assert (restored.left_hz, restored.right_hz) == (200.0, 260.0)


def test_only_the_flag_is_stored():
    """The difference is re-derived from the pair, so no lock can contradict it.

    A session claiming to lock +10 Hz while carrying 200/215 is written exactly like any
    other: two frequencies and a boolean. There is nowhere to put a stale difference.
    """
    save(Session(left_hz=200.0, right_hz=260.0, difference_locked=True))
    settings = QtCore.QSettings("binaural", "binaural")
    assert settings.value("session/difference_locked") in (True, "true", "True")
    assert not any("difference" in key and key != "session/difference_locked" for key in settings.allKeys())


def test_a_session_written_before_the_lock_existed_still_loads():
    """The field is additive: an older settings file has no key and reads as `False`."""
    save(Session(left_hz=200.0, right_hz=260.0, timer_minutes=30))
    settings = QtCore.QSettings("binaural", "binaural")
    settings.remove("session/difference_locked")
    settings.sync()

    restored = load()
    assert restored.difference_locked is False
    assert restored.timer_minutes == 30
    assert (restored.left_hz, restored.right_hz) == (200.0, 260.0)


def test_an_unlocked_session_saves_it_unlocked():
    save(Session(difference_locked=True))
    save(Session())
    assert load().difference_locked is False


def test_a_nonsense_lock_value_falls_back_to_the_default():
    settings = QtCore.QSettings("binaural", "binaural")
    settings.setValue("session/difference_locked", "perhaps")
    settings.sync()
    assert load().difference_locked is False


def test_save_overwrites_previous_state():
    save(Session(left_hz=100.0, right_hz=110.0))
    save(Session(left_hz=300.0, right_hz=320.0, volume=0.1))
    restored = load()
    assert (restored.left_hz, restored.right_hz) == (300.0, 320.0)
    assert restored.volume == pytest.approx(0.1)


def test_volume_is_clamped_on_load():
    save(Session(volume=4.0))
    assert load().volume == 1.0


def test_settings_write_and_sync():
    save(Session())
    settings = QtCore.QSettings("binaural", "binaural")
    assert settings.contains("session/left_hz")
    settings.sync()
    assert settings.status() == QtCore.QSettings.Status.NoError

def test_roundtrip_keeps_the_skipped_update_version():
    """"Skip this version" is remembered across restarts, like the timer is."""
    save(Session(skipped_update_version="0.2.0"))
    assert load().skipped_update_version == "0.2.0"


def test_no_skipped_version_by_default():
    """A fresh session asks about every release."""
    assert Session().skipped_update_version is None
    assert load().skipped_update_version is None


def test_a_session_written_before_the_field_existed_still_loads():
    """The field is additive: an older settings file has no key and reads as `None`."""
    save(Session(timer_minutes=30, left_hz=200.0, right_hz=260.0))
    settings = QtCore.QSettings("binaural", "binaural")
    settings.remove("session/skipped_update_version")
    settings.sync()

    restored = load()
    assert restored.skipped_update_version is None
    assert restored.timer_minutes == 30
    assert (restored.left_hz, restored.right_hz) == (200.0, 260.0)


def test_an_empty_skipped_version_reads_as_none():
    """A blank string names no version, so it is "ask about everything"."""
    save(Session())
    settings = QtCore.QSettings("binaural", "binaural")
    settings.setValue("session/skipped_update_version", "   ")
    settings.sync()
    assert load().skipped_update_version is None
