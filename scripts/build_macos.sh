#!/bin/sh
#
# Build the macOS release archive: the native Swift app, unsigned.
#
#   sh scripts/build_macos.sh           # dist/binaural-<ver>-macos-arm64.tar.gz
#   sh scripts/build_macos.sh --clean   # also remove apple/dist first
#
# The archive holds Binaural.app/ at its root, the layout install.sh and the native updater
# (UpdateInstaller) both expect. apple/build_release.sh builds the app and verifies the
# frequency data; this script versions and packs the result. It needs Xcode and xcodegen,
# so it runs on a Mac: CI uses macos-latest.
#
# --arch and --python are accepted so scripts/make_release.sh can call every platform the
# same way. The macOS app is built for arm64 only.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPLE="${ROOT}/apple"
DIST_DIR="${ROOT}/dist"

CLEAN=0
ARCH="arm64"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() { printf '==> %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1 ;;
        --arch)
            [ "$#" -ge 2 ] || die "--arch needs a value"
            ARCH="$2"
            shift
            ;;
        --arch=*) ARCH="${1#--arch=}" ;;
        --python)
            [ "$#" -ge 2 ] || die "--python needs a value"
            shift
            ;;
        --python=*) ;;
        -h|--help)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

[ "$ARCH" = "arm64" ] || die "the macOS app is built for arm64 only, not ${ARCH}"
command -v xcodebuild >/dev/null 2>&1 || die "Xcode is required: xcodebuild was not found"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen is required: brew install xcodegen"

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${ROOT}/pyproject.toml" | head -n 1)"
[ -n "$VERSION" ] || die "cannot read the version from pyproject.toml"

if [ "$CLEAN" -eq 1 ]; then
    step "removing apple/dist"
    rm -rf "${APPLE}/dist"
fi

step "building the native app, unsigned (apple/build_release.sh)"
(cd "$APPLE" && xcodegen generate >/dev/null && sh build_release.sh)
[ -d "${APPLE}/dist/Binaural.app" ] || die "expected ${APPLE}/dist/Binaural.app after the build"

ARCHIVE="${DIST_DIR}/binaural-${VERSION}-macos-arm64.tar.gz"
step "packing $(basename "$ARCHIVE")"
mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE"
tar -czf "$ARCHIVE" -C "${APPLE}/dist" Binaural.app
printf '    %s\n' "$ARCHIVE"
step "done"
