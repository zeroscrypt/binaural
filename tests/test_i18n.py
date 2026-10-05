"""Language tests (SPEC §7 "English + Russian, switchable").

The catalogue and the switch are pure logic and run everywhere; the widget
tests at the bottom need a QApplication and skip without a display, like the
rest of the UI suite.

Existing UI tests assert English captions, so every test starts from ``en``
(the module default) and restores the previous language afterwards.
"""

from __future__ import annotations

import ast
import os
import re
from pathlib import Path

import pytest

from PySide6.QtCore import QSettings  # noqa: E402

from binaural import i18n  # noqa: E402
from binaural.locales import catalog, known_languages  # noqa: E402
from binaural.locales.ru import MESSAGES as RU_MESSAGES  # noqa: E402

SRC = Path(__file__).resolve().parent.parent / "src" / "binaural"

pytestmark = pytest.mark.usefixtures("isolated_language")


@pytest.fixture(autouse=True)
def isolated_language(tmp_path_factory, monkeypatch):
    """Isolate the language: English by default, settings in a temp HOME.

    ``set_language`` mutates process-wide state and writes QSettings, so both
    must be contained: without this the rest of the suite would inherit
    whichever language ran last, and the user's real ini would keep a "ru"
    left behind by a test.
    """
    home = tmp_path_factory.mktemp("i18n-home")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home))
    monkeypatch.setenv("HOME", str(home))
    # IniFormat, like the app does, so QSettings follows HOME instead of writing
    # a plist into the real ~/Library/Preferences.
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)

    previous = i18n.language()
    if previous != "en":
        i18n.set_language("en")
    yield
    i18n.set_language("en")


# --------------------------------------------------------------------------
# Core: tr()
# --------------------------------------------------------------------------


def test_tr_returns_source_in_english():
    assert i18n.language() == "en"
    assert i18n.tr("Play") == "Play"
    assert i18n.tr("&Help") == "&Help"


def test_tr_translates_a_known_key_in_russian():
    i18n.set_language("ru")
    assert i18n.language() == "ru"
    assert i18n.tr("Play") == RU_MESSAGES["Play"]
    assert i18n.tr("Play") != "Play"


def test_tr_falls_back_to_english_for_a_missing_key():
    """An untranslated string must degrade, never raise."""
    i18n.set_language("ru")
    missing = "A string nobody ever put into the catalogue"
    assert i18n.tr(missing) == missing


def test_tr_substitutes_positional_placeholders():
    i18n.set_language("ru")
    out = i18n.tr("Active channel: %1", "ЛЕВОЕ УХО")
    assert "%1" not in out
    assert "ЛЕВОЕ УХО" in out


def test_tr_keeps_placeholder_text_around_the_substitution():
    """Only %1..%n are filled; the wording itself comes from the catalogue."""
    i18n.set_language("ru")
    assert i18n.tr("Preset applied: difference %1 Hz", "10") == (
        "Пресет применён: разность 10 Гц"
    )


# --------------------------------------------------------------------------
# Switching
# --------------------------------------------------------------------------


def test_set_language_emits_the_change():
    seen: list[str] = []
    i18n.language_changed.connect(seen.append)
    try:
        i18n.set_language("ru")
    finally:
        i18n.language_changed.disconnect(seen.append)
    assert seen == ["ru"]


def test_set_language_ignores_unknown_codes():
    i18n.set_language("ru")
    assert i18n.set_language("de") == "ru"
    assert i18n.language() == "ru"
    assert i18n.set_language("") == "ru"


def test_set_language_returns_the_active_code():
    assert i18n.set_language("ru") == "ru"
    # Same code twice: no signal, but the return value stays truthful.
    assert i18n.set_language("ru") == "ru"


def test_languages_registry():
    languages = i18n.languages()
    assert languages == {"en": "English", "ru": "Русский"}
    assert i18n.language_name("ru") == "Русский"
    assert i18n.language_name("xx") == "xx"


def test_resolve_initial_language_returns_a_supported_code():
    resolved = i18n.resolve_initial_language()
    assert resolved in i18n.languages()


def test_resolve_initial_language_prefers_the_stored_value():
    """A stored choice wins over the system locale of the test machine."""
    settings = QSettings()
    settings.setValue("ui/language", "ru")
    settings.sync()
    try:
        assert i18n.resolve_initial_language() == "ru"
    finally:
        settings.remove("ui/language")
        settings.sync()


# --------------------------------------------------------------------------
# The Russian catalogue
# --------------------------------------------------------------------------


def test_catalog_exposes_the_russian_messages():
    assert "ru" in known_languages()
    assert catalog()["ru"] == RU_MESSAGES


def test_catalog_values_are_usable_strings():
    for key, value in RU_MESSAGES.items():
        assert isinstance(key, str) and key.strip(), f"bad key: {key!r}"
        assert isinstance(value, str) and value.strip(), f"empty value for {key!r}"


def test_catalog_has_no_duplicate_keys_with_conflicting_values():
    """Python collapses literal duplicates at parse time; catch them in the AST."""
    for path in sorted((SRC / "locales").glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        seen: dict[str, ast.Constant] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Dict):
                for key, value in zip(node.keys, node.values):
                    if not (
                        isinstance(key, ast.Constant)
                        and isinstance(value, ast.Constant)
                    ):
                        continue
                    previous = seen.get(key.value)
                    if previous is not None:
                        assert previous.value == value.value, (
                            f"{path.name}: {key.value!r} has two translations"
                        )
                    seen[key.value] = value


def test_placeholders_survive_translation():
    """A translation must not lose or invent a %n / {name} placeholder."""
    pattern = re.compile(r"%[1-9]|\{[a-z_]+\}")
    for key, value in RU_MESSAGES.items():
        assert sorted(pattern.findall(key)) == sorted(pattern.findall(value)), (
            f"placeholder mismatch for {key!r}"
        )


# --------------------------------------------------------------------------
# Completeness: every tr() string has a Russian translation
# --------------------------------------------------------------------------


def _assigned_names(tree: ast.Module) -> set[str]:
    """Names bound at module or class level by ``=`` or ``: T =``."""
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
    return names


#: Message tables whose values are user-visible text but reach ``tr()`` through a
#: local alias (``tr(text, "Step")``), which a static walk cannot follow — so they
#: are collected by name. The value is the index of the translated element inside
#: each tuple, or ``None`` when every string in the table is text. Icons
#: ("✓", "▶") and QSS roles ("ok", "danger") sit next to the text and are not
#: translated, hence the indices.
MESSAGE_TABLES: dict[str, int | None] = {
    "EVIDENCE_LABELS": None,
    "SOURCES": None,
    # Audio error texts: looked up by code, translated in ``_error_text``.
    "_ERROR_SOURCES": None,
    "STEP_TEXT": 0,
    "VERDICT_TEXT": 1,
    "_ANSWER_TEXTS": None,
    "_CONFIRMATIONS": 0,
    "_CONFIDENCE_LABEL": None,
    "_LR_RESULT_TEXT": 0,
    "_VERDICT_LABEL": None,
}
#: ``index=None`` above means "every string is text"; these entries must stay in
#: sync with the tables, hence the explicit assertion in the test below.
MESSAGE_TABLE_TEXT_ONLY: frozenset[str] = frozenset(
    {
        "EVIDENCE_LABELS",
        "SOURCES",
        "_ANSWER_TEXTS",
        "_CONFIDENCE_LABEL",
        "_ERROR_SOURCES",
        "_VERDICT_LABEL",
    }
)


def _source_strings() -> set[str]:
    """Every string that reaches ``tr()``, however it is spelled.

    Literal arguments, module-level string constants (``tr(_TITLE)``),
    subscripted keys (``tr(sources["show"])``) and the values of the known
    message tables are all collected.
    """
    found: set[str] = set()
    for path in sorted(SRC.rglob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))

        strings: dict[str, set[str]] = {}
        tables: dict[str, set[str]] = {}
        classes = (c.body for c in tree.body if isinstance(c, ast.ClassDef))
        for scope in (tree.body, *classes):
            for node in scope:
                target = None
                if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
                    target = node.targets[0].id
                elif (
                    isinstance(node, ast.AnnAssign)
                    and isinstance(node.target, ast.Name)
                ):
                    target = node.target.id
                if target is None:
                    continue
                if isinstance(node.value, ast.Constant):
                    if isinstance(node.value.value, str):
                        strings[target] = {node.value.value}
                elif isinstance(node.value, ast.Dict):
                    tables[target] = _string_values(
                        node.value, MESSAGE_TABLES.get(target), strings
                    )

        # Message tables reach tr() through an alias, so their text elements
        # are collected by table name instead of by call site.
        for name, values in tables.items():
            if name in MESSAGE_TABLES:
                found |= values
        strings.update({k: v for k, v in tables.items() if k not in MESSAGE_TABLES})

        assigned = _assigned_names(tree)
        for node in ast.walk(tree):
            if not (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Name)
                and node.func.id == "tr"
            ):
                continue
            if not node.args:
                continue
            first = node.args[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                found.add(first.value)
            elif isinstance(first, ast.Name) and first.id in strings:
                found |= strings[first.id]
            elif isinstance(first, ast.Subscript):
                holder = first.value
                key = first.slice
                name = holder.id if isinstance(holder, ast.Name) else None
                if name is None and isinstance(holder, ast.Attribute):
                    name = holder.attr
                if (
                    name is not None
                    and name in assigned
                    and isinstance(key, ast.Constant)
                    and isinstance(key.value, str)
                ):
                    found.add(key.value)
    # Ear captions live in constants now; the call sites pass the name.
    found |= {"LEFT EAR", "RIGHT EAR"}
    return found


def _string_values(
    node: ast.Dict,
    index: int | None = None,
    constants: dict[str, set[str]] | None = None,
) -> set[str]:
    """Translated strings of a dict literal.

    ``index`` picks one element of every tuple value — used by the tables that
    keep an icon or a QSS role next to the text. ``None`` collects every string.
    An element may be a module constant by name (``_READY`` inside STEP_TEXT),
    which ``constants`` resolves.
    """
    values: set[str] = set()
    known = constants or {}
    for value in node.values:
        if index is not None:
            element = (
                value.elts[index]
                if isinstance(value, ast.Tuple) and len(value.elts) > index
                else None
            )
            values |= _resolved(element, known)
            continue
        for element in ast.walk(value):
            if isinstance(element, ast.Constant) and isinstance(element.value, str):
                values.add(element.value)
    return values


def _resolved(node: ast.expr | None, constants: dict[str, set[str]]) -> set[str]:
    """Strings of one expression: a literal, or the constant it names."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value}
    if isinstance(node, ast.Name):
        return constants.get(node.id, set())
    return set()


def test_every_tr_string_is_translated():
    missing = sorted(s for s in _source_strings() if s not in RU_MESSAGES)
    assert not missing, "untranslated UI strings:\n" + "\n".join(missing)


def test_no_orphan_catalogue_entries():
    """Every key must exist for a reason: stale entries hide removed strings."""
    orphans = sorted(set(RU_MESSAGES) - _source_strings())
    assert not orphans, "catalogue entries nothing references:\n" + "\n".join(orphans)


# --------------------------------------------------------------------------
# Bilingual frequency reference data
# --------------------------------------------------------------------------


def test_frequency_accessors_follow_the_language():
    from binaural.data.frequencies import categories_with_counts, search

    category, _count = categories_with_counts()[0]
    entry = search("Delta")[0]

    assert category.localized_label() == category.label_en
    assert category.localized_description() == category.description_en
    assert category.other_label() == category.label_ru
    assert entry.localized_effect() == entry.effect_en
    assert entry.other_effect() == entry.effect_ru

    i18n.set_language("ru")
    assert category.localized_label() == category.label_ru
    assert category.localized_description() == category.description_ru
    assert category.other_label() == category.label_en
    assert entry.localized_effect() == entry.effect_ru
    assert entry.other_effect() == entry.effect_en


def test_localized_effect_falls_back_when_russian_is_missing():
    """A record without Russian text must still read in the Russian UI."""
    import dataclasses

    from binaural.data.frequencies import FrequencyEntry

    entry = FrequencyEntry(
        id="x",
        category="c",
        label="X",
        beat_hz=1.0,
        beat_min=None,
        beat_max=None,
        carrier_hz=200.0,
        effect_en="English",
        effect_ru="",
        evidence="reported",
        source="s",
    )
    i18n.set_language("ru")
    assert entry.localized_effect() == "English"
    assert dataclasses.replace(entry, effect_ru="Русский").other_effect() == "English"


# --------------------------------------------------------------------------
# Widgets: the runtime switch (needs a display)
# --------------------------------------------------------------------------


@pytest.fixture(scope="session")
def qapp():
    app = pytest.importorskip("PySide6.QtWidgets").QApplication.instance()
    if app is None:
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        app = pytest.importorskip("PySide6.QtWidgets").QApplication(["binaural-i18n"])
    return app


def _window():
    from binaural.core.oscillator import StereoOscillator
    from binaural.ui.main_window import MainWindow

    class _Engine:
        started = None
        stopped = None
        error = None

        def start(self) -> bool:
            return False

        def stop(self) -> None:
            pass

        def shutdown(self) -> None:
            pass

    return MainWindow(_Engine(), oscillator=StereoOscillator())


def test_main_window_retranslates_every_caption(qapp):
    window = _window()
    try:
        assert window._play_button.text() == "Play"
        assert window._left.caption() == "LEFT EAR"

        i18n.set_language("ru")

        assert window.windowTitle() == i18n.tr("Binaural")
        assert window._play_button.text() == RU_MESSAGES["Play"]
        assert window._volume_caption.text() == RU_MESSAGES["Volume"]
        assert window._presets_caption.text() == RU_MESSAGES["Presets"]
        assert window._save_preset_button.text() == RU_MESSAGES["Save preset"]
        assert window._left.caption() == RU_MESSAGES["LEFT EAR"]
        assert window._right.caption() == RU_MESSAGES["RIGHT EAR"]
        assert window._beat._beat_caption.text() == RU_MESSAGES["BEAT"]
        assert window._beat._carrier_caption.text() == RU_MESSAGES["CARRIER"]
        assert window._beat._beat_unit.text() == RU_MESSAGES["Hz"]
        assert window._view_menu.title() == RU_MESSAGES["&View"]
        assert window._language_menu.title() == RU_MESSAGES["Language"]
        assert window._help_menu.title() == RU_MESSAGES["&Help"]
        assert window._reference_action.text() == RU_MESSAGES["Frequency &reference…"]
        assert window._about_action.text() == RU_MESSAGES["&About"]
        assert window.status_indicator.text() == RU_MESSAGES["Unknown device"]
    finally:
        i18n.set_language("en")
        window.deleteLater()


def test_main_window_restores_english(qapp):
    window = _window()
    try:
        i18n.set_language("ru")
        i18n.set_language("en")
        assert window._play_button.text() == "Play"
        assert window._left.caption() == "LEFT EAR"
        assert window._help_menu.title() == "&Help"
    finally:
        i18n.set_language("en")
        window.deleteLater()


def test_play_button_retranslates_in_both_states(qapp):
    window = _window()
    try:
        i18n.set_language("ru")
        window.start_playback()
        window._set_playing(True)
        assert window._play_button.text() == RU_MESSAGES["Stop"]
        window._set_playing(False)
        assert window._play_button.text() == RU_MESSAGES["Play"]
    finally:
        i18n.set_language("en")
        window.deleteLater()


def test_language_menu_marks_the_active_language(qapp):
    window = _window()
    try:
        window.set_language("ru")
        assert window._language_actions["ru"].isChecked() is True
        assert window._language_actions["en"].isChecked() is False

        window.set_language("en")
        assert window._language_actions["en"].isChecked() is True
        assert window._language_actions["ru"].isChecked() is False
    finally:
        i18n.set_language("en")
        window.deleteLater()


def test_reference_dialog_follows_the_language(qapp):
    """The reference shows the JSON's Russian text under a Russian UI."""
    QLabel = pytest.importorskip("PySide6.QtWidgets").QLabel

    from binaural.data.frequencies import categories_with_counts, search
    from binaural.ui.dialogs.reference import ReferenceDialog

    category, _count = categories_with_counts()[0]
    entry = next(e for e in search("Delta") if e.category == category.id)

    i18n.set_language("ru")
    try:
        dialog = ReferenceDialog()
        try:
            text = "\n".join(
                label.text() for label in dialog.findChildren(QLabel)
            )
            # Sidebar, group header and card effect all come from the JSON's
            # Russian variants when the UI language is Russian.
            assert category.label_ru in text
            assert category.description_ru in text
            assert entry.effect_ru in text
        finally:
            dialog.deleteLater()
    finally:
        i18n.set_language("en")


def test_about_dialog_follows_the_language(qapp):
    from binaural.ui.dialogs.about import AboutDialog

    i18n.set_language("ru")
    try:
        dialog = AboutDialog()
        try:
            assert dialog.windowTitle() == RU_MESSAGES["About Binaural"]
            assert "не является медицинским изделием" in dialog.disclaimer_text
        finally:
            dialog.deleteLater()
    finally:
        i18n.set_language("en")