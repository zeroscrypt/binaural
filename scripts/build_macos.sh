#!/bin/sh
#
# Build a macOS release archive with PyInstaller.
#
#   sh scripts/build_macos.sh              # dist/binaural-<ver>-macos-arm64.tar.gz
#   sh scripts/build_macos.sh --clean
#   sh scripts/build_macos.sh --arch arm64 # build for a foreign architecture
#
# Output layout inside the archive:
#
#   binaural-<version>-macos-<arch>/
#     Binaural.app/                      one-dir bundle: the `binaural` binary + Qt + Python
#       Contents/MacOS/binaural          the executable install.sh symlinks to
#
# install.sh looks for `*/bin/binaural`, `*/Binaural/binaural`, a `*.app` bundle or
# similar, so the extra wrapper directory does not matter to it.
#
# No code signing: there is no certificate in this repository and an unsigned bundle
# runs fine locally. Gatekeeper will complain about *downloaded* unsigned apps, which is
# a distribution decision (release notes / `xattr -dr com.apple.quarantine`), not a
# build step, so nothing here tries to fake a signature.
#

set -eu

APP_NAME="Binaural"
EXE_NAME="binaural"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${ROOT}/packaging/pyinstaller.spec"
ENTRY="${ROOT}/src/binaural/app.py"
BUILD_DIR="${ROOT}/build"
DIST_DIR="${ROOT}/dist"
STAGE_DIR="${BUILD_DIR}/stage"

CLEAN=0
TARGET_ARCH=""
PYTHON="${PYTHON:-python3}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# read_version — the single version string from pyproject.toml. One source of truth:
# the archive name, install.sh and the .app bundle all have to agree with it.
read_version() {
    _v=""
    if command -v "$PYTHON" >/dev/null 2>&1 </dev/null; then
        _v="$("$PYTHON" -c 'import re,sys;from pathlib import Path
try:
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
except OSError:
    raise SystemExit(1)
m = re.search(r"^version\s*=\s*\"([^\"]+)\"", text, re.MULTILINE)
print(m.group(1) if m else "")' "${ROOT}/pyproject.toml" 2>/dev/null </dev/null || printf '')"
    fi
    if [ -z "$_v" ]; then
        _v="$(grep -m1 -E '^version[[:space:]]*=' "${ROOT}/pyproject.toml" 2>/dev/null </dev/null \
            | sed -E 's/.*"([^"]+)".*/\1/' || printf '')"
    fi
    printf '%s' "$_v"
}

# checksum FILE — sha256 on every platform we build on
checksum() {
    if command -v sha256sum >/dev/null 2>&1 </dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

usage() {
    cat <<EOF
Build a macOS release archive with PyInstaller.

  --clean       remove build/ and dist/ before building
  --arch ARCH   build for ARCH (x64, arm64) instead of the host architecture
  --python P    python interpreter to build with (default: python3)
  -h, --help    this text
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean)    CLEAN=1 ;;
        --arch)     shift; TARGET_ARCH="${1:-}" ;;
        --arch=*)   TARGET_ARCH="${1#--arch=}" ;;
        --python)   shift; PYTHON="${1:-python3}" ;;
        --python=*) PYTHON="${1#--python=}" ;;
        -h|--help)  usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
    shift
done

# --------------------------------------------------------------------------- #
# Preconditions
# --------------------------------------------------------------------------- #

# macOS is the only platform this script builds for: the native Swift app in apple/ is
# the primary macOS product, but the Python app still ships as a prebuilt archive so
# that `curl | sh` downloads a binary instead of falling back to source.
[ "$(uname -s)" = "Darwin" ] || die "this script only builds on macOS (found $(uname -s)).
For Linux use: sh scripts/build_linux.sh"

command -v "$PYTHON" >/dev/null 2>&1 </dev/null || die "python interpreter not found: ${PYTHON}
Install Python 3.10+ (brew install python@3.12) or pass --python"

"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
    </dev/null >/dev/null 2>&1 || die "$PYTHON is older than 3.10."

"$PYTHON" -c 'import PyInstaller' </dev/null >/dev/null 2>&1 \
    || die "PyInstaller is not installed for ${PYTHON}.
Install it with:  ${PYTHON} -m pip install pyinstaller"

# Two different causes, one check: the wheel can be missing, or it can be installed
# and still fail to load because the system library it needs is absent. On macOS the
# second is rare (AVFoundation is a system framework), but a broken Python or a
# half-installed PySide6 wheel fails here too, and the message says which.
"$PYTHON" -c 'import PySide6.QtMultimedia' </dev/null >/dev/null 2>&1 \
    || die "PySide6.QtMultimedia will not import for ${PYTHON}. Audio output would be broken.
Install the wheels:
    ${PYTHON} -m pip install 'PySide6-Essentials>=6.5' 'PySide6-Addons>=6.5'"

command -v tar >/dev/null 2>&1 </dev/null || die "tar is not installed; it is needed to build the archive."
command -v gzip >/dev/null 2>&1 </dev/null || die "gzip is not installed; it is needed to build the archive."

[ -f "$SPEC" ] || die "PyInstaller spec not found: ${SPEC}"
[ -f "$ENTRY" ] || die "entry point not found: ${ENTRY}
The GUI layer (src/binaural/app.py) has to exist before packaging."

# --- architecture ---------------------------------------------------------- #

case "${TARGET_ARCH:-}" in
    "") TARGET_ARCH="$(uname -m)" ;;
esac
case "$TARGET_ARCH" in
    x86_64|amd64)   TARGET_ARCH="x64" ;;
    arm64|aarch64)  TARGET_ARCH="arm64" ;;
    *) die "unsupported target architecture: ${TARGET_ARCH} (use x64 or arm64)" ;;
esac

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    x86_64) HOST_ARCH="x64" ;;
    arm64|aarch64) HOST_ARCH="arm64" ;;
esac
if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
    info "note: cross-building for ${TARGET_ARCH} on a ${HOST_ARCH} host."
    info "      Qt binaries are not relocatable across architectures, so the result"
    info "      will only run on ${TARGET_ARCH}. Build on the target machine, or use CI."
fi

# --- version --------------------------------------------------------------- #

VERSION="$(read_version)"
info "version: ${VERSION}"

ARCHIVE_NAME="${EXE_NAME}-${VERSION}-macos-${TARGET_ARCH}.tar.gz"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #

if [ "$CLEAN" -eq 1 ]; then
    step "cleaning build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi

step "building the one-dir bundle with PyInstaller"
info "python: $("$PYTHON" -c 'import sys; print(sys.executable)' </dev/null)"
info "spec:   ${SPEC}"

# --noconfirm: never stop for the existing-dist question. The spec runs windowed
# (console=False), so the result is a GUI bundle that grows no terminal on launch.
(cd "$ROOT" && "$PYTHON" -m PyInstaller \
    --noconfirm \
    --clean \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    "$SPEC")

# On macOS PyInstaller's COLLECT step produces a .app bundle, not a plain directory.
BUNDLE="${DIST_DIR}/${APP_NAME}.app"
[ -d "$BUNDLE" ] || die "expected ${BUNDLE} after the build, but it does not exist."
EXECUTABLE="${BUNDLE}/Contents/MacOS/${EXE_NAME}"
[ -x "$EXECUTABLE" ] || die "no executable at ${EXECUTABLE}."

# --------------------------------------------------------------------------- #
# Archive
# --------------------------------------------------------------------------- #

step "packing ${ARCHIVE_NAME}"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
STAGE_ROOT="${STAGE_DIR}/${EXE_NAME}-${VERSION}-macos-${TARGET_ARCH}"
mkdir -p "$STAGE_ROOT"
cp -R "$BUNDLE" "$STAGE_ROOT/"

mkdir -p "${DIST_DIR}"
rm -f "$ARCHIVE_PATH"
tar -czf "$ARCHIVE_PATH" \
    --owner=0 --group=0 \
    -C "$STAGE_DIR" \
    "${EXE_NAME}-${VERSION}-macos-${TARGET_ARCH}"

rm -rf "$STAGE_DIR"

[ -f "$ARCHIVE_PATH" ] || die "the archive was not created: ${ARCHIVE_PATH}"
info "path:  ${ARCHIVE_PATH}"
info "size:  $(du -h "$ARCHIVE_PATH" | cut -f1)"
info "sha256: $(checksum "$ARCHIVE_PATH")"

printf '\n'
step "done"
info "Install it with:"
info "  sh install.sh --prefix=\"\$HOME/.binaural\""
info "or unpack manually and run the bundled binary."
printf '\n'
