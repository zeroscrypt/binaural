# Binaural

<h2 align="right">🇬🇧 <strong>English</strong> &nbsp;·&nbsp; 🇷🇺 <a href="README.ru.md"><strong>Русский</strong></a></h2>

[![license](https://img.shields.io/badge/license-MIT-blue)][license]
[![release](https://img.shields.io/badge/release-v0.1.0-blue)][releases]
[![platform](https://img.shields.io/badge/platform-macOS%20(Swift)%20%7C%20Linux%20(Python)-lightgrey)][install]
[![python](https://img.shields.io/badge/python-3.10%2B-blue)][install]

**Two independent frequencies. One perceived difference.**

---

<details>
<summary>Table of contents</summary>

- [About the Project](#about-the-project)
  - [Why headphones are not optional](#why-headphones-are-not-optional)
  - [Built With](#built-with)
- [What are binaural beats?](#what-are-binaural-beats)
  - [The phenomenon](#the-phenomenon)
  - [Where it happens in the brain](#where-it-happens-in-the-brain)
  - [A short history](#a-short-history)
  - [The five brainwave bands](#the-five-brainwave-bands)
  - [What the evidence actually shows](#what-the-evidence-actually-shows)
  - [Why headphones are a physical requirement](#why-headphones-are-a-physical-requirement)
  - [What this app does about it](#what-this-app-does-about-it)
- [Features](#features)
- [Getting Started](#getting-started)
  - [Prerequisites](#prerequisites)
  - [macOS — the native app](#macos--the-native-app)
  - [Linux — one command](#linux--one-command)
  - [From source (either platform)](#from-source-either-platform)
- [Usage](#usage)
  - [Start with your headphones on](#start-with-your-headphones-on)
  - [Set the two frequencies](#set-the-two-frequencies)
  - [Press play](#press-play)
  - [Presets](#presets)
  - [The timer](#the-timer)
  - [Lock difference](#lock-difference)
  - [The frequency reference](#the-frequency-reference)
  - [Settings and the interface language](#settings-and-the-interface-language)
- [Frequency reference](#frequency-reference)
- [What the research says](#what-the-research-says)
- [Disclaimer](#disclaimer)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)
- [Contact](#contact)
- [Acknowledgments](#acknowledgments)

</details>

---

## About the Project

<pre align="center">
Left ear:   fL = 205.0 Hz
Right ear:  fR = 215.0 Hz
                    ↓
Perceived:    10.0 Hz   ← the beat, produced by the brain, not present in the signal
</pre>

Binaural is a desktop generator of binaural beats. You set one frequency for the left ear and
another for the right ear. The brain merges the two tones and perceives a third, virtual tone
whose pitch is the **difference** between them. Formally:

```
beat    = |fL − fR|
carrier = (fL + fR) / 2
```

**macOS** gets the native Swift app in [`apple/`][apple-dir]. **Linux** gets the Python/Qt app in
[`src/`][src-dir]. Windows is future work.

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

### Why headphones are not optional

This is not a recommendation. It is the physical condition under which the method works at all.

On speakers, the two tones travel through the same air and **mix before they reach your ears**.
Both ears receive the same jumbled waveform, so there is nothing left for the brain to
differentiate. The difference, and with it the effect, is gone. There is no setting in the app
that can fix this.

Put the headphones on before you press play. The app checks the output device on every start and
tells you if it thinks you are on speakers. The dialog with the full L/R test appears until you
confirm it once, and you can bring it back any time from Settings or *Help*.

### Built With

- **macOS app** — Swift 6.4 in strict concurrency, `AVAudioEngine` + CoreAudio for output,
  `BinauralCore` as a testable framework, AppKit for the window, a SwiftUI shell for iOS
  ([`apple/`][apple-dir], Xcode + `xcodegen`)
- **Linux app** — Python 3.10+ and PySide6 (Qt 6); output through `QAudioSink` from QtMultimedia,
  `pytest` for the suite ([`src/`][src-dir] + [`tests/`][tests-dir])
- **Shared by both** — one frequency reference file (`frequencies.json`) and one API contract
  ([`docs/CONTRACT.md`][contract]). Data and behaviour are shared; source code never is.

<a href="#about-the-project">⬆ Back to top</a>

---

## What are binaural beats?

The one-sentence version: **a tone that is not in the signal.** Two slightly different frequencies
are sent to the two ears, and the listener hears a third one — their difference — which exists
nowhere in the audio data. Every design decision in this app follows from that fact.

### The phenomenon

Send `205 Hz` to the left ear and `215 Hz` to the right ear at the same time, each through its own
channel. Nobody hears "205 and 215". They hear one steady tone at about 210 Hz — the **carrier** —
with something moving inside it: a slow pulse, a flicker, a wobble at 10 Hz. That wobble is the
binaural beat.

```
beat    = |fL − fR|          # 10 Hz in the example above
carrier = (fL + fR) / 2      # 210 Hz — the pitch you actually hear as a tone
```

The carrier is the pitch, the beat is the motion. They are independent numbers: the same 200 Hz
carrier can carry a 1 Hz beat or a 25 Hz one, and those are different experiences.

### Where it happens in the brain

Both signals travel along the auditory nerve to the **medial superior olive (MSO)** — a small
nucleus in the brainstem, and the first station in the auditory pathway where the two ears are
compared at all. Above it, in the thalamus and the auditory cortex, the brain is still working on
one fused stream. The MSO notices that the left input is very slightly slower than the right one
and responds at the rate of their difference.

The consequence is the strange part:

> **The beat frequency is not present in the audio signal.** Each ear receives a plain sine wave.
> There is no 10 Hz in either channel. The difference exists only after the two signals meet in the
> listener's brain.

So it is an internal sound: there is no waveform of it anywhere, and no microphone at the ear will
find it, because the difference is created downstream by the listener's own circuitry. The app
cannot fake it for you either, which is why it is a two-channel generator and nothing more.

### A short history

- **1839 — Heinrich Wilhelm Dove**, a Prussian physicist, publishes the phenomenon: two pure tones
  of slightly different frequency, presented separately and simultaneously to the two ears, are
  heard as producing illusory beats between them. His setup did not need headphones — two tuning
  forks and a tube to each ear do the same job, because all that matters is that the two paths
  stay separate.
- For more than a century and a quarter it stays a curiosity in acoustics.
- **1973 — Gerald Oster** publishes *"Auditory Beats in the Brain"* in *Scientific American*. That
  paper is what brought the effect to wide attention and turned it into a research programme.
  Oster's subject was how the auditory system works, not what binaural beats treat.

### The five brainwave bands

A **brainwave** is the rhythmic electrical activity of neurons, recorded on the scalp as an EEG and
divided by frequency into named bands. Five of them are what this method is usually discussed in
terms of:

| Band | Beat | Normally associated with |
|---|---|---|
| **Delta** | 0.5–4 Hz | Deep sleep without dreams; physical restoration, growth hormone release, immune support |
| **Theta** | 4–8 Hz | Meditation, REM sleep, the drowsy state on the way into sleep; creativity, memory consolidation |
| **Alpha** | 8–13 Hz | Relaxed alertness — awake but not tense; stress reduction, sustained focus, the pre-sleep state |
| **Beta** | 13–30 Hz | Active thinking; concentration, alertness, problem solving. Long exposure at the high end goes with over-arousal and anxiety |
| **Gamma** | 30–100 Hz | Higher-order cognitive processing, binding perception into one whole; 40 Hz specifically is studied in neurodegeneration research |

These five are the part of the [frequency reference](#frequency-reference) with actual research
behind them — every one of them carries the 🟢 badge for peer-reviewed EEG literature.

The overlap with what is perceivable is not a coincidence. Beats are perceived roughly in the
**1–30 Hz** range, which is exactly the amplitude-modulation range that a sustained tone can
follow: below about 1 Hz the fluctuation is too slow to track, and above about 30 Hz the
difference stops being heard as a beat and becomes a separate tone instead. Delta, theta, alpha and
beta therefore sit inside the window. **Gamma mostly does not** — which is why the 20 presets stop
at 30 Hz even though gamma entries are still in the reference.

One caveat, stated plainly: the bands and what they go with are not in dispute. The extra step —
that a beat at 10 Hz *entrains* alpha activity and so produces the behavioural effects alpha goes
with — is exactly the step the studies disagree about. *Entrainment* is the name for the hypothesis
that an external rhythm pulls the brain's own rhythm along with it, the way two pendulums on the
same board fall into step.

### What the evidence actually shows

**Solid.**

- The phenomenon is **real and measurable**. Two responses are recorded from scalp EEG: the
  **frequency-following response (FFR)**, which locks onto the carrier, and the **auditory
  steady-state response (ASSR)**, which appears at the beat frequency. Both have been demonstrated
  experimentally. The brain measurably tracks the beat.
- **Low carriers work better.** Responses are measurable at a carrier around 400 Hz, become
  unreliable above roughly 3 kHz, and sensitivity appears to peak near 250 Hz.
- **Noise masks it.** Broadband noise in the signal weakens the response — measurably so: it is
  smaller with noise in the signal than without.
- **Not everyone perceives a beat**, and among those who do, the reported intensity differs widely.

**Contested.**

- A **2023 systematic review** looked at 14 relevant studies: **6 supported the entrainment
  hypothesis, 9 did not or were inconclusive.** The studies also measure different things — EEG
  markers, subjective reports, sleep quality, cognitive performance — which makes them hard to
  compare directly.
- **Tracking is not the same as benefit.** The FFR and ASSR findings show that the auditory system
  *follows* the beat. They do not on their own show that listening to it improves sleep, mood,
  attention or health. That step needs its own evidence, and that evidence is where the studies
  disagree.
- **Much of the popular material is not scientific at all.** The 🟣 and 🟡 entries in the reference
  come from esoteric, energy-based or alternative practice. "DNA repair", detoxification and agency
  endorsements are claims, not findings.

So: the phenomenon is real, subjective reports of an effect are common, and the claim that it
*does* something specific for you is contested — this is a field with genuinely ambiguous data.
The longer version with every source is in [What the research says](#what-the-research-says) and
in **[`docs/SCIENCE.md`][science]**. The [Disclaimer](#disclaimer) applies to everything above.

### Why headphones are a physical requirement

On speakers the two tones leave the same box into the same air, and air adds waveforms together:
the two frequencies **mix before they reach your ears**. Both ears then receive the same jumbled
waveform, the signal no longer has a `fL` and an `fR` to separate, the MSO has nothing to compare,
and the beat is gone. Not quieter — *gone*, because the comparison has nothing left to do.

Keeping the two paths separate is the only requirement. Two tuning forks and two tubes were enough
in 1839; headphones are the version everybody owns. No setting in this app can recover the effect
on speakers. What the app does about it is in [Why headphones are not
optional](#why-headphones-are-not-optional), and in [Troubleshooting](#troubleshooting) for the
case where the beat is expected and missing.

### What this app does about it

Every finding above has a consequence in the code:

| Decision | Reason |
|---|---|
| Two independent frequencies, one per channel, nothing else | The difference has to be computed by the listener's brain. The app cannot fake it and does not try |
| Default carrier **200 Hz** | Responses are measurable near 400 Hz, unreliable above ~3 kHz, sensitivity peaking near 250 Hz |
| **No noise layer at all** | Broadband noise weakens the effect |
| Default **15-minute timer** with a smooth fade-out | Sessions in the literature run 5–15 minutes |
| **20 presets, all inside 1–30 Hz**, exactly one band each | The perception range. Gamma stays in the reference but is not a preset, because presets stop at 30 Hz |
| `BEAT` and `CARRIER` shown live at all times | So you can see what is actually being generated instead of trusting a label |
| A hint when the difference leaves **0.5–100 Hz** | The same idea — say so when the numbers are outside the range where a beat is worth expecting |
| Every one of the **110 reference entries** carries an evidence badge | 🟢 12 well-studied, 🔵 16 studied, 🟡 14 reported, 🟣 68 traditional. Nothing hidden, nothing ranked, esoteric claims labelled rather than dropped |

The complete tables behind the last row are in **[`docs/FREQUENCIES.md`][frequencies]**.

<a href="#what-are-binaural-beats">⬆ Back to top</a>

---

## Features

- **Zero configuration to hear something.** Two numbers, one button. No audio files, no
  processing chain, no import step.
- **You always know what you are hearing.** `BEAT` and `CARRIER` update as you type, with a hint
  when the beat falls outside the usual 0.5–100 Hz perception range.
- **Twenty presets, seven categories, one click.** Pick a category, pick a preset, and both
  frequencies are set around the 200 Hz carrier so the difference is exactly the beat.
- **The session ends by itself.** A playback timer stops the tone when it runs out, so you can
  fall asleep to it.
- **Tuning that does not click.** Frequency changes keep the phase continuous, ramps are smooth,
  and *Lock difference* lets you tune one ear by hand while the other follows.
- **It warns you before it goes silent.** A headphone check runs on every start; a perceptual
  left/right test catches swapped channels and swaps the output for you.
- **A reference that shows its sources.** 110 entries in 11 categories, each with an evidence
  badge, searchable, and bilingual in English and Russian — including the claims that are
  tradition or folklore rather than research.

<a href="#features">⬆ Back to top</a>

---

## Getting Started

### Prerequisites

| Platform | What you need |
|---|---|
| **macOS** | macOS 12 or newer. To build: Xcode (Swift 6.4) and `xcodegen` (`brew install xcodegen`). No Apple Developer account. |
| **Linux** | Linux (x86_64 or arm64) with a running PulseAudio or PipeWire session. From source: Python 3.10+ (developed against 3.12) and `pip`. PySide6 6.5+ is pulled in for you. |

### macOS — the native app

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural/apple
./build_release.sh          # builds apple/dist/Binaural.app
open apple/dist/Binaural.app
```

`build_release.sh` builds Release into a throwaway derived-data directory, copies the finished
bundle to `apple/dist/Binaural.app`, verifies the bundled `frequencies.json` against the single
copy in `src/` with `shasum`, and deletes the build tree. No Xcode needed afterwards — it is a
plain `.app` you can double-click. Add `--smoke` to have the script launch the app once and kill
it, which is how a launch crash gets caught. What the milestones delivered and what the signing
constraints are is written up in [`apple/README.md`][apple-readme].

> **It is unsigned.** No Apple Developer identity is configured on the build machine, so the app
> is built with `CODE_SIGNING_ALLOWED=NO` and there is no notarisation. It runs for whoever built
> it; for anyone else Gatekeeper blocks the first launch, and right-click → *Open* is the way past
> it. Proper distribution — signing, notarisation, the App Store — needs an Apple Developer
> account and is not done. **v0.1.0 on GitHub is source only**: no binaries are attached to the
> release, so building it yourself is the install path on macOS.

### Linux — one command

```bash
curl -fsSL https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh | sh
```

The script detects your OS and architecture, downloads the matching release archive, unpacks it
into `~/.binaural/`, symlinks `binaural` into `~/.local/bin` (adding it to `PATH` if needed) and
verifies the result with `binaural --version`. No Python or Qt on your machine is required — the
archive ships its own runtime.

Useful flags: `--dry-run` prints every step and changes nothing, `--uninstall` removes the
installation, and `--help` lists the rest. If you would rather read the script before running it,
download it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/zeroscrypt/binaural/main/install.sh
less install.sh
sh install.sh --dry-run
```

> **Heads up:** Linux is the only platform this script installs a Python build for, and the
> release archives have not shipped yet. If it reports that no release is available, it falls back
> to installing from source on its own — a fully supported path, not an error.
>
> On macOS the script says what the situation is and then does the source install, because the
> macOS product is the Swift app above.

### From source (either platform)

```bash
git clone https://github.com/zeroscrypt/binaural.git
cd binaural
python3 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"
.venv/bin/binaural
```

The `dev` extra adds `pytest` and `numpy`, which the test suite needs. `pip install -e .` also
installs the `binaural` console script, so `.venv/bin/binaural` is the entry point. This path is
fully supported on macOS too — the Python app still detects CoreAudio devices there.

Full details, including manual builds and every troubleshooting case, are in
**[`docs/INSTALL.md`][install]**.

<a href="#getting-started">⬆ Back to top</a>

---

## Usage

Three steps, in order.

### Start with your headphones on

Start the app with your headphones already on. If the output device looks like speakers, the app
says so and offers a check; see [Why headphones are not
optional](#why-headphones-are-not-optional).

### Set the two frequencies

The window shows one control per ear — a large readout, a slider and a field you can type into.
Move one and the other stays exactly where it was. Range 1–20000 Hz, 0.1 Hz steps.

In the middle, `BEAT` is the difference and `CARRIER` is the mean of the two. Start from the
example: 205 Hz left, 215 Hz right, and you get a 10 Hz beat at a 210 Hz carrier.

### Press play

*Play* starts the tone, *Stop* ends it, and `Space` toggles between them. `↑`/`↓` nudge the
active channel by 0.1 Hz, `←`/`→` switch between ears. Frequencies can be changed while playing
without a click — the phase is continuous and the amplitude ramps.

What you see in the window: the two frequency controls, the BEAT and CARRIER metrics with the
*Lock difference* checkbox under the beat, the play button, volume, the playback timer and its
countdown, and the two-level preset chips along the bottom.

### Presets

Seven categories — Sleep, Meditation, Relaxation, Awareness, Concentration, Work, Sport — hold
20 presets in total. Every preset sits inside 1–30 Hz and in exactly one brainwave band, and one
click sets **both** frequencies around the 200 Hz carrier so the difference is the beat:
`fL = 200 − beat/2`, `fR = 200 + beat/2`. The category you picked is remembered between sessions.

*Save preset* stores the pair you currently have for the next run.

### The timer

0 means off — play until you stop it. Otherwise pick from 5, 10, 15, 20, 30, 45, 60, 90 or 120
minutes; the default is 15. The remaining time counts down on screen and playback stops by
itself when it runs out.

### Lock difference

Tick it and editing one channel moves the other by the same amount, so the signed difference
stays where you put it. At the edge of the 1–20000 Hz range the edited channel stops rather than
the lock being broken. A preset sets its own difference and clears the lock.

### The frequency reference

Open it from *Help → Frequency reference* (`Ctrl+O` / `⌘O`). A category sidebar with counters on
the left, a search field, and for each entry: name → frequency → *Apply* → the effect text → an
evidence badge → the source. *Apply* sets both channels from the record. The dialog is bilingual
in its own right, independently of the interface language.

### Settings and the interface language

*Settings* (`Ctrl+,` / `⌘,`) holds the interface language, the default timer, volume, and the
button that re-runs the headphone check. Every control writes straight through to the running
window.

The interface is **English or Russian**, switchable from *View → Language* or from Settings. The
switch applies immediately — including the open window and the open dialog — and the choice is
remembered under `ui/language`. On the very first start there is nothing stored yet, so the app
follows the system locale. Both implementations share the key and the Russian text: the Swift
catalogue is **generated** from the Python one (`src/binaural/locales/ru.py`), and a test fails
the build if the two ever disagree about which strings are translated.

Elsewhere in the app: *Help → Check headphones…* (`Ctrl+Shift+H`) re-runs the device check and the
perceptual L/R test, and *Help → About* (`Ctrl+Shift+I`) holds the description and the disclaimer.

<a href="#usage">⬆ Back to top</a>

---

## Frequency reference

The app ships a static reference of **110 entries across 11 categories**, stored as data in
`src/binaural/data/frequencies.json` and shown in-app with search, per-category counters and an
evidence badge. That file is the only copy in the repository — the Swift app reads it too.

| Category | Entries | Category | Entries |
|---|---|---|---|
| 🧠 Brainwave Entrainment | 12 | ⚡ Rife & Therapeutic | 40 |
| 🪐 Planetary Frequencies | 10 | 🎵 Solfeggio | 9 |
| 🌍 Schumann Resonance | 5 | 🚀 Space & Consciousness | 7 |
| ✨ Healing & Energy | 7 | ☀️ Mood & Positive Affect | 7 |
| 🎼 Tuning & Reference | 5 | 🔬 Research & Studies | 4 |
| 🧪 Substances & Medication | 4 | **Total** | **110** |

Evidence badges on every entry: 🟣 68 traditional, 🟢 12 well-studied, 🟡 14 reported, 🔵 16
studied.

The five EEG bands, which are the part with actual research behind it:

| Band | Beat | Commonly associated with | Evidence |
|---|---|---|---|
| Delta | 0.5–4 Hz | Deep sleep without dreams | 🟢 peer-reviewed EEG literature |
| Theta | 4–8 Hz | Meditation, REM sleep, hypnagogia | 🟢 peer-reviewed EEG literature |
| Alpha | 8–13 Hz | Relaxed alertness | 🟢 peer-reviewed EEG literature |
| Beta | 13–30 Hz | Active thinking | 🟢 peer-reviewed EEG literature |
| Gamma | 30–100 Hz | Higher-order cognitive processing | 🟢 peer-reviewed EEG literature |

Everything in the reference is listed without ranking or filtering. Entries that come from
esoteric, energy or alternative practices are marked 🟣 and kept visible rather than hidden, so you
can see what a claim is and where it comes from.

The complete tables are in **[`docs/FREQUENCIES.md`][frequencies]**.

<a href="#frequency-reference">⬆ Back to top</a>

---

## What the research says

Short version: the auditory effect is real and measurable, the behavioural claims are contested.

**Fairly well established**

- The perceived beat sits in roughly **1–30 Hz**, which overlaps the main EEG bands. Outside that
  range you are unlikely to perceive much.
- **Low carriers work better.** A carrier around 400 Hz produces a measurable response; above about
  3 kHz the effect is not detectable. A peak in sensitivity has been reported near 250 Hz. This is
  why the app defaults to a 200 Hz carrier. The app itself does not warn about the carrier — the
  only range check it makes is on the beat.
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
therapeutic claim. See **[`docs/SCIENCE.md`][science]** for the longer version.

Sources: [systematic review 2023 (PMC10198548)][pmc-review] ·
[Reznik & Allen 2020, *eNeuro*][ez] ·
[Garcia-Argibay et al. 2025, *Scientific Reports*][sci-rep] ·
plus Pratt et al. 2009 (ERP) and Schwarz & Taylor for the carrier-frequency findings.

<a href="#what-the-research-says">⬆ Back to top</a>

---

## Disclaimer

These frequencies and the effect descriptions come from research literature **and** from esoteric,
energy-based and alternative practices. The application is **not a medical device** and is not
intended for the diagnosis, treatment or prevention of any disease. Do not use it with epilepsy, a
cardiac pacemaker, during pregnancy, or with photosensitivity without consulting a doctor. Keep the
volume at a reasonable level.

Binaural beats are sound, not a substance, and they do not replace one. Nothing here helps with
withdrawal, craving, tolerance or relapse, and this app does not treat dependence of any kind.
Dependence is a medical condition with risks of its own: withdrawal from alcohol and from sedatives
can be dangerous. If you are dependent on something, or want to use less of it, that is a question
for a doctor or a specialist service, not for a tone generator.

This text is [§6.13 of the project specification][spec] and it is shown in the app under
*Help → About*.

<a href="#disclaimer">⬆ Back to top</a>

---

## Troubleshooting

Full details and the complete matrix are in **[`docs/INSTALL.md`][install]**. The cases that
actually come up:

### `qt.qpa.plugin: Could not load the Qt platform plugin "xcb"`

Qt cannot open a window. On a desktop session this usually means missing system libraries for the
platform theme plugin — the xcb plugin needs a handful of X11 packages:

```bash
# Debian/Ubuntu
sudo apt-get install -y libxcb-cursor0 libxkbcommon-x11-0 libxcb-xinerama0 libxcb-icccm4 \
  libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xkb1 \
  libegl1 libgl1 libglib2.0-0

# Fedora
sudo dnf install -y xcb-util-cursor xcb-util-keysyms xcb-util-wm xcb-util-image \
  libxkbcommon-x11 mesa-libEGL mesa-libGL

# Arch
sudo pacman -S --needed xcb-util-cursor xcb-util-keysyms xcb-util-wm xcb-util-image \
  libxkbcommon-x11 mesa
```

### Qt does not start on a headless machine

With no display there is no window to open. For tests, CI or anything non-interactive:

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest
```

`offscreen` keeps Qt fully functional minus the actual window. It is not a workaround for running
the UI over a real remote session — for that use X11 forwarding or a Wayland session.

### No audio, or the error mentions `QAudioSink`

`QAudioSink` comes from PySide6-Addons. If you installed only PySide6-Essentials, the audio
engine cannot start.

```bash
.venv/bin/python -m pip install "PySide6-Addons>=6.5"
```

Then check that the platform can open the device at all:

```bash
pactl list short sinks
pactl get-default-sink
```

If the sink exists and PulseAudio is running but audio is still silent, note that a session running
over SSH has no access to the local sound server.

### `binaural: command not found` after install

The symlink is in `~/.local/bin` and that directory is not on your `PATH`. Add it:

```bash
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc

# zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Confirm with `ls -l ~/.local/bin/binaural` — if the symlink is missing, rerun the installer with
`--prefix=DIR` and put `binaural` on your `PATH` directly.

### macOS: "cannot be opened because the developer cannot be verified"

The Swift app in `apple/` is **unsigned**, so Gatekeeper blocks it for anyone but the person who
built it. Right-click → *Open* in Finder and confirm in the dialog — this works once per binary —
or clear the quarantine flag from a terminal:

```bash
xattr -d com.apple.quarantine /path/to/Binaural.app
```

On Apple Silicon, System Settings → Privacy & Security also offers "Open Anyway" after the first
blocked attempt. This applies to `apple/dist/Binaural.app`, not to the Python app: a source
install is built locally and never goes through Gatekeeper.

### The beat is not audible on speakers

Expected, not a bug. On speakers the two frequencies mix in the air before reaching your ears and
the effect disappears. See [Why headphones are not
optional](#why-headphones-are-not-optional).

<a href="#troubleshooting">⬆ Back to top</a>

---

## Contributing

Working on this repository? Read **[`CONTEXT.md`][context]** first — it says where the project
stands and what will bite you. The rules that bind both implementations are in
**[`docs/CONTRACT.md`][contract]**; where an implementation and the specification disagree,
**[`docs/SPEC.md`][spec]** wins.

**Run the tests before you commit.**

```bash
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest     # 488 passed, 2 skipped
```

The Swift side has its own suites, and **nothing in CI runs them** — every `xcodebuild` check is
yours to run locally:

```bash
cd apple && xcodegen generate                               # 208 core tests
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Binaural.xcodeproj -scheme Binaural \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test # + 141 window tests
```

`CODE_SIGNING_ALLOWED=NO` is required: no Apple Developer certificate is configured.

Three conventions worth knowing before your first commit:

- **English identifiers and comments in code**; all user-facing text goes through `tr()` /
  `L10n.tr`. The Swift Russian catalogue is *generated* from `src/binaural/locales/ru.py` — if you
  change one, regenerate the other or the Swift suite fails.
- **Never duplicate `frequencies.json`.** It is the only copy in the repository, and the Swift
  suite pins its counts on purpose: adding entries means updating the JSON, the Swift literals and
  `docs/FREQUENCIES.md` in one commit.
- **Commit per item, and never finish with uncommitted work.** Check `git status` before and after.

Layers are separated on purpose: `core/` is pure math with no Qt import (unit-tested without any
audio hardware), `audio/` handles device enumeration and headphone detection, `ui/` only displays.
They talk through Qt signals.

<a href="#contributing">⬆ Back to top</a>

---

## Roadmap

**v0.1.0 is tagged and published** — source only, no binaries are attached to the release,
because an unsigned `.app` cannot be distributed. Alpha otherwise.

**Done**

| Area | State |
|---|---|
| Python core | phase-continuous stereo oscillator with click-free ramps, `QAudioSink` output, session state, playback timer, `difference_lock` — implemented, tested |
| Python audio | device enumeration and classification (CoreAudio, `pactl`/`pw-cli`/`amixer`), headphone heuristics plus the perceptual L/R test — implemented, tested |
| Python UI | main window with live beat/carrier, the 7-category / 20-preset registry, frequency reference dialog, headphone-check and L/R dialogs, Settings, tray — implemented, tested |
| Python suite | **488 passed**, 2 skipped |
| `apple/` core | `BinauralCore` — provably equal to Python by test, not merely compiling |
| `apple/` macOS | live audio, main window, the full preset registry, the frequency reference, headphone check, Settings, About, playback timer, menu-bar item, session persistence, *Lock difference*, EN/RU — implemented, **208 core + 141 macOS tests** |
| `apple/` Release | `apple/dist/Binaural.app`, **unsigned** |
| Linux packaging | `install.sh`, PyInstaller spec and the release script in place; **no archive published yet** |
| Windows | not started |

**Next**

- **Linux release archives** — the packaging is in place; nothing has been built and attached to a
  release yet, which is why `v0.1.0` is source only.
- **Windows** — a WASAPI backend behind `audio/platform/`, a PyInstaller build, `install.ps1`
- Optional `miniaudio` fallback output where `QAudioSink` is unavailable
- **Screenshots** — none are published yet, which is why the ASCII diagram in
  [About the Project](#about-the-project) is the only visual in this file
- **iOS** — the scheme builds and links, but it has never been run: this machine has no Simulator
  runtime. Installing one (`xcodebuild -downloadPlatform iOS`) turns it into a real check

**Still honest limits**

- The macOS app is **unsigned** — no Apple Developer identity on the build machine, no
  notarisation, no App Store. Gatekeeper blocks it for anyone but the builder.
- **No WAV export.** Deliberately absent from both implementations; the specification calls it
  optional.
- Only a human with headphones on can judge the perceptual L/R test and its edge cases.

<a href="#roadmap">⬆ Back to top</a>

---

## License

MIT — © 2026 Dmitriy Solontsov. See [`LICENSE`][license].

<a href="#license">⬆ Back to top</a>

---

## Contact

- Author — **@zeroscrypt** (Dmitriy Solontsov)
- Issues — [github.com/zeroscrypt/binaural/issues][issues]
- Source — <https://github.com/zeroscrypt/binaural>

<a href="#contact">⬆ Back to top</a>

---

## Acknowledgments

- Special thanks to **@hakatao**.
- The frequency reference draws on published EEG literature and on esoteric and alternative
  traditions, marked as such entry by entry. The sources are listed in
  [`docs/FREQUENCIES.md`][frequencies] and [`docs/SCIENCE.md`][science].

<a href="#acknowledgments">⬆ Back to top</a>

---

<!-- Markdown link declarations -->

[license]: LICENSE
[releases]: https://github.com/zeroscrypt/binaural/releases
[issues]: https://github.com/zeroscrypt/binaural/issues
[context]: CONTEXT.md
[spec]: docs/SPEC.md
[contract]: docs/CONTRACT.md
[install]: docs/INSTALL.md
[frequencies]: docs/FREQUENCIES.md
[science]: docs/SCIENCE.md
[apple-dir]: apple/
[apple-readme]: apple/README.md
[src-dir]: src/
[tests-dir]: tests/
[pmc-review]: https://pmc.ncbi.nlm.nih.gov/articles/PMC10198548/
[ez]: https://www.eneuro.org/content/7/2/ENEURO.0232-19.2020
[sci-rep]: https://www.nature.com/articles/s41598-025-88517-z