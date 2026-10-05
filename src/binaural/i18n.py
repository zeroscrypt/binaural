"""Runtime UI language: English and Russian (SPEC: интерфейс на двух языках).

Design notes
------------
English is the *source* language: every call site passes the English string,
which is exactly what a translation catalogue keys on. When the language is
``en`` the source string is returned untouched (``QCoreApplication.translate``
also returns the source when no ``.ts`` translator is installed, so behaviour
before and after this module existed is identical).

Russian is looked up in :mod:`binaural.locales`. A missing key never raises —
it falls back to English — because a half-finished catalogue must degrade to a
usable UI, not to a crash.

Changing the language emits :data:`language_changed`. Widgets created
*after* the change pick the new language up automatically; the one persistent
widget — ``MainWindow`` — subscribes and re-reads its own captions
(``MainWindow.retranslate``). Dialogs are rebuilt on every open, so they need
no subscription.
"""

from __future__ import annotations

from PySide6.QtCore import QCoreApplication, QObject, QSettings, QLocale, Signal

__all__ = [
    "SUPPORTED_LANGUAGES",
    "language",
    "language_changed",
    "language_name",
    "languages",
    "resolve_initial_language",
    "set_language",
    "tr",
]

#: Code -> native name, shown verbatim in the language menu.
SUPPORTED_LANGUAGES: dict[str, str] = {
    "en": "English",
    "ru": "Русский",
}

_DEFAULT_LANGUAGE = "en"
_SETTINGS_KEY = "ui/language"
_CONTEXT = "Binaural"


class _Bus(QObject):
    """Owns the signal so it survives module-level function scope."""

    language_changed = Signal(str)


_bus = _Bus()
#: Emits the new language code (``"en"`` / ``"ru"``) after it is set.
language_changed: Signal = _bus.language_changed

_current: str = _DEFAULT_LANGUAGE


def languages() -> dict[str, str]:
    """``{"en": "English", "ru": "Русский"}`` for building the menu."""
    return dict(SUPPORTED_LANGUAGES)


def language_name(code: str) -> str:
    """Native display name for ``code``; the code itself when unknown."""
    return SUPPORTED_LANGUAGES.get(code, code)


def language() -> str:
    """The active language code."""
    return _current


def resolve_initial_language() -> str:
    """Stored preference, else the system locale, else English.

    The first run has nothing in QSettings, so a Russian system is detected
    through :class:`QLocale` and the choice is then persisted by
    :func:`set_language`.
    """
    try:
        stored = QSettings().value(_SETTINGS_KEY)
    except Exception:
        stored = None
    if stored is not None:
        code = str(stored).strip().lower()
        if code in SUPPORTED_LANGUAGES:
            return code

    try:
        locale = QLocale.system()
        if locale.language() == QLocale.Language.Russian:
            return "ru"
    except Exception:
        pass
    return _DEFAULT_LANGUAGE


def set_language(code: str) -> str:
    """Switch the UI language. Returns the code actually applied.

    Unknown codes are ignored (the current language is kept) rather than
    raising: a corrupt setting must not stop the app from starting.
    """
    global _current
    normalized = str(code).strip().lower()
    if normalized not in SUPPORTED_LANGUAGES or normalized == _current:
        return _current
    _current = normalized
    try:
        settings = QSettings()
        settings.setValue(_SETTINGS_KEY, normalized)
        settings.sync()
    except Exception:
        pass  # persistence is a convenience, never a blocker
    language_changed.emit(normalized)
    return _current


def _translate(text: str, context: str) -> str:
    if _current == _DEFAULT_LANGUAGE:
        # Source language: Qt returns the source unchanged without a
        # translator, which keeps lupdate/lconvert tooling honest.
        return QCoreApplication.translate(context, text)
    try:
        from .locales import catalog

        hit = catalog().get(_current, {}).get(text)
    except Exception:
        hit = None
    return hit if isinstance(hit, str) and hit else text


def tr(text: str, *args: str, context: str = _CONTEXT) -> str:
    """Translate ``text`` and substitute ``%1``..``%n`` (the Qt idiom).

    ``context`` is accepted for call sites that already pass one; the catalogue
    is keyed on the English source only, so contexts are deliberately unused.
    """
    result = _translate(str(text), context)
    for index, value in enumerate(args, start=1):
        result = result.replace(f"%{index}", str(value))
    return result
