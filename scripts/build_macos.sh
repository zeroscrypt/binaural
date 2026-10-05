#!/bin/sh
#
# Build Binaural.app on macOS with PyInstaller.
#
#   sh scripts/build_macos.sh              # one-dir .app in dist/Binaural.app
#   sh scripts/build_macos.sh --clean      # wipe build/ and dist/ first
#   sh scripts/build_macos.sh --verify     # run the built binary once
#
# No code signing: there is no certificate in this repository and an unsigned bundle
# runs fine locally. Gatekeeper will complain about *downloaded* unsigned apps, which is
# a distribution decision (release notes / `xattr -dr com.apple.quarantine`), not a
# build step, so nothing here tries to fake a signature.
#
# Output: dist/Binaural.app
#

set -eu

APP_NAME="Binaural"
EXE_NAME="binaural"
BUNDLE_ID="io.github.zeroscrypt.binaural"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPEC="${ROOT}/packaging/pyinstaller.spec"
INFO_PLIST="${ROOT}/packaging/macos/Info.plist"
ENTRY="${ROOT}/src/binaural/app.py"
BUILD_DIR="${ROOT}/build"
DIST_DIR="${ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

CLEAN=0
VERIFY=0
PYTHON="${PYTHON:-python3}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

usage() {
    cat <<EOF
Build ${APP_NAME}.app on macOS.

  --clean      remove build/ and dist/ before building
  --verify     run the built binary once (needs a GUI session; use --no-verify on CI)
  --python P   python interpreter to build with (default: python3)
  -h, --help   this text
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean)   CLEAN=1 ;;
        --verify)  VERIFY=1 ;;
        --no-verify) VERIFY=0 ;;
        --python)  shift; PYTHON="${1:-python3}" ;;
        --python=*) PYTHON="${1#--python=}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
    shift
done

# --------------------------------------------------------------------------- #
# Preconditions — report every missing thing at once instead of failing halfway
# --------------------------------------------------------------------------- #

[ "$(uname -s)" = "Darwin" ] || die "this script only builds on macOS (found $(uname -s)).
For Linux use: sh scripts/build_linux.sh"

command -v "$PYTHON" >/dev/null 2>&1 </dev/null || die "python interpreter not found: ${PYTHON}
Install Python 3.10+ (brew install python@3.12) or pass --python /path/to/python3"

"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
    </dev/null >/dev/null 2>&1 || die "$PYTHON is older than 3.10."

"$PYTHON" -c 'import PyInstaller' </dev/null >/dev/null 2>&1 \
    || die "PyInstaller is not installed for ${PYTHON}.
Install it with:
    ${PYTHON} -m pip install pyinstaller
or build in the project venv:
    python3 -m venv .venv && .venv/bin/pip install pyinstaller"

"$PYTHON" -c 'import PySide6.QtMultimedia' </dev/null >/dev/null 2>&1 \
    || die "PySide6.QtMultimedia is missing for ${PYTHON}. Audio output would be broken.
Install it with:
    ${PYTHON} -m pip install 'PySide6-Essentials>=6.5' 'PySide6-Addons>=6.5'"

[ -f "$SPEC" ]       || die "PyInstaller spec not found: ${SPEC}"
[ -f "$ENTRY" ]      || die "entry point not found: ${ENTRY}
The GUI layer (src/binaural/app.py) has to exist before packaging."
[ -f "$INFO_PLIST" ] || die "Info.plist not found: ${INFO_PLIST}"

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #

if [ "$CLEAN" -eq 1 ]; then
    step "cleaning build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
fi

step "building ${APP_NAME}.app with PyInstaller"
info "python:  $("$PYTHON" -c 'import sys; print(sys.executable)' </dev/null)"
info "spec:    ${SPEC}"
info "version: $("$PYTHON" -c 'import sys; print(sys.version.split()[0])' </dev/null)"

# --noconfirm: never stop for the existing-dist question.
# --windowed/--noconsole: a GUI app must not grow a terminal on launch.
(cd "$ROOT" && "$PYTHON" -m PyInstaller \
    --noconfirm \
    --clean \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_DIR" \
    "$SPEC")

# --------------------------------------------------------------------------- #
# Post-process the bundle
# --------------------------------------------------------------------------- #

[ -d "$APP_BUNDLE" ] || die "expected ${APP_BUNDLE} to exist after the build, but it does not."

step "installing Info.plist"
cp "$INFO_PLIST" "${APP_BUNDLE}/Contents/Info.plist"

# PyInstaller's own plist wins if it was generated, so force our identity fields back.
if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 </dev/null; then
    PLIST="${APP_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${EXE_NAME}" "$PLIST" >/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${EXE_NAME}" "$PLIST" >/dev/null \
        || info "could not set CFBundleExecutable (left as generated)"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLE_ID}" "$PLIST" >/dev/null \
        || info "could not set CFBundleIdentifier (left as generated)"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 11.0" "$PLIST" >/dev/null \
        || info "could not set LSMinimumSystemVersion (left as generated)"
    info "bundle id: ${BUNDLE_ID}"
elif command -v plutil >/dev/null 2>&1 </dev/null; then
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "${APP_BUNDLE}/Contents/Info.plist" \
        || info "could not rewrite the bundle id"
fi

# Strip the per-machine build paths that PyInstaller leaves behind: they make the bundle
# bigger and leak the builder's home directory.
/usr/bin/plutil -convert xml1 -o /dev/null "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null \
    && info "Info.plist is valid" \
    || die "Info.plist is not a valid property list: ${APP_BUNDLE}/Contents/Info.plist"

step "checking the executable"
EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${EXE_NAME}"
[ -x "$EXECUTABLE" ] || die "the bundle has no executable at ${EXECUTABLE}."
info "size: $(du -sh "$APP_BUNDLE" | cut -f1)"
info "arch: $(lipo -archs "$EXECUTABLE" 2>/dev/null || echo unknown)"

# Unsigned, so mark it explicitly: an ad-hoc signature keeps Gatekeeper's first-launch
# prompt predictable and costs nothing. Not a substitute for a real Developer ID.
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 \
    && info "ad-hoc code signature applied" \
    || info "ad-hoc signing skipped (codesign unavailable or refused)"

# --------------------------------------------------------------------------- #
# Optional smoke test
# --------------------------------------------------------------------------- #

if [ "$VERIFY" -eq 1 ]; then
    step "running ${EXECUTABLE} once"
    if "$EXECUTABLE" >/dev/null 2>&1 </dev/null; then
        info "the app started and exited cleanly"
    else
        info "the app exited with status $? — check the log above if anything looks wrong"
    fi
fi

say_result() {
    printf '\n'
    step "done"
    info "bundle: ${APP_BUNDLE}"
    info "to try it:  open ${APP_BUNDLE}"
    info "to package: sh scripts/make_release.sh"
    printf '\n'
}

say_result
