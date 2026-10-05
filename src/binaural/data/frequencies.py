"""Frequency reference data.

Load and query the catalogue in ``frequencies.json`` (SPEC §6).
Pure data access — no Qt, no audio, no side effects.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

__all__ = [
    "Category",
    "FrequencyEntry",
    "DATA_FILE",
    "EVIDENCE_BADGES",
    "EVIDENCE_LEVELS",
    "load",
    "categories_with_counts",
    "search",
    "evidence_badge",
]

DATA_FILE = "frequencies.json"

#: Evidence levels of SPEC §6.2 — the badge is a hint, never a filter.
EVIDENCE_BADGES: dict[str, str] = {
    "well-studied": "\U0001F7E2",  # green circle
    "studied": "\U0001F535",  # blue circle
    "reported": "\U0001F7E1",  # yellow circle
    "traditional": "\U0001F7E3",  # purple circle
}

EVIDENCE_LEVELS: tuple[str, ...] = tuple(EVIDENCE_BADGES)


@dataclass(frozen=True)
class Category:
    """A reference category; ``icon``/``color`` come only from this registry."""

    id: str
    order: int
    icon: str
    color: str
    label_en: str
    label_ru: str
    description_en: str
    description_ru: str

    def localized_label(self) -> str:
        """Category name in the current UI language."""
        return self.label_ru if _russian() and self.label_ru else self.label_en

    def localized_description(self) -> str:
        """Category description in the current UI language."""
        return (
            self.description_ru
            if _russian() and self.description_ru
            else self.description_en
        )

    def other_label(self) -> str:
        """Category name in the *other* language — used for tooltips.

        Keeps the second language reachable on hover whichever one is shown.
        """
        return self.label_en if _russian() else self.label_ru


@dataclass(frozen=True)
class FrequencyEntry:
    """One reference record.

    Either ``beat_hz`` or the ``beat_min``/``beat_max`` pair is set, never both.
    Entries tagged ``tonal`` carry a tone frequency in ``beat_hz`` rather than a
    difference — see SPEC §6.5.
    """

    id: str
    category: str
    label: str
    beat_hz: float | None
    beat_min: float | None
    beat_max: float | None
    carrier_hz: float
    effect_en: str
    effect_ru: str
    evidence: str
    source: str
    tags: list[str] = field(default_factory=list)

    @property
    def is_range(self) -> bool:
        """True for band entries that span ``beat_min``..``beat_max``."""
        return self.beat_hz is None and self.beat_min is not None and self.beat_max is not None

    @property
    def is_tonal(self) -> bool:
        """True when ``beat_hz`` holds a tone frequency, not a beat difference."""
        return "tonal" in self.tags

    @property
    def badge(self) -> str:
        """Evidence badge for this entry."""
        return evidence_badge(self.evidence)

    def localized_effect(self) -> str:
        """Effect description in the current UI language."""
        return self.effect_ru if _russian() and self.effect_ru else self.effect_en

    def other_effect(self) -> str:
        """Effect description in the *other* language — used for tooltips.

        Keeps the second language reachable on hover whichever one is shown.
        """
        return self.effect_en if _russian() else self.effect_ru

    @property
    def sort_key(self) -> tuple[int, float, str]:
        """Ranges first, then ascending beat value (SPEC §6.12)."""
        if self.is_range:
            return (0, float(self.beat_min or 0.0), self.id)
        return (1, float(self.beat_hz or 0.0), self.id)

    def frequency_text(self) -> str:
        """Human-readable frequency: ``10 Hz`` or ``0.5–4 Hz``."""
        if self.is_range:
            return f"{_fmt(self.beat_min)}\u2013{_fmt(self.beat_max)} Hz"
        return f"{_fmt(self.beat_hz)} Hz"


def _fmt(value: float | None) -> str:
    """Format a frequency without a trailing ``.0``."""
    if value is None:
        return ""
    return f"{value:g}"


def _russian() -> bool:
    """True when the UI language is Russian.

    Resolved through :mod:`binaural.i18n` lazily so this module keeps working
    without Qt (the data layer is import-safe on its own) and so a language
    switch is picked up by the accessors below without a reload.
    """
    try:
        from ..i18n import language

        return language() == "ru"
    except Exception:
        return False


def _resolve_data_file() -> Path:
    """Locate ``frequencies.json`` next to this module.

    Works both from a source checkout and from an installed package.
    """
    return Path(__file__).resolve().parent / DATA_FILE


@lru_cache(maxsize=1)
def load() -> tuple[list[Category], list[FrequencyEntry]]:
    """Load and cache the reference.

    Returns ``(categories, entries)`` with categories sorted by ``order`` and
    entries ordered ranges-first then by beat value.
    """
    path = _resolve_data_file()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:  # pragma: no cover - broken installation
        raise FileNotFoundError(f"Frequency reference not found: {path}") from exc

    categories = [
        Category(
            id=str(c["id"]),
            order=int(c["order"]),
            icon=str(c["icon"]),
            color=str(c["color"]),
            label_en=str(c["label_en"]),
            label_ru=str(c["label_ru"]),
            description_en=str(c["description_en"]),
            description_ru=str(c["description_ru"]),
        )
        for c in raw.get("categories", [])
    ]
    categories.sort(key=lambda c: c.order)

    entries = [
        _make_entry(e) for e in raw.get("frequencies", [])
    ]
    entries.sort(key=lambda e: e.sort_key)

    return categories, entries


def _make_entry(data: dict[str, Any]) -> FrequencyEntry:
    """Build an entry from a raw JSON record; ``None`` for absent numbers."""
    return FrequencyEntry(
        id=str(data["id"]),
        category=str(data["category"]),
        label=str(data["label"]),
        beat_hz=_opt_float(data.get("beat_hz")),
        beat_min=_opt_float(data.get("beat_min")),
        beat_max=_opt_float(data.get("beat_max")),
        carrier_hz=float(data["carrier_hz"]),
        effect_en=str(data.get("effect_en", "")),
        effect_ru=str(data.get("effect_ru", "")),
        evidence=str(data.get("evidence", "")),
        source=str(data.get("source", "")),
        tags=[str(t) for t in data.get("tags", [])],
    )


def _opt_float(value: Any) -> float | None:
    return None if value is None else float(value)


def categories_with_counts() -> list[tuple[Category, int]]:
    """``[(category, entry_count), ...]`` in category ``order``."""
    categories, entries = load()
    counts: dict[str, int] = {}
    for entry in entries:
        counts[entry.category] = counts.get(entry.category, 0) + 1
    return [(category, counts.get(category.id, 0)) for category in categories]


def search(query: str, category: str | None = None) -> list[FrequencyEntry]:
    """Find entries by label, number, tag or effect text.

    An empty query returns everything (optionally restricted to ``category``).
    A numeric query matches ``beat_hz``/``beat_min``/``beat_max`` numerically as
    well as by text, so ``7.83`` finds the Schumann entry.
    """
    _, entries = load()
    needle = query.strip().lower()

    result = []
    for entry in entries:
        if category is not None and entry.category != category:
            continue
        if not needle or _matches(entry, needle):
            result.append(entry)
    return result


def _matches(entry: FrequencyEntry, needle: str) -> bool:
    """Text or numeric match against one entry."""
    number = _as_float(needle)
    if number is not None and _hits_number(entry, number):
        return True
    haystack = (
        entry.label,
        entry.id,
        entry.effect_en,
        entry.effect_ru,
        entry.category,
        " ".join(entry.tags),
    )
    return any(needle in field.lower() for field in haystack if field)


def _as_float(text: str) -> float | None:
    """Parse a frequency query; ``None`` when it is not a number."""
    try:
        return float(text.replace(" ", "").replace(",", "."))
    except ValueError:
        return None


def _hits_number(entry: FrequencyEntry, number: float) -> bool:
    """True when the query equals one of the entry's beat values (±0.01 Hz).

    The carrier is deliberately not matched: it is a default, so ``200`` would
    otherwise match almost every record.
    """
    for value in (entry.beat_hz, entry.beat_min, entry.beat_max):
        if value is not None and abs(value - number) <= 0.01:
            return True
    return False


def evidence_badge(evidence: str) -> str:
    """Badge for an evidence level; ``⚪`` for an unknown level.

    The badge is a hint for the reader, not a filter — nothing is hidden.
    """
    return EVIDENCE_BADGES.get(evidence, "⚪")
