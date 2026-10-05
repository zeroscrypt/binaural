"""Session persistence through QSettings."""

from __future__ import annotations

import pytest

QtCore = pytest.importorskip("PySide6.QtCore")

from binaural.core.session import Session, load, save  # noqa: E402


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
    )
    save(original)
    assert load() == original


def test_roundtrip_with_none_preset():
    original = Session(last_preset=None)
    save(original)
    assert load().last_preset is None


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