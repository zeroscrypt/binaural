#!/bin/bash
# Build a Release Binaural.app that launches by double-clicking, with no Xcode and no
# DerivedData left behind.
#
# What this produces, and what it deliberately does not:
#
#   * UNSIGNED. `security find-identity` on this machine reports 0 identities, so the build
#     passes CODE_SIGNING_ALLOWED=NO. Nothing here fakes a signature, and there is no
#     notarisation: an unsigned .app is runnable by the person who built it, and nothing
#     more. Anyone else would have to right-click → Open, and Gatekeeper distribution is
#     out of scope without a Developer account (M2.md §11).
#   * SELF-CONTAINED. The app is built into a throwaway derived-data directory and then
#     copied to apple/dist/, so what is left on disk does not point into DerivedData.
#   * ONE frequencies.json. It is copied into the bundle by the existing xcodegen
#     copy-files phase straight from src/binaural/data/frequencies.json; this script
#     verifies the copy with shasum rather than trusting the phase.
#
# Usage:  ./build_release.sh [--smoke]
#           --smoke   also launch the built app, confirm it stays alive, and kill it.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
SOURCE_JSON="$REPO_ROOT/src/binaural/data/frequencies.json"

# DerivedData goes to a temporary directory that is removed on exit: the deliverable is
# the .app in dist/, not the build tree it came from.
BUILD_DIR="$(mktemp -d -t binaural-release-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

OUTPUT_DIR="$APP_DIR/dist"

echo "==> Generating the project (xcodegen)"
cd "$APP_DIR"
xcodegen generate

echo "==> Building Release for macOS (unsigned)"
xcodebuild \
  -project Binaural.xcodeproj \
  -scheme Binaural \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 20

BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/Binaural.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "error: no Binaural.app at $BUILT_APP" >&2
  exit 1
fi

echo "==> Verifying frequencies.json came from the single copy in src/"
BUNDLED_JSON="$BUILT_APP/Contents/Resources/frequencies.json"
if [ ! -f "$BUNDLED_JSON" ]; then
  echo "error: frequencies.json is not in the bundle at $BUNDLED_JSON" >&2
  exit 1
fi
shasum -a 256 "$SOURCE_JSON" "$BUNDLED_JSON"
if ! cmp -s "$SOURCE_JSON" "$BUNDLED_JSON"; then
  echo "error: the bundled frequencies.json differs from the one in src/" >&2
  exit 1
fi

echo "==> Installing to $OUTPUT_DIR/Binaural.app"
rm -rf "$OUTPUT_DIR/Binaural.app"
mkdir -p "$OUTPUT_DIR"
cp -R "$BUILT_APP" "$OUTPUT_DIR/Binaural.app"

echo "==> Built $(du -sh "$OUTPUT_DIR/Binaural.app" | cut -f1) at $OUTPUT_DIR/Binaural.app"
echo "    unsigned: double-click works for you; Gatekeeper will object for anyone else."

if [ "${1:-}" = "--smoke" ]; then
  echo "==> Smoke test: launch, confirm alive, kill"
  CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
  BEFORE="$(mktemp)"
  AFTER="$(mktemp)"
  ls "$CRASH_DIR" 2>/dev/null | grep -i '^Binaural' | sort > "$BEFORE" || true

  open "$OUTPUT_DIR/Binaural.app"
  sleep 5
  if ! pgrep -f "$OUTPUT_DIR/Binaural.app/Contents/MacOS/Binaural" > /dev/null; then
    echo "error: the app did not stay alive" >&2
    ls "$CRASH_DIR" 2>/dev/null | grep -i '^Binaural' | sort > "$AFTER" || true
    diff "$BEFORE" "$AFTER" || true
    exit 1
  fi
  pgrep -fl "$OUTPUT_DIR/Binaural.app/Contents/MacOS/Binaural"
  pkill -f "$OUTPUT_DIR/Binaural.app/Contents/MacOS/Binaural"
  sleep 1

  ls "$CRASH_DIR" 2>/dev/null | grep -i '^Binaural' | sort > "$AFTER" || true
  if diff -q "$BEFORE" "$AFTER" > /dev/null; then
    echo "    alive after 5 s, no new crash reports — OK"
  else
    echo "error: a new crash report appeared:" >&2
    diff "$BEFORE" "$AFTER" >&2 || true
    exit 1
  fi
  rm -f "$BEFORE" "$AFTER"
fi
