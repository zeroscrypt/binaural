"""Downloading a release archive to a temporary file, with progress.

The counterpart of ``apple/Sources/Core/UpdateDownloader.swift``. The download
itself is injected — the same seam the checker has for its fetch — so the tests
run against a loader that writes a file rather than against the network.

The file this returns is the caller's to remove: the coordinator deletes it after
a successful install, and on the way out when the user cancels.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Callable
from urllib import error as _urlerror
from urllib import request as _urlrequest

__all__ = [
    "REQUEST_TIMEOUT",
    "UpdateDownloadError",
    "UpdateDownloader",
]

#: Long enough for a slow connection to deliver a release archive, short enough
#: that a stalled socket does not leave a progress window open forever.
REQUEST_TIMEOUT = 60.0

#: How much of the response is read at a time. 64 KiB is one network read: big
#: enough to be cheap, small enough that progress moves visibly.
CHUNK_BYTES = 64 * 1024


class UpdateDownloadError(Exception):
    """The download failed: no network, a non-2xx status, or an empty body.

    Its own type rather than :class:`~binaural.core.update_checker.UpdateError`
    because the user's next move differs — a failed *check* is retried by asking
    again, a failed *download* is retried by pressing the button again — and the
    coordinator shows a different sentence for each.
    """


class UpdateDownloader:
    """Downloads a release archive to a temporary file, reporting progress."""

    #: How much of the download has arrived, 0..1. Called on the loading thread;
    #: the caller hops to the UI thread.
    Progress = Callable[[float], None]

    #: Write ``url`` to a temporary file and return where it landed.
    Loader = Callable[[str, "Progress | None"], Path]

    def __init__(self, load: "Loader | None" = None) -> None:
        self._load = load or self.url_load

    def download(self, url: str, progress: "Progress | None" = None) -> Path:
        """Download ``url`` to a temporary file and return where it landed."""
        return self._load(url, progress)

    # ------------------------------------------------------------------ loader

    @staticmethod
    def url_load(url: str, progress: "Progress | None" = None) -> Path:
        """The default loader: stream the URL into a file under ``tempfile``.

        The archive is written straight to disk rather than assembled in memory —
        a PyInstaller bundle is tens of megabytes, and a partly-written temporary
        file is a clean failure while an exhausted heap is a crash. A temporary
        *directory* per download means one ``rmtree`` cleans up the file, whatever
        the file is called.
        """
        name = Path(url.split("?", 1)[0].split("#", 1)[0]).name or "download"
        directory = Path(tempfile.mkdtemp(prefix="binaural-update-"))
        destination = directory / name

        request = _urlrequest.Request(
            url,
            headers={"User-Agent": "Binaural-Linux"},
        )
        try:
            with _urlrequest.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                # `urlopen` already raises for an HTTP error status, so a status
                # here is a confirmation; a scheme that reports none (`file://`)
                # has nothing to check and is not a failure.
                status = _response_status(response)
                if status is not None and not 200 <= status < 300:
                    raise UpdateDownloadError(f"the download answered {status}")
                total = _content_length(response)
                written = 0
                with destination.open("wb") as handle:
                    while True:
                        chunk = response.read(CHUNK_BYTES)
                        if not chunk:
                            break
                        handle.write(chunk)
                        written += len(chunk)
                        if progress is not None and total > 0:
                            progress(min(max(written / total, 0.0), 1.0))
        except UpdateDownloadError:
            _discard(directory)
            raise
        except _urlerror.HTTPError as exc:
            _discard(directory)
            raise UpdateDownloadError(f"the download answered {exc.code}") from exc
        except Exception as exc:
            _discard(directory)
            raise UpdateDownloadError(str(exc)) from exc

        if written == 0:
            # An empty archive is not an update; it is a failed download, and the
            # installer must never be handed one to "verify".
            _discard(directory)
            raise UpdateDownloadError("the download produced no file")
        if progress is not None:
            progress(1.0)
        return destination


def _response_status(response) -> int | None:
    """The HTTP status of a response, or ``None`` when the handler reports none."""
    raw = getattr(response, "status", None)
    if raw is None:
        try:
            raw = response.getcode()
        except Exception:
            return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _content_length(response) -> int:
    """``Content-Length`` as an int, or ``0`` when the server did not say.

    ``0`` is read as "no total known" and progress is then left alone, rather
    than being reported as a fraction of nothing.
    """
    try:
        return int(response.headers.get("Content-Length") or 0)
    except (TypeError, ValueError):
        return 0


def _discard(directory: Path) -> None:
    """Remove a download directory and everything in it. Never raises."""
    import shutil

    try:
        shutil.rmtree(directory, ignore_errors=True)
    except Exception:  # pragma: no cover - a failure here must not mask the cause
        pass