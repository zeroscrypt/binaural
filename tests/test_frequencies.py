"""Validity of the frequency reference (CONTRACT §5, SPEC §6)."""

from __future__ import annotations

import json

import pytest

from binaural.data import frequencies as fx

VALID_EVIDENCE = {"well-studied", "studied", "reported", "traditional"}
EXPECTED_CATEGORIES = [
    "brainwave",
    "schumann",
    "planetary",
    "solfeggio",
    "tuning",
    "research",
    "rife",
    "nasa",
    "healing",
    "substance",
    "affect",
]

EXPECTED_BADGES = {
    "well-studied": "\U0001F7E2",
    "studied": "\U0001F535",
    "reported": "\U0001F7E1",
    "traditional": "\U0001F7E3",
}


@pytest.fixture(scope="module")
def raw() -> dict:
    """The parsed JSON document, straight from disk."""
    return json.loads(fx._resolve_data_file().read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def loaded() -> tuple[list[fx.Category], list[fx.FrequencyEntry]]:
    return fx.load()


# --- file structure --------------------------------------------------------------

def test_json_parses(raw):
    assert raw["version"] == 1
    assert isinstance(raw["categories"], list)
    assert isinstance(raw["frequencies"], list)
    assert len(raw["frequencies"]) >= 90


def test_category_fields_are_complete(raw):
    for category in raw["categories"]:
        for field in ("id", "order", "icon", "color", "label_en", "label_ru",
                      "description_en", "description_ru"):
            assert str(category.get(field, "")).strip(), f"{category.get('id')}.{field} is empty"
        assert category["color"].startswith("#") and len(category["color"]) == 7


def test_all_eleven_categories_present_and_non_empty(loaded):
    categories, entries = loaded
    assert [c.id for c in categories] == EXPECTED_CATEGORIES
    assert [c.order for c in categories] == list(range(1, 12))
    for category in categories:
        assert any(e.category == category.id for e in entries), f"{category.id} is empty"


# --- per-entry validity ----------------------------------------------------------

def test_entry_category_exists(loaded):
    known = {c.id for c in loaded[0]}
    for entry in loaded[1]:
        assert entry.category in known, f"{entry.id}: unknown category {entry.category!r}"


def test_ids_are_globally_unique(loaded):
    ids = [e.id for e in loaded[1]]
    assert len(ids) == len(set(ids))


def test_evidence_values_are_allowed(loaded):
    for entry in loaded[1]:
        assert entry.evidence in VALID_EVIDENCE, f"{entry.id}: {entry.evidence!r}"


def test_frequency_values(loaded):
    for entry in loaded[1]:
        if entry.beat_hz is not None:
            assert entry.beat_hz > 0, f"{entry.id}: beat_hz must be > 0"
            assert entry.beat_min is None and entry.beat_max is None, entry.id
        else:
            assert entry.beat_min > 0, f"{entry.id}: beat_min must be > 0"
            assert entry.beat_max > entry.beat_min, f"{entry.id}: beat_max must exceed beat_min"
        assert entry.carrier_hz > 0, f"{entry.id}: carrier_hz must be > 0"


def test_effects_are_bilingual_and_non_empty(loaded):
    for entry in loaded[1]:
        assert entry.effect_en.strip(), f"{entry.id}: effect_en is empty"
        assert entry.effect_ru.strip(), f"{entry.id}: effect_ru is empty"
        assert entry.label.strip(), f"{entry.id}: label is empty"
        assert entry.source.strip(), f"{entry.id}: source is empty"


def test_science_entries_come_from_science_sources(loaded):
    """well-studied must never be backed by the alternative-medicine source."""
    for entry in loaded[1]:
        if entry.evidence == "well-studied":
            assert "EEG literature" in entry.source, f"{entry.id}: {entry.source!r}"


def test_traditional_entries_are_not_claimed_as_science(loaded):
    """traditional must not lean on the peer-reviewed source."""
    for entry in loaded[1]:
        if entry.evidence == "traditional":
            assert "EEG literature" not in entry.source, f"{entry.id}: {entry.source!r}"


# --- spec coverage ---------------------------------------------------------------

def test_spec_coverage(loaded):
    """Every category from SPEC §6 carries its expected contents."""
    _, entries = loaded
    by_category: dict[str, list[fx.FrequencyEntry]] = {}
    for entry in entries:
        by_category.setdefault(entry.category, []).append(entry)

    def beats(category: str) -> set[float]:
        return {e.beat_hz for e in by_category[category] if e.beat_hz is not None}

    # SPEC §6.3: five EEG bands plus the typical point values
    bands = {e.beat_min: e.beat_max for e in by_category["brainwave"] if e.is_range}
    assert bands == {0.5: 4.0, 4.0: 8.0, 8.0: 13.0, 13.0: 30.0, 30.0: 100.0}
    assert {1.94, 4.0, 10.0, 12.0, 14.0, 20.0, 40.0} <= beats("brainwave")

    # SPEC §6.4–6.5
    assert {7.83, 14.3, 20.8, 27.3, 33.8} <= beats("schumann")
    assert {126.22, 210.42, 141.27, 221.23, 144.72, 183.58, 147.85, 211.44, 144.25, 194.18} \
        <= beats("planetary")

    # SPEC §6.6–6.8
    assert {174.0, 285.0, 396.0, 417.0, 528.0, 639.0, 741.0, 852.0, 963.0} <= beats("solfeggio")
    assert {432.0, 440.0, 417.0, 136.1, 111.0} <= beats("tuning")
    assert {40.0, 10.0, 4.0, 2.0} <= beats("research")

    # SPEC §6.9: at least 15 Rife records, grouped by purpose
    rife = by_category["rife"]
    assert len(rife) >= 15
    assert {"infection", "pain", "inflammation", "nervous", "emotional", "other"} \
        <= {tag for e in rife for tag in e.tags}

    # SPEC §6.10–6.11
    assert 5 <= len(by_category["nasa"]) <= 10
    assert 5 <= len(by_category["healing"]) <= 10

    # SPEC §6.14–6.15: substances and mood, with the study-backed beats named
    assert len(by_category["substance"]) >= 4
    assert len(by_category["affect"]) >= 7
    assert {4.0, 5.0} <= beats("substance")
    assert {7.0, 16.0, 24.0, 40.0} <= beats("affect")


def test_substance_and_affect_entries_are_evidence_backed(loaded):
    """The two researched categories carry study citations, not tradition.

    Every record must name the study it comes from, so a reader can open it.
    """
    for entry in loaded[1]:
        if entry.category in {"substance", "affect"}:
            assert entry.evidence in {"studied", "reported"}, entry.id
            assert "DOI" in entry.source or "PMID" in entry.source, entry.id


def test_tonal_entries_are_flagged(loaded):
    """Tone frequencies live in beat_hz but are marked with the 'tonal' tag."""
    tonal = [e for e in loaded[1] if e.category in {"planetary", "solfeggio", "tuning"}]
    assert tonal
    for entry in tonal:
        assert entry.is_tonal, entry.id


# --- api behaviour ---------------------------------------------------------------

def test_load_is_cached(loaded):
    assert fx.load() is fx.load()
    assert fx.load() is loaded


def test_categories_are_sorted_and_counted(loaded):
    counts = fx.categories_with_counts()
    assert [c.id for c, _ in counts] == EXPECTED_CATEGORIES
    assert sum(n for _, n in counts) == len(loaded[1])
    assert all(n > 0 for _, n in counts)


def test_search_by_label_substring(loaded):
    for needle in ("alpha", "Schumann", "Om"):
        assert fx.search(needle), f"nothing found for {needle!r}"
    labels = {e.label.lower() for e in fx.search("gamma")}
    assert any("gamma" in label for label in labels)


def test_search_by_number(loaded):
    found = fx.search("7.83")
    assert {e.id for e in found} >= {"schumann-7-83", "nasa-7-83"}
    assert {e.id for e in fx.search("10")} >= {"brainwave-10", "research-10"}
    # A band boundary is findable too
    assert "brainwave-delta" in {e.id for e in fx.search("0.5")}


def test_search_by_category_and_empty_query(loaded):
    assert len(fx.search("")) == len(loaded[1])
    scoped = fx.search("", category="solfeggio")
    assert scoped and all(e.category == "solfeggio" for e in scoped)
    assert not fx.search("432", category="brainwave")


def test_search_matches_effect_text():
    assert fx.search("DNA", category="solfeggio")
    assert fx.search("заземление")


def test_evidence_badges():
    for level, badge in EXPECTED_BADGES.items():
        assert fx.evidence_badge(level) == badge
    assert fx.evidence_badge("nonsense") not in EXPECTED_BADGES.values()


def test_entries_expose_display_helpers(loaded):
    band = next(e for e in loaded[1] if e.is_range)
    assert "–" in band.frequency_text() and band.frequency_text().endswith("Hz")
    point = next(e for e in loaded[1] if not e.is_range)
    assert point.frequency_text().endswith(" Hz")
    assert point.badge == EXPECTED_BADGES[point.evidence]
