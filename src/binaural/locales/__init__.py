"""Translation catalogues.

Each supported language is a module exposing ``MESSAGES: dict[str, str]``
keyed by the English source string. :func:`catalog` loads them lazily and
memoizes the result, so importing the package never costs I/O at startup.
"""

from __future__ import annotations

import importlib
from typing import Any

__all__ = ["catalog", "known_languages"]

_MODULE_BY_LANGUAGE = {"ru": "binaural.locales.ru"}

_cache: dict[str, dict[str, str]] = {}


def known_languages() -> list[str]:
    """Language codes that ship a catalogue module."""
    return sorted(_MODULE_BY_LANGUAGE)


def catalog() -> dict[str, dict[str, str]]:
    """``{"ru": {english_source: translation}}``, loading each module once.

    A module that is missing or broken yields an empty mapping for that
    language: the UI then falls back to English instead of failing to start.
    """
    if _cache:
        return _cache
    for code, module_name in _MODULE_BY_LANGUAGE.items():
        try:
            module: Any = importlib.import_module(module_name)
            messages = getattr(module, "MESSAGES", None)
            if isinstance(messages, dict):
                _cache[code] = {
                    str(key): str(value)
                    for key, value in messages.items()
                    if isinstance(key, str) and isinstance(value, str) and value
                }
        except Exception:
            continue
    return _cache
