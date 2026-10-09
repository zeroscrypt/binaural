"""The version has to be the same in every file that states it (``scripts/check_version.py``).

The failure this prevents is the quiet one. A tag of ``v0.3.0`` with
``MARKETING_VERSION`` left at ``0.2.2`` builds an app that calls itself 0.2.2, names the
archive ``binaural-0.2.2-macos-arm64.tar.gz``, and ships an updater that asks GitHub for
``binaural-0.3.0-macos-arm64.tar.gz``. Nothing errors: the build succeeds, the release
publishes, and *Check for updates* answers "you are up to date" forever, because the
version it compares against never moves.

So the checker runs against **this repository** on every test run, and the tests below
run it against deliberately broken copies — a checker that cannot fail is not a check.
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def _load_checker():
    """Import ``scripts/check_version.py`` by path: ``scripts`` is not a package."""
    spec = importlib.util.spec_from_file_location(
        "check_version", ROOT / "scripts" / "check_version.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["check_version"] = module
    spec.loader.exec_module(module)
    return module


check_version = _load_checker()


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


@pytest.fixture()
def repo(tmp_path: Path) -> Path:
    """A copy of the three files the checker reads, small enough to break on purpose.

    Copied rather than stubbed so the fixture cannot drift away from the real layout —
    a hand-written fake ``project.yml`` would pass against a checker that no longer parses
    the real one.
    """
    (tmp_path / "pyproject.toml").write_text(
        (ROOT / "pyproject.toml").read_text(encoding="utf-8"), encoding="utf-8"
    )
    (tmp_path / "apple").mkdir()
    shutil.copy(ROOT / "apple/project.yml", tmp_path / "apple/project.yml")
    (tmp_path / "scripts").mkdir()
    shutil.copy(
        ROOT / "scripts/build_macos.sh", tmp_path / "scripts/build_macos.sh"
    )
    # The package's fallback version literal: the checker watches it, so the
    # fixture has to contain it or the check would quietly have nothing to read.
    (tmp_path / "src").mkdir()
    (tmp_path / "src/binaural").mkdir()
    shutil.copy(
        ROOT / "src/binaural/__init__.py", tmp_path / "src/binaural/__init__.py"
    )
    (tmp_path / "apple/Sources").mkdir()
    (tmp_path / "apple/Sources/Core").mkdir()
    shutil.copy(
        ROOT / "apple/Sources/Core/UpdateChecker.swift",
        tmp_path / "apple/Sources/Core/UpdateChecker.swift",
    )
    return tmp_path


def _set_version(root: Path, path: str, old: str, new: str) -> None:
    target = root / path
    text = target.read_text(encoding="utf-8")
    assert old in text, f"{path} does not contain {old!r} — the test needs updating"
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


def _current_version() -> str:
    """The version this repository states right now, read from the real tree.

    The tests below break a version on purpose, so they need the live value to break
    it from. Hard-coding it meant every bump turned three of them red for reasons
    that had nothing to do with what they test — the failure reads like a version
    problem and is really a stale literal.
    """
    return check_version.pyproject_version()


def _break_the_xcode_versions(repo: Path) -> None:
    """Move the first Xcode target to a version the package does not have."""
    current = _current_version()
    _set_version(
        repo,
        "apple/project.yml",
        f'MARKETING_VERSION: "{current}"',
        'MARKETING_VERSION: "0.0.0-bumped"',
    )


# --------------------------------------------------------------------------
# This repository
# --------------------------------------------------------------------------


def test_the_repository_version_is_consistent():
    """The real tree, right now, with no arguments.

    Runs on every ``pytest`` on every platform. A version bump that misses one of the
    three files fails here rather than in a user's update check.
    """
    assert check_version.main([]) == 0


def _newest_tag() -> str | None:
    """The newest ``v*`` tag, from git rather than from ``.git/refs``.

    Tags get packed into ``.git/packed-refs`` after a few clones, so reading the loose-ref
    directory skips most of them — which would turn this into a test that quietly checks
    nothing.
    """
    import subprocess

    out = subprocess.run(
        ["git", "-C", str(ROOT), "tag", "--list", "v*", "--sort=-v:refname"],
        capture_output=True,
        text=True,
        check=False,
    )
    tags = [line.strip() for line in out.stdout.splitlines() if line.strip()]
    return tags[0] if tags else None


def test_the_repository_matches_its_latest_tag():
    """``pyproject.toml``, ``apple/project.yml`` and the newest tag all say one thing."""
    newest = _newest_tag()
    if newest is None:
        pytest.skip("no release tag in this clone")
    assert check_version.main(["--tag", newest]) == 0


def test_the_python_package_reports_the_repository_version():
    """``binaural.__version__`` must be the version in ``pyproject.toml``.

    It used to be a literal here, and the two drifted: a release tagged
    ``v0.2.3`` while this file said ``0.2.2`` shipped an app that reported
    itself as 0.2.2. ``running_version()`` then compared 0.2.2 with the 0.2.3
    release, found nothing newer, and answered *you are up to date* forever —
    the exact failure this module exists to prevent, invisible to it because the
    checker did not know the file existed.
    """
    import binaural

    assert binaural.__version__ == check_version.pyproject_version()


def test_a_stale_fallback_version_is_caught(repo: Path):
    """The uninstalled-source-tree fallback is checked too.

    ``binaural.__version__`` normally comes from distribution metadata, but a
    source tree that was never installed has none to read, and the literal is
    what it falls back to. That is the one remaining way the package can
    misreport itself, so the checker watches it like every other copy.
    """
    found = check_version.fallback_versions(repo)
    if not found:
        pytest.skip("no fallback literal in the copied tree")
    for relative, version in found.items():
        _set_version(
            repo,
            str(relative),
            f'_FALLBACK_VERSION = "{version}"',
            '_FALLBACK_VERSION = "0.0.0-stale"',
        )
    assert check_version.main([], root=repo) == 1


def test_every_xcode_target_carries_the_version():
    """Not "the first target says 0.2.2" — all three of them.

    ``Binaural``, ``BinauralCore`` and ``Binaural-iOS`` each get their own
    ``MARKETING_VERSION``, and only the app target's ends up in front of a user. The
    other two can drift for a long time before anything looks wrong.
    """
    versions = check_version.marketing_versions()
    package = check_version.pyproject_version()
    assert len(versions) >= 3, f"only found {sorted(versions)}"
    for target, version in versions.items():
        assert version == package, f"{target} says {version}, package says {package}"


def test_the_updater_and_the_build_name_the_same_archive():
    """The two ends of the update, in a shell script and in Swift, have to agree."""
    assert check_version.check_asset_contract() == []


# --------------------------------------------------------------------------
# The checker fails when it should
# --------------------------------------------------------------------------


def test_a_target_left_at_the_old_version_is_caught(repo: Path):
    _break_the_xcode_versions(repo)
    assert check_version.main([], root=repo) == 1


def test_a_tag_that_does_not_match_is_caught(repo: Path):
    assert check_version.main(["--tag", f"v{_current_version()}"], root=repo) == 0
    assert check_version.main(["--tag", "v9.9.9"], root=repo) == 1


def test_a_tag_without_the_v_is_caught(repo: Path):
    assert check_version.main(["--tag", _current_version()], root=repo) == 1


def test_a_renamed_archive_is_caught(repo: Path):
    _set_version(
        repo,
        "scripts/build_macos.sh",
        "binaural-${VERSION}-macos-arm64.tar.gz",
        "Binaural-${VERSION}-macos-arm64.tar.gz",
    )
    assert check_version.main([], root=repo) == 1


def test_an_updater_looking_for_another_name_is_caught(repo: Path):
    _set_version(
        repo,
        "apple/Sources/Core/UpdateChecker.swift",
        "binaural-\\($0)-macos-arm64.tar.gz",
        "binaural-\\($0)-macOS-arm64.zip",
    )
    assert check_version.main([], root=repo) == 1


def test_every_problem_is_reported_at_once(repo: Path):
    """All of them, not the first one.

    A checker that stops at the first failure turns a version bump into a guessing game:
    fix, run, read, fix, run. The whole point of running it in CI is to get the whole
    list in one pass.
    """
    _break_the_xcode_versions(repo)
    _set_version(
        repo,
        "scripts/build_macos.sh",
        "binaural-${VERSION}-macos-arm64.tar.gz",
        "Binaural-${VERSION}-macos-arm64.tar.gz",
    )
    assert check_version.main([], root=repo) == 1


def test_the_bump_commit_can_say_so_on_purpose(repo: Path):
    """``--allow-mismatch`` is for the commit that bumps the version.

    Bumping is two edits, not one, so the commit that does it cannot pass a strict
    check — the second edit lands in the next commit. ``--allow-mismatch`` reports and
    exits 0 for exactly that step, and nothing else uses it.
    """
    _break_the_xcode_versions(repo)
    assert check_version.main([], root=repo) == 1
    assert check_version.main(["--allow-mismatch"], root=repo) == 0
