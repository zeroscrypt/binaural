# Releasing

One version, two products, one tag.

| Product | Built by | Tested by | Archive |
|---|---|---|---|
| macOS app (`apple/`) | `scripts/build_macos.sh` | `xcodebuild test` (`test-macos`) | `binaural-<v>-macos-arm64.tar.gz` |
| Linux bundles | `scripts/build_linux.sh` | `pytest` (`test`) | `binaural-<v>-linux-<arch>.tar.gz` |

They share a repository and a contract, not a toolchain, so they are gated separately.
A crash in the Qt suite does not stop the native app from being published, and a Swift
layout failure does not stop the PyInstaller bundle.

## The whole thing

```sh
# 1. Bump the version. Two files, and they have to move together.
$EDITOR pyproject.toml            # version = "0.3.0"
$EDITOR apple/project.yml         # MARKETING_VERSION: "0.3.0"  (all three targets)

# 2. Check they agree, before you commit anything.
python3 scripts/check_version.py

# 3. Run both suites. Neither is a substitute for CI, both catch it sooner.
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest
cd apple && xcodegen generate \
  && xcodebuild -project Binaural.xcodeproj -scheme BinauralCore \
       -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test \
  && xcodebuild -project Binaural.xcodeproj -scheme Binaural \
       -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# 4. Commit, push, wait for CI.
git commit -am "Release 0.3.0" && git push origin main

# 5. Tag. CI checks the tag against the files and refuses to publish if they differ.
git tag -a v0.3.0 -m "0.3.0" && git push origin v0.3.0
```

Steps 2 and 5 are the ones that used to be missed. `scripts/check_version.py` also runs
inside `pytest` (`tests/test_release_metadata.py`) and as its own CI job, so a bump that
misses a file fails before anything is published rather than after.

## What `check_version.py` guards

* `pyproject.toml` vs. **every** `MARKETING_VERSION` in `apple/project.yml` — three
  targets, `Binaural`, `BinauralCore`, `Binaural-iOS`, and only the app's is visible to a
  user, so the other two can drift unnoticed for a long time.
* The tag, when one is given. CI passes `--tag "$GITHUB_REF_NAME"` on a tag push.
* **The update contract**: the archive name `scripts/build_macos.sh` writes and the name
  `UpdateChecker.macOSArchive` looks for. They are a shell script and a Swift file, and
  neither imports the other — so one of them can be renamed and the other never notices.
  The symptom is an app that reports "you are up to date" forever, because it is looking
  for a file nobody published.

`--allow-mismatch` exists for exactly one commit: the one that bumps the version, where
the second of the two edits has not landed yet. Nothing in CI passes it.

## Why the gates are what they are

* `version` runs first. It takes ten seconds to fix and means nothing is publishable.
* `test-macos` was added in 0.2.2. Until then the Swift suite ran only on the machine
  that wrote it, while CI built and published the app it verifies — every macOS bug fixed
  so far passed the entire Python matrix, because the Python matrix does not build a line
  of Swift.
* `test` (Python 3.10 and 3.12, Linux and macOS) gates the Linux bundle only.

## If CI is red

* **A version mismatch** — `check_version.py` prints every disagreement at once. Fix all
  of them, not the first.
* **`test` red, `test-macos` green** — the Linux bundle is held, the macOS app is not.
  This is the split working, not a hole: they are different products.
* **`test-macos` red on a runner but green locally** — the window tests compare frames,
  so a different macOS version moves text metrics. Assert on relationships (one row is
  right of another, nothing overlaps) rather than on absolute points.

## After the release

The tag push creates the GitHub Release and attaches both archives
(`publish-release`). The macOS app's *Check for updates…* then finds
`binaural-<v>-macos-arm64.tar.gz` by name, verifies it by content before it replaces
anything, and installs it.
