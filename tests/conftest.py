"""Shared setup for the test suite.

The interface language is pinned to English for every test.

The app itself opens in Russian — that is its own language, and a first launch that
greets a Russian speaker in English is the wrong first impression. The tests are a
different matter: they compare against the English source strings, and they must not
depend on which language happens to be active, nor on the order the tests happen to
run in. The Linux CI runs one process per test, so a language left over from a previous
test is not something to rely on.

The private flag is patched rather than ``set_language()`` called, so a test run never
writes a language preference into the reader's real settings.
"""

from __future__ import annotations

import sys

import pytest


@pytest.fixture(autouse=True)
def english_interface(monkeypatch):
    """Pin the interface language to English for the duration of a test.

    The module is only patched if it is already loaded. Importing it here would pull
    PySide6 into every test process — including the ones that never touch Qt — and
    shiboken leaks a reference to ``None`` per destroyed Qt object, which aborts
    CPython once the count reaches zero. A test that reads captions imports the
    module at the top of its own file, so by the time this runs it is there.
    """
    module = sys.modules.get("binaural.i18n")
    if module is None:
        yield
        return
    monkeypatch.setattr(module, "_current", "en")
    yield
