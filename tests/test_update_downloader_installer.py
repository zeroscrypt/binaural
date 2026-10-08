"""Downloading the release archive and replacing the installed app.

Mirrors ``apple/Tests/CoreTests/UpdateDownloaderTests.swift`` and
``UpdateInstallerTests.swift`` — the same rules, the Python spelling. The loader,
the replace and the relaunch are all injected, so nothing here touches the network
and the two real filesystem steps run against a fake prefix in a temporary
directory.
"""

from __future__ import annotations

import os
import stat
import tarfile
from pathlib import Path

import pytest

from binaural.core.update_checker import AppVersion
from binaural.core.update_downloader import UpdateDownloadError, UpdateDownloader
from binaural.core.update_installer import (
    ArchiveHasNoExecutable,
    ReplaceFailed,
    UnreadableArchive,
    UpdateInstaller,
    VersionMismatch,
    find_executable,
    installed_release_dir,
    installed_version,
    version_from_name,
)


# --------------------------------------------------------------------------
# Fixtures: a real release archive and a real installed prefix
# --------------------------------------------------------------------------


def make_tree(root: Path, *, version: str = "0.1.0", layout: str = "release") -> Path:
    """A release tree laid out the way ``scripts/build_linux.sh`` packs it.

    ``layout="release"`` is the archive's own layout — ``binaural-<ver>-linux-x64/``
    around the bundle — and ``"flat"`` is the bare bundle, for the case where an
    archive has no version directory around it.
    """
    if layout == "release":
        tree = root / f"binaural-{version}-linux-x64"
    else:
        tree = root / "Binaural"
    bundle = tree / "Binaural"
    bundle.mkdir(parents=True)
    binary = bundle / "binaural"
    binary.write_bytes(b"#!/bin/sh\nexit 0\n")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    (bundle / "share").mkdir()
    (bundle / "share" / "frequencies.json").write_text("{}", encoding="utf-8")
    return tree


def make_archive(tmp_path: Path, *, version: str = "0.1.0", layout: str = "release") -> Path:
    """Tar a release tree the way the release pipeline tars it."""
    staging = tmp_path / f"staging-{version}-{layout}"
    staging.mkdir(parents=True, exist_ok=True)
    tree = make_tree(staging, version=version, layout=layout)
    archive = tmp_path / f"binaural-{version}-linux-x64.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(tree, arcname=tree.name)
    return archive


def make_prefix(tmp_path: Path, *, version: str = "0.1.0") -> Path:
    """An installed prefix with a release in it, as ``install.sh`` leaves one."""
    prefix = tmp_path / ".binaural"
    app = prefix / "app"
    app.mkdir(parents=True)
    make_tree(app, version=version)
    (prefix / "install-meta").write_text(
        "release-url=https://example.invalid/a.tar.gz\n"
        f"version={version}\n"
        "platform=linux-x64\n"
        f"executable={app}/binaural-{version}-linux-x64/Binaural/binaural\n",
        encoding="utf-8",
    )
    return prefix


def recording_installer(events: list[str]):
    """An installer that records what it was asked to do instead of doing it."""
    return UpdateInstaller(
        replace=lambda new, current: events.append(f"replace:{new.name}->{current.name}"),
        relauncher=lambda entry: events.append(f"relaunch:{entry.name}"),
    )


# --------------------------------------------------------------------------
# The downloader
# --------------------------------------------------------------------------


def test_download_writes_a_file_and_reports_progress(tmp_path):
    seen: list[float] = []
    destination = tmp_path / "downloaded" / "binaural-0.2.0-linux-x64.tar.gz"

    def load(url, progress):
        destination.parent.mkdir(parents=True, exist_ok=True)
        progress(0.5)
        progress(1.0)
        destination.write_bytes(b"archive")
        return destination

    written = UpdateDownloader(load=load).download("https://example.invalid/a.tar.gz", seen.append)
    assert written == destination
    assert written.read_bytes() == b"archive"
    assert seen == [0.5, 1.0]


def test_a_download_failure_propagates():
    def explode(_url, _progress):
        raise UpdateDownloadError("the download answered 404")

    with pytest.raises(UpdateDownloadError):
        UpdateDownloader(load=explode).download("https://example.invalid/a.tar.gz")


def test_the_default_loader_reports_a_body_it_actually_read(tmp_path):
    """The real loader against a ``file://`` URL: no network, but the real code path."""
    payload = tmp_path / "archive.bin"
    payload.write_bytes(b"x" * 4096)
    seen: list[float] = []
    written = UpdateDownloader().download(payload.as_uri(), seen.append)
    try:
        assert written.read_bytes() == payload.read_bytes()
        assert written.parent.name.startswith("binaural-update-")
        assert seen and seen[-1] == 1.0
    finally:
        import shutil

        shutil.rmtree(written.parent, ignore_errors=True)


def test_the_default_loader_rejects_an_empty_body(tmp_path):
    """An empty archive is a failed download, not something to verify."""
    empty = tmp_path / "empty.bin"
    empty.write_bytes(b"")
    with pytest.raises(UpdateDownloadError):
        UpdateDownloader().download(empty.as_uri())


def test_the_default_loader_rejects_a_missing_file(tmp_path):
    with pytest.raises(UpdateDownloadError):
        UpdateDownloader().download((tmp_path / "nope.bin").as_uri())


# --------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------


def test_extract_finds_the_release_inside_the_archive(tmp_path):
    archive = make_archive(tmp_path)
    installer = recording_installer([])
    root = installer.extract(archive, expected_version=AppVersion("0.1.0"))
    try:
        assert root.name == "binaural-0.1.0-linux-x64"
        assert find_executable(root).name == "binaural"
    finally:
        import shutil

        shutil.rmtree(root.parent, ignore_errors=True)


def test_extract_finds_a_release_with_no_version_directory_around_it(tmp_path):
    archive = make_archive(tmp_path, layout="flat")
    installer = recording_installer([])
    root = installer.extract(archive)
    try:
        assert find_executable(root) is not None
    finally:
        import shutil

        shutil.rmtree(root.parent, ignore_errors=True)


def test_extract_refuses_an_unreadable_archive(tmp_path):
    junk = tmp_path / "junk.tar.gz"
    junk.write_bytes(b"not a tarball at all")
    with pytest.raises(UnreadableArchive):
        recording_installer([]).extract(junk)


def test_extract_refuses_an_archive_with_no_executable(tmp_path):
    staging = tmp_path / "empty-release"
    (staging / "binaural-0.1.0-linux-x64").mkdir(parents=True)
    (staging / "binaural-0.1.0-linux-x64" / "README.md").write_text("hi", encoding="utf-8")
    archive = tmp_path / "empty.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(staging, arcname=staging.name)

    with pytest.raises(ArchiveHasNoExecutable):
        recording_installer([]).extract(archive)


def test_extract_checks_the_version_against_the_release(tmp_path):
    """The guard against installing a stale or wrong archive over a good one."""
    archive = make_archive(tmp_path, version="0.1.0")
    with pytest.raises(VersionMismatch) as caught:
        recording_installer([]).extract(archive, expected_version=AppVersion("0.2.0"))
    assert caught.value.expected == AppVersion("0.2.0")
    assert caught.value.found == "0.1.0"


def test_extract_accepts_the_version_that_was_offered(tmp_path):
    archive = make_archive(tmp_path, version="0.2.0")
    root = recording_installer([]).extract(archive, expected_version=AppVersion("0.2.0"))
    import shutil

    shutil.rmtree(root.parent, ignore_errors=True)


def test_a_tree_that_reports_no_version_is_a_mismatch(tmp_path):
    """An unverifiable archive is refused rather than installed on trust."""
    staging = tmp_path / "binaural-bundle"
    make_tree(staging, layout="flat")
    archive = tmp_path / "anonymous.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(staging, arcname=staging.name)
    with pytest.raises(VersionMismatch) as caught:
        recording_installer([]).extract(archive, expected_version=AppVersion("0.2.0"))
    assert caught.value.found is None


def test_an_archive_that_writes_outside_itself_is_refused(tmp_path):
    """A traversal attempt is a failure, not something to unpack."""
    archive = tmp_path / "evil.tar.gz"
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("keep", encoding="utf-8")
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(victim, arcname="../victim")
    with pytest.raises(UnreadableArchive):
        recording_installer([]).extract(archive)
    assert (victim / "keep.txt").read_text(encoding="utf-8") == "keep"


# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------


def test_install_replaces_then_relaunches(tmp_path):
    events: list[str] = []
    prefix = make_prefix(tmp_path)
    installer = recording_installer(events)
    installer.install_root = prefix

    new_root = make_tree(tmp_path / "new", version="0.2.0")
    entry = installer.install(new_root, expected_version=AppVersion("0.2.0"))

    assert events == [
        f"replace:{new_root.name}->binaural-0.1.0-linux-x64",
        "relaunch:binaural",
    ]
    assert entry.name == "binaural"


def test_install_refuses_a_version_that_does_not_match(tmp_path):
    events: list[str] = []
    prefix = make_prefix(tmp_path)
    installer = recording_installer(events)
    installer.install_root = prefix

    new_root = make_tree(tmp_path / "new", version="0.1.0")
    with pytest.raises(VersionMismatch):
        installer.install(new_root, expected_version=AppVersion("0.2.0"))
    assert events == [], "a refused install touches nothing"


def test_install_refuses_when_nothing_is_installed(tmp_path):
    """No installed release means no replace; reinstalling by hand is the honest answer."""
    prefix = tmp_path / "empty-prefix"
    prefix.mkdir()
    installer = recording_installer([])
    installer.install_root = prefix
    new_root = make_tree(tmp_path / "new", version="0.2.0")
    with pytest.raises(ReplaceFailed):
        installer.install(new_root)


def test_the_one_shot_install_runs_the_whole_sequence(tmp_path):
    events: list[str] = []
    prefix = make_prefix(tmp_path)
    archive = make_archive(tmp_path, version="0.2.0")
    installer = recording_installer(events)
    installer.install_root = prefix

    entry = installer.install_archive(archive, expected_version=AppVersion("0.2.0"))
    assert entry.name == "binaural"
    assert events == ["replace:binaural-0.2.0-linux-x64->binaural-0.1.0-linux-x64", "relaunch:binaural"]


def test_install_archive_cleans_up_the_extraction_directory(tmp_path):
    events: list[str] = []
    prefix = make_prefix(tmp_path)
    archive = make_archive(tmp_path, version="0.2.0")
    installer = recording_installer(events)
    installer.install_root = prefix

    before = set(Path(os.environ.get("TMPDIR", "/tmp")).glob("binaural-extract-*"))
    installer.install_archive(archive, expected_version=AppVersion("0.2.0"))
    after = set(Path(os.environ.get("TMPDIR", "/tmp")).glob("binaural-extract-*"))
    assert after <= before


# --------------------------------------------------------------------------
# The real replace, against a real prefix
# --------------------------------------------------------------------------


def test_the_default_replace_puts_the_new_release_in_place(tmp_path, monkeypatch):
    prefix = make_prefix(tmp_path)
    installer = UpdateInstaller(relauncher=lambda _entry: None, install_root=prefix)

    new_root = make_tree(tmp_path / "new", version="0.2.0")
    installer.default_replace(new_root, prefix / "app" / "binaural-0.1.0-linux-x64")

    installed = prefix / "app" / "binaural-0.1.0-linux-x64"
    assert (installed / "Binaural" / "binaural").is_file()
    assert (installed / "Binaural" / "share" / "frequencies.json").is_file()
    assert list((prefix / "app").iterdir()) == [installed], "the backup is cleaned up"


def test_the_default_replace_restores_the_old_release_when_the_copy_fails(
    tmp_path, monkeypatch
):
    """The undo: the old release is renamed aside, so a failed copy costs nothing."""
    prefix = make_prefix(tmp_path)
    current = prefix / "app" / "binaural-0.1.0-linux-x64"
    installer = UpdateInstaller(relauncher=lambda _entry: None, install_root=prefix)
    new_root = make_tree(tmp_path / "new", version="0.2.0")

    def explode(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr("binaural.core.update_installer.shutil.copytree", explode)
    with pytest.raises(ReplaceFailed):
        installer.default_replace(new_root, current)

    assert (current / "Binaural" / "binaural").is_file(), "the old release is back"
    assert list((prefix / "app").iterdir()) == [current]


def test_the_default_replace_repairs_the_symlink_and_the_metadata(tmp_path, monkeypatch):
    """A dangling ``binaural`` on the PATH would be a soft brick."""
    prefix = make_prefix(tmp_path)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    link = bin_dir / "binaural"
    link.symlink_to(prefix / "app" / "binaural-0.1.0-linux-x64" / "Binaural" / "binaural")
    monkeypatch.setenv("BINAURAL_BIN_DIR", str(bin_dir))
    monkeypatch.setattr("binaural.core.update_installer.INSTALL_ROOT", prefix)

    installer = UpdateInstaller(relauncher=lambda _entry: None, install_root=prefix)
    new_root = make_tree(tmp_path / "new", version="0.2.0")
    installer.default_replace(new_root, prefix / "app" / "binaural-0.1.0-linux-x64")

    assert link.resolve().is_file(), "the symlink points at something real again"
    meta = (prefix / "install-meta").read_text(encoding="utf-8")
    recorded = [
        line for line in meta.splitlines() if line.startswith("executable=")
    ][0]
    assert Path(recorded.partition("=")[2]).resolve().is_file()
    assert installed_version(prefix) == AppVersion("0.1.0"), (
        "install-meta still describes what was installed"
    )


# --------------------------------------------------------------------------
# Reading the installed prefix
# --------------------------------------------------------------------------


def test_installed_release_dir_finds_the_release(tmp_path):
    prefix = make_prefix(tmp_path)
    assert installed_release_dir(prefix).name == "binaural-0.1.0-linux-x64"


def test_installed_release_dir_ignores_a_leftover_backup(tmp_path):
    """A backup left by an interrupted update is not a release."""
    prefix = make_prefix(tmp_path)
    # The decoy is a complete, executable tree — only its name marks it as a backup.
    backup = prefix / "app" / "binaural-0.2.0-linux-x64.old-deadbeef"
    make_tree(backup, version="0.2.0", layout="flat")
    assert installed_release_dir(prefix).name == "binaural-0.1.0-linux-x64"


def test_installed_release_dir_is_none_for_an_empty_prefix(tmp_path):
    prefix = tmp_path / "nothing"
    prefix.mkdir()
    assert installed_release_dir(prefix) is None


def test_installed_version_prefers_the_metadata(tmp_path):
    prefix = make_prefix(tmp_path, version="0.1.0")
    assert installed_version(prefix) == AppVersion("0.1.0")
    # install-meta wins over the directory name when the two disagree.
    (prefix / "install-meta").write_text("version=0.3.0\n", encoding="utf-8")
    assert installed_version(prefix) == AppVersion("0.3.0")


def test_installed_version_falls_back_to_the_directory_name(tmp_path):
    prefix = make_prefix(tmp_path)
    (prefix / "install-meta").unlink()
    assert installed_version(prefix) == AppVersion("0.1.0")


def test_version_from_name():
    assert version_from_name("binaural-0.2.0-linux-x64") == AppVersion("0.2.0")
    assert version_from_name("binaural-0.2.0-linux-arm64") == AppVersion("0.2.0")
    assert version_from_name("Binaural") is None
    assert version_from_name("binaural-nightly-linux-x64") is None


def test_find_executable_prefers_the_shallowest_match(tmp_path):
    """A bundle also carries Python's own ``bin/``; the wrong ``binaural`` is a script."""
    tree = make_tree(tmp_path, layout="flat")
    inner = tree / "Binaural" / "_internal" / "bin"
    inner.mkdir(parents=True)
    decoy = inner / "binaural"
    decoy.write_text("#!/bin/sh\n", encoding="utf-8")
    decoy.chmod(0o755)
    assert find_executable(tree) == tree / "Binaural" / "binaural"


def test_find_executable_is_none_without_one(tmp_path):
    plain = tmp_path / "plain"
    plain.mkdir()
    assert find_executable(plain) is None
    assert find_executable(tmp_path / "missing") is None