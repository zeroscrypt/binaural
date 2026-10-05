"""Static data for Binaural: the frequency reference (SPEC §6).

Re-exports the load/query API so callers can use either::

    from binaural.data import load
    from binaural.data.frequencies import load
"""

from __future__ import annotations

from .frequencies import (
    DATA_FILE,
    EVIDENCE_BADGES,
    EVIDENCE_LEVELS,
    Category,
    FrequencyEntry,
    categories_with_counts,
    evidence_badge,
    load,
    search,
)

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
