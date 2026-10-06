#!/bin/sh
#
# Build a Linux release archive with PyInstaller.
#
#   sh scripts/build_linux.sh              # dist/binaural-<ver>-linux-x64.tar.gz
#   sh scripts/build_linux.sh --clean
#   sh scripts/build_linux.sh --arch arm64 # build for a foreign architecture
#
# Output layout inside the archive:
#
#   binaural-<version>-linux-<arch>/
#     Binaural/                      one-dir bundle: the `binaural` binary + Qt + Python
#       share/applications/binaural.desktop
#       share/icons/hicolor/scalable/apps/binaural.svg
#
# install.sh looks for `*/bin/binaural`, `*/Binaural/binaural` or similar, so the extra
# wrapper directory does not matter to it.
#
# The icon is a plain SVG kept in packaging/linux/binaural.svg. No rasterisation step is
# needed: modern desktops (GNOME, KDE, Xfce) load SVG directly, and the .desktop file only
# needs the icon name to resolve. If a PNG ever becomes necessary, drop
# packaging/linux/binaural.png next to it and the spec bundles that instead.
#

set -eu

APP_NAME="Binaural"
EXE_NAME="binaural"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${ROOT}/packaging/pyinstaller.spec"
DESKTOP="${ROOT}/packaging/linux/binaural.desktop"
ICON_SVG="${ROOT}/packaging/linux/binaural.svg"
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
Build a Linux release archive with PyInstaller.

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

# Linux is the only Python release platform: macOS ships the native app in apple/, and
# there is no PyInstaller bundle for it to build any more.
[ "$(uname -s)" = "Linux" ] || die "this script only builds on Linux (found $(uname -s)).
macOS ships the native app from apple/ — see apple/README.md"

command -v "$PYTHON" >/dev/null 2>&1 </dev/null || die "python interpreter not found: ${PYTHON}
Install Python 3.10+ (apt install python3 / dnf install python3) or pass --python"

"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
    </dev/null >/dev/null 2>&1 || die "$PYTHON is older than 3.10."

"$PYTHON" -c 'import PyInstaller' </dev/null >/dev/null 2>&1 \
    || die "PyInstaller is not installed for ${PYTHON}.
Install it with:  ${PYTHON} -m pip install pyinstaller"

"$PYTHON" -c 'import PySide6.QtMultimedia' </dev/null >/dev/null 2>&1 \
    || die "PySide6.QtMultimedia is missing for ${PYTHON}. Audio output would be broken.
Install it with:
    ${PYTHON} -m pip install 'PySide6-Essentials>=6.5' 'PySide6-Addons>=6.5'"

command -v tar >/dev/null 2>&1 </dev/null || die "tar is not installed; it is needed to build the archive."
command -v gzip >/dev/null 2>&1 </dev/null || die "gzip is not installed; it is needed to build the archive."

[ -f "$SPEC" ] || die "PyInstaller spec not found: ${SPEC}"
[ -f "$ENTRY" ] || die "entry point not found: ${ENTRY}
The GUI layer (src/binaural/app.py) has to exist before packaging."
[ -f "$DESKTOP" ] || die "desktop entry not found: ${DESKTOP}"

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

ARCHIVE_NAME="${EXE_NAME}-${VERSION}-linux-${TARGET_ARCH}.tar.gz"
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

(cd "$ROOT" && "$PYTHON" -m PyInstaller \
    --noconfirm \
    --clean \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    "$SPEC")

BUNDLE="${DIST_DIR}/${APP_NAME}"
[ -d "$BUNDLE" ] || die "expected ${BUNDLE} after the build, but it does not exist."
[ -x "${BUNDLE}/${EXE_NAME}" ] || die "no executable at ${BUNDLE}/${EXE_NAME}."

# --------------------------------------------------------------------------- #
# Desktop integration inside the bundle
# --------------------------------------------------------------------------- #

step "adding desktop integration"

mkdir -p "${BUNDLE}/share/applications"
cp "$DESKTOP" "${BUNDLE}/share/applications/binaural.desktop"
chmod 644 "${BUNDLE}/share/applications/binaural.desktop"
info "share/applications/binaural.desktop"

generate_icon_svg() {
    # Written by the build rather than committed, so the icon always matches the palette
    # in SPEC §7.1 (primary #7C3AED, accent #059669, background #FAF5FF) without anyone
    # having to hand-edit vector art. Drop a real packaging/linux/binaural.svg in place to
    # override it; this function only runs when the file is absent.
    cat >"$1" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Binaural: two tones and the difference between them. -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FAF5FF"/>
      <stop offset="1" stop-color="#EDE4FE"/>
    </linearGradient>
  </defs>
  <rect x="8" y="8" width="240" height="240" rx="48" fill="url(#bg)"/>
  <!-- left ear tone -->
  <path d="M36 150 q20 -50 40 0 t40 0 t40 0"
        fill="none" stroke="#7C3AED" stroke-width="10"
        stroke-linecap="round"/>
  <!-- right ear tone, offset in phase: the beat is the gap between the crests -->
  <path d="M36 106 q20 -50 40 0 t40 0 t40 0"
        fill="none" stroke="#8B5CF6" stroke-width="10"
        stroke-linecap="round" opacity="0.65"/>
  <!-- perceived beat -->
  <circle cx="188" cy="128" r="18" fill="#059669"/>
</svg>
SVG
}

if [ -f "$ICON_SVG" ]; then
    mkdir -p "${BUNDLE}/share/icons/hicolor/scalable/apps"
    cp "$ICON_SVG" "${BUNDLE}/share/icons/hicolor/scalable/apps/binaural.svg"
    chmod 644 "${BUNDLE}/share/icons/hicolor/scalable/apps/binaural.svg"
    info "share/icons/hicolor/scalable/apps/binaural.svg (from packaging/linux/)"
else
    mkdir -p "${BUNDLE}/share/icons/hicolor/scalable/apps"
    generate_icon_svg "${BUNDLE}/share/icons/hicolor/scalable/apps/binaural.svg"
    chmod 644 "${BUNDLE}/share/icons/hicolor/scalable/apps/binaural.svg"
    info "share/icons/hicolor/scalable/apps/binaural.svg (generated)"
    info "commit packaging/linux/binaural.svg to replace the generated icon"
fi

# A README inside the archive: what it is, how to install, that it needs no packages.
if [ -f "${ROOT}/README.md" ] && [ -s "${ROOT}/README.md" ]; then
    cp "${ROOT}/README.md" "${BUNDLE}/README.md"
fi

# --------------------------------------------------------------------------- #
# Archive
# --------------------------------------------------------------------------- #

step "packing ${ARCHIVE_NAME}"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
STAGE_ROOT="${STAGE_DIR}/${EXE_NAME}-${VERSION}-linux-${TARGET_ARCH}"
mkdir -p "$STAGE_ROOT"
cp -R "$BUNDLE" "$STAGE_ROOT/"

mkdir -p "${DIST_DIR}"
rm -f "$ARCHIVE_PATH"
tar -czf "$ARCHIVE_PATH" \
    --owner=0 --group=0 \
    -C "$STAGE_DIR" \
    "${EXE_NAME}-${VERSION}-linux-${TARGET_ARCH}"

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
