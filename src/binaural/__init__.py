"""Binaural — binaural beat generator for macOS and Linux.

The distribution's identity — its version and where it lives — is read from the
installed metadata, not restated here. Both were literals once, and both drifted
during a release.

``__version__`` used to say ``0.2.2`` while a release tagged ``v0.2.3`` was being
cut. The app then reported itself as 0.2.2, ``running_version()`` compared 0.2.2
against the 0.2.3 release, found nothing newer, and answered *you are up to date*
forever. ``scripts/check_version.py`` is the one thing in this repository whose
job is to stop the version drifting, and it did not catch that: it had no
knowledge of this file. It watches the fallbacks below now.

``PROJECT_URL`` was the same story in miniature — written out in ``about.py``,
again in ``update_checker.py``, and in ``pyproject.toml``, so the About dialog and
the update check could disagree about which project they belonged to.

``pyproject.toml`` is the single place either is written. The literals below are
the fallback for a source tree that was never installed, where there is no
metadata to read; that path is the only one that can still be stale, and
``tests/test_release_metadata.py`` checks them against ``pyproject.toml`` so it
cannot stay that way.
"""

from __future__ import annotations

from importlib.metadata import PackageNotFoundError
from importlib.metadata import metadata as _metadata
from importlib.metadata import version as _distribution_version

#: Fallbacks for a source tree that was never installed — `python src/...` with no
#: `pip install -e .` leaves no distribution metadata to read.
_FALLBACK_VERSION = "0.2.4"
_FALLBACK_PROJECT_URL = "https://github.com/zeroscrypt/binaural"


def _project_url() -> str:
    """The Homepage from ``[project.urls]``, or the fallback above.

    Setuptools writes ``Project-URL`` headers into the installed metadata, so an
    installed distribution answers this without the repository being restated.
    """
    try:
        entries = _metadata("binaural").get_all("Project-URL") or []
    except PackageNotFoundError:  # pragma: no cover - depends on the install
        return _FALLBACK_PROJECT_URL
    for entry in entries:
        label, _, url = entry.partition(",")
        if label.strip().lower() == "homepage" and url.strip():
            return url.strip()
    return _FALLBACK_PROJECT_URL


try:
    __version__ = _distribution_version("binaural")
except PackageNotFoundError:  # pragma: no cover - depends on the install
    __version__ = _FALLBACK_VERSION

#: Where this project lives, used by the About dialog and to build the releases API URL.
PROJECT_URL = _project_url()

__all__ = ["PROJECT_URL", "__version__"]