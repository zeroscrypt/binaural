"""The preset registry of SPEC §5 F3, checked against the rules F3 states.

The assertions here are the ones ``PresetCatalogueTests`` makes on the Swift side, and
they are the assertions F3 itself implies: seven categories, twenty presets, every beat
inside 1–30 Hz and inside **exactly one** half-open band, no Gamma, labels
``<band> <beat>``, and ``relaxation`` as the default. A registry edited away from F3
fails here rather than in the window.
"""

from __future__ import annotations

import math

import pytest

QtCore = pytest.importorskip("PySide6.QtCore")

from binaural import i18n  # noqa: E402
from binaural.core.oscillator import (  # noqa: E402
    DEFAULT_CARRIER_HZ,
    beat_frequency,
    carrier_frequency,
)
from binaural.core.session import DEFAULT_PRESET_CATEGORY, Session  # noqa: E402
from binaural.ui.presets import (  # noqa: E402
    MAX_PRESET_HZ,
    MIN_PRESET_HZ,
    PRESET_CATEGORIES,
    PRESETS,
    BrainwaveBand,
    Preset,
    band_name,
    category,
    category_index,
    category_name,
    frequencies_for,
    hz_text,
    preset_by_id,
    presets_in,
    resolved_category,
)


@pytest.fixture
def isolated_language(tmp_path, monkeypatch):
    """Switch the language inside one test and put it back afterwards.

    The same isolation ``tests/test_i18n.py`` uses: ``set_language`` writes QSettings and
    mutates process-wide state, so both are contained in a temporary HOME.
    """
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.setenv("HOME", str(tmp_path))
    QtCore.QSettings.setDefaultFormat(QtCore.QSettings.Format.IniFormat)

    def switch(code: str) -> str:
        return i18n.set_language(code)

    if i18n.language() != "en":
        i18n.set_language("en")
    yield switch
    i18n.set_language("en")


# ------------------------------------------------------------------- shape


def test_seven_categories_in_f3_order():
    assert [entry.id for entry in PRESET_CATEGORIES] == [
        "sleep",
        "meditation",
        "relaxation",
        "awareness",
        "concentration",
        "work",
        "sport",
    ]


def test_twenty_presets_in_total():
    assert len(PRESET_CATEGORIES) == 7
    assert len(PRESETS) == 20


def test_registry_matches_the_f3_table():
    """F3's own table, transcribed. If the registry and this table disagree, F3 wins."""
    expected = {
        "sleep": [1.0, 2.0, 3.0],
        "meditation": [4.0, 5.0, 6.0],
        "relaxation": [8.0, 9.0, 10.0],
        "awareness": [11.0, 12.0],
        "concentration": [13.0, 14.0, 15.0],
        "work": [16.0, 18.0, 20.0],
        "sport": [22.0, 25.0, 28.0],
    }
    assert len(expected) == len(PRESET_CATEGORIES)
    for entry in PRESET_CATEGORIES:
        assert [preset.beat_hz for preset in entry.presets] == expected[entry.id], entry.id


def test_presets_ascend_inside_each_category():
    for entry in PRESET_CATEGORIES:
        beats = [preset.beat_hz for preset in entry.presets]
        assert beats == sorted(beats), entry.id


def test_every_preset_names_its_own_category():
    for entry in PRESET_CATEGORIES:
        for preset in entry.presets:
            assert preset.category_id == entry.id


# ------------------------------------------------------------------- rules


def test_every_preset_is_inside_the_perceptible_range():
    """F3: «все пресеты внутри 1–30 Гц»."""
    for preset in PRESETS:
        assert MIN_PRESET_HZ <= preset.beat_hz <= MAX_PRESET_HZ, preset.id


def test_every_preset_falls_in_exactly_one_band():
    """F3: «каждый пресет попадает ровно в один диапазон §6.1»."""
    for preset in PRESETS:
        matches = [band for band in BrainwaveBand if band.contains(preset.beat_hz)]
        assert len(matches) == 1, f"{preset.id} matched {matches}"


def test_no_preset_is_in_the_gamma_band():
    """F3: «Gamma в пресеты не входит» — the 30 Hz cap is the reason."""
    for preset in PRESETS:
        assert preset.band is not BrainwaveBand.GAMMA, preset.id


@pytest.mark.parametrize(
    "beat_hz, expected",
    [
        (0.5, BrainwaveBand.DELTA),
        (3.99, BrainwaveBand.DELTA),
        (0.49, None),
        # 4 belongs to Theta, not Delta; 8 to Alpha; 13 to Beta.
        (4.0, BrainwaveBand.THETA),
        (8.0, BrainwaveBand.ALPHA),
        (13.0, BrainwaveBand.BETA),
        (29.99, BrainwaveBand.BETA),
        # …and nothing below 30 is Gamma.
        (30.0, BrainwaveBand.GAMMA),
        (100.0, BrainwaveBand.GAMMA),
        (100.1, None),
        (float("nan"), None),
        (float("inf"), None),
    ],
)
def test_band_boundaries_are_half_open(beat_hz, expected):
    """The half-open reading F3 asks for, at every shared endpoint."""
    assert BrainwaveBand.band_for(beat_hz) is expected


def test_band_range_labels_match_the_reference():
    assert [band.json_range_label for band in BrainwaveBand] == [
        "Delta 0.5–4 Hz",
        "Theta 4–8 Hz",
        "Alpha 8–13 Hz",
        "Beta 13–30 Hz",
        "Gamma 30–100 Hz",
    ]


def test_the_bands_are_read_out_of_the_reference():
    """F3 says the bounds come from `frequencies.json`; every band record is there."""
    from binaural.data import frequencies

    labels = {entry.label for entry in frequencies.load()[1]}
    for band in BrainwaveBand:
        assert band.json_range_label in labels


# ------------------------------------------------------------------ labels


def test_preset_ids_and_beat_text():
    assert PRESETS[0].id == "sleep-1"
    assert PRESETS[-1].id == "sport-28"
    # A whole number shows without a pointless ".0".
    for preset in PRESETS:
        assert "." not in preset.beat_text
    assert hz_text(10.5) == "10.5"


def test_preset_titles_are_band_then_beat_in_both_languages(isolated_language):
    """F3: the caption is `<band> <beat>`, localised, with the names it lists."""
    expected_en = {
        "sleep-1": "Delta 1",
        "meditation-6": "Theta 6",
        "relaxation-10": "Alpha 10",
        "awareness-12": "Alpha 12",
        "concentration-13": "Beta 13",
        "sport-28": "Beta 28",
    }
    expected_ru = {
        "sleep-1": "Дельта 1",
        "meditation-6": "Тета 6",
        "relaxation-10": "Альфа 10",
        "awareness-12": "Альфа 12",
        "concentration-13": "Бета 13",
        "sport-28": "Бета 28",
    }
    for preset_id, caption in expected_en.items():
        preset = preset_by_id(preset_id)
        assert preset is not None, preset_id
        isolated_language("en")
        assert preset.localized_title() == caption, preset_id
        isolated_language("ru")
        assert preset.localized_title() == expected_ru[preset_id], preset_id


def test_every_preset_title_is_band_then_beat(isolated_language):
    russian = {"Delta": "Дельта", "Theta": "Тета", "Alpha": "Альфа", "Beta": "Бета"}
    for preset in PRESETS:
        band = preset.band
        assert band is not None, preset.id
        for language, band_caption in (("en", band.value), ("ru", russian[band.value])):
            isolated_language(language)
            assert preset.localized_title() == f"{band_caption} {preset.beat_text}"


def test_category_names_follow_f3_in_both_languages(isolated_language):
    expected_en = [
        "Sleep",
        "Meditation",
        "Relaxation",
        "Awareness",
        "Concentration",
        "Work",
        "Sport",
    ]
    expected_ru = [
        "Сон",
        "Медитация",
        "Расслабление",
        "Ясность",
        "Сосредоточенность",
        "Работа",
        "Спорт",
    ]
    for language, expected in (("en", expected_en), ("ru", expected_ru)):
        isolated_language(language)
        assert [entry.localized_name() for entry in PRESET_CATEGORIES] == expected
        assert [category_name(entry.id) for entry in PRESET_CATEGORIES] == expected


def test_band_names_follow_the_f3_list(isolated_language):
    for language, names in (
        ("en", {"Delta": "Delta", "Theta": "Theta", "Alpha": "Alpha", "Beta": "Beta"}),
        (
            "ru",
            {"Delta": "Дельта", "Theta": "Тета", "Alpha": "Альфа", "Beta": "Бета"},
        ),
    ):
        isolated_language(language)
        for band, caption in names.items():
            assert band_name(BrainwaveBand(band)) == caption


# ------------------------------------------------- default category, unknown ids


def test_default_category_is_relaxation_and_matches_the_session():
    """F3: the default category is `relaxation` — one default, not two that can drift."""
    assert DEFAULT_PRESET_CATEGORY == "relaxation"
    assert resolved_category(None) == DEFAULT_PRESET_CATEGORY
    assert Session().preset_category == DEFAULT_PRESET_CATEGORY
    assert Session().preset_category == resolved_category("missing")


def test_unknown_category_falls_back_to_the_default():
    assert resolved_category(None) == "relaxation"
    assert resolved_category("") == "relaxation"
    assert resolved_category("focus") == "relaxation"
    assert resolved_category("work") == "work"


def test_unknown_category_yields_no_presets():
    assert presets_in("focus") == ()
    assert category("focus") is None
    assert category_index("focus") is None
    assert category_index("work") == 5


def test_presets_in_a_category_agree_with_the_category_list():
    for entry in PRESET_CATEGORIES:
        assert presets_in(entry.id) == entry.presets


def test_unknown_preset_id_is_none():
    assert preset_by_id("focus-9") is None
    assert preset_by_id("sleep-2") is not None


# ------------------------------------------------------------ applying a preset


def test_applying_a_preset_sets_both_channels_to_the_chosen_difference():
    """F3: one click sets **both** channels so the difference is the preset's beat."""
    for preset in PRESETS:
        left, right = frequencies_for(preset)
        assert beat_frequency(left, right) == pytest.approx(preset.beat_hz), preset.id
        assert carrier_frequency(left, right) == pytest.approx(
            DEFAULT_CARRIER_HZ
        ), preset.id


def test_the_spec_example_holds():
    """F3's own `fL = 205, fR = 215 → 10 Hz`, at the carrier that example implies."""
    at_210 = frequencies_for(Preset("relaxation", 10.0), carrier_hz=210.0)
    assert at_210 == (205.0, 215.0)
    # The default the app actually applies is CONTRACT §1's 200 Hz carrier.
    assert frequencies_for(Preset("relaxation", 10.0)) == (195.0, 205.0)


def test_no_registry_preset_leaves_the_audible_range():
    for preset in PRESETS:
        left, right = frequencies_for(preset)
        assert 1.0 <= left <= 20000.0
        assert 1.0 <= right <= 20000.0
        assert math.isfinite(left) and math.isfinite(right)
