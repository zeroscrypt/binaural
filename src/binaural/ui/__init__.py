"""UI layer: display only, all behaviour comes from signals (SPEC §8)."""

from __future__ import annotations

__all__ = ["MainWindow"]


def __getattr__(name: str):
    # Lazy so importing `binaural.ui` stays cheap and free of import cycles.
    if name == "MainWindow":
        from .main_window import MainWindow

        return MainWindow
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")