"""The chakra sequence: seven solfeggio steps, the measured default beat, and the pair.

The frequencies are the contract. A solfeggio set is a fixed table, and a mode that
drifts from it is not the mode — it is a different app. The default beat is pinned here
too, because it was measured rather than chosen: 21 Hz is the pulsing rate of the
reference recording, and changing it silently would change what the mode is.
"""

from __future__ import annotations

import math

import pytest

from binaural.core import chakras
from binaural.core.chakras import (
    DEFAULT_BEAT_HZ,
    DEFAULT_STEP_SECONDS,
    MAX_BEAT_HZ,
    MIN_BEAT_HZ,
    STEPS,
    STEP_SECONDS_CHOICES,
    step_text,
)


# ---------------------------------------------------------------- shape


def test_eight_steps_from_earth_to_crown():
    """Eight, not seven: the earth step below the root is 174 Hz, the lowest tone of
    the extended Solfeggio set — the one called *the foundation*, for grounding and
    stability. Without it the sequence starts one step up the spine."""
    assert [step.id for step in STEPS] == [
        "earth",
        "root",
        "sacral",
        "solar-plexus",
        "heart",
        "throat",
        "third-eye",
        "crown",
    ]


def test_the_frequencies_are_the_solfeggio_set():
    assert [step.hz for step in STEPS] == [
        174, 396, 417, 528, 639, 741, 852, 963
    ]


def test_the_steps_rise():
    """The mode rises. A sequence that went up and down would not be "from root to
    crown", and the order is the whole point of the mode."""
    hz = [step.hz for step in STEPS]
    assert hz == sorted(hz)
    assert len(set(hz)) == len(hz), "no step repeats a frequency"


def test_every_step_is_named_and_described():
    for step in STEPS:
        assert chakras.step_name(step.id), f"{step.id} has no name"
        assert chakras.step_description(step.id), f"{step.id} has no description"


def test_the_names_are_captions_and_not_ids():
    """A step that fell through to its id would show `solar-plexus` in the panel, which
    is not a caption anyone can read."""
    for step in STEPS:
        assert chakras.step_name(step.id) != step.id


# ---------------------------------------------------------------- the beat


def test_the_default_beat_is_the_measured_one():
    """21.00 Hz came out of a spectrum analysis of a reference recording: the envelope
    of its 380-430 Hz band pulsated at exactly 21 Hz in every step after the first."""
    assert DEFAULT_BEAT_HZ == 21.0


def test_the_default_beat_is_inside_the_allowed_range():
    assert MIN_BEAT_HZ <= DEFAULT_BEAT_HZ <= MAX_BEAT_HZ


def test_the_default_step_is_half_a_minute():
    """The step is the *switch timer*: how long a chakra lasts before the next one.

    The choices are half a minute, one, two and five minutes. A journey of fifteen steps
    at half a minute is a quarter of an hour, which is a session; at five minutes it is
    an afternoon, which is not.
    """
    assert DEFAULT_STEP_SECONDS == 30
    assert list(STEP_SECONDS_CHOICES) == [30, 60, 120, 300]
    assert DEFAULT_STEP_SECONDS in STEP_SECONDS_CHOICES


def test_a_step_is_capped_in_whole_minutes():
    """A step is shown in seconds below a minute and in minutes above it."""
    assert step_text(30) == "30 s"
    assert step_text(60) == "1 min"
    assert step_text(300) == "5 min"


# ---------------------------------------------------------------- the pair


def test_the_pair_is_centred_on_the_carrier():
    """The carrier is the step's own frequency and the beat is split evenly, so the
    pitch a listener hears stays on the solfeggio note."""
    step = STEPS[3]  # 528 Hz, the solar plexus
    left, right = chakras.pair(step, 21)
    assert (left + right) / 2 == pytest.approx(528, abs=0.05)
    assert right - left == pytest.approx(21, abs=0.05)


@pytest.mark.parametrize("step", STEPS, ids=lambda step: step.id)
@pytest.mark.parametrize("beat", [MIN_BEAT_HZ, 21.0, 40.0])
def test_every_pair_is_quantised_and_audible(step, beat):
    """The engine only plays quantised frequencies, so an unquantised pair would not be
    what the slider and the readout show."""
    left, right = chakras.pair(step, beat)
    assert left == pytest.approx(round(left, 1))
    assert right == pytest.approx(round(right, 1))
    assert 1.0 <= left <= 20000.0
    assert 1.0 <= right <= 20000.0


def test_the_beat_is_clamped_into_range():
    """A beat outside the range is clamped rather than refused: the field it comes from
    is free text, and refusing would leave the mode stuck on the old value."""
    step = STEPS[0]
    low_left, low_right = chakras.pair(step, 0)
    assert low_right - low_left == pytest.approx(MIN_BEAT_HZ, abs=0.1)
    high_left, high_right = chakras.pair(step, 5000)
    assert high_right - high_left == pytest.approx(MAX_BEAT_HZ, abs=0.1)


@pytest.mark.parametrize("bad", [math.nan, math.inf, -math.inf])
def test_a_non_finite_beat_falls_back_to_the_default(bad):
    """A half-typed field is not a number, and a non-finite beat must not reach the
    engine. Swift's `isFinite` check takes the same branch."""
    left, right = chakras.pair(STEPS[0], bad)
    assert right - left == pytest.approx(DEFAULT_BEAT_HZ, abs=0.1)


# ---------------------------------------------------------------- indexing


@pytest.mark.parametrize(
    "given, expected", [(-5, 0), (0, 0), (6, 6), (99, len(STEPS) - 1)]
)
def test_the_index_is_clamped_into_range(given, expected):
    """The step index moves with a timer, so an out-of-range value has to be
    survivable rather than fatal."""
    assert chakras.step_index(given) == expected


def test_a_step_is_found_by_its_id():
    assert chakras.step_by_id("heart").hz == 639
    assert chakras.step_by_id("kundalini") is None


# ---------------------------------------------------------------- the palette


def test_the_palette_is_the_rainbow_from_root_to_crown():
    """The colours follow the rainbow from the bottom of the body to the top: red,
    orange, yellow, green, light blue, blue, violet. It is the order everyone already
    knows, so a reader can tell which chakra they are looking at from the colour."""
    from binaural.ui import theme

    assert chakras.PALETTE_TOKENS == (
        "chakra-earth",
        "chakra-root",
        "chakra-sacral",
        "chakra-solar-plexus",
        "chakra-heart",
        "chakra-throat",
        "chakra-third-eye",
        "chakra-crown",
    )
    for token in chakras.PALETTE_TOKENS:
        assert token in theme.TOKENS, f"{token} is not in the theme"
    light = [theme.TOKENS[token][0] for token in chakras.PALETTE_TOKENS]
    assert len(set(light)) == len(STEPS), "no two steps share a colour"


def test_the_palette_values_are_pinned():
    """The shades are muted on purpose: a saturated red on a dark background is a
    glare, and seven of them at once is a rainbow of noise. Pinned so a change to them
    is a decision rather than an accident."""
    from binaural.ui import theme

    assert theme.TOKENS["chakra-earth"] == ("#7A6E5C", "#B3A692")
    assert theme.TOKENS["chakra-root"] == ("#C8503F", "#F0877A")
    assert theme.TOKENS["chakra-sacral"] == ("#C06A22", "#F0A45F")
    assert theme.TOKENS["chakra-solar-plexus"] == ("#A1810F", "#E3C453")
    assert theme.TOKENS["chakra-heart"] == ("#3F8A4C", "#6FBE7C")
    assert theme.TOKENS["chakra-throat"] == ("#2E88A8", "#5FB6D2")
    assert theme.TOKENS["chakra-third-eye"] == ("#4E63C4", "#8A9BEA")
    assert theme.TOKENS["chakra-crown"] == ("#8149B0", "#B183DE")


def test_every_colour_clears_the_contrast_bar():
    """The frequency number is large text and the point on the figure is a non-text
    element; 3:1 is the bar both of them answer to."""
    from binaural.ui import theme

    def luminance(hex_colour: str) -> float:
        channels = [int(hex_colour[i : i + 2], 16) / 255 for i in (1, 3, 5)]
        linear = [
            c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels
        ]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

    def ratio(a: str, b: str) -> float:
        high, low = sorted((luminance(a), luminance(b)), reverse=True)
        return (high + 0.05) / (low + 0.05)

    for token in chakras.PALETTE_TOKENS:
        light, dark = theme.TOKENS[token]
        assert ratio(light, theme.LIGHT["surface"]) >= 3.0, f"{token} is too pale"
        assert ratio(dark, theme.DARK["surface"]) >= 3.0, f"{token} is too dark"
