#!/usr/bin/env python3
"""One version, one place to forget it.

The repository states the version in three files that no tool reads from one
another:

* ``pyproject.toml``      — the Python package, and what ``scripts/make_release.sh``
                            reads to name the archives
* ``apple/project.yml``   — ``MARKETING_VERSION`` for every Xcode target, which is
                            what ends up in ``CFBundleShortVersionString`` and is
                            therefore what the user sees in *About* and what the
                            in-app updater compares against
* the git tag             — ``v0.2.2``, which is what a GitHub Release is filed under

Nothing checked that they agreed. A tag of ``v0.3.0`` with ``MARKETING_VERSION`` left
at ``0.2.2`` produced an app that calls itself 0.2.2 forever, an archive named
``binaural-0.2.2-macos-arm64.tar.gz``, and an updater looking for
``binaural-0.3.0-macos-arm64.tar.gz`` — which never arrives. Every one of those is
silent: the build succeeds, the release publishes, the update check reports "you are up
to date" forever.

The second thing it checks is the contract between the two ends of the update: the name
``scripts/build_macos.sh`` writes, and the name ``UpdateChecker`` looks for. Those live in
a shell script and in Swift, and nothing on either side imports the other.

    python3 scripts/check_version.py                 # the three files must agree
    python3 scripts/check_version.py --tag v0.2.2    # ...and so must the tag
    python3 scripts/check_version.py --tag v0.3.0 --allow-mismatch   # during a bump

Exit status is 0 when everything agrees and 1 with every disagreement listed at once,
because a checker that stops at the first problem makes a version bump a guessing game.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

#: The asset name the native updater asks GitHub for, and the one the build writes.
#: Checked in both source files rather than declared here, so this script cannot drift
#: away from the code it exists to protect.
UPDATER_MATCHES = (
    Path("apple/Sources/Core/UpdateChecker.swift"),
    "binaural-\\($0)-macos-arm64.tar.gz",
)
BUILD_MATCHES = (
    Path("scripts/build_macos.sh"),
    "binaural-${VERSION}-macos-arm64.tar.gz",
)


class Problem(Exception):
    """One thing that has to be fixed before a release can be cut."""


def pyproject_version(root: Path = ROOT) -> str:
    text = (root / "pyproject.toml").read_text(encoding="utf-8")
    match = re.search(r'^version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match is None:
        raise Problem("pyproject.toml has no version = \"…\" line")
    return match.group(1)


#: The version literal in `binaural/__init__.py`. Not the source of truth — the
#: package reads its metadata, and this is only the fallback for a source tree
#: that was never installed. It still has to agree: a stale fallback is the one
#: way this file can report the wrong version, and it did exactly that at 0.2.2
#: while the release being cut was 0.2.3.
FALLBACK_VERSION_MATCHES = (
    (Path("src/binaural/__init__.py"), r'_FALLBACK_VERSION\s*=\s*"([^"]+)"'),
)


def fallback_versions(root: Path = ROOT) -> dict[Path, str]:
    """The fallback literal in each file that carries one, keyed by path."""
    found: dict[Path, str] = {}
    for relative, pattern in FALLBACK_VERSION_MATCHES:
        path = root / relative
        if not path.exists():
            continue
        match = re.search(pattern, path.read_text(encoding="utf-8"))
        if match is not None:
            found[relative] = match.group(1)
    return found


def marketing_versions(root: Path = ROOT) -> dict[str, str]:
    """``MARKETING_VERSION`` of every Xcode target, keyed by the target's name.

    Read from ``apple/project.yml`` because that is what ``xcodegen generate`` reads: the
    ``.xcodeproj`` is generated and git-ignored, so a check that read the project file
    would be checking a build product.
    """
    text = (root / "apple/project.yml").read_text(encoding="utf-8")
    out: dict[str, str] = {}
    section: str | None = None
    target: str | None = None
    for line in text.splitlines():
        stripped = line.strip()
        # The target name is a key at two spaces of indentation under `targets:`; a
        # deeper key belongs to whichever target was named last, so both levels have to
        # be tracked to say *which* target a version belongs to.
        indent = len(line) - len(line.lstrip())
        match = re.match(r'([\w.\-]+):\s*$', stripped)
        if match and indent == 2:
            target = match.group(1)
            continue
        if match and indent == 0:
            section, target = match.group(1), None
            continue
        if section != "targets" and target is None:
            continue
        version = re.match(r'MARKETING_VERSION:\s*"([^"]+)"', stripped)
        if version and target:
            # A target may set it more than once under different settings keys; the
            # first one is what wins in the generated project, so only a later value can
            # disagree with the rest.
            out.setdefault(f"{section or ''}.{target}", version.group(1))
    if not out:
        raise Problem("apple/project.yml sets MARKETING_VERSION nowhere")
    return out


def tag_version(tag: str) -> str:
    """``v0.2.2`` -> ``0.2.2``."""
    if not tag.startswith("v"):
        raise Problem(f"a release tag must start with 'v', not {tag!r}")
    return tag[1:]


def check_asset_contract(root: Path = ROOT) -> list[str]:
    """The archive name has to be written where it is built and read where it is found."""
    problems = []
    for relative, needle in (UPDATER_MATCHES, BUILD_MATCHES):
        path = root / relative
        if not path.exists():
            problems.append(f"{relative}: missing")
            continue
        if needle not in path.read_text(encoding="utf-8"):
            problems.append(
                f"{relative}: no longer contains {needle!r} — the archive name the "
                "updater asks for and the one the build writes have diverged"
            )
    return problems


def main(argv: list[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--tag", help="the git tag being released, e.g. v0.2.2", default=None
    )
    parser.add_argument(
        "--allow-mismatch",
        action="store_true",
        help="report problems but exit 0 — for the commit that bumps the version, "
             "where the tag does not exist yet",
    )
    args = parser.parse_args(argv)

    problems: list[str] = []
    try:
        package = pyproject_version(root)
        targets = marketing_versions(root)
    except Problem as exc:
        print(f"check_version: {exc}", file=sys.stderr)
        return 1

    for target, version in sorted(targets.items()):
        if version != package:
            problems.append(
                f"apple/project.yml: target {target} has MARKETING_VERSION {version!r}, "
                f"pyproject.toml says {package!r}"
            )

    for relative, version in sorted(fallback_versions(root).items()):
        if version != package:
            problems.append(
                f"{relative}: _FALLBACK_VERSION is {version!r}, pyproject.toml says "
                f"{package!r} — an app run from an uninstalled source tree would "
                f"report itself as the wrong version"
            )

    if args.tag:
        try:
            tagged = tag_version(args.tag)
        except Problem as exc:
            problems.append(str(exc))
        else:
            if tagged != package:
                problems.append(
                    f"tag {args.tag} does not match the version in pyproject.toml "
                    f"({package!r})"
                )

    problems.extend(check_asset_contract(root))

    if problems:
        print("check_version: the release metadata does not line up:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        if args.allow_mismatch:
            return 0
        return 1

    where = f" and tag {args.tag}" if args.tag else ""
    print(f"check_version: {package}{where} — {len(targets)} Xcode targets, updater agrees")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
