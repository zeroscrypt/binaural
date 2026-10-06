"""The preset registry of SPEC §5 F3 — the list both implementations share.

Seven categories, twenty presets, every beat inside **1–30 Hz** (§2.1: the range
of perceivable beats) and inside **exactly one** brainwave band, read with the
half-open bounds F3 tabulates. This replaced the five band chips
``PRESETS = (Delta 2, Theta 6, Alpha 10, Beta 20, Gamma 40)`` that used to live in
``main_window.py``: all five sat in the right band, but ``Gamma 40`` is outside the
30 Hz cap the very same rule imposes on presets, so Gamma does not appear here at
all. That is a rule about *presets* only — ``frequencies.json`` keeps ``Gamma 40 Hz``
and ``Gamma 30–100 Hz`` untouched, exactly as F3 says.

Swift implements the same registry in ``apple/Sources/Core/PresetCatalogue.swift``;
SPEC §5 F3 is the contract both read, and ``tests/test_presets.py`` states the same
rules the Swift suite states in ``PresetCatalogueTests``.

Two levels, because F3 makes the category part of the state: ``Session.preset_category``
is persisted, so the chips are a control the user picks rather than a heading. Selecting
a category never changes a frequency — only choosing a preset does, and it then sets
**both** channels at once (SPEC F3).

Names are English source strings of the shared catalogue, so the Russian text stays in
``binaural/locales/ru.py`` (§7.4) instead of being stored a second time beside the data.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from ..core.oscillator import DEFAULT_CARRIER_HZ, pair_from_beat
from ..core.session import DEFAULT_PRESET_CATEGORY
from ..i18n import tr

__all__ = [
    "BrainwaveBand",
    "Preset",
    "PresetCategory",
    "PRESET_CATEGORIES",
    "PRESETS",
    "MIN_PRESET_HZ",
    "MAX_PRESET_HZ",
    "DEFAULT_PRESET_CATEGORY",
    "category",
    "category_index",
    "presets_in",
    "preset_by_id",
    "resolved_category",
    "category_name",
    "band_name",
    "frequencies_for",
    "hz_text",
]


def hz_text(value: float) -> str:
    """Frequency text without a pointless ``.0`` on whole numbers."""
    value = float(value)
    if abs(value - round(value)) < 0.05:
        return f"{int(round(value))}"
    return f"{value:.1f}"


#: F3's band table, in catalogue order: band -> (lower bound, upper bound).
_BAND_BOUNDS: dict[str, tuple[float, float]] = {
    "Delta": (0.5, 4.0),
    "Theta": (4.0, 8.0),
    "Alpha": (8.0, 13.0),
    "Beta": (13.0, 30.0),
    "Gamma": (30.0, 100.0),
}

#: The ``frequencies.json`` record the bounds above are read from.
_BAND_RANGE_LABELS: dict[str, str] = {
    "Delta": "Delta 0.5–4 Hz",
    "Theta": "Theta 4–8 Hz",
    "Alpha": "Alpha 8–13 Hz",
    "Beta": "Beta 13–30 Hz",
    "Gamma": "Gamma 30–100 Hz",
}


class BrainwaveBand(Enum):
    """The brainwave bands of SPEC §6.1 / F3.

    The values are the **English** names, because they are also the identifier a
    catalogue record carries (``Alpha 10 Hz`` in ``frequencies.json``) and the source
    string the Russian catalogue translates.
    """

    DELTA = "Delta"
    THETA = "Theta"
    ALPHA = "Alpha"
    BETA = "Beta"
    GAMMA = "Gamma"

    @property
    def lower_bound_hz(self) -> float:
        """Lower bound, inclusive."""
        return _BAND_BOUNDS[self.value][0]

    @property
    def upper_bound_hz(self) -> float:
        """Upper bound, **exclusive** — except Gamma, which F3 tabulates closed.

        The bounds are half-open on purpose. F3 reads them out of
        ``frequencies.json``, where a band record is *one* record and the next one
        starts at the same number; with closed intervals 4, 8, 13 and 30 would each
        belong to two bands, and "exactly one band" would be false for four of the
        twenty presets.
        """
        return _BAND_BOUNDS[self.value][1]

    @property
    def json_range_label(self) -> str:
        """The matching ``frequencies.json`` record, where the bounds come from."""
        return _BAND_RANGE_LABELS[self.value]

    def contains(self, beat_hz: float) -> bool:
        """Does ``beat_hz`` fall inside this band under the half-open reading?"""
        beat_hz = float(beat_hz)
        if not math.isfinite(beat_hz) or beat_hz < self.lower_bound_hz:
            return False
        # Gamma is the only band closed at the top: F3 writes `[30, 100]`, and there is
        # no 100.1 Hz record for it to overlap with.
        if self is BrainwaveBand.GAMMA:
            return beat_hz <= self.upper_bound_hz
        return beat_hz < self.upper_bound_hz

    @classmethod
    def band_for(cls, beat_hz: float) -> BrainwaveBand | None:
        """The single band ``beat_hz`` falls into, or ``None`` when it falls into none.

        Because the bounds are half-open this is total: a value can never match twice,
        which is what F3's "exactly one band" rule asks for. Catalogue order rather than
        a numeric search, so adding a band cannot silently change the answer for an
        existing one.
        """
        for band in cls:
            if band.contains(beat_hz):
                return band
        return None


def band_name(band: BrainwaveBand) -> str:
    """The band name in the current language.

    F3 lists the four names it localises — ``Delta/Дельта``, ``Theta/Тета``,
    ``Alpha/Альфа``, ``Beta/Бета`` — as ordinary catalogue keys, so the Russian text
    lives in ``locales/ru.py`` like every other caption. ``Gamma`` is here for
    completeness (it is the one name F3 does not tabulate, because no preset is Gamma)
    and can never reach a preset label, see :attr:`Preset.band`.
    """
    return {
        BrainwaveBand.DELTA: tr("Delta"),
        BrainwaveBand.THETA: tr("Theta"),
        BrainwaveBand.ALPHA: tr("Alpha"),
        BrainwaveBand.BETA: tr("Beta"),
        BrainwaveBand.GAMMA: tr("Gamma"),
    }.get(band, band.value)


def category_name(category_id: str) -> str:
    """The category name in the current language — F3's own table, through the catalogue."""
    return {
        "sleep": tr("Sleep"),
        "meditation": tr("Meditation"),
        "relaxation": tr("Relaxation"),
        "awareness": tr("Awareness"),
        "concentration": tr("Concentration"),
        "work": tr("Work"),
        "sport": tr("Sport"),
    }.get(category_id, category_id)


@dataclass(frozen=True)
class Preset:
    """One preset: a beat difference inside a category (SPEC F3).

    A preset carries **no frequencies of its own**: one click sets both channels so that
    their difference is :attr:`beat_hz` around the default carrier.
    """

    category_id: str
    beat_hz: float

    @property
    def id(self) -> str:
        """Stable identifier, ``sleep-2``.

        Built from the beat rather than from an index, so it survives the registry being
        reordered — and it does not change with the UI language, which a caption would.
        """
        return f"{self.category_id}-{self.beat_text}"

    @property
    def beat_text(self) -> str:
        """The beat as text: ``2``, not ``2.0`` — no pointless zero on whole numbers."""
        return hz_text(self.beat_hz)

    @property
    def band(self) -> BrainwaveBand | None:
        """The band this preset belongs to.

        Never ``None`` for a registry entry; a preset outside every band would be a
        registry bug, and the tests fail on it rather than letting the UI invent a label.
        """
        return BrainwaveBand.band_for(self.beat_hz)

    def localized_title(self) -> str:
        """The chip caption ``<band> <beat>`` in the current language (SPEC F3)."""
        band = self.band
        return f"{band_name(band)} {self.beat_text}" if band is not None else self.beat_text


@dataclass(frozen=True)
class PresetCategory:
    """One level of the two-level preset control: a category and its presets."""

    id: str
    presets: tuple[Preset, ...]

    def localized_name(self) -> str:
        """The chip caption in the current language (SPEC F3's table)."""
        return category_name(self.id)


#: Presets stay inside this value (SPEC §2.1) …
MIN_PRESET_HZ: float = 1.0
#: … and not below this one.
MAX_PRESET_HZ: float = 30.0

#: F3's table, transcribed: category id -> the preset beats it holds, ascending.
#: Twenty beats in seven categories, none of them Gamma and none above 30 Hz.
_CATEGORY_BEATS: dict[str, tuple[float, ...]] = {
    "sleep": (1.0, 2.0, 3.0),
    "meditation": (4.0, 5.0, 6.0),
    "relaxation": (8.0, 9.0, 10.0),
    "awareness": (11.0, 12.0),
    "concentration": (13.0, 14.0, 15.0),
    "work": (16.0, 18.0, 20.0),
    "sport": (22.0, 25.0, 28.0),
}


def _build_categories() -> tuple[PresetCategory, ...]:
    return tuple(
        PresetCategory(
            id=category_id,
            presets=tuple(Preset(category_id, beat) for beat in beats),
        )
        for category_id, beats in _CATEGORY_BEATS.items()
    )


#: The registry, in the order F3's table lists it — that order is the chip order.
PRESET_CATEGORIES: tuple[PresetCategory, ...] = _build_categories()

#: Every preset, in registry order.
PRESETS: tuple[Preset, ...] = tuple(
    preset for entry in PRESET_CATEGORIES for preset in entry.presets
)


def category(category_id: str) -> PresetCategory | None:
    """The category with this id, or ``None``."""
    for entry in PRESET_CATEGORIES:
        if entry.id == category_id:
            return entry
    return None


def category_index(category_id: str) -> int | None:
    """Index of a category in chip order, or ``None`` when the id is unknown."""
    for index, entry in enumerate(PRESET_CATEGORIES):
        if entry.id == category_id:
            return index
    return None


def presets_in(category_id: str) -> tuple[Preset, ...]:
    """The presets of one category.

    Empty for an unknown id rather than a crash, so a hand-edited ``preset_category``
    degrades to an empty chip row instead of taking the window down.
    """
    entry = category(category_id)
    return entry.presets if entry is not None else ()


def preset_by_id(preset_id: str) -> Preset | None:
    """The preset with this id, or ``None``."""
    for preset in PRESETS:
        if preset.id == preset_id:
            return preset
    return None


def resolved_category(category_id: str | None) -> str:
    """A stored category id, or the default when it is missing or unknown.

    CONTRACT §7 allows ``preset_category`` to be a free string on the way *in* — the
    stored value is never discarded — so this only decides what the **chips** select.
    """
    if category_id and category(category_id) is not None:
        return category_id
    return DEFAULT_PRESET_CATEGORY


def frequencies_for(
    preset: Preset, carrier_hz: float = DEFAULT_CARRIER_HZ
) -> tuple[float, float]:
    """The pair a preset sets: both channels around ``carrier_hz``, difference = beat.

    F3's own example (``fL = 205, fR = 215 → 10 Hz``) illustrates the rule at a 210 Hz
    carrier; at the app default of 200 Hz the same preset is 195 / 205.
    """
    return pair_from_beat(float(preset.beat_hz), carrier_hz)
