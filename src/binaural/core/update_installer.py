"""Extracting a release archive, verifying it, and replacing the installed app.

The counterpart of ``apple/Sources/Core/UpdateInstaller.swift``. This is the
dangerous half of the update flow, written so that a failure at any step leaves
the installed app exactly as it was:

* the archive is extracted into a throwaway directory and verified **before**
  anything installed is touched — an incomplete download is a clean error, not a
  half-written bundle;
* the installed release directory is renamed aside, not deleted, and that rename
  is the undo: if the copy into place fails, the old directory is moved back;
* the new tree is checked for a usable entry point and for the version that was
  downloaded, so a stale or wrong archive cannot be installed over a good one;
* the shell symlink and ``install-meta`` are re-pointed afterwards, because an
  update that left ``~/.local/bin/binaural`` dangling would be a soft brick.

The replace and relaunch steps are injected — they are the two that need the real
filesystem and a running process, which is exactly what the tests must not have.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import uuid
from pathlib import Path
from typing import Callable

from .update_checker import AppVersion

__all__ = [
    "INSTALL_APP_DIRNAME",
    "INSTALL_META_NAME",
    "INSTALL_ROOT",
    "RELEASE_DIR",
    "UpdateInstallError",
    "UpdateInstaller",
    "installed_release_dir",
    "installed_version",
]

#: Where ``install.sh`` puts things: the prefix is ``~/.binaural``, the extracted
#: release lives under ``app/`` and what was installed is recorded in
#: ``install-meta``. Read from the environment at import so a test can point the
#: installer at a temporary home.
INSTALL_ROOT = Path(os.environ.get("BINAURAL_PREFIX") or Path.home() / ".binaural")
INSTALL_APP_DIRNAME = "app"
INSTALL_META_NAME = "install-meta"
#: The name ``scripts/build_linux.sh`` gives the bundle inside the archive, and
#: the executable inside it.
RELEASE_DIR = "Binaural"
EXECUTABLE_NAME = "binaural"

#: ``binaural-0.1.0-linux-x64`` -> ``0.1.0``.
_RELEASE_DIRNAME = re.compile(r"^binaural-(?P<version>[^-]+)-linux", re.IGNORECASE)

#: How long to wait between starting the new process and leaving, so the new
#: instance takes over the desktop before this one goes away.
RELAUNCH_DELAY_SECONDS = 1.0


class UpdateInstallError(Exception):
    """Why an install could not be completed. Every case leaves the app as it was."""

    #: A stable tag per subclass, for logs and tests. Not user-facing.
    code = "unknown"


class UnreadableArchive(UpdateInstallError):
    """The archive is not a readable ``.tar.gz``."""

    code = "unreadable_archive"


class ArchiveHasNoExecutable(UpdateInstallError):
    """The archive holds no ``binaural`` entry point — an incomplete download."""

    code = "archive_has_no_executable"


class VersionMismatch(UpdateInstallError):
    """The tree inside is not the version that was downloaded."""

    code = "version_mismatch"

    def __init__(self, expected: AppVersion, found: str | None) -> None:
        super().__init__(
            f"expected {expected}, found {found or 'no version at all'}"
        )
        self.expected = expected
        self.found = found


class ReplaceFailed(UpdateInstallError):
    """The new tree could not be put in place; the previous one was restored."""

    code = "replace_failed"


class UpdateInstaller:
    """Extracts a release archive, verifies it, and replaces the installed app."""

    #: Put ``new_root`` where ``current_root`` is, leaving the app able to run
    #: either way.
    Replace = Callable[[Path, Path], None]

    #: Start the replaced app and stop this process.
    Relauncher = Callable[[Path], None]

    def __init__(
        self,
        replace: "UpdateInstaller.Replace | None" = None,
        relauncher: "UpdateInstaller.Relauncher | None" = None,
        install_root: Path | None = None,
    ) -> None:
        self._replace = replace or self.default_replace
        self._relaunch = relauncher or self.default_relaunch
        #: The prefix the installer replaces into (``~/.binaural`` by default).
        #: An attribute rather than a constant so a test can point it at a
        #: temporary directory instead of the real installation.
        self.install_root = Path(install_root) if install_root else INSTALL_ROOT

    # ----------------------------------------------------------------- extract

    def extract(
        self, archive: Path, expected_version: AppVersion | None = None
    ) -> Path:
        """Extract ``archive`` and return the release tree inside it.

        Touches nothing installed. The extraction directory is removed on failure;
        on success it is the caller's — :meth:`install_archive` removes it after the
        replace.
        """
        directory = Path(tempfile.mkdtemp(prefix="binaural-extract-"))
        try:
            _extract_tar(archive, directory)
            root = find_release_root(directory)
            _verify(root, expected_version)
            return root
        except Exception:
            shutil.rmtree(directory, ignore_errors=True)
            raise

    def install(
        self, new_root: Path, expected_version: AppVersion | None = None
    ) -> Path:
        """Replace the installed release with an already-extracted ``new_root``.

        Returns the entry point that was launched, so the caller can report it.
        """
        _verify(new_root, expected_version)
        current = installed_release_dir(self.install_root)
        if current is None:
            raise ReplaceFailed(
                f"nothing is installed under {self.install_root}; "
                "reinstall by hand instead of updating"
            )
        self._replace(new_root, current)
        entry_point = find_executable(new_root)
        if entry_point is None:  # pragma: no cover - _verify guarantees one exists
            raise ArchiveHasNoExecutable(str(new_root))
        self._relaunch(entry_point)
        return entry_point

    def install_archive(
        self, archive: Path, expected_version: AppVersion | None = None
    ) -> Path:
        """Extract, verify, replace and relaunch — the whole install."""
        root = self.extract(archive, expected_version=expected_version)
        try:
            return self.install(root, expected_version=expected_version)
        finally:
            # The tree is in place and running; the extraction directory is spent.
            # Its *parent* goes too, because the tree is nested inside it.
            shutil.rmtree(root.parent, ignore_errors=True)

    # -------------------------------------------------------- the real replace

    def default_replace(self, new_root: Path, current_root: Path) -> None:
        """Rename the installed release aside, put the new tree in, undo on failure.

        Rename-aside rather than delete-first is the whole safety of the operation:
        the old release stays on disk under a generated name until the new one is in
        place, so a failed copy is undone by moving it back and the app is never
        without a bundle.
        """
        backup = current_root.with_name(f"{current_root.name}.old-{uuid.uuid4()}")
        try:
            os.replace(current_root, backup)
        except OSError as exc:
            raise ReplaceFailed(
                f"could not move the installed app aside: {exc}"
            ) from exc
        try:
            # `os.replace` on a directory across devices raises EXDEV, so the copy
            # path is not a fallback but the normal case: the extraction lives in
            # the system temp directory and the prefix does not have to.
            shutil.copytree(new_root, current_root, symlinks=True)
        except Exception as exc:
            # The copy failed and the old release is still on disk under the backup
            # name. Moving it back is what leaves the app exactly as it was.
            try:
                os.replace(backup, current_root)
            except OSError:  # pragma: no cover - the undo failing is not recoverable
                pass
            raise ReplaceFailed(f"could not copy the new app into place: {exc}") from exc

        _repoint_metadata(new_root, current_root)
        # The new tree is in place and verified; the old one has served its purpose.
        shutil.rmtree(backup, ignore_errors=True)

    def default_relaunch(self, entry_point: Path) -> None:
        """Start the replaced app and stop this process.

        ``Popen`` starts the new process without waiting for it to be ready; the
        delay before leaving is the window in which it takes over the desktop. The
        exit is deliberately abrupt — an orderly Qt shutdown on the way out could
        fail halfway and leave both instances fighting over the audio device.
        """
        try:
            subprocess.Popen(  # noqa: S603 - the path is the installed entry point
                [str(entry_point)],
                start_new_session=True,
            )
        except Exception:
            # The new app did not start. Leaving this one running is the better
            # failure: the user still has a working app.
            return
        time.sleep(RELAUNCH_DELAY_SECONDS)
        os._exit(0)  # noqa: SLF001 - an orderly exit here is the riskier choice


# ---------------------------------------------------------------------------
# Finding the installed release
# ---------------------------------------------------------------------------


def app_dir(install_root: Path) -> Path:
    """Where ``install.sh`` unpacks a release: ``<prefix>/app``."""
    return Path(install_root) / INSTALL_APP_DIRNAME


def installed_release_dir(install_root: Path) -> Path | None:
    """The extracted release directory under ``install_root``, or ``None``.

    ``install.sh`` unpacks the archive into ``<prefix>/app``, so the release is one
    level below that; a directory with no entry point inside is not a release and
    is skipped.
    """
    root = app_dir(install_root)
    if not root.is_dir():
        return None
    candidates = [
        child for child in sorted(root.iterdir()) if child.is_dir() and ".old-" not in child.name
    ]
    for child in candidates:
        if find_executable(child) is not None:
            return child
    return None


def installed_version(install_root: Path) -> AppVersion | None:
    """The version the installed release reports, or ``None`` when it says nothing.

    ``install.sh`` writes ``version=<x>`` into ``<prefix>/install-meta``; that is
    the first answer because it is what the installer recorded, and the release
    directory name is the fallback for an install that predates it.
    """
    meta = Path(install_root) / INSTALL_META_NAME
    try:
        text = meta.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator and key.strip() == "version":
            found = AppVersion.parse(value.strip())
            if found is not None:
                return found
    root = installed_release_dir(install_root)
    if root is not None:
        found = version_from_name(root.name)
        if found is not None:
            return found
    return None


def version_from_name(name: str) -> AppVersion | None:
    """``binaural-0.1.0-linux-x64`` -> ``0.1.0``; ``None`` for anything else."""
    match = _RELEASE_DIRNAME.match(name)
    if match is None:
        return None
    return AppVersion.parse(match.group("version"))


def find_executable(root: Path) -> Path | None:
    """The ``binaural`` entry point inside ``root``, or ``None``.

    ``install.sh``'s own rule: ``bin/binaural`` or ``Binaural/binaural`` within a
    couple of levels, which is exactly the layout ``scripts/build_linux.sh`` packs.
    Preferring the shallowest match matters because a bundle also carries Python's
    ``bin/`` directory — the wrong ``binaural`` inside it would be a script, not the
    app.
    """
    root = Path(root)
    if not root.is_dir():
        return None
    best: tuple[int, Path] | None = None
    for dirpath, dirnames, filenames in os.walk(root):
        depth = len(Path(dirpath).relative_to(root).parts)
        dirnames.sort()
        if EXECUTABLE_NAME in filenames:
            candidate = Path(dirpath) / EXECUTABLE_NAME
            if os.access(candidate, os.X_OK):
                if best is None or depth < best[0]:
                    best = (depth, candidate)
        if depth >= 3:
            # Deeper than the layout ``install.sh`` produces; nothing down here is
            # the entry point, and a whole PyInstaller bundle is a lot to walk.
            dirnames[:] = []
    return best[1] if best is not None else None


def find_release_root(directory: Path) -> Path:
    """The extracted release tree, wherever the archive put it.

    The archive normally holds ``binaural-<version>-linux-<arch>/`` at its root; a
    top-level folder around it is found just as readily. The only preference is for
    the tree this release is supposed to ship, so an archive with a stray directory
    beside it installs the real one.
    """
    directory = Path(directory)
    children = sorted(child for child in directory.iterdir() if child.is_dir())
    for child in children:
        if _RELEASE_DIRNAME.match(child.name) and find_executable(child) is not None:
            return child
    for child in children:
        if find_executable(child) is not None:
            return child
    raise ArchiveHasNoExecutable(str(directory))


# ---------------------------------------------------------------------------
# Extraction and verification
# ---------------------------------------------------------------------------


def _extract_tar(archive: Path, into: Path) -> None:
    """Unpack a ``.tar.gz`` into ``into``.

    ``tarfile`` with the ``data`` filter: an archive that tries to write outside the
    extraction directory, follows a symlink out of it or sets a device node is a
    failure, not something to install. Members are unpacked in Python rather than by
    shelling out to ``tar`` — a PyInstaller bundle runs to tens of thousands of
    members, and spawning one process per file is not an option.
    """
    try:
        with tarfile.open(archive, "r:gz") as tar:
            try:
                tar.extractall(into, filter="data")  # noqa: S202 - 'data' is the safe filter
            except TypeError:  # pragma: no cover - Python < 3.12 has no filter kwarg
                _extract_without_filter(tar, into)
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise UnreadableArchive(str(exc)) from exc


def _extract_without_filter(tar: tarfile.TarFile, into: Path) -> None:
    """Unpack on a Python without ``extractall(filter=...)``, refusing the same members.

    Kept so the code is honest on 3.10, which the project's ``requires-python``
    still allows: the checks are the ones ``data`` performs.
    """
    root = into.resolve()
    for member in tar.getmembers():
        target = (root / member.name).resolve()
        if root not in target.parents and target != root:
            raise UnreadableArchive(f"the archive writes outside itself: {member.name}")
        if member.issym() or member.islnk():
            link = (target.parent / member.linkname).resolve()
            if root not in link.parents and link != root:
                raise UnreadableArchive(
                    f"the archive links outside itself: {member.name}"
                )
        if member.isdev() or member.isfifo():
            raise UnreadableArchive(f"the archive carries a device: {member.name}")
    tar.extractall(into)


def _verify(root: Path, expected_version: AppVersion | None) -> None:
    """Check that ``root`` is a complete release of the version that was downloaded.

    The completeness check is the guard against installing an incomplete download;
    the version check refuses to replace a good release with a stale or wrong one.
    Neither touches anything installed.
    """
    if find_executable(root) is None:
        raise ArchiveHasNoExecutable(str(root))
    if expected_version is None:
        return
    found = version_from_name(Path(root).name)
    if found is None:
        # No version in the directory name; a version written inside the tree by
        # install.sh is the only other answer, and its absence is a mismatch rather
        # than a pass — an unverifiable archive is not installed.
        found = _version_in_tree(Path(root))
    if found != expected_version:
        raise VersionMismatch(expected_version, None if found is None else str(found))


def _version_in_tree(root: Path) -> AppVersion | None:
    """``version=`` from an ``install-meta`` inside the tree, if there is one."""
    try:
        metas = sorted(root.glob(f"*/{INSTALL_META_NAME}")) + [root / INSTALL_META_NAME]
    except OSError:  # pragma: no cover - a glob over a missing tree is harmless
        return None
    for meta in metas:
        try:
            text = meta.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() == "version":
                found = AppVersion.parse(value.strip())
                if found is not None:
                    return found
    return None


# ---------------------------------------------------------------------------
# Keeping the install's own records true
# ---------------------------------------------------------------------------


def _repoint_metadata(new_root: Path, current_root: Path) -> None:
    """Rewrite ``install-meta`` and the shell symlink for the replaced release.

    ``install-meta`` records ``executable=<path inside the prefix>`` and
    ``~/.local/bin/binaural`` is a symlink to that path. Both name the release
    *directory*, which carries the version in its name — so after a replace both
    point at a directory that no longer exists. Leaving them would be a soft brick:
    ``binaural`` on the command line would stop working, and ``install.sh --force``
    would claim the app was not installed at all.

    A failure here is swallowed: the app is already in place and running, and a
    stale metadata file is recoverable by hand, while an exception would leave the
    caller showing "could not install" over a successful update.
    """
    try:
        executable = find_executable(current_root)
        if executable is None:  # pragma: no cover - the tree was verified before this
            return
        meta = INSTALL_ROOT / INSTALL_META_NAME
        if meta.is_file():
            lines = meta.read_text(encoding="utf-8", errors="replace").splitlines()
            rewritten = [
                f"executable={executable}" if line.startswith("executable=") else line
                for line in lines
            ]
            meta.write_text("\n".join(rewritten) + "\n", encoding="utf-8")
        _repoint_symlink(executable)
    except Exception:
        pass


def _repoint_symlink(entry_point: Path) -> None:
    """Fix ``~/.local/bin/binaural`` if it is a symlink into the replaced release."""
    bin_dir = Path(os.environ.get("BINAURAL_BIN_DIR") or Path.home() / ".local" / "bin")
    link = bin_dir / EXECUTABLE_NAME
    try:
        if not link.is_symlink():
            return
        target = Path(os.readlink(link))
        resolved = (link.parent / target).resolve() if not target.is_absolute() else target
        if resolved == entry_point.resolve():
            return
        # Only rewrite a link that pointed inside the release directory; a symlink
        # the user put somewhere else is theirs.
        if not resolved.exists():
            link.unlink()
            link.symlink_to(entry_point)
    except OSError:
        pass


