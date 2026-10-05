#!/bin/sh
#
# Build every release artifact and produce SHA256SUMS.
#
#   sh scripts/make_release.sh                  # build for the host platform
#   sh scripts/make_release.sh --all            # try all four, skip what cannot run here
#   sh scripts/make_release.sh --target linux-x64
#   sh scripts/make_release.sh --checksums-only # just refresh SHA256SUMS
#
# Naming matches install.sh exactly:
#
#   binaural-<version>-macos-arm64.tar.gz   -> Binaural.app/...      (installed as .app)
#   binaural-<version>-macos-x64.tar.gz
#   binaural-<version>-linux-x64.tar.gz     -> Binaural/ one-dir
#   binaural-<version>-linux-arm64.tar.gz
#
# PyInstaller bundles are platform-specific in both architecture *and* OS, so an artifact
# can only be produced on a matching host. --all reports the ones it cannot build instead
# of failing; CI builds the matrix on real runners.
#

set -eu

APP_NAME="Binaural"
EXE_NAME="binaural"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT}/build"
DIST_DIR="${ROOT}/dist"

TARGETS="auto"
CHECKSUMS_ONLY=0
CLEAN=0
# Prefer the project venv when PYTHON is not given: PySide6 and PyInstaller are
# installed there, and a bare `python3` on a dev machine usually has neither.
# The platform scripts get --python forwarded below; without it they would fall
# back to their own `python3` default and fail the PyInstaller preflight.
if [ -z "${PYTHON:-}" ] && [ -x "${ROOT}/.venv/bin/python" ]; then
    PYTHON="${ROOT}/.venv/bin/python"
else
    PYTHON="${PYTHON:-python3}"
fi

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Build release artifacts for Binaural.

  --target PLATFORM   Build only PLATFORM. One of:
                        macos-arm64 macos-x64 linux-x64 linux-arm64
  --all               Attempt every platform, skip the ones this host cannot build
  --clean             remove build/ and dist/ before building
  --checksums-only    Regenerate dist/SHA256SUMS from whatever is already in dist/
  --dist-dir DIR      Output directory (default: ${ROOT}/dist)
  --python P          python interpreter used to read the version (default: python3)
  -h, --help          this text

Artifacts land in dist/ as binaural-<version>-<platform>.tar.gz.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)  shift; TARGETS="${1:-}" ;;
        --target=*) TARGETS="${1#--target=}" ;;
        --all)     TARGETS="all" ;;
        --checksums-only) CHECKSUMS_ONLY=1 ;;
        --clean)          CLEAN=1 ;;
        --dist-dir) shift; DIST_DIR="${1:-$DIST_DIR}" ;;
        --dist-dir=*) DIST_DIR="${1#--dist-dir=}" ;;
        --python)  shift; PYTHON="${1:-python3}" ;;
        --python=*) PYTHON="${1#--python=}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown option: $1" ;;
    esac
    shift
done

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

checksum() {
    if command -v sha256sum >/dev/null 2>&1 </dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

ALL_PLATFORMS="macos-arm64 macos-x64 linux-x64 linux-arm64"

# The lists are space-separated words, so pad both sides before matching: without the
# leading space, "macos-arm64" fails to match itself in a `*" $x "*` test.
is_known_platform() {
    case " ${ALL_PLATFORMS} " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

host_platform() {
    _os="$(uname -s)"
    _arch="$(uname -m)"
    case "$_arch" in
        arm64|aarch64) _arch="arm64" ;;
        x86_64|amd64) _arch="x64" ;;
        *) _arch="unknown" ;;
    esac
    case "$_os" in
        Darwin) printf 'macos-%s' "$_arch" ;;
        Linux)  printf 'linux-%s' "$_arch" ;;
        *)      printf 'unknown-%s' "$_arch" ;;
    esac
}

HOST="$(host_platform)"

if [ "$TARGETS" = "auto" ]; then
    TARGETS="$HOST"
fi
if [ "$TARGETS" = "all" ]; then
    TARGETS="$ALL_PLATFORMS"
fi

# --------------------------------------------------------------------------- #
# Version
# --------------------------------------------------------------------------- #

VERSION="$(read_version)"
[ -n "$VERSION" ] || die "cannot read the version from ${ROOT}/pyproject.toml"

printf '%s%s release builder%s — version %s\n' \
    "$(printf '\033[1m' 2>/dev/null || printf '')" "$APP_NAME" \
    "$(printf '\033[0m' 2>/dev/null || printf '')" "$VERSION"
info "host:   ${HOST}"
info "dist:   ${DIST_DIR}"
info "target: ${TARGETS}"
printf '\n'

mkdir -p "$DIST_DIR"

if [ "$CLEAN" -eq 1 ]; then
    step "cleaning build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
    mkdir -p "$DIST_DIR"
fi

# Forwarded to the platform scripts so a single --clean reaches the whole chain.
CLEAN_FLAG=""
if [ "$CLEAN" -eq 1 ]; then
    CLEAN_FLAG="--clean"
fi

# --------------------------------------------------------------------------- #
# Checksums
# --------------------------------------------------------------------------- #

write_checksums() {
    step "writing SHA256SUMS"
    _sums="${DIST_DIR}/SHA256SUMS"
    rm -f "$_sums"
    _count=0
    for _pattern in '*.tar.gz' '*.zip'; do
        for _archive in "${DIST_DIR}"/$_pattern; do
            [ -f "$_archive" ] || continue
            _base="$(basename "$_archive")"
            case "$_base" in
                *.dSYM*|*-macos-*.app*) continue ;;
            esac
            if command -v sha256sum >/dev/null 2>&1 </dev/null; then
                (cd "$DIST_DIR" && sha256sum "$_base") >>"$_sums"
            else
                (cd "$DIST_DIR" && shasum -a 256 "$_base") >>"$_sums"
            fi
            _count=$((_count + 1))
        done
    done
    if [ "$_count" -eq 0 ]; then
        info "no archives in ${DIST_DIR}, nothing to checksum."
        return 0
    fi
    info "${_count} archive(s) -> ${_sums}"
    printf '\n'
    cat "$_sums"
    printf '\n'
    return 0
}

if [ "$CHECKSUMS_ONLY" -eq 1 ]; then
    write_checksums
    step "done"
    exit 0
fi

# --------------------------------------------------------------------------- #
# Build
# --------------------------------------------------------------------------- #

BUILT=""
SKIPPED=""

for _target in $TARGETS; do
    if ! is_known_platform "$_target"; then
        die "unknown platform: ${_target}
One of: ${ALL_PLATFORMS}"
    fi

    if [ "$_target" = "$HOST" ]; then
        :
    else
        warn "skipping ${_target}: PyInstaller bundles only run on the OS and CPU they were built for."
        warn "  this host is ${HOST}. Build ${_target} on a matching machine or in CI:"
        warn "    .github/workflows/ci.yml  (workflow_dispatch -> build-release)"
        SKIPPED="${SKIPPED} ${_target}"
        continue
    fi

    _arch="${_target#*-}"
    case "$_target" in
        macos-*)
            step "building ${_target}"
            # shellcheck disable=SC2086
            sh "${SCRIPT_DIR}/build_macos.sh" $CLEAN_FLAG --python "$PYTHON" \
                || die "the macOS build failed"
            # Both formats on purpose:
            #  * .tar.gz is what install.sh fetches (name must match exactly);
            #  * .zip is what a macOS user double-clicks, and tar's handling of the
            #    symlinks and modes inside a .app is not something to bet an install on.
            _tarball="${DIST_DIR}/${EXE_NAME}-${VERSION}-${_target}.tar.gz"
            rm -f "$_tarball"
            tar -czf "$_tarball" -C "$DIST_DIR" "${APP_NAME}.app"
            info "$(basename "$_tarball")  ($(du -h "$_tarball" | cut -f1))"
            BUILT="${BUILT} $(basename "$_tarball")"

            if command -v zip >/dev/null 2>&1 </dev/null; then
                _zip="${DIST_DIR}/${EXE_NAME}-${VERSION}-${_target}.zip"
                rm -f "$_zip"
                # -y keeps symlinks as symlinks, which a .app needs to stay valid.
                (cd "$DIST_DIR" && zip -q -r -y "$_zip" "${APP_NAME}.app")
                info "$(basename "$_zip")  ($(du -h "$_zip" | cut -f1))"
                BUILT="${BUILT} $(basename "$_zip")"
            else
                info "zip not installed, skipping the .zip (install.sh uses the .tar.gz)"
            fi
            ;;
        linux-*)
            step "building ${_target}"
            # shellcheck disable=SC2086
            sh "${SCRIPT_DIR}/build_linux.sh" $CLEAN_FLAG --arch "$_arch" --python "$PYTHON" \
                || die "the Linux build failed"
            BUILT="${BUILT} ${EXE_NAME}-${VERSION}-${_target}.tar.gz"
            ;;
    esac
done

# --------------------------------------------------------------------------- #
# Checksums and summary
# --------------------------------------------------------------------------- #

write_checksums

step "summary"
if [ -n "$BUILT" ]; then
    for _f in $BUILT; do
        info "built: ${_f}"
    done
else
    info "nothing was built on this host."
fi
if [ -n "$SKIPPED" ]; then
    info "skipped (wrong host):${SKIPPED}"
    info "CI builds the full matrix; see .github/workflows/ci.yml"
fi
printf '\n'

if [ -z "$BUILT" ]; then
    warn "no artifacts were produced. Publishing an empty release is not possible;"
    warn "run this on a matching host, or trigger the CI release job."
    exit 1
fi

step "next steps"
info "tag and push:      git tag v${VERSION} && git push origin v${VERSION}"
info "create the release: gh release create v${VERSION} ${DIST_DIR}/*.tar.gz ${DIST_DIR}/*.zip --notes-from-tag"
printf '\n'
