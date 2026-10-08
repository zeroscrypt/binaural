"""The update check: the version order and the GitHub release lookup.

Pure logic, no Qt and no network of its own: the endpoint, the fetcher and the
comparator are all injected, so every rule that matters — which tag is read,
which asset is picked, and in which order two versions come — is unit-testable
without touching the network. The counterpart of ``apple/Sources/Core/
UpdateChecker.swift``; CONTRACT rule 9 asks for the same decisions, not the same
code.

``UpdateChecker`` never decides what a failure looks like: it raises one of the
``UpdateError`` subclasses, and the caller turns it into silence (at launch) or
into a sentence (from *About*).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable
from urllib import error as _urlerror
from urllib import request as _urlrequest

__all__ = [
    "AppVersion",
    "Availability",
    "GitHubRelease",
    "ReleaseAsset",
    "UpdateAvailability",
    "UpdateChecker",
    "UpdateError",
    "UpdateHttpError",
    "UpdateMissingArchive",
    "UpdateMissingVersionTag",
    "UpdatePayloadError",
    "UpdateTransportError",
    "running_version",
]

#: ``GET /repos/{owner}/{repo}/releases/latest`` for this repository.
DEFAULT_ENDPOINT = "https://api.github.com/repos/zeroscrypt/binaural/releases/latest"

#: How long a check may take before the app gives up on it. A launch-time check
#: must not hold the window hostage on a bad connection.
REQUEST_TIMEOUT = 15.0

#: GitHub rejects a request with no ``User-Agent`` outright, so one is always sent.
USER_AGENT = "Binaural-Linux"

#: The leading digits of a version chunk: ``1.2.3abc`` is ``1.2.3`` as far as
#: ordering goes, and a chunk with no digits ends the version rather than failing
#: it.
_LEADING_DIGITS = re.compile(r"\d+")

#: ``binaural-0.2.0-linux-x64.tar.gz`` -> ``0.2.0``. The archive name is the
#: release tag by construction (``scripts/build_linux.sh``), which is what makes it
#: usable as the version of the bundle inside.
_ARCHIVE_NAME = re.compile(r"^binaural-(?P<version>[^-]+)-linux", re.IGNORECASE)

#: Platform words an archive name may carry. A ``.tar.gz`` naming none of them is a
#: release whose asset carries no platform at all — a rename — and is still ours.
_PLATFORM_WORDS = (
    "linux",
    "macos",
    "osx",
    "darwin",
    "windows",
    "win",
    "freebsd",
)


# ---------------------------------------------------------------------------
# Version order
# ---------------------------------------------------------------------------


class AppVersion:
    """A dotted version number, compared **numerically** component by component.

    The update check compares the running app's ``binaural.__version__`` with the
    tag of the newest GitHub release, and the only thing that must be right here
    is the order: ``0.10.0`` is newer than ``0.1.0``, and a string comparison gets
    that exactly backwards.

    Three tolerances, each of which the app actually depends on:

    * a leading ``v`` is stripped — a GitHub tag is normally ``v0.1.0`` while the
      package says ``0.1.0``;
    * missing components count as zero, so ``0.1`` and ``0.1.0`` are the **same**
      version and a build is never told it is out of date by its own release;
    * a pre-release suffix (``0.2.0-beta.1``) is **older** than ``0.2.0``, so a
      beta is never offered as an update to a release build.

    ``AppVersion("nonsense")`` raises ``ValueError``; :meth:`parse` returns
    ``None`` instead. A tag the app cannot read must mean "no update offered"
    rather than an error dialog about an update, so the checker only ever uses
    ``parse``.
    """

    __slots__ = ("components", "prerelease", "raw")

    #: The numeric components, most significant first: ``0.1.10`` is ``[0, 1, 10]``.
    components: tuple[int, ...]
    #: Everything after the first ``-``, verbatim; ``None`` for a plain release.
    prerelease: str | None
    #: The text this version was parsed from, minus a leading ``v``.
    raw: str

    def __init__(self, text: str) -> None:
        parsed = _parse(str(text))
        if parsed is None:
            raise ValueError(f"not a version number: {text!r}")
        self.components, self.prerelease, self.raw = parsed

    @classmethod
    def parse(cls, text: object) -> "AppVersion | None":
        """The version ``text`` names, or ``None`` when it names none.

        Never raises: ``"unknown"``, ``""``, ``"v"`` and ``None`` are all simply
        not versions.
        """
        if text is None:
            return None
        parsed = _parse(str(text))
        if parsed is None:
            return None
        version = cls.__new__(cls)
        version.components, version.prerelease, version.raw = parsed
        return version

    # ----------------------------------------------------------------- order

    def order(self, other: "AppVersion") -> int:
        """``-1`` older, ``0`` the same version, ``1`` newer.

        The one place the three-way answer is built, so the operators and
        :class:`UpdateChecker` cannot disagree about what "newer" means.

        The two are compared over the same number of components by padding the
        shorter one with zeros, which is what makes ``0.1`` and ``0.1.0`` equal
        rather than "the shorter one is older".
        """
        if not isinstance(other, AppVersion):
            return NotImplemented
        count = max(len(self.components), len(other.components))
        for index in range(count):
            left = self.components[index] if index < len(self.components) else 0
            right = other.components[index] if index < len(other.components) else 0
            if left != right:
                return -1 if left < right else 1
        # Equal numbers: ``1.0.0-beta.1`` is earlier than ``1.0.0``.
        if self.prerelease == other.prerelease:
            return 0
        if self.prerelease is None:
            return 1  # a release is newer than any pre-release
        if other.prerelease is None:
            return -1
        return -1 if self.prerelease < other.prerelease else 1

    def __lt__(self, other: "AppVersion") -> bool:
        order = self.order(other)
        return order is NotImplemented or order < 0

    def __le__(self, other: "AppVersion") -> bool:
        order = self.order(other)
        return order is NotImplemented or order <= 0

    def __gt__(self, other: "AppVersion") -> bool:
        order = self.order(other)
        return order is not NotImplemented and order > 0

    def __ge__(self, other: "AppVersion") -> bool:
        order = self.order(other)
        return order is not NotImplemented and order >= 0

    def __eq__(self, other: object) -> bool:
        """Equality by the same order, not by the stored text.

        ``0.1`` and ``0.1.0`` are the same version — that is the rule the padding
        in :meth:`order` exists for — and ``1.2.3 (17)`` is ``1.2.3`` rather than
        a different version, so the stored ``raw`` and the number of parsed
        components are deliberately not compared.
        """
        if not isinstance(other, AppVersion):
            return NotImplemented
        return self.order(other) == 0

    def __hash__(self) -> int:
        """Hash the *significant* components, so equal versions hash equally.

        Trailing zeros carry no order, so they are dropped before hashing; at
        least one component is kept, because ``0.0.0`` and ``0`` are the same
        version too and an empty tuple would collide with a parse failure.
        """
        significant = list(self.components)
        while len(significant) > 1 and significant[-1] == 0:
            significant.pop()
        return hash((tuple(significant), self.prerelease))

    def __str__(self) -> str:
        text = ".".join(str(part) for part in self.components)
        return f"{text}-{self.prerelease}" if self.prerelease else text

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"AppVersion({str(self)!r})"


def _parse(text: str) -> tuple[tuple[int, ...], str | None, str] | None:
    """``(components, prerelease, raw)`` for ``text``, or ``None`` when it is no version.

    A ``-`` starts a pre-release and a ``+`` starts build metadata; both end the
    numeric part. Build metadata is not part of the version at all and is dropped
    with everything after it.
    """
    body = text.strip()
    # ``v0.1.0`` and ``V 0.1.0`` are both tags people write; both mean ``0.1.0``.
    if body[:1] in ("v", "V"):
        body = body[1:].strip()

    separators = [index for index, char in enumerate(body) if char in "-+"]
    split_at = separators[0] if separators else len(body)
    release_part, tail = body[:split_at], body[split_at:]

    components: list[int] = []
    for chunk in release_part.split("."):
        digits = _LEADING_DIGITS.match(chunk)
        if digits is None:
            break
        components.append(int(digits.group()))

    prerelease: str | None = None
    if tail.startswith("-"):
        prerelease = tail[1:].split("+", 1)[0] or None
    if not components:
        return None
    return tuple(components), prerelease, body


def running_version() -> AppVersion | None:
    """The running application's version, from ``binaural.__version__``.

    ``None`` when the package version is unreadable, which the caller reports as
    "nothing to check" rather than as an error.
    """
    from .. import __version__

    return AppVersion.parse(__version__)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class UpdateError(Exception):
    """Why an update check could not produce an answer.

    Every case is something a person can read: the app never shows a raw HTTP
    body, and it never treats a failed check as "no update" *silently* — the
    launch check says nothing at all and the About button reports the error.
    """

    #: A stable tag per subclass, for logs and tests. Not user-facing.
    code = "unknown"


class UpdateTransportError(UpdateError):
    """The request itself failed: no network, DNS, TLS."""

    code = "transport"

    def __init__(self, detail: str = "") -> None:
        super().__init__(detail or "the request failed")
        self.detail = detail


class UpdateHttpError(UpdateError):
    """GitHub answered with something other than 2xx."""

    code = "http_status"

    def __init__(self, status: int) -> None:
        super().__init__(f"the releases API answered {status}")
        self.status = status


class UpdatePayloadError(UpdateError):
    """The body was not the JSON document the API documents."""

    code = "unreadable_payload"


class UpdateMissingVersionTag(UpdateError):
    """The release carries a tag that is not a version."""

    code = "missing_version_tag"


class UpdateMissingArchive(UpdateError):
    """The release has no Linux archive to install."""

    code = "missing_archive"


# ---------------------------------------------------------------------------
# The release document
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ReleaseAsset:
    """One file a release publishes."""

    name: str
    #: ``browser_download_url`` — where GitHub serves the file from.
    url: str
    #: Size in bytes as GitHub reports it. ``0`` when the API did not say, which
    #: is "unknown" rather than "empty file".
    size: int = 0
    content_type: str | None = None

    @classmethod
    def from_json(cls, payload: object) -> "ReleaseAsset":
        """One asset, or :class:`ValueError` when it carries no usable name or URL.

        A malformed entry must not hide the rest of the release, so the caller
        drops it and carries on.
        """
        if not isinstance(payload, dict):
            raise ValueError(f"an asset is not an object: {payload!r}")
        name = payload.get("name")
        url = payload.get("browser_download_url")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("an asset has no name")
        if not isinstance(url, str) or not url.strip():
            raise ValueError(f"asset {name!r} has no download URL")
        size = payload.get("size")
        content_type = payload.get("content_type")
        return cls(
            name=name,
            url=url,
            size=size if isinstance(size, int) and size > 0 else 0,
            content_type=content_type if isinstance(content_type, str) else None,
        )


@dataclass(frozen=True)
class GitHubRelease:
    """The payload of ``GET /repos/{owner}/{repo}/releases/latest``.

    Only the fields the update flow uses are decoded; the rest of the GitHub
    document is ignored.
    """

    tag_name: str
    name: str | None = None
    html_url: str | None = None
    is_draft: bool = False
    is_prerelease: bool = False
    assets: tuple[ReleaseAsset, ...] = field(default_factory=tuple)

    @classmethod
    def from_json(cls, payload: object) -> "GitHubRelease":
        """Decode the document strictly: one bad asset raises :class:`ValueError`."""
        if not isinstance(payload, dict):
            raise ValueError(f"the release is not an object: {payload!r}")
        tag = payload.get("tag_name")
        if not isinstance(tag, str) or not tag.strip():
            raise ValueError("the release has no tag_name")
        raw_assets = payload.get("assets") or []
        if not isinstance(raw_assets, list):
            raise ValueError("assets is not a list")
        return cls(
            tag_name=tag,
            name=_text(payload.get("name")),
            html_url=_text(payload.get("html_url")),
            is_draft=bool(payload.get("draft", False)),
            is_prerelease=bool(payload.get("prerelease", False)),
            assets=tuple(ReleaseAsset.from_json(item) for item in raw_assets),
        )

    @classmethod
    def lenient_from_json(cls, payload: object) -> "GitHubRelease":
        """Decode the document again, dropping whatever will not parse.

        One malformed field must not hide the release: GitHub adds fields, it does
        not remove ``tag_name``, so a second pass that keeps only what the update
        flow reads is still a usable answer.
        """
        if not isinstance(payload, dict):
            raise ValueError(f"the release is not an object: {payload!r}")
        tag = payload.get("tag_name")
        if not isinstance(tag, str) or not tag.strip():
            raise ValueError("the release has no tag_name")
        raw_assets = payload.get("assets")
        assets: list[ReleaseAsset] = []
        if isinstance(raw_assets, list):
            for item in raw_assets:
                try:
                    assets.append(ReleaseAsset.from_json(item))
                except ValueError:
                    continue
        return cls(
            tag_name=tag,
            name=_text(payload.get("name")),
            html_url=_text(payload.get("html_url")),
            is_draft=bool(payload.get("draft", False)),
            is_prerelease=bool(payload.get("prerelease", False)),
            assets=tuple(assets),
        )

    @property
    def version(self) -> AppVersion | None:
        """The version the tag names, ``None`` when the tag is not a version."""
        return AppVersion.parse(self.tag_name)

    def linux_archive(
        self,
        version: AppVersion | None = None,
        platform_tag: str | None = None,
    ) -> ReleaseAsset | None:
        """The Linux archive to install, or ``None`` when the release has none.

        The exact name first — ``binaural-<version>-<platform>.tar.gz``, where the
        platform is this machine's ``linux-x64`` / ``linux-arm64`` — then
        progressively looser matches: any archive naming this architecture, then
        any archive naming Linux, then any ``.tar.gz`` that names no platform at
        all.

        Guessing rather than refusing is deliberate: a release whose asset was
        renamed is still a usable update, and the archive is verified by content
        in :mod:`binaural.core.update_installer` before it replaces anything.
        ``None`` is :class:`UpdateMissingArchive` at the call site rather than a
        wrong file here.

        One guess is refused that the macOS side allows: an archive naming
        *another* platform. macOS is the only platform Swift ships, so its chain
        can end in "any archive at all"; here that would offer a user an archive
        that cannot possibly run, and offering nothing is the better failure.
        """
        wanted_version = version or self.version
        tag = platform_tag or host_platform_tag()
        archives = [asset for asset in self.assets if asset.name.endswith(".tar.gz")]
        if wanted_version is not None and tag:
            exact = f"binaural-{wanted_version}-{tag}.tar.gz"
            hit = _first(archives, lambda asset: asset.name == exact)
            if hit is not None:
                return hit
        architecture = tag.rpartition("-")[2] if tag else ""
        if architecture:
            hit = _first(
                archives,
                lambda asset: "linux" in asset.name and architecture in asset.name,
            )
            if hit is not None:
                return hit
        hit = _first(archives, lambda asset: "linux" in asset.name)
        if hit is not None:
            return hit
        return _first(
            archives,
            lambda asset: not _names_a_platform(asset.name),
        )


def _text(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def _names_a_platform(name: str) -> bool:
    lowered = name.lower()
    return any(word in lowered for word in _PLATFORM_WORDS)


def _first(assets: Iterable[ReleaseAsset], predicate: Callable[[ReleaseAsset], bool]):
    for asset in assets:
        if predicate(asset):
            return asset
    return None


def host_platform_tag() -> str | None:
    """``linux-x64`` / ``linux-arm64`` for this machine, ``None`` off Linux.

    The Python app ships Linux archives only (``scripts/build_linux.sh``), and the
    bundle is architecture-specific, so the platform has to be part of the archive
    name rather than a guess made later.
    """
    import platform
    import sys

    if not sys.platform.startswith("linux"):
        return None
    machine = platform.machine().lower()
    if machine in ("x86_64", "amd64"):
        architecture = "x64"
    elif machine in ("arm64", "aarch64"):
        architecture = "arm64"
    else:
        architecture = machine or ""
    return f"linux-{architecture}" if architecture else None


# ---------------------------------------------------------------------------
# The answer
# ---------------------------------------------------------------------------


class Availability(Enum):
    """The three answers to "is there an update"."""

    UP_TO_DATE = "up_to_date"
    UPDATE_AVAILABLE = "update_available"
    SKIPPED = "skipped"


@dataclass(frozen=True)
class UpdateAvailability:
    """What the check concluded.

    Three cases and not two, because "the user asked not to hear about this
    release" is a **third** answer, not the same as "there is none". The launch
    check stays silent for both of the first and the third.
    """

    kind: Availability
    current: AppVersion
    release: GitHubRelease | None = None

    @classmethod
    def up_to_date(cls, current: AppVersion) -> "UpdateAvailability":
        return cls(Availability.UP_TO_DATE, current)

    @classmethod
    def update_available(
        cls, current: AppVersion, release: GitHubRelease
    ) -> "UpdateAvailability":
        return cls(Availability.UPDATE_AVAILABLE, current, release)

    @classmethod
    def skipped(
        cls, current: AppVersion, release: GitHubRelease
    ) -> "UpdateAvailability":
        return cls(Availability.SKIPPED, current, release)

    @property
    def is_worth_telling(self) -> bool:
        """True when the user should be told — the one case launch may interrupt for."""
        return self.kind is Availability.UPDATE_AVAILABLE


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------


def _numeric_order(left: AppVersion, right: AppVersion) -> int:
    return left.order(right)


class UpdateChecker:
    """Looks up the newest release on GitHub and compares it with the running version.

    Every dependency is injected — the endpoint, the fetch and the comparator —
    because every rule worth testing here is a rule about *this* code. The default
    endpoint is the repository's own releases API and the default fetch is a plain
    ``urllib`` call.

    Nothing throws at the UI on its own: the caller decides what a failure looks
    like (the launch check stays silent, the About dialog reports).
    """

    #: Fetches a URL and returns the body as ``str`` or ``bytes``.
    Fetch = Callable[[str], "str | bytes"]
    #: Orders two versions: negative, zero or positive.
    Compare = Callable[[AppVersion, AppVersion], int]

    def __init__(
        self,
        endpoint: str | None = None,
        fetch: "UpdateChecker.Fetch | None" = None,
        compare: "UpdateChecker.Compare | None" = None,
    ) -> None:
        self._endpoint = endpoint or DEFAULT_ENDPOINT
        self._fetch = fetch or self.url_session_fetch
        self._compare = compare or _numeric_order

    @property
    def endpoint(self) -> str:
        return self._endpoint

    def latest_release(self) -> GitHubRelease:
        """The newest release, decoded."""
        try:
            body = self._fetch(self._endpoint)
        except UpdateError:
            # Already one of ours — a non-200 from the default fetch, say. Wrapped
            # again it would read as a network failure, which is a lie.
            raise
        except Exception as exc:  # the fetcher is injected and may raise anything
            # The checker's contract is that a failure is an ``UpdateError``, never a
            # raw error from somebody else's stack.
            raise UpdateTransportError(str(exc)) from exc

        if isinstance(body, bytes):
            body = body.decode("utf-8", errors="replace")
        try:
            payload = json.loads(body)
        except (TypeError, ValueError) as exc:
            raise UpdatePayloadError(f"the releases payload is not JSON: {exc}") from exc

        try:
            return GitHubRelease.from_json(payload)
        except ValueError:
            pass
        # One malformed field must not hide the release — try again with only what
        # the update flow reads.
        try:
            return GitHubRelease.lenient_from_json(payload)
        except ValueError as exc:
            raise UpdatePayloadError(str(exc)) from exc

    def check(
        self,
        current_version: AppVersion,
        skipping: AppVersion | None = None,
    ) -> UpdateAvailability:
        """The newest release, compared with ``current_version``.

        :param skipping: the version the user chose to skip, or ``None``. An equal
            version means :attr:`Availability.SKIPPED`, which the launch check
            treats as silence and the About button treats as a normal "there is an
            update" answer.
        """
        release = self.latest_release()
        release_version = release.version
        if release_version is None:
            raise UpdateMissingVersionTag(f"not a version tag: {release.tag_name!r}")
        if self._compare(release_version, current_version) <= 0:
            return UpdateAvailability.up_to_date(current_version)
        if skipping is not None and self._compare(release_version, skipping) == 0:
            return UpdateAvailability.skipped(current_version, release)
        return UpdateAvailability.update_available(current_version, release)

    def ordering(self, left: AppVersion, right: AppVersion) -> int:
        """The comparator this checker actually uses.

        Exposed so a test can pin that :meth:`check` orders with :class:`AppVersion`
        rather than with something else, without re-testing the order here.
        """
        return self._compare(left, right)

    # ------------------------------------------------------------------ fetch

    @staticmethod
    def url_session_fetch(url: str) -> bytes:
        """The default fetch: a ``GET`` with the headers GitHub asks for.

        Mapped onto :class:`UpdateError` so a failure never reaches the UI as an
        ``URLError`` nobody can read.
        """
        request = _urlrequest.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with _urlrequest.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                status = getattr(response, "status", None) or response.getcode()
                if not 200 <= int(status) < 300:
                    raise UpdateHttpError(int(status))
                return response.read()
        except UpdateError:
            raise
        except _urlerror.HTTPError as exc:
            raise UpdateHttpError(int(exc.code)) from exc
        except Exception as exc:
            raise UpdateTransportError(str(exc)) from exc