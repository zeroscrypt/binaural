# Binaural

![license](https://img.shields.io/badge/license-MIT-blue) ![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey) ![python](https://img.shields.io/badge/python-3.10%2B-blue)

**Two independent frequencies, one perceived difference.**

Binaural is a desktop generator of binaural beats for **macOS** and **Linux**. You set one
frequency for the left ear and another for the right ear. The brain merges the two tones and
perceives a third, virtual tone whose pitch is the **difference** between them.

```
Left ear:   fL = 205.0 Hz
Right ear:  fR = 215.0 Hz
                    ↓
Perceived:    10.0 Hz   ← the beat, produced by the brain, not present in the signal
```

Formally: `beat = |fL − fR|`, `carrier = (fL + fR) / 2`.

> English | [Русский](README.ru.md)

---

## Table of contents

- [What it actually does](#what-it-actually-does)
- [Why headphones are mandatory](#why-headphones-are-mandatory)
- [Install](#install)
- [Screenshots](#screenshots)
- [Features](#features)
- [Language](#language)
- [Frequency reference](#frequency-reference)
- [What the research says](#what-the-research-says)
- [Disclaimer](#disclaimer)
- [Requirements](#requirements)
- [Development](#development)
- [Project status](#project-status)
- [Roadmap](#roadmap)
- [License](#license)

---

## What it actually does

The signal is deliberately boring: two sine oscillators, one per channel, no effects, no scene,
no music, no processing.

```
   ┌─────────────┐      ┌─────────────┐
   │ Oscillator  │      │ Oscillator  │
   │   L: 205 Hz │      │ R: 215 Hz   │
   └──────┬──────┘      └──────┬──────┘
          │                    │
          └────────┬───────────┘
                   ▼
           Stereo output ──► Left ear / Right ear
                   │
                   ▼
        The brain hears a tone at |fL − fR|
```

A 10 Hz tone is **not in the audio stream**. Each ear receives a plain tone around 210 Hz. The
10 Hz "flicker" you may perceive is the difference between the two channels, computed inside your
auditory system. That is why each ear has to get its own frequency and nothing else.

---

## Why headphones are mandatory

This is not a recommendation. It is the physical condition under which the method works at all.

On speakers, the two tones travel through the same air and **mix before they reach your ears**.
Both ears receive the same jumbled waveform, so there is nothing left for the brain to
differentiate. The difference, and with it the effect, is gone. There is no setting in the app
that can fix this.

Put the headphones on before you press play. The app checks this on startup and tells you if it
thinks you are on speakers.

---

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh
```

The script detects your OS and architecture, downloads the matching release archive, unpacks it
into `~/.binaural/`, symlinks `binaural` into `~/.local/bin` (adding it to `PATH` if needed) and
verifies the result with `binaural --version`. No Python or Qt on your machine is required — the
archive ships its own runtime.

> **Heads up:** release archives are produced by the packaging step, which has not shipped yet.
> If the one-liner reports that no release is available for your platform, build from source
> instead — it is a fully supported path.

### From source

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural
python3 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
.venv/bin/binaural
```

`pip install -e .` also installs the `binaural` console script, so `.venv/bin/binaural` is the
entry point.

Full details, including manual builds and troubleshooting, are in
**[docs/INSTALL.md](docs/INSTALL.md)**.

---

## Screenshots

*Screenshots will be added here once the packaging and the UI polish land.* Expected content:

- **Main window, light theme** — large left/right frequency readouts, two sliders, the BEAT and
  CARRIER metrics in the centre, play button, volume, and the preset chips along the bottom.
- **Headphone check dialog** — the warning shown when speakers are detected, with
  *Continue anyway* and *Retry check*.
- **Perceptual L/R test** — the left-then-right tone sequence and the question "what did you hear?".
- **Frequency reference dialog** — the category sidebar with counters, the search field, and an
  entry card showing name → frequency → *Apply* → effect text → evidence badge.

No image files are referenced until they exist, so nothing here is broken.

---

## Features

Planned scope, from the project specification. See [Project status](#project-status) for what is
already implemented and what is still being built.

- **Two independent frequencies** — separate fields and sliders for left and right, exact keyboard
  entry, 0.1 Hz steps, 1–20000 Hz. Moving the left channel never moves the right one.
- **Live beat and carrier readout** — `Beat: |fL − fR|` and `Carrier: (fL + fR) / 2` update as you
  type, with a hint when the beat falls outside the usual 0.5–100 Hz perception range.
- **Click-free playback** — frequency changes are applied without breaking phase, amplitude ramps
  over tens of milliseconds, `Space` toggles play/stop.
- **Band presets** — one click sets **both** frequencies to produce a target difference, e.g.
  `fL = 205, fR = 215 → 10 Hz`.
- **Headphone check on startup** — device heuristics first (Bluetooth/USB/HDMI/built-in, port
  names), then a fast perceptual left/right test. If the channels come back swapped, the app
  remembers it and swaps its output so you get the right difference on the right side.
- **Frequency reference, 9 categories** — brainwave bands, Schumann resonance, planetary tones,
  solfeggio, tuning references, research frequencies, Rife, space/consciousness claims, healing and
  energy. Bilingual (en/ru), searchable, with an evidence badge per entry. Details in
  **[docs/FREQUENCIES.md](docs/FREQUENCIES.md)**.
- **Light and dark theme**, native Qt widgets, HiDPI, full keyboard navigation.
- **English and Russian interface**, switchable at runtime — see [Language](#language).
- **macOS and Linux** from one codebase, Windows next.
- **Two implementations** — the Python/Qt app above, plus a native Swift app for macOS and iOS
  under [`apple/`](apple/README.md). They share the frequency reference file and the API
  contract, never source code.

Explicitly out of scope: 3D/HRTF positioning, overlaying onto files or radio, spectrum analysis,
recording or streaming. iOS is in scope through `apple/` rather than through Python; Android is
not planned.

---

## Language

The interface is **English or Russian**, switched from the app menu: *View → Language*
(*Вид → Язык*). The switch applies immediately — including the open main window — and the
choice is remembered in `QSettings` under `ui/language`, so the next start opens in the same
language. On the very first start there is nothing stored yet, so the app follows the system
locale (a Russian locale opens in Russian).

The frequency reference is bilingual independently of the UI language: category names and
effect descriptions come from `frequencies.json`, which carries both variants, and the other
language stays available on hover.

---

## Frequency reference

The app ships a static reference of **99 entries across 9 categories**, stored as data in
`src/binaural/data/frequencies.json` and shown in-app with search, per-category counters and an
evidence badge.

The complete tables are in **[docs/FREQUENCIES.md](docs/FREQUENCIES.md)**.

The five EEG bands, which are the part with actual research behind it:

| Band | Beat | Commonly associated with | Evidence |
|---|---|---|---|
| Delta | 0.5–4 Hz | Deep sleep without dreams | 🟢 peer-reviewed EEG literature |
| Theta | 4–8 Hz | Meditation, REM sleep, hypnagogia | 🟢 peer-reviewed EEG literature |
| Alpha | 8–13 Hz | Relaxed alertness | 🟢 peer-reviewed EEG literature |
| Beta | 13–30 Hz | Active thinking | 🟢 peer-reviewed EEG literature |
| Gamma | 30–100 Hz | Higher-order cognitive processing | 🟢 peer-reviewed EEG literature |

Everything in the reference is listed without ranking or filtering. Entries that come from
esoteric, energy or alternative practices are marked 🟣 and kept visible rather than hidden, so
you can see what a claim is and where it comes from.

---

## What the research says

Short version: the auditory effect is real and measurable, the behavioural claims are contested.

**Fairly well established**

- The perceived beat sits in roughly **1–30 Hz**, which overlaps the main EEG bands. Outside that
  range you are unlikely to perceive much.
- **Low carriers work better.** A carrier around 400 Hz produces a measurable response; above about
  3 kHz the effect is not detectable. A peak in sensitivity has been reported near 250 Hz. This is
  why the app defaults to a 200 Hz carrier and warns before you go much higher.
- Two measurable responses exist in the EEG: the **frequency-following response (FFR)** locked to
  the carrier, and the **auditory steady-state response (ASSR)** at the beat frequency. Both have
  been demonstrated experimentally.
- **Noise masks it.** White noise in the signal weakens entrainment, which is why the app ships
  without noise.
- Stimulation durations in the literature are typically **5–15 minutes**.

**Contested**

- Outcomes are inconsistent. In a 2023 systematic review of 14 relevant studies, **6 supported the
  entrainment hypothesis and 9 did not** or were inconclusive. Individual results vary between
  people.
- The FFR/ASSR findings show that the brain *tracks* the beat. They do not by themselves establish
  that listening to it changes sleep, mood, focus or health outcomes.

So: research suggests the phenomenon exists, some users report subjective effects, and the
evidence on what those effects *do* is mixed. Nothing here is a promise, and the app makes no
therapeutic claim. See **[docs/SCIENCE.md](docs/SCIENCE.md)** for the longer version.

Sources: [systematic review 2023 (PMC10198548)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10198548/) ·
[Reznik & Allen 2020, *eNeuro*](https://www.eneuro.org/content/7/2/ENEURO.0232-19.2020) ·
[Garcia-Argibay et al. 2025, *Scientific Reports*](https://www.nature.com/articles/s41598-025-88517-z) ·
plus Pratt et al. 2009 (ERP) and Schwarz & Taylor for the carrier-frequency findings.

---

## Disclaimer

These frequencies and the effect descriptions come from research literature **and** from esoteric,
energy-based and alternative practices. The application is **not a medical device** and is not
intended for the diagnosis, treatment or prevention of any disease. Do not use it with epilepsy, a
cardiac pacemaker, during pregnancy, or with photosensitivity without consulting a doctor. Keep the
volume at a reasonable level.

The same disclaimer is shown in the app under *Help → About*.

---

## Requirements

**Running the packaged app** — no runtime dependencies:

- macOS 12 or newer, or
- Linux (x86_64 or arm64) with a running PulseAudio or PipeWire session

**Building from source** — Python 3.10 or newer (developed against 3.12) plus `pip`. PySide6
6.5+ (Essentials and Addons) is pulled in automatically; `numpy` comes with the `dev` extra.

**Building the Swift implementation (`apple/`)** — Xcode 27 (Swift 6.4) and `xcodegen`
(`brew install xcodegen`). No Apple Developer account is needed to build and test; deploying to
a physical iPhone is what needs one.

---

## Development

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural
python3 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
```

Run the tests:

```bash
.venv/bin/python -m pytest
```

Run the app from the checkout:

```bash
.venv/bin/binaural
```

Layers are separated on purpose: `core/` is pure math with no Qt import (unit-tested without any
audio hardware), `audio/` handles device enumeration and headphone detection, `ui/` only displays.
They talk through Qt signals. See `docs/CONTRACT.md` for the API contract.

On a headless Linux box the app needs an offscreen Qt platform:

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest
```

### The native Swift implementation (`apple/`)

The second implementation is written in Swift and built with Xcode. It reads the same
`src/binaural/data/frequencies.json` — there is deliberately no second copy of the reference.

```bash
cd apple
xcodegen generate
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

`CODE_SIGNING_ALLOWED=NO` is required: no Apple Developer certificate is configured. What M1
delivered, what M2 owes and the signing constraints are written up in
[apple/README.md](apple/README.md) and `apple/DESIGN.md`.

---

## Project status

Alpha. Honest breakdown of what exists in the tree today:

| Area | Status |
|---|---|
| `core/oscillator.py` — phase-continuous stereo oscillator, click-free ramps | implemented, tested |
| `core/engine.py` — `QAudioSink` output, volume, start/stop | implemented, tested |
| `core/session.py` — last frequencies, volume, swap flag, playback timer, preset category | implemented, tested |
| `audio/platform/` — device enumeration and classification (CoreAudio, `pactl`/`pw-cli`/`amixer`) | implemented, tested |
| `audio/headphones.py` — heuristics plus the perceptual L/R test sequence | implemented, tested |
| `data/frequencies.json` — 99 entries, 9 categories, bilingual | implemented, tested |
| `ui/` — main window, reference dialog, headphone-check dialogs | in progress |
| `app.py`, packaging, `install.sh` | in progress |
| `apple/` — Swift foundation: beat math, oscillator, synthesiser, catalogue, session | implemented, 73 parity tests |
| `apple/` — live audio, real UI, iOS Simulator test run | not started (M2) |

---

## Roadmap

**P1 — finishing the current scope**

- Main window: frequency controls, live beat/carrier readout, preset chips
- Headphone-check and L/R-test dialogs wired to the existing detection code
- Frequency reference dialog with search, category filters and evidence badges
- Settings dialog with the language switch inside it, a headphone-check button in the main
  window, the playback timer and two-level presets — `Session.timer_minutes` and
  `Session.preset_category` are already persisted, they simply have no control yet
- Light/dark theme, keyboard shortcuts, accessibility rules from the spec

**P2 — after that**

- WAV export of a session
- Optional `miniaudio` fallback output where `QAudioSink` is unavailable
- Smooth fade-out when the timer expires
- Windows: a WASAPI backend behind `audio/platform/`, a PyInstaller build, `install.ps1`

**Swift (`apple/`)**

- **M2** — live audio, headphone detection, the real UI, EN/RU, tests on the iOS Simulator
- After parity — drop the *release* build of the Python app for macOS; keep running it from
  source, since that is how the Python side is developed

---

## License

MIT — see [LICENSE](LICENSE).