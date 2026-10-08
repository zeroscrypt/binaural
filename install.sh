#!/bin/sh
#
# Binaural — installer.
#
#   curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh
#
# Constraints that shape this file:
#   * POSIX sh only (no bashisms): runs under dash, busybox ash, bash, zsh, ksh.
#     That includes the error handling: `trap ... ERR` is not POSIX, and dash rejects
#     the condition outright ("trap: ERR: bad trap"), so failures are caught by must()
#     at the call site and by the on_exit() backstop instead.
#   * Never reads stdin. When the script is piped, stdin *is* the script itself, so any
#     interactive read would swallow the remaining program text. Everything that could
#     consume stdin is redirected from /dev/null.
#   * No root and no system packages: everything lands in a user-writable prefix.
#   * No `local`, no arrays, no [[ ]], no $'...', no `function`.
#
# Strategy:
#   1. primary  — download the prebuilt archive for this platform from GitHub Releases
#                (self-contained PyInstaller bundle: its own Python and Qt). Linux and
#                macOS both ship one; macOS also has the native app in apple/.
#   2. fallback — no release available (HTTP 404, which is the normal state before the
#                first release is published): create a private virtualenv in
#                $PREFIX/venv from the source tree and pip-install the project into it.
#                Needs python3 >= 3.10, nothing else.
#
# Flags:
#   --help -h            usage
#   --version            installer version
#   --uninstall          remove prefix, symlink and the managed PATH block
#   --prefix=DIR         install prefix            (default: $HOME/.binaural)
#   --bin-dir=DIR        symlink location          (default: $HOME/.local/bin)
#   --force              reinstall over an existing install
#   --dry-run            print the plan, touch nothing
#   --source             skip the release download, always use the source fallback
#   --no-path-edit       do not touch ~/.zshrc, ~/.bashrc, ~/.profile
#   --no-verify          skip the `binaural --version` check
#   --release-url=URL    fetch this exact archive instead of a GitHub Release
#   --source-url=URL     fetch the source tarball from here
#

set -eu

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #

INSTALLER_VERSION="1.0.0"
APP_NAME="binaural"
APP_DISPLAY_NAME="Binaural"
DEFAULT_APP_VERSION="0.1.0"

REPO="zeroscrypt/binaural"
REPO_URL="https://github.com/${REPO}"
RELEASES_API="https://api.github.com/repos/${REPO}/releases"
SOURCE_URL_DEFAULT="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"

PATH_MARKER="# >>> binaural installer - managed block, do not edit >>>"
PATH_MARKER_END="# <<< binaural installer - managed block <<<"

EXIT_OK=0
EXIT_FAIL=1
EXIT_USAGE=2

# --------------------------------------------------------------------------- #
# State (every variable has a default, so `set -u` is safe)
# --------------------------------------------------------------------------- #

PREFIX="${HOME}/.binaural"
BIN_DIR="${HOME}/.local/bin"
RELEASE_URL="${BINAURAL_RELEASE_URL:-}"
SOURCE_URL="${BINAURAL_SOURCE_URL:-$SOURCE_URL_DEFAULT}"
APP_VERSION="${BINAURAL_VERSION:-$DEFAULT_APP_VERSION}"

MODE_UNINSTALL=0
DRY_RUN=0
FORCE=0
WANT_SOURCE=0
EDIT_PATH=1
DO_VERIFY=1
VERIFY_TIMEOUT=25

# Error reporting. ERROR_REPORTED is set by everything that explains its own failure
# (die, usage_error, on_error), so the on_exit() backstop stays quiet for those and
# speaks up only when a command simply failed with nobody watching.
ERROR_REPORTED=0

OS_NAME=""
ARCH_NAME=""
PLATFORM=""
HAVE_CURL=0
HAVE_WGET=0
HAVE_TAR=0
HAVE_GZIP=0
HAVE_UNZIP=0
PYTHON_BIN=""
TMPDIR_RUN=""
TARGET=""
INSTALLED_TARGET=""

# --------------------------------------------------------------------------- #
# Output helpers
#
# Progress goes to stderr on purpose: several install steps hand their result back to
# the caller through stdout (command substitution), so anything printed to stdout
# would be swallowed. Only --help / --version / the final report use stdout.
# --------------------------------------------------------------------------- #

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_OFF="$(printf '\033[0m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[36m')"
    C_BOLD="$(printf '\033[1m')"
else
    C_OFF=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_BOLD=''
fi

say()   { printf '%s\n' "$*" >&2; }                 # progress / guidance
out()   { printf '%s\n' "$*"; }                    # real stdout (help, version)
step()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*" >&2; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_OFF" "$*" >&2; }
info()  { printf '      %s%s%s\n' "$C_BOLD" "$*" "$C_OFF" >&2; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
err()   { printf '%serror%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }

die() {
    err "$*"
    ERROR_REPORTED=1
    exit "$EXIT_FAIL"
}

usage_error() {
    err "$*"
    say ""
    say "Run 'sh install.sh --help' for usage."
    ERROR_REPORTED=1
    exit "$EXIT_USAGE"
}

# on_error CODE [LINE] [STEP] [CMD] — the one place an unexplained failure is
# reported, so a failure caught at a call site, one caught by the on_exit() backstop
# and one caught by the zsh hook below all read the same. LINE is "?" when the shell
# cannot be trusted to produce a real one; STEP and CMD are optional.
on_error() {
    _code="${1:-1}"
    _line="${2:-?}"
    _step="${3:-}"
    _cmd="${4:-}"
    ERROR_REPORTED=1
    if [ "$_line" = "?" ]; then
        err "installer failed with exit status ${_code}"
    else
        err "installer failed at line ${_line} (exit status ${_code})"
    fi
    if [ -n "$_step" ]; then
        say "  step:    ${_step}"
    fi
    if [ -n "$_cmd" ]; then
        say "  command: ${_cmd}"
    fi
    say ""
    say "Likely causes:"
    say "  * no network or a blocking proxy — github.com and codeload.github.com are needed"
    say "  * truncated download — just run the command again"
    say "  * \$HOME is read-only or the disk is full — try --prefix=/somewhere/writable"
    say ""
    say "Re-run with --dry-run to see the plan without touching anything."
    exit "$_code"
}

cleanup_tmpdir() {
    if [ -n "$TMPDIR_RUN" ] && [ -d "$TMPDIR_RUN" ]; then
        rm -rf "$TMPDIR_RUN" 2>/dev/null || true
    fi
    return 0
}

# on_exit — removes the temporary directory and is the backstop for everything must()
# does not cover: `set -e` still turns any unhandled non-zero status into an exit,
# and this makes sure that exit is never a silent one.
on_exit() {
    _status=$?
    trap - EXIT
    cleanup_tmpdir
    # No step and no command to name here: must() reports the failures it catches, and
    # whatever reaches this handler came out of a construct we cannot describe.
    # Pointing at the previous command would be a guess, and a wrong guess is worse
    # than none.
    if [ "$_status" -ne 0 ] && [ "$ERROR_REPORTED" -eq 0 ]; then
        on_error "$_status"
    fi
    exit "$_status"
}

# zsh is the one shell here that skips the EXIT trap when `set -e` aborts inside a
# function, and every command in this installer lives in one — so on zsh the backstop
# above would never run and an unexpected failure would exit in silence. zsh's own ERR
# hook covers that case. In every other shell TRAPZERR is an ordinary function that
# simply never gets called, so this costs nothing and is not a bashism: it fires on
# exactly the commands `set -e` acts on, and on nothing else.
TRAPZERR() {
    on_error "$?"
}

trap 'on_exit' EXIT

# Not every shell tracks $LINENO inside a function: bash, ksh and macOS sh report the
# line being executed, dash always reports 1 and zsh always 0. A line number that points
# at the wrong line is worse than none, so the installer probes once, at the top level
# where all of them are correct, and drops line numbers where they cannot be trusted.
#
# The probe must stay a one-line function on the line directly below the assignment,
# because a shell that tracks $LINENO reports the function's *body* line — which is
# exactly the line a must() call reports, and here that is assignment + 1.
_LINENO_TOP="${LINENO:-0}"
_probe_lineno() { _PROBE_LINENO_IN="${LINENO:-0}"; }
_probe_lineno
LINENO_TRUSTED=0
if [ "$_PROBE_LINENO_IN" -eq "$((_LINENO_TOP + 1))" ]; then
    LINENO_TRUSTED=1
fi

# run: print the command, execute it unless this is a dry run
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    %s[dry-run]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
        return 0
    fi
    "$@"
}

# must LINE STEP CMD... — the POSIX replacement for `trap ... ERR` at a call site.
#
# Runs CMD (through run(), so --dry-run still touches nothing) and aborts through
# on_error() if it fails, naming the step, the command and the line it was called
# from. LINE is always passed as "${LINENO:-?}"; whether it is printed depends on the
# probe above.
must() {
    _must_line="${1:-}"
    shift
    _must_step="${1:-}"
    shift
    if [ "$LINENO_TRUSTED" -ne 1 ]; then
        _must_line="?"
    fi
    run "$@" || on_error "$?" "$_must_line" "$_must_step" "$*"
}

# append_to FILE CMD... — append CMD's output to FILE, and overwrite_file FILE SRC...
# — replace FILE's contents. A redirection is not an argument, so the two places that
# need one call through these instead of writing `>>"$file"` themselves.
append_to() {
    _append_file="$1"
    shift
    "$@" >>"$_append_file"
}

overwrite_file() {
    _overwrite_target="$1"
    shift
    cat "$1" >"$_overwrite_target"
}

# --------------------------------------------------------------------------- #
# Help / version
# --------------------------------------------------------------------------- #

show_help() {
    out "${C_BOLD}${APP_DISPLAY_NAME} installer${C_OFF} (v${INSTALLER_VERSION})"
    out ""
    out "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sh"
    out ""
    out "${C_BOLD}USAGE${C_OFF}"
    out "  sh install.sh [options]"
    out ""
    out "${C_BOLD}OPTIONS${C_OFF}"
    out "  --help, -h       Show this help and exit."
    out "  --version        Print the installer version and exit."
    out "  --uninstall      Remove ${APP_NAME}: prefix, symlink, managed PATH block."
    out "  --prefix=DIR     Install prefix (default: \$HOME/.${APP_NAME})."
    out "  --bin-dir=DIR    Where the '${APP_NAME}' symlink goes (default: \$HOME/.local/bin)."
    out "  --force          Reinstall even if ${APP_NAME} is already there."
    out "  --dry-run        Print every action, change nothing."
    out "  --source         Skip the release download, install from the source tree."
    out "  --no-path-edit   Do not modify ~/.zshrc, ~/.bashrc or ~/.profile."
    out "  --no-verify      Skip the '${APP_NAME} --version' check."
    out "  --release-url=URL  Fetch this exact archive instead of a GitHub Release."
    out "  --source-url=URL   Fetch the source tarball from here (default: main branch)."
    out ""
    out "${C_BOLD}ENVIRONMENT${C_OFF}"
    out "  BINAURAL_VERSION=0.1.0     App version to look for."
    out "  BINAURAL_PREFIX=DIR        Same as --prefix."
    out "  BINAURAL_BIN_DIR=DIR       Same as --bin-dir."
    out "  BINAURAL_RELEASE_URL=URL   Same as --release-url."
    out "  BINAURAL_SOURCE_URL=URL    Same as --source-url."
    out "  BINAURAL_PIP_ARGS='...'    Extra flags for pip in --source mode."
    out "  BINAURAL_SKIP_VERIFY=1     Same as --no-verify."
    out "  BINAURAL_VERIFY_TIMEOUT=N  Seconds before the version check aborts (default 25)."
    out "  NO_COLOR=1                 Disable colored output."
    out ""
    out "${C_BOLD}INSTALL LAYOUT${C_OFF}"
    out "  \$PREFIX/app/            unpacked release bundle"
    out "  \$PREFIX/venv/           virtualenv, only in --source mode"
    out "  \$PREFIX/install-meta    what was installed, from where"
    out "  \$BIN_DIR/${APP_NAME}         symlink to the installed entry point"
    out "  ~/.local/share/         the .desktop launcher and icon (Linux releases)"
    out ""
    out "Supported platforms: linux-x64 linux-arm64 macos-arm64"
}

print_version() {
    out "${APP_DISPLAY_NAME} installer ${INSTALLER_VERSION}"
    out "default app version: ${APP_VERSION}"
    out "platforms: linux-x64 linux-arm64 macos-arm64"
    out "repository: ${REPO_URL}"
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                exit "$EXIT_OK"
                ;;
            -V|--version)
                print_version
                exit "$EXIT_OK"
                ;;
            --uninstall)
                MODE_UNINSTALL=1
                ;;
            --dry-run)      DRY_RUN=1 ;;
            --force)        FORCE=1 ;;
            --source)       WANT_SOURCE=1 ;;
            --no-path-edit) EDIT_PATH=0 ;;
            --no-verify)    DO_VERIFY=0 ;;
            --prefix=*)     PREFIX="${1#--prefix=}" ;;
            --bin-dir=*)    BIN_DIR="${1#--bin-dir=}" ;;
            --release-url=*) RELEASE_URL="${1#--release-url=}" ;;
            --source-url=*)  SOURCE_URL="${1#--source-url=}" ;;
            --prefix|--bin-dir)
                _opt="$1"
                shift
                if [ "$#" -eq 0 ] || [ -z "$1" ]; then
                    usage_error "${_opt} requires a directory."
                fi
                case "$1" in
                    -*) usage_error "${_opt} requires a directory." ;;
                esac
                if [ "$_opt" = "--prefix" ]; then
                    PREFIX="$1"
                else
                    BIN_DIR="$1"
                fi
                ;;
            -*)  usage_error "unknown option: $1" ;;
            *)   usage_error "unexpected argument: $1" ;;
        esac
        shift
    done

    if [ -z "$PREFIX" ]; then
        usage_error "--prefix must not be empty."
    fi
    if [ -z "$BIN_DIR" ]; then
        usage_error "--bin-dir must not be empty."
    fi

    if [ "${BINAURAL_SKIP_VERIFY:-0}" = "1" ]; then
        DO_VERIFY=0
    fi
    case "${BINAURAL_VERIFY_TIMEOUT:-}" in
        ''|*[!0-9]*) ;;
        *) VERIFY_TIMEOUT="$BINAURAL_VERIFY_TIMEOUT" ;;
    esac
    if [ -n "${BINAURAL_FORCE:-}" ]; then
        FORCE=1
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Platform detection
# --------------------------------------------------------------------------- #

detect_platform() {
    _os="$(uname -s 2>/dev/null || printf 'unknown')"
    _arch="$(uname -m 2>/dev/null || printf 'unknown')"

    case "$_os" in
        Linux)  OS_NAME="linux" ;;
        Darwin)
            # macOS has a Python release archive (binaural-<ver>-macos-arm64.tar.gz,
            # built by scripts/build_macos.sh) next to the native Swift app in apple/.
            OS_NAME="macos"
            ;;
        *)
            err "unsupported operating system: ${_os}"
            say "The Python build ships for Linux; Windows is not in this release."
            say "On macOS use the native app from apple/ — see apple/README.md."
            ERROR_REPORTED=1
            exit "$EXIT_FAIL"
            ;;
    esac

    case "$_arch" in
        arm64|aarch64|armv8|armv8l) ARCH_NAME="arm64" ;;
        x86_64|amd64)               ARCH_NAME="x64" ;;
        *)
            err "unsupported CPU architecture: ${_arch}"
            say "Supported: x86_64 (reported as x64) and arm64."
            ERROR_REPORTED=1
            exit "$EXIT_FAIL"
            ;;
    esac

    PLATFORM="${OS_NAME}-${ARCH_NAME}"
    return 0
}

detect_tools() {
    if command -v curl >/dev/null 2>&1 </dev/null; then
        HAVE_CURL=1
    fi
    if command -v wget >/dev/null 2>&1 </dev/null; then
        HAVE_WGET=1
    fi
    if command -v tar >/dev/null 2>&1 </dev/null; then
        HAVE_TAR=1
    fi
    if command -v gzip >/dev/null 2>&1 </dev/null; then
        HAVE_GZIP=1
    fi
    if command -v unzip >/dev/null 2>&1 </dev/null; then
        HAVE_UNZIP=1
    fi
    return 0
}

downloader_name() {
    if [ "$HAVE_CURL" -eq 1 ]; then
        printf 'curl (%s)' "$(command -v curl)"
    else
        printf 'wget (%s)' "$(command -v wget)"
    fi
}

need_downloader() {
    if [ "$HAVE_CURL" -eq 1 ]; then
        return 0
    fi
    if [ "$HAVE_WGET" -eq 1 ]; then
        return 0
    fi
    err "neither curl nor wget was found, and one of them is required."
    say "  Debian/Ubuntu : sudo apt-get install -y curl"
    say "  Fedora        : sudo dnf install -y curl"
    say "  Alpine        : apk add curl"
    say "  macOS         : /usr/bin/curl ships with the system"
    ERROR_REPORTED=1
    exit "$EXIT_FAIL"
}

need_extractor() {
    if [ "$HAVE_TAR" -eq 1 ] && [ "$HAVE_GZIP" -eq 1 ]; then
        return 0
    fi
    if [ "$HAVE_UNZIP" -eq 1 ]; then
        return 0
    fi
    err "no archive extractor found (need tar + gzip, or unzip)."
    say "  Debian/Ubuntu : sudo apt-get install -y tar gzip"
    say "  macOS         : tar and gzip ship with the system"
    ERROR_REPORTED=1
    exit "$EXIT_FAIL"
}

find_python() {
    for _c in "${PYTHON_BIN:-}" python3 python3.13 python3.12 python3.11 python3.10 python; do
        [ -n "$_c" ] || continue
        if ! command -v "$_c" >/dev/null 2>&1 </dev/null; then
            continue
        fi
        _ver="$("$_c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null </dev/null || printf '')"
        case "$_ver" in
            ''|*[!0-9.]*) continue ;;
        esac
        _major="${_ver%%.*}"
        _minor="${_ver#*.}"
        if [ "$_major" -gt 3 ] || { [ "$_major" -eq 3 ] && [ "$_minor" -ge 10 ]; }; then
            PYTHON_BIN="$_c"
            return 0
        fi
    done
    return 1
}

python_version_string() {
    if [ -z "$PYTHON_BIN" ]; then
        printf 'not found'
        return 0
    fi
    _v="$("$PYTHON_BIN" -c 'import platform; print(platform.python_version())' 2>/dev/null </dev/null || printf '')"
    if [ -z "$_v" ]; then
        printf 'unknown'
    else
        printf '%s (%s)' "$_v" "$PYTHON_BIN"
    fi
}

need_python() {
    if find_python; then
        return 0
    fi
    err "python3 >= 3.10 is required for the source fallback, but none was found."
    say ""
    say "Binaural normally installs as a self-contained binary and needs no Python."
    say "This machine has no published release for ${PLATFORM}, so the fallback was used."
    say "Install Python and run this script again:"
    say "  Debian/Ubuntu : sudo apt-get install -y python3 python3-venv"
    say "  Fedora        : sudo dnf install -y python3"
    say "  Alpine        : apk add python3"
    say "  macOS         : brew install python@3.12"
    ERROR_REPORTED=1
    exit "$EXIT_FAIL"
}

# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

# http_get URL DEST — download; non-zero exit on any HTTP error (404 included)
http_get() {
    if [ "$HAVE_CURL" -eq 1 ]; then
        curl -fsSL --retry 2 --connect-timeout 20 -o "$2" "$1" </dev/null
    else
        wget -q -O "$2" "$1" </dev/null
    fi
}

# http_get_stdout URL — download to stdout; non-zero exit on any HTTP error
http_get_stdout() {
    if [ "$HAVE_CURL" -eq 1 ]; then
        curl -fsSL --retry 1 --connect-timeout 20 "$1" </dev/null
    else
        wget -q -O - "$1" </dev/null
    fi
}

normalize_tag() {
    # The newline matters: candidate_tags prints this tag and the one from the API into
    # the same stream, and without it the two run together into "v0.1.0v0.1.0" — a tag
    # that 404s, so the release path silently never finds an archive.
    case "$1" in
        v*) printf '%s\n' "$1" ;;
        *)  printf 'v%s\n' "$1" ;;
    esac
}

release_archive_names() {
    _ver="$1"
    printf '%s\n' \
        "${APP_NAME}-${_ver}-${PLATFORM}.tar.gz" \
        "${APP_NAME}-${PLATFORM}.tar.gz" \
        "${APP_NAME}-${_ver}-${PLATFORM}.zip"
}

# candidate_tags — one tag per line: requested version, then the newest published one
candidate_tags() {
    normalize_tag "$APP_VERSION"
    _tag="$(latest_tag_from_api || true)"
    if [ -n "$_tag" ]; then
        printf '%s\n' "$_tag"
    fi
    return 0
}

# latest_tag_from_api — best effort; prints nothing when the API is unreachable
latest_tag_from_api() {
    for _endpoint in "${RELEASES_API}/latest" "${RELEASES_API}"; do
        _body="$(http_get_stdout "$_endpoint" 2>/dev/null </dev/null || true)"
        if [ -z "$_body" ]; then
            continue
        fi
        _tag="$(printf '%s' "$_body" \
            | tr ',' '\n' \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n 1)"
        if [ -n "$_tag" ]; then
            printf '%s' "$_tag"
            return 0
        fi
    done
    return 0
}

# candidate_release_urls — one archive URL per line
candidate_release_urls() {
    if [ -n "$RELEASE_URL" ]; then
        printf '%s\n' "$RELEASE_URL"
        return 0
    fi
    _tags="$(candidate_tags)"
    printf '%s\n' "$_tags" | while IFS= read -r _tag; do
        [ -n "$_tag" ] || continue
        _ver="${_tag#v}"
        release_archive_names "$_ver" | while IFS= read -r _name; do
            printf '%s\n' "${REPO_URL}/releases/download/${_tag}/${_name}"
        done
    done
    return 0
}

# --------------------------------------------------------------------------- #
# Filesystem helpers
# --------------------------------------------------------------------------- #

make_tmpdir() {
    _base="${TMPDIR:-/tmp}"
    case "$_base" in
        /) _base="//tmp" ;;
    esac
    TMPDIR_RUN="$(mktemp -d "${_base%/}/binaural-install.XXXXXX" 2>/dev/null || printf '')"
    if [ -z "$TMPDIR_RUN" ] || [ ! -d "$TMPDIR_RUN" ]; then
        TMPDIR_RUN=""
        die "cannot create a temporary directory under ${_base}."
    fi
    return 0
}

tmpfile() {
    printf '%s/%s' "${TMPDIR_RUN:-${TMPDIR:-/tmp}}" "$1"
}

# extract_archive ARCHIVE DEST — unpack; prefers tar+gzip, falls back to unzip
extract_archive() {
    _archive="$1"
    _dest="$2"
    if [ ! -s "$_archive" ]; then
        err "archive is missing or empty: ${_archive}"
        return 1
    fi
    must "${LINENO:-?}" "create ${_dest}" mkdir -p "$_dest"
    if [ "$HAVE_TAR" -eq 1 ] && [ "$HAVE_GZIP" -eq 1 ]; then
        if run tar -xzf "$_archive" -C "$_dest"; then
            return 0
        fi
        if [ "$HAVE_UNZIP" -eq 1 ]; then
            warn "tar could not unpack the archive, retrying with unzip."
            run unzip -q -o "$_archive" -d "$_dest"
            return 0
        fi
        return 1
    fi
    run unzip -q -o "$_archive" -d "$_dest"
    return 0
}

# locate_executable ROOT — print the entry point of an unpacked release
locate_executable() {
    _root="$1"
    # The search list is written out at every level instead of held in a variable:
    # `for _c in $_level` only word-splits under shells that do word splitting (dash,
    # bash, ksh, busybox ash), and zsh — which this installer also runs under — would
    # iterate once over the single literal word "bin/binaural binaural" and match
    # nothing. Quoted explicit entries behave the same everywhere.
    #
    # `-x` alone is true for directories too (it means "searchable" for them), and the
    # one-dir bundle is a directory named Binaural/ — without the `! -d` guard a
    # case-insensitive filesystem (macOS default) would return the bundle itself as
    # the "executable" and the verify step would fail with "is a directory".
    for _c in "bin/${APP_NAME}" "${APP_NAME}"; do
        if [ -x "$_root/$_c" ] && [ ! -d "$_root/$_c" ]; then
            printf '%s' "$_root/$_c"
            return 0
        fi
    done
    # A macOS .app bundle keeps its executable at Contents/MacOS/<name>, a path the
    # bin/<name> / <name> patterns below do not reach. Checked without a glob on
    # purpose: an unmatched *.app glob aborts the whole script under zsh
    # ("no matches found"), and this installer also runs under zsh.
    if [ -x "${_root}/${APP_DISPLAY_NAME}.app/Contents/MacOS/${APP_NAME}" ]; then
        printf '%s' "${_root}/${APP_DISPLAY_NAME}.app/Contents/MacOS/${APP_NAME}"
        return 0
    fi
    for _l1 in "$_root"/*; do
        [ -d "$_l1" ] || continue
        if [ -x "$_l1/${APP_DISPLAY_NAME}.app/Contents/MacOS/${APP_NAME}" ]; then
            printf '%s' "$_l1/${APP_DISPLAY_NAME}.app/Contents/MacOS/${APP_NAME}"
            return 0
        fi
        for _c in "bin/${APP_NAME}" "${APP_NAME}"; do
            if [ -x "$_l1/$_c" ] && [ ! -d "$_l1/$_c" ]; then
                printf '%s' "$_l1/$_c"
                return 0
            fi
        done
        for _l2 in "$_l1"/*; do
            [ -d "$_l2" ] || continue
            for _c in "bin/${APP_NAME}" "${APP_NAME}"; do
                if [ -x "$_l2/$_c" ] && [ ! -d "$_l2/$_c" ]; then
                    printf '%s' "$_l2/$_c"
                    return 0
                fi
            done
            for _l3 in "$_l2"/*; do
                [ -d "$_l3" ] || continue
                for _c in "bin/${APP_NAME}" "${APP_NAME}"; do
                    if [ -x "$_l3/$_c" ] && [ ! -d "$_l3/$_c" ]; then
                        printf '%s' "$_l3/$_c"
                        return 0
                    fi
                done
            done
        done
    done
    return 1
}

# locate_project_dir ROOT — print the directory that holds pyproject.toml
locate_project_dir() {
    _root="$1"
    for _c in "${REPO}-main" "${REPO}-master" main master; do
        if [ -f "$_root/$_c/pyproject.toml" ]; then
            printf '%s' "$_root/$_c"
            return 0
        fi
    done
    for _l1 in "$_root"/*; do
        if [ -f "$_l1/pyproject.toml" ]; then
            printf '%s' "$_l1"
            return 0
        fi
    done
    for _l2 in "$_root"/*/*; do
        if [ -f "$_l2/pyproject.toml" ]; then
            printf '%s' "$_l2"
            return 0
        fi
    done
    return 1
}

find_installed() {
    for _c in "${BIN_DIR}/${APP_NAME}" \
             "${PREFIX}/app/bin/${APP_NAME}" \
             "${PREFIX}/app/${APP_NAME}" \
             "${PREFIX}/app/${APP_NAME}-${PLATFORM}/${APP_NAME}" \
             "${PREFIX}/venv/bin/${APP_NAME}"; do
        if [ -e "$_c" ] || [ -L "$_c" ]; then
            printf '%s' "$_c"
            return 0
        fi
    done
    return 1
}

installed_version() {
    _exe="$1"
    if [ ! -x "$_exe" ]; then
        return 0
    fi
    # short timeout: a GUI entry point must never block the installer
    _outfile="$(tmpfile existing-version)"
    run_capture 5 "$_outfile" "$_exe" --version >/dev/null 2>&1 || true
    head -n 1 "$_outfile" 2>/dev/null | tr -d '\r' || true
    rm -f "$_outfile"
    return 0
}

write_meta() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    %s[dry-run]%s would write %s/install-meta\n' \
            "$C_YELLOW" "$C_OFF" "$PREFIX" >&2
        return 0
    fi
    must "${LINENO:-?}" "write ${PREFIX}/install-meta" write_meta_body "$@"
}

# the actual write, split out so that must() can guard it: a redirection cannot be
# passed as an argument, and a full disk must not pass unnoticed
write_meta_body() {
    printf '%s\n' "$@" >"${PREFIX}/install-meta"
}

# --------------------------------------------------------------------------- #
# PATH block management (idempotent, marked block, only existing rc files)
# --------------------------------------------------------------------------- #

path_has_bindir() {
    case ":${PATH:-}:" in
        *":${BIN_DIR}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

rc_candidates() {
    case "${SHELL:-}" in
        */zsh)  printf '%s\n' "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.profile" ;;
        */bash) printf '%s\n' "${HOME}/.bashrc" "${HOME}/.profile" ;;
        *)      printf '%s\n' "${HOME}/.profile" ;;
    esac
    return 0
}

rc_has_marker() {
    [ -f "$1" ] || return 1
    grep -F "$PATH_MARKER" "$1" >/dev/null 2>&1 </dev/null
}

rc_mentions_bindir() {
    [ -f "$1" ] || return 1
    grep -F "$BIN_DIR" "$1" >/dev/null 2>&1 </dev/null
}

write_path_block() {
    _rc="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    %s[dry-run]%s would add %s to PATH in %s\n' \
            "$C_YELLOW" "$C_OFF" "$BIN_DIR" "$_rc" >&2
        return 0
    fi
    must "${LINENO:-?}" "add ${BIN_DIR} to PATH in ${_rc}" \
        append_to "$_rc" path_block_body
}

# path_block_body — the managed PATH block, printed to stdout
path_block_body() {
    printf '%s\n' "$PATH_MARKER"
    printf '# Adds ~/.local/bin to PATH if it is not there yet. Added by install.sh.\n'
    printf 'case ":${PATH}:" in\n'
    printf '  *:%s:*) ;;\n' "$BIN_DIR"
    printf '  *) PATH="%s:${PATH}" ;;\n' "$BIN_DIR"
    printf 'esac\n'
    printf 'export PATH\n'
    printf '%s\n' "$PATH_MARKER_END"
}

setup_path() {
    if [ "$EDIT_PATH" -eq 0 ]; then
        info "shell PATH editing skipped (--no-path-edit)"
        return 0
    fi
    if path_has_bindir; then
        ok "${BIN_DIR} is already in PATH for this shell"
        return 0
    fi

    _list="$(tmpfile rc-list)"
    rc_candidates >"$_list"
    _touched=""
    _created=0
    while IFS= read -r _rc; do
        [ -n "$_rc" ] || continue
        if rc_has_marker "$_rc"; then
            info "${_rc}: managed PATH block already present"
            continue
        fi
        if rc_mentions_bindir "$_rc"; then
            info "${_rc}: ${BIN_DIR} is already mentioned, left untouched"
            continue
        fi
        if [ ! -f "$_rc" ]; then
            if [ "$_created" -eq 0 ] && [ "$_rc" = "${HOME}/.profile" ]; then
                step "creating ${_rc} with the PATH entry"
                must "${LINENO:-?}" "create ${HOME}" mkdir -p "$HOME"
                write_path_block "$_rc"
                _touched="$_touched $_rc"
                _created=1
            fi
            continue
        fi
        step "adding ${BIN_DIR} to PATH in ${_rc}"
        write_path_block "$_rc"
        _touched="$_touched $_rc"
    done <"$_list"
    rm -f "$_list"

    if [ -z "$_touched" ]; then
        warn "no shell startup file was changed. Add this line yourself:"
        say "  export PATH=\"${BIN_DIR}:\$PATH\""
    else
        ok "PATH is set up for new shells"
    fi
    return 0
}

strip_path_block() {
    _list="$(tmpfile rc-list-un)"
    rc_candidates >"$_list"
    while IFS= read -r _rc; do
        [ -n "$_rc" ] || continue
        if ! rc_has_marker "$_rc"; then
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '    %s[dry-run]%s would remove the managed PATH block from %s\n' \
                "$C_YELLOW" "$C_OFF" "$_rc" >&2
            continue
        fi
        # Delete the whole marker-to-marker range, not just the marker lines: the body
        # in between is ours too. Markers hold no '/' or other sed metacharacter.
        _tmp="$(tmpfile rc-stripped)"
        sed "/${PATH_MARKER}/,/${PATH_MARKER_END}/d" "$_rc" >"$_tmp" 2>/dev/null </dev/null || true
        # write through the original file so its permissions and inode survive
        must "${LINENO:-?}" "restore ${_rc}" overwrite_file "$_rc" "$_tmp"
        rm -f "$_tmp"
        ok "removed the managed PATH block from ${_rc}"
    done <"$_list"
    rm -f "$_list"
    return 0
}

# --------------------------------------------------------------------------- #
# Symlink
# --------------------------------------------------------------------------- #

link_binary() {
    _target="$1"
    _link="${BIN_DIR}/${APP_NAME}"

    if [ -e "$_link" ] && [ ! -L "$_link" ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "${_link} is a regular file, replacing it (--force)"
            must "${LINENO:-?}" "remove ${_link}" rm -f "$_link"
        else
            die "${_link} already exists and is not a symlink. Move it aside or rerun with --force."
        fi
    fi

    must "${LINENO:-?}" "create the symlink directory ${BIN_DIR}" mkdir -p "$BIN_DIR"
    step "linking ${_link} -> ${_target}"
    must "${LINENO:-?}" "remove the old ${_link}" rm -f "$_link"
    run ln -s "$_target" "$_link" || die "could not create the symlink ${_link}."
    ok "symlink created"
    return 0
}

# --------------------------------------------------------------------------- #
# Install strategies
# --------------------------------------------------------------------------- #

# install_desktop_files EXE — copy the .desktop launcher and its icon out of an unpacked
# Linux release into ~/.local/share, so the app appears in the desktop menu. The archive
# carries them beside the executable, under Binaural/share/{applications,icons/...}; the
# bundle directory is derived from EXE, so there are no globs to mismatch — an unmatched
# glob aborts the whole script under zsh ("no matches found"), and this installer also
# runs under zsh. A macOS release has no .desktop file and a source install has no
# share/ tree at all; for both this is a quiet no-op.
install_desktop_files() {
    _exe="$1"
    [ "$OS_NAME" = "linux" ] || return 0
    _bundle="${_exe%/*}"
    _desktop="${_bundle}/share/applications/binaural.desktop"
    [ -f "$_desktop" ] || return 0

    _icon=""
    for _icon_path in "${_bundle}/share/icons/hicolor/scalable/apps/binaural.svg" \
                       "${_bundle}/share/icons/hicolor/scalable/apps/binaural.png"; do
        if [ -f "$_icon_path" ]; then
            _icon="$_icon_path"
            break
        fi
    done

    step "installing the desktop launcher"
    must "${LINENO:-?}" "create ${HOME}/.local/share/applications" \
        mkdir -p "${HOME}/.local/share/applications"
    _desktop_name="$(basename "$_desktop")"
    run cp "$_desktop" "${HOME}/.local/share/applications/${_desktop_name}"
    ok "${HOME}/.local/share/applications/${_desktop_name}"

    if [ -n "$_icon" ]; then
        must "${LINENO:-?}" "create the local icon directory" \
            mkdir -p "${HOME}/.local/share/icons/hicolor/scalable/apps"
        _icon_name="$(basename "$_icon")"
        run cp "$_icon" "${HOME}/.local/share/icons/hicolor/scalable/apps/${_icon_name}"
        ok "${HOME}/.local/share/icons/hicolor/scalable/apps/${_icon_name}"
    fi

    # Refresh the desktop database when the tool is there. A missing or failing
    # update-desktop-database is not an install failure: the files are already in place.
    if command -v update-desktop-database >/dev/null 2>&1 </dev/null; then
        run update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 \
            || info "update-desktop-database reported a problem; the launcher is still installed"
    fi
    return 0
}

# install_from_release — prints the installed entry point on stdout, non-zero if the
# platform has no published release.
install_from_release() {
    step "looking for a prebuilt ${PLATFORM} release"
    _list="$(tmpfile release-urls)"
    candidate_release_urls >"$_list"
    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        warn "no release URL could be formed"
        return 1
    fi

    _archive="$(tmpfile release-archive)"
    _hit=""
    while IFS= read -r _url; do
        [ -n "$_url" ] || continue
        info "try ${_url}"
        if http_get "$_url" "$_archive" 2>/dev/null; then
            _hit="$_url"
            break
        fi
        info "not available"
    done <"$_list"
    rm -f "$_list"

    if [ -z "$_hit" ]; then
        return 1
    fi

    info "downloaded $(wc -c <"$_archive" | tr -d ' ') bytes"
    extract_archive "$_archive" "${PREFIX}/app" || die "cannot unpack ${_hit}."
    _exe="$(locate_executable "${PREFIX}/app" || true)"
    if [ -z "$_exe" ]; then
        die "the archive from ${_hit} contains no '${APP_NAME}' executable."
    fi
    write_meta "release-url=${_hit}" "version=${APP_VERSION}" "platform=${PLATFORM}" "executable=${_exe}"
    install_desktop_files "$_exe"
    printf '%s' "$_exe"
    return 0
}

# install_from_source — prints the installed entry point on stdout.
install_from_source() {
    step "source install: building a private environment (python3 only)"
    _archive="$(tmpfile source-archive)"
    info "downloading ${SOURCE_URL}"
    if ! http_get "$SOURCE_URL" "$_archive" 2>/dev/null; then
        err "cannot download the sources from ${SOURCE_URL}"
        say "Check the network, or download the tarball manually and pass it as"
        say "  --source-url=file:///path/to/binaural-main.tar.gz"
        return 1
    fi

    _srcdir="$(tmpfile source-tree)"
    extract_archive "$_archive" "$_srcdir" || die "cannot unpack the source archive."
    _proj="$(locate_project_dir "$_srcdir" || true)"
    if [ -z "$_proj" ]; then
        err "no pyproject.toml inside the downloaded source archive"
        return 1
    fi
    info "source tree: ${_proj}"

    need_python
    info "python3: $(python_version_string)"

    if [ -e "${PREFIX}/venv" ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "replacing the existing ${PREFIX}/venv (--force)"
        else
            info "replacing the existing ${PREFIX}/venv"
        fi
        must "${LINENO:-?}" "remove the old ${PREFIX}/venv" rm -rf "${PREFIX}/venv"
    fi

    step "creating the virtualenv ${PREFIX}/venv"
    if ! run "${PYTHON_BIN}" -m venv "${PREFIX}/venv"; then
        die "'${PYTHON_BIN} -m venv' failed. On Debian/Ubuntu: sudo apt-get install -y python3-venv"
    fi

    _venv_python="${PREFIX}/venv/bin/python"
    if [ ! -x "$_venv_python" ]; then
        die "the virtualenv was created but ${_venv_python} is missing."
    fi
    # pip chatter goes to stderr: this function returns its result on stdout
    if ! "$_venv_python" -m pip install --upgrade pip </dev/null >&2; then
        warn "could not upgrade pip inside the virtualenv, continuing with the bundled pip"
    fi

    step "installing binaural and PySide6 into the virtualenv (a few hundred MB)"
    # shellcheck disable=SC2086
    if ! "$_venv_python" -m pip install ${BINAURAL_PIP_ARGS:-} "$_proj" </dev/null >&2; then
        err "pip install failed inside ${PREFIX}/venv"
        say "Free disk space and a working network are the usual causes."
        say "Retry, or install manually: ${_venv_python} -m pip install ${BINAURAL_PIP_ARGS:-} ${_proj}"
        return 1
    fi

    _exe="${PREFIX}/venv/bin/${APP_NAME}"
    if [ ! -x "$_exe" ]; then
        err "pip finished but ${_exe} does not exist"
        return 1
    fi
    write_meta "source-url=${SOURCE_URL}" "version=${APP_VERSION}" "platform=${PLATFORM}" "executable=${_exe}"
    printf '%s' "$_exe"
    return 0
}

# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #

# run_capture TIMEOUT_SECONDS OUTFILE CMD... — run a command, capture stdout+stderr into
# OUTFILE, and never block longer than the timeout.
#
# The timeout matters: a GUI app that does not understand --version would open a window
# and hang forever, and this script may be running with nobody watching it.
run_capture() {
    _seconds="$1"
    _outfile="$2"
    shift 2

    # The braces keep the shell's job-control notice ("Terminated: 15") off stderr;
    # that message is emitted by the shell itself, not by the child.
    {
        : >"$_outfile"
        "$@" </dev/null >"$_outfile" 2>&1 &
        _pid=$!

        _waited=0
        while kill -0 "$_pid" 2>/dev/null; do
            if [ "$_waited" -ge "$_seconds" ]; then
                kill -TERM "$_pid" 2>/dev/null || true
                sleep 1
                kill -KILL "$_pid" 2>/dev/null || true
                wait "$_pid" 2>/dev/null || true
                return 124
            fi
            sleep 1
            _waited=$((_waited + 1))
        done

        wait "$_pid" 2>/dev/null
    } 2>/dev/null
    return $?
}

verify_install() {
    if [ "$DO_VERIFY" -eq 0 ]; then
        info "verification skipped (--no-verify)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    %s[dry-run]%s would run: %s --version\n' \
            "$C_YELLOW" "$C_OFF" "$TARGET" >&2
        return 0
    fi

    step "verifying: ${APP_NAME} --version"
    _outfile="$(tmpfile version-out)"
    _code=0
    run_capture "$VERIFY_TIMEOUT" "$_outfile" "${TARGET}" --version || _code=$?

    if [ "$_code" -eq 124 ]; then
        warn "'${APP_NAME} --version' did not exit within ${VERIFY_TIMEOUT}s and was stopped."
        warn "The files are installed; run '${APP_NAME}' yourself to check."
    else
        _out="$(head -n 5 "$_outfile" | tr -d '\r')"
        if [ "$_code" -ne 0 ]; then
            err "'${APP_NAME} --version' failed with exit status ${_code}."
            [ -n "$_out" ] && say "${_out}"
            say ""
            say "Usual causes:"
            say "  * a dynamic library is missing"
            say "      ldd ${TARGET}          # Linux"
            say "  * the GUI needs a display — nothing to fix for the version check"
            say "  * the app does not handle --version yet (development build)"
            say ""
            say "Reinstall with:  sh install.sh --force --prefix=\"${PREFIX}\""
            say "Skip the check:  sh install.sh --no-verify"
            ERROR_REPORTED=1
            exit "$EXIT_FAIL"
        fi
        if [ -n "$_out" ]; then
            ok "$_out"
        else
            warn "'${APP_NAME} --version' printed nothing (the GUI probably opened instead)."
        fi
    fi
    rm -f "$_outfile"

    if path_has_bindir; then
        if command -v "${APP_NAME}" >/dev/null 2>&1 </dev/null; then
            ok "'${APP_NAME}' resolves on PATH"
        else
            warn "${BIN_DIR} is in PATH but the shell has not picked it up yet"
        fi
    else
        warn "${BIN_DIR} is not in PATH for this shell. Add:"
        say "  export PATH=\"${BIN_DIR}:\$PATH\""
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Dry-run plan
# --------------------------------------------------------------------------- #

plan_install() {
    step "plan (dry run — nothing will be created)"
    info "platform        ${PLATFORM}"
    info "prefix          ${PREFIX}"
    info "bin dir         ${BIN_DIR}"
    info "downloader      $(downloader_name)"
    if [ "$HAVE_TAR" -eq 1 ] && [ "$HAVE_GZIP" -eq 1 ]; then
        info "extractor       tar + gzip"
    else
        info "extractor       unzip"
    fi
    if find_python; then
        info "python3         $(python_version_string)"
    else
        info "python3         not found (needed only for the source fallback)"
    fi
    if [ "$WANT_SOURCE" -eq 1 ]; then
        info "strategy        source only (--source)"
    else
        info "strategy        GitHub Release, then source fallback"
    fi

    _list="$(tmpfile plan-urls)"
    if [ "$WANT_SOURCE" -eq 1 ]; then
        info "release candidates: none (--source)"
    elif candidate_release_urls >"$_list" && [ -s "$_list" ]; then
        info "release candidates:"
        while IFS= read -r _u; do
            [ -n "$_u" ] || continue
            info "  ${_u}"
        done <"$_list"
    else
        info "release candidates: none"
    fi
    rm -f "$_list"
    info "source fallback ${SOURCE_URL}"

    say ""
    say "  1. mkdir -p ${PREFIX}/app"
    say "  2. download + unpack the archive, or: python3 -m venv ${PREFIX}/venv && pip install ."
    say "  3. ln -s <entry point> ${BIN_DIR}/${APP_NAME}"
    say "  4. add ${BIN_DIR} to PATH in the shell startup file"
    say "  5. ${APP_NAME} --version"
    if [ "$OS_NAME" = "linux" ]; then
        say "  (linux) the .desktop launcher and icon are copied to ~/.local/share"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# Install / uninstall
# --------------------------------------------------------------------------- #

do_install() {
    detect_platform
    detect_tools
    need_downloader
    need_extractor
    make_tmpdir

    say "${C_BOLD}${APP_DISPLAY_NAME} installer${C_OFF} — ${PLATFORM}"
    say ""

    if INSTALLED_TARGET="$(find_installed)"; then
        _have="$(installed_version "$INSTALLED_TARGET")"
        if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
            ok "${APP_NAME} is already installed: ${INSTALLED_TARGET}"
            if [ -n "$_have" ]; then
                info "version: ${_have}"
            fi
            say ""
            say "Nothing was changed."
            say "  reinstall : sh install.sh --force"
            say "  uninstall : sh install.sh --uninstall"
            return "$EXIT_OK"
        fi
        if [ "$DRY_RUN" -eq 0 ]; then
            warn "reinstalling over ${INSTALLED_TARGET}"
        else
            info "already installed at ${INSTALLED_TARGET} — the plan below would replace it"
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        plan_install
        say ""
        ok "dry run finished, no changes were made."
        return "$EXIT_OK"
    fi

    must "${LINENO:-?}" "create the install prefix ${PREFIX}" mkdir -p "$PREFIX"

    TARGET=""
    if [ "$WANT_SOURCE" -eq 0 ]; then
        if TARGET="$(install_from_release)"; then
            :
        else
            TARGET=""
            warn "no prebuilt release for ${PLATFORM} is published (expected before the first release)"
        fi
    fi
    if [ -z "$TARGET" ]; then
        if TARGET="$(install_from_source)"; then
            :
        else
            TARGET=""
        fi
    fi
    if [ -z "$TARGET" ]; then
        die "installation failed, see the messages above."
    fi
    if [ ! -x "$TARGET" ]; then
        die "installation failed: ${TARGET} is not executable."
    fi

    ok "entry point: ${TARGET}"
    link_binary "$TARGET"
    setup_path
    verify_install

    say ""
    ok "${APP_DISPLAY_NAME} is installed."
    out ""
    out "  start it with:  ${APP_NAME}"
    if ! path_has_bindir; then
        out "  ${BIN_DIR} is not in PATH for this shell. Either reopen your terminal or run:"
        out "    export PATH=\"${BIN_DIR}:\$PATH\""
    fi
    out ""
    return "$EXIT_OK"
}

do_uninstall() {
    detect_platform
    make_tmpdir
    say "${APP_DISPLAY_NAME} uninstall"
    say ""

    _found=0
    if INSTALLED_TARGET="$(find_installed)"; then
        info "found: ${INSTALLED_TARGET}"
        _found=1
    fi

    _link="${BIN_DIR}/${APP_NAME}"
    if [ -e "$_link" ] || [ -L "$_link" ]; then
        step "removing ${_link}"
        must "${LINENO:-?}" "remove the symlink ${_link}" rm -f "$_link"
        _found=1
    fi

    if [ -d "$PREFIX" ]; then
        step "removing ${PREFIX}"
        must "${LINENO:-?}" "remove ${PREFIX}" rm -rf "$PREFIX"
        _found=1
    fi

    strip_path_block

    say ""
    if [ "$_found" -eq 0 ]; then
        ok "${APP_NAME} is not installed — nothing to remove."
        return "$EXIT_OK"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        ok "dry run finished, nothing was removed."
    else
        ok "${APP_DISPLAY_NAME} uninstalled."
    fi
    return "$EXIT_OK"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

main() {
    parse_args "$@"

    if [ "$#" -eq 0 ]; then
        if [ -n "${BINAURAL_PREFIX:-}" ]; then
            PREFIX="$BINAURAL_PREFIX"
        fi
        if [ -n "${BINAURAL_BIN_DIR:-}" ]; then
            BIN_DIR="$BINAURAL_BIN_DIR"
        fi
        case "$PREFIX" in
            "~/"*) PREFIX="$HOME/${PREFIX#'~/'}" ;;
        esac
        case "$BIN_DIR" in
            "~/"*) BIN_DIR="$HOME/${BIN_DIR#'~/'}" ;;
        esac
    fi

    # Called plainly, not as `do_install || _status=$?`. On the right-hand side of an
    # AND-OR list the shell suspends `set -e` for the whole call — a failing command
    # inside the install would then be carried past in silence. (bash's ERR trap has
    # the same blind spot, so this was not caught before either.)
    if [ "$MODE_UNINSTALL" -eq 1 ]; then
        do_uninstall
    else
        do_install
    fi
    exit "$EXIT_OK"
}

main "$@"
