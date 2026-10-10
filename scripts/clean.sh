#!/bin/sh
#
# Remove what a development run leaves behind.
#
#   sh scripts/clean.sh              # repo artefacts + this project's Xcode cache
#   sh scripts/clean.sh --dry-run    # say what would go, delete nothing
#   sh scripts/clean.sh --all        # also shared Xcode caches and .probe/
#   sh scripts/clean.sh --no-xcode   # repo artefacts only
#
# Why this exists. Two caches grow without bound and neither is ever emptied:
#
#   * `xcodebuild test` writes an `.xcresult` bundle per run into
#     `~/Library/Developer/Xcode/DerivedData/Binaural-*/Logs/Test`. Each is a few hundred
#     megabytes, and a session of running the suite leaves hundreds of them behind — 785 MB
#     here, of which 671 MB was result bundles from a single afternoon.
#   * `dist/` and `apple/dist/` hold whole applications. `scripts/make_release.sh` now prunes
#     the archives of previous versions, but a built `.app` and the PyInstaller tree are
#     outside its reach.
#
# What it deliberately does NOT touch:
#
#   * `.venv/` — the working environment. Removing it means reinstalling PySide6 and numpy,
#     which is minutes of work for no disk saved next to the caches above.
#   * `.probe/` — scratch space from an investigation, ignored by git but possibly still
#     holding something the author wants.
#   * Xcode's *shared* caches (`ModuleCache.noindex`, `SDKExplicitPrecompiledModules`,
#     `SymbolCache.noindex`). Those are every project's, and emptying them slows down the next
#     build of everything on the machine. They are behind `--all`, never the default.
#
# Apple also ships this: Xcode's *Clean Build Folder* is ⇧⌘K, and it empties the same
# DerivedData for the open project. This script exists to do it from the terminal, to cover
# the PyInstaller side as well, and to say how much it freed.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"

DRY_RUN=0
WANT_XCODE=1
WANT_ALL=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --no-xcode) WANT_XCODE=0 ;;
        --all)      WANT_ALL=1 ;;
        -h|--help)  usage 0 ;;
        *)          printf 'error: unknown option: %s\n\n' "$1" >&2; usage 2 ;;
    esac
    shift
done

FREED_KB=0
REMOVED=0

# size_kb PATH — size in KB, or 0 when the path is not there. `du` fails on a missing
# path, and `set -e` would abort the script on the first thing that was never built.
size_kb() {
    [ -e "$1" ] || { printf '0'; return 0; }
    _kb="$(du -sk "$1" 2>/dev/null | awk '{print $1}')"
    printf '%s' "${_kb:-0}"
}

human_kb() {
    awk -v kb="$1" 'BEGIN { if (kb >= 1048576) printf "%.1f GB", kb/1048576;
                                else if (kb >= 1024)    printf "%.0f MB", kb/1024;
                                else                       printf "%d KB", kb }'
}

# remove PATH LABEL — delete one path, reporting it. Directories go with `rm -rf`.
remove() {
    _target="$1"
    _label="$2"
    [ -e "$_target" ] || return 0
    _kb="$(size_kb "$_target")"
    _mb="$(human_kb "$_kb")"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would remove %-28s %s\n' "${_label}" "${_mb}"
    else
        rm -rf "$_target"
        printf '  removed    %-28s %s\n' "${_label}" "${_mb}"
    fi
    FREED_KB=$((FREED_KB + _kb))
    REMOVED=$((REMOVED + 1))
}

printf '==> cleaning %s\n\n' "${ROOT}"

# --------------------------------------------------------------------------- #
# Build output and caches inside the repository
# --------------------------------------------------------------------------- #

printf 'repository:\n'
remove "${ROOT}/build" "build/ (PyInstaller tree)"
remove "${ROOT}/dist" "dist/ (release archives)"
remove "${ROOT}/apple/dist" "apple/dist/ (built .app)"
remove "${ROOT}/.pytest_cache" ".pytest_cache/"
remove "${ROOT}/.DS_Store" ".DS_Store"

# Python bytecode, at any depth. `__pycache__` is regenerated on the next run and costs
# nothing to lose.
# shellcheck disable=SC2044
for _pycache in $(find "${ROOT}" -type d -name __pycache__ -not -path "${ROOT}/.venv/*" 2>/dev/null); do
    remove "${_pycache}" "${_pycache#${ROOT}/}"
done

# A core dump from a crashed run. `python /tmp/whatever.py` that segfaults leaves a 20 MB
# ELF file in the working directory, which is what this is: a crash, not a build product.
# The name is plain `core`, so it has to be matched by path — see the note on the Xcode
# glob below for why `core` in .gitignore is anchored the same way.
remove "${ROOT}/core" "core (crash dump)"

# Metadata `pip install -e .` writes for the package it points at. Setuptools regenerates
# it on the next install; it is not the installed copy.
for _egg in "${ROOT}"/src/*.egg-info; do
    [ -d "$_egg" ] || continue
    remove "${_egg}" "${_egg#${ROOT}/}"
done

# Finder's per-directory metadata. It is not the user's data and macOS recreates it the
# moment they open the folder in Finder again — which is why it comes back rather than
# staying gone.
# shellcheck disable=SC2044
for _dsstore in $(find "${ROOT}" -name .DS_Store -not -path "${ROOT}/.venv/*" 2>/dev/null); do
    remove "${_dsstore}" "${_dsstore#${ROOT}/}"
done

# The Xcode project, which `xcodegen generate` rewrites from apple/project.yml in about a
# second. It is a build product by the repository's own statement — "never committed, run
# `xcodegen generate`" — and leaving it costs a stale generated project rather than a
# convenience: opening a stale one is exactly how a checked-in .xcodeproj drifts.
remove "${ROOT}/apple/Binaural.xcodeproj" "apple/Binaural.xcodeproj"

# --------------------------------------------------------------------------- #
# Xcode
# --------------------------------------------------------------------------- #

if [ "$WANT_XCODE" -eq 1 ]; then
    printf '\nXcode:\n'
    # Matched on the project's own DerivedData only. `Binaural-*` is what Xcode derives from
    # the target name, and a glob that was less specific would take other people's builds
    # with it.
    for _dd in "${DERIVED}"/Binaural-*; do
        [ -d "$_dd" ] || continue
        remove "${_dd}" "${_dd##*/} (incl. .xcresult logs)"
    done

    if [ "$WANT_ALL" -eq 1 ]; then
        printf '\n  shared caches (every project slows down once after this):\n'
        remove "${DERIVED}/SDKExplicitPrecompiledModules" "SDKExplicitPrecompiledModules"
        remove "${DERIVED}/ModuleCache.noindex" "ModuleCache.noindex"
        remove "${DERIVED}/SymbolCache.noindex" "SymbolCache.noindex"
    fi
fi

# --------------------------------------------------------------------------- #
# Scratch space, only on request
# --------------------------------------------------------------------------- #

# `.probe/` holds one-off reproducers from an investigation. Ignored by git, but unlike a
# cache it might still hold something the author was in the middle of — so `--all`, never
# the default.
if [ "$WANT_ALL" -eq 1 ]; then
    printf '\nscratch:\n'
    remove "${ROOT}/.probe" ".probe/ (investigation scratch)"
fi

# --------------------------------------------------------------------------- #

printf '\n'
if [ "$REMOVED" -eq 0 ]; then
    printf 'nothing to clean.\n'
elif [ "$DRY_RUN" -eq 1 ]; then
    printf '%d path(s), %s — nothing was deleted (--dry-run).\n' \
        "${REMOVED}" "$(human_kb "${FREED_KB}")"
else
    printf 'freed %s across %d path(s).\n' "$(human_kb "${FREED_KB}")" "${REMOVED}"
    printf '.venv/ was left alone: it is the working environment, not a cache.\n'
    printf 'Regenerate the Xcode project with: cd apple && xcodegen generate\n'
fi