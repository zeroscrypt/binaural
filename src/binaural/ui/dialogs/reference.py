"""Frequency reference (SPEC §6, §6.12, §6.13).

Category sidebar with per-category counts, a search field across every category,
an evidence filter that hides nothing by default, and one card per record:
title -> frequency -> Apply -> effect -> evidence badge and source.

Emoji inside the sidebar and the badges are *data* from the reference registry
(SPEC §6.1), which SPEC §7.3 explicitly allows; interface chrome uses words and
shapes instead.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QFrame,
    QHBoxLayout,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from binaural.core.oscillator import DEFAULT_CARRIER_HZ, pair_from_beat
from binaural.data.frequencies import (
    Category,
    FrequencyEntry,
    categories_with_counts,
    evidence_badge,
    search,
)

from . import (
    SPACE_LG,
    SPACE_MD,
    SPACE_SM,
    SPACE_XS,
    button_row,
    make_button,
    make_label,
    make_panel,
    panel_layout,
    style_dialog,
    tr,
)
from .about import DISCLAIMER_TITLE, disclaimer_text

__all__ = [
    "ReferenceDialog",
    "frequencies_for",
    "ALL_CATEGORIES",
    "TONAL_BEAT_HZ",
    "EVIDENCE_LABELS",
]

#: Sentinel meaning "every category" in the sidebar.
ALL_CATEGORIES = ""

#: Beat applied to *tonal* records: those store a tone frequency, not a
#: difference, so the tone becomes the carrier and the beat stays perceivable.
TONAL_BEAT_HZ = 10.0

EVIDENCE_LABELS: dict[str, str] = {
    "well-studied": "Well-studied",
    "studied": "Studied",
    "reported": "Reported",
    "traditional": "Traditional",
}

_ALL_EVIDENCE = "All evidence"
_SEARCH_PLACEHOLDER = "Search name, frequency or effect…"
_NO_MATCHES = "Nothing matches this filter."
_CATEGORIES = "Categories"

_LIST_CATEGORY_ROLE = Qt.ItemDataRole.UserRole


def frequencies_for(entry: FrequencyEntry) -> tuple[float, float]:
    """``(left_hz, right_hz)`` for one reference record (SPEC §6.12 "Apply").

    A range record uses the middle of its band. A tonal record stores a tone
    frequency rather than a difference, so it becomes the carrier with a small
    default beat — otherwise "528 Hz" would be played as a 528 Hz *difference*.
    """
    carrier = float(entry.carrier_hz or DEFAULT_CARRIER_HZ)
    if entry.is_range:
        beat = (float(entry.beat_min or 0.0) + float(entry.beat_max or 0.0)) / 2.0
    elif entry.is_tonal:
        carrier = float(entry.beat_hz or carrier)
        beat = TONAL_BEAT_HZ
    else:
        beat = float(entry.beat_hz or 0.0)

    try:
        return pair_from_beat(beat, carrier)
    except ValueError:
        # Defensive: a record whose pair would leave the audible range falls back
        # to the default carrier instead of breaking the Apply button.
        return pair_from_beat(min(beat, TONAL_BEAT_HZ), DEFAULT_CARRIER_HZ)


def _evidence_label(evidence: str) -> str:
    label = EVIDENCE_LABELS.get(evidence)
    return tr(label, "Evidence") if label else evidence


class ReferenceDialog(QDialog):
    """Searchable, filterable frequency catalogue with an Apply signal."""

    #: ``(left_hz, right_hz)`` — the pair that realises the entry's difference.
    apply_frequencies = Signal(float, float)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("Frequency reference"))
        self.setAccessibleName(tr("Frequency reference"))
        self.setModal(True)
        self.resize(960, 680)

        self._category_id: str | None = None
        self._evidence: str | None = None
        self._cards: dict[str, QFrame] = {}
        self._shown: list[FrequencyEntry] = []
        self._cards_layout: QVBoxLayout | None = None
        self._counts: list[tuple[Category, int]] = []
        self._categories: dict[str, Category] = {}

        root = QVBoxLayout(self)
        root.setContentsMargins(SPACE_LG, SPACE_LG, SPACE_LG, SPACE_LG)
        root.setSpacing(SPACE_MD)

        root.addWidget(make_label(tr("Frequency reference"), role="heading"))
        root.addWidget(
            make_label(
                tr(
                    "Every record from the built-in reference, from EEG literature to "
                    "esoteric traditions. Nothing is ranked and nothing is hidden."
                ),
                role="muted",
                word_wrap=True,
            )
        )

        splitter_row = QHBoxLayout()
        splitter_row.setContentsMargins(0, 0, 0, 0)
        splitter_row.setSpacing(SPACE_MD)

        self._search_field = self._build_search()
        splitter_row.addWidget(self._search_field, 2)

        self._evidence_combo = self._build_evidence_filter()
        splitter_row.addWidget(self._evidence_combo, 1)
        root.addLayout(splitter_row)

        body = QHBoxLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(SPACE_MD)
        body.addWidget(self._build_sidebar(), 1)
        body.addWidget(self._build_results(), 3)
        root.addLayout(body, 1)

        self._disclaimer_panel = self._build_disclaimer()
        root.addWidget(self._disclaimer_panel)

        self._result_label = make_label(role="caption")
        self._disclaimer_button = make_button(
            tr("Disclaimer"),
            checkable=True,
            on_click=self._on_disclaimer_toggled,
            min_width=140,
            accessible_name=tr("Show or hide the medical disclaimer"),
            tooltip=tr("Medical and safety disclaimer."),
        )
        self._disclaimer_button.setChecked(True)
        close = make_button(
            tr("Close"),
            variant="primary",
            on_click=self.accept,
            min_width=120,
            accessible_name=tr("Close the frequency reference"),
        )
        close.setDefault(True)

        footer = button_row()
        footer.addWidget(self._result_label)
        footer.addStretch(1)
        footer.addWidget(self._disclaimer_button)
        footer.addWidget(close)
        root.addLayout(footer)
        self._close_button = close

        # Tab order: search -> evidence filter -> categories -> footer.
        self.setTabOrder(self._search_field, self._evidence_combo)
        self.setTabOrder(self._evidence_combo, self._category_list)
        self.setTabOrder(self._category_list, self._disclaimer_button)
        self.setTabOrder(self._disclaimer_button, close)

        self._refresh()
        style_dialog(self)
        self._search_field.setFocus()

    # ------------------------------------------------------------------ build

    def _build_search(self) -> QLineEdit:
        field = QLineEdit()
        field.setPlaceholderText(tr(_SEARCH_PLACEHOLDER, "ReferenceSearch"))
        field.setAccessibleName(tr("Search the frequency reference"))
        field.setClearButtonEnabled(True)
        field.textChanged.connect(self._on_query_changed)
        return field

    def _build_evidence_filter(self) -> QComboBox:
        combo = QComboBox()
        combo.setAccessibleName(tr("Filter by evidence level"))
        combo.setToolTip(
            tr("Badges show how well a record is studied. Nothing is hidden by default.")
        )
        combo.addItem(tr(_ALL_EVIDENCE, "Evidence"), "")
        for evidence in EVIDENCE_LABELS:
            combo.addItem(
                f"{evidence_badge(evidence)} {_evidence_label(evidence)}", evidence
            )
        combo.currentIndexChanged.connect(self._on_evidence_changed)
        return combo

    def _build_sidebar(self) -> QWidget:
        panel = make_panel()
        panel.setMaximumWidth(280)
        layout = panel_layout(panel, spacing=SPACE_SM)

        self._sidebar_title = make_label(tr(_CATEGORIES), role="heading")
        layout.addWidget(self._sidebar_title)

        self._category_list = QListWidget()
        self._category_list.setAccessibleName(tr("Reference categories"))
        self._category_list.setUniformItemSizes(True)
        self._category_list.setAlternatingRowColors(False)
        self._category_list.currentRowChanged.connect(self._on_category_changed)
        layout.addWidget(self._category_list, 1)

        self._populate_categories()
        self._category_list.setCurrentRow(0)
        return panel

    def _populate_categories(self) -> None:
        try:
            counts = categories_with_counts()
        except Exception:  # pragma: no cover - missing data file
            counts = []
        self._counts = counts
        self._categories = {category.id: category for category, _ in counts}

        total = sum(count for _, count in counts)
        all_item = QListWidgetItem(f"\U0001F4DB {tr('All categories')} ({total})")
        all_item.setData(_LIST_CATEGORY_ROLE, ALL_CATEGORIES)
        all_item.setToolTip(tr("Show every record of the reference"))
        self._category_list.addItem(all_item)

        # Order comes from the registry (``Category.order``), never from sorting
        # here: it is the single source of truth (SPEC §6.1).
        for category, count in counts:
            item = QListWidgetItem(
                f"{category.icon} {category.localized_label()} ({count})"
            )
            item.setData(_LIST_CATEGORY_ROLE, category.id)
            # The other language stays reachable on hover whichever one is shown.
            item.setToolTip(
                f"{category.localized_description()}\n{category.other_label()}"
            )
            self._category_list.addItem(item)

    def _build_results(self) -> QWidget:
        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setAccessibleName(tr("Reference records"))
        self._scroll.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )

        container = QWidget()
        self._cards_layout = QVBoxLayout(container)
        self._cards_layout.setContentsMargins(0, 0, SPACE_SM, 0)
        self._cards_layout.setSpacing(SPACE_MD)
        self._cards_layout.addStretch(1)
        self._scroll.setWidget(container)
        return self._scroll

    def _build_disclaimer(self) -> QWidget:
        panel = make_panel(object_name="disclaimer")
        panel.setAccessibleName(tr(DISCLAIMER_TITLE))
        layout = panel_layout(panel, spacing=SPACE_XS, margins=SPACE_MD)
        layout.addWidget(make_label(tr(DISCLAIMER_TITLE), role="heading"))
        self._disclaimer_label = make_label(
            disclaimer_text(),
            role="caption",
            word_wrap=True,
            selectable=True,
            tooltip=tr("Medical disclaimer — read it before using the application."),
        )
        layout.addWidget(self._disclaimer_label)
        return panel

    # ----------------------------------------------------------------- public

    @property
    def search_field(self) -> QLineEdit:
        return self._search_field

    @property
    def category_list(self) -> QListWidget:
        return self._category_list

    @property
    def evidence_combo(self) -> QComboBox:
        return self._evidence_combo

    @property
    def query(self) -> str:
        return self._search_field.text()

    @property
    def selected_category(self) -> str | None:
        """The active category id, or ``None`` for "All categories"."""
        return self._category_id

    @property
    def evidence_filter(self) -> str | None:
        """The active evidence level, or ``None`` when nothing is filtered."""
        return self._evidence

    @property
    def visible_entries(self) -> list[FrequencyEntry]:
        """The records currently on screen, ranges first, then by beat value."""
        return list(self._shown)

    @property
    def visible_entry_ids(self) -> list[str]:
        return [entry.id for entry in self._shown]

    @property
    def result_count_text(self) -> str:
        return self._result_label.text()

    @property
    def disclaimer_text(self) -> str:
        return self._disclaimer_label.text()

    @property
    def disclaimer_visible(self) -> bool:
        # ``isHidden`` is the explicit state and stays correct while the dialog
        # itself has not been shown yet.
        return not self._disclaimer_panel.isHidden()

    def set_disclaimer_visible(self, visible: bool) -> None:
        self._disclaimer_panel.setVisible(visible)
        self._disclaimer_button.setChecked(visible)

    def category_ids(self) -> list[str]:
        """Sidebar ids in display order, ``""`` first for "All categories"."""
        ids: list[str] = []
        for row in range(self._category_list.count()):
            item = self._category_list.item(row)
            ids.append(str(item.data(_LIST_CATEGORY_ROLE) or ""))
        return ids

    def category_counts(self) -> dict[str, int]:
        return {category.id: count for category, count in self._counts}

    def entry_card(self, entry_id: str) -> QWidget | None:
        """The card widget for a record, or ``None`` when it is filtered out."""
        return self._cards.get(entry_id)

    def set_query(self, text: str) -> None:
        self._search_field.setText(text)

    def select_category(self, category_id: str | None) -> None:
        """Select a sidebar row by id (``None``/``""`` for all categories)."""
        wanted = category_id or ALL_CATEGORIES
        for row in range(self._category_list.count()):
            item = self._category_list.item(row)
            if str(item.data(_LIST_CATEGORY_ROLE) or "") == wanted:
                self._category_list.setCurrentRow(row)
                return

    def set_evidence(self, evidence: str | None) -> None:
        """Filter by evidence level; ``None`` shows every level."""
        index = self._evidence_combo.findData(evidence or "")
        self._evidence_combo.setCurrentIndex(max(0, index))

    def apply_entry(self, entry: FrequencyEntry) -> tuple[float, float]:
        """Emit ``apply_frequencies`` for one record and return the pair."""
        left, right = frequencies_for(entry)
        self.apply_frequencies.emit(float(left), float(right))
        return (left, right)

    # ------------------------------------------------------------- behaviour

    def _on_query_changed(self, text: str) -> None:
        self._refresh()

    def _on_evidence_changed(self, index: int) -> None:
        data = self._evidence_combo.itemData(index)
        self._evidence = str(data) if data else None
        self._refresh()

    def _on_category_changed(self, row: int) -> None:
        item = self._category_list.item(row) if row >= 0 else None
        data = item.data(_LIST_CATEGORY_ROLE) if item is not None else None
        category_id = str(data) if data else None
        self._category_id = category_id or None
        self._refresh()

    def _on_disclaimer_toggled(self, checked: bool) -> None:
        self._disclaimer_panel.setVisible(checked)

    def _refresh(self) -> None:
        # The sidebar emits currentRowChanged while it is being populated, before
        # the results layout exists; the final _refresh() at the end of __init__
        # does the real work.
        if self._cards_layout is None:
            return
        self._clear_cards()
        entries = search(self.query, self._category_id)
        if self._evidence:
            entries = [entry for entry in entries if entry.evidence == self._evidence]
        # ``sort_key`` puts ranges first, then ascending beat value (SPEC §6.12).
        entries.sort(key=lambda entry: entry.sort_key)
        self._shown = entries

        if not entries:
            self._insert(make_label(tr(_NO_MATCHES), role="muted"))
        else:
            self._fill_cards(entries)

        self._result_label.setText(
            tr("Showing {shown} of {total} records").format(
                shown=len(entries), total=self._total_entries()
            )
        )

    def _total_entries(self) -> int:
        return sum(count for _, count in self._counts)

    def _clear_cards(self) -> None:
        self._cards.clear()
        # Take items from the front; the trailing stretch added in _build_results
        # stays, which is why the loop stops at one remaining item.
        while self._cards_layout.count() > 1:
            item = self._cards_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                # Re-parent before deleteLater so the card disappears at once
                # instead of lingering until the event loop runs.
                widget.setParent(None)
                widget.deleteLater()

    def _fill_cards(self, entries: list[FrequencyEntry]) -> None:
        """Group records by category with a header per group (SPEC §6.12)."""
        groups: dict[str, list[FrequencyEntry]] = {}
        for entry in entries:
            groups.setdefault(entry.category, []).append(entry)

        for category in self._ordered_categories(groups.keys()):
            group_entries = groups[category.id]
            if category.id in self._categories:
                self._insert(self._build_header(category, len(group_entries)))
            for entry in group_entries:
                card = self._build_card(entry)
                self._cards[entry.id] = card
                self._insert(card)

    def _ordered_categories(self, present) -> list[Category]:
        """Registry order, with unknown ids appended so nothing is lost."""
        wanted = set(present)
        ordered = [category for category, _ in self._counts if category.id in wanted]
        known = {category.id for category in ordered}
        for category_id in sorted(wanted - known):
            ordered.append(
                Category(
                    id=category_id,
                    order=10_000,
                    icon="\U0001F4C4",
                    color="",
                    label_en=category_id,
                    label_ru="",
                    description_en="",
                    description_ru="",
                )
            )
        return ordered

    def _insert(self, widget: QWidget) -> None:
        self._cards_layout.insertWidget(self._cards_layout.count() - 1, widget)

    def _build_header(self, category: Category, count: int) -> QWidget:
        header = QWidget()
        header.setAccessibleName(f"{category.localized_label()} ({count})")
        layout = QHBoxLayout(header)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(SPACE_SM)

        icon = make_label(category.icon, role="icon")
        # Icon + colour + text: three signals, colour is never alone.
        icon.setStyleSheet(f"color: {category.color}; background: transparent;")
        layout.addWidget(icon)

        titles = QVBoxLayout()
        titles.setContentsMargins(0, 0, 0, 0)
        titles.setSpacing(0)
        titles.addWidget(
            make_label(f"{category.localized_label()} ({count})", role="heading")
        )
        titles.addWidget(
            make_label(category.localized_description(), role="caption", word_wrap=True)
        )
        layout.addLayout(titles, 1)
        return header

    def _build_card(self, entry: FrequencyEntry) -> QFrame:
        card = make_panel(object_name="card")
        card.setAccessibleName(entry.label)
        card.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Minimum)
        layout = panel_layout(card, spacing=SPACE_XS)

        title_row = QHBoxLayout()
        title_row.setContentsMargins(0, 0, 0, 0)
        title_row.setSpacing(SPACE_SM)
        title_row.addWidget(make_label(entry.label, role="heading"), 1)

        apply_button = make_button(
            tr("Apply"),
            variant="channel",
            on_click=lambda _checked=False, item=entry: self.apply_entry(item),
            min_width=96,
            accessible_name=tr("Apply {label}").format(label=entry.label),
            tooltip=self._apply_tooltip(entry),
        )
        title_row.addWidget(apply_button)
        layout.addLayout(title_row)

        hint = tr("Carries {carrier} Hz").format(carrier=f"{entry.carrier_hz:g}")
        if entry.is_tonal:
            hint = tr("Tone — applied as the carrier with a {beat} Hz beat").format(
                beat=f"{TONAL_BEAT_HZ:g}"
            )
        layout.addWidget(make_label(f"{entry.frequency_text()}  ·  {hint}", role="muted"))

        # Effect in the current language on screen, the other one on hover.
        effect = make_label(
            entry.localized_effect(),
            word_wrap=True,
            tooltip=entry.other_effect() or entry.localized_effect(),
        )
        effect.setAccessibleDescription(
            entry.other_effect() or entry.localized_effect()
        )
        layout.addWidget(effect)

        badge = entry.badge
        meta = f"{badge} {_evidence_label(entry.evidence)}"
        if entry.source:
            meta = f"{meta}  ·  {entry.source}"
        layout.addWidget(make_label(meta, role="caption", word_wrap=True))
        return card

    def _apply_tooltip(self, entry: FrequencyEntry) -> str:
        left, right = frequencies_for(entry)
        return tr(
            "Set left = {left} Hz and right = {right} Hz (difference {beat})"
        ).format(
            left=f"{left:g}",
            right=f"{right:g}",
            beat=entry.frequency_text(),
        )
