# apple/ — Swift implementation (macOS + iOS)

The second, independent implementation of Binaural. Not a port of the Python
code — a native app written in Swift.

```
apple/
├── project.yml        # xcodegen: one project, two targets
├── Binaural.xcodeproj # generated, never committed
├── Sources/
│   ├── Shared/         # synthesis, session, frequency catalogue — common
│   ├── macOS/
│   └── iOS/
└── Tests/
```

## Why a separate implementation exists

| | `src/` (Python + Qt) | `apple/` (Swift) |
|---|---|---|
| Platforms | Linux, macOS, Windows | macOS, iOS |
| Build | PyInstaller | Xcode |
| Distribute | `curl \| sh`, tar.gz | App Store / TestFlight, or `xcodebuild` |

Once the Swift macOS app reaches feature parity, the *release* build of the
Python app for macOS is dropped — one product per platform. Python remains the
development and CI toolchain, and `src/binaural/audio/platform/macos.py` stays
so the app can still be run from source on a Mac.

## Shared data

`frequencies.json` lives once, at `src/binaural/data/frequencies.json`, and is
read by both implementations. The Python package needs it next to its module so
`pip install` carries it along; the Xcode target adds a *Copy Files* build phase
pointing at that same path (`$(SRCROOT)/../src/binaural/data/frequencies.json`).

Do not duplicate the file — the reference is edited constantly and two copies
would drift.

## Prerequisites

- Xcode 16+ and `xcodegen` (`brew install xcodegen`)
- An Apple Developer account to deploy to a physical iPhone (a free account
  signs for 7 days; the paid membership signs for a year)

## Status

Not started. See `docs/SPEC.md` for behaviour, `docs/CONTRACT.md` for the API
the two implementations must both honour.
