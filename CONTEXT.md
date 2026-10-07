# CONTEXT.md — orientation and project status

**Read this before you touch anything.** It answers *where things stand* and *what will bite you*.
It does **not** replace `docs/SPEC.md` or `docs/CONTRACT.md` — read those before changing behaviour.

> ## If you change behaviour, update the affected part of this file in the same commit.
>
> The numbers, commands and status below go stale silently. A context file that lies is worse than
> no context file, because it is trusted. If you add a frequency, change a test count, land a
> feature, resolve an open question or add a trap: edit this file in the same commit as the change.
> An out-of-date `CONTEXT.md` is a bug.

Everything numeric below was verified against the tree on `main`. Numbers that are pinned by a test
are marked **[pinned]**.

---

## 1. What this is

Binaural is a desktop generator of binaural beats. You set one frequency for the left ear and one for
the right; the brain merges the two tones and perceives a third tone that is not in the signal at
all. Formally: `beat = |fL − fR|`, `carrier = (fL + fR) / 2`. Two sine oscillators, one per channel,
no effects and no processing. Headphones are a physical precondition of the method, not a
recommendation — on speakers the tones mix in the air before either ear.

## 2. Two implementations, one contract

| | Path | Platforms | Stack |
|---|---|---|---|
| Swift | `apple/` | macOS (shipped), iOS (builds, untested) | `BinauralCore` framework + AppKit app + SwiftUI shell |
| Python | `src/` + `tests/` | Linux (shipped), Windows (planned, **not started**) | PySide6 / Qt |

- **macOS → Swift**, `apple/`. Complete for M2. Ships as a Release `.app` (`apple/dist/Binaural.app`).
- **iOS** builds from the same `apple/` tree but has **never been run**: this machine has no iOS
  Simulator runtime. `apple/Sources/iOS` is a SwiftUI shell around the shared core.
- `docs/CONTRACT.md` binds **both** implementations — same frequency values, same catalogue counts,
  same session defaults. Where the two disagree it is either a bug or a deviation recorded in
  `apple/DESIGN.md`; a *silent* disagreement does not exist (CONTRACT rule 9).
- Where SPEC and the implementations disagree, **`docs/SPEC.md` wins**.

## 3. Where the truth lives

| File | What it is | Language |
|---|---|---|
| `docs/SPEC.md` | The specification. Source of truth. 739 lines. | Russian |
| `docs/CONTRACT.md` | The rules both implementations honour (§1–§7.1 plus rules for implementers). | Russian |
| `docs/FREQUENCIES.md` | The frequency reference as prose and tables. | English |
| `docs/SCIENCE.md` | What the evidence does and does not support. | English |
| `docs/INSTALL.md` | Install paths and troubleshooting. | English |
| `apple/DESIGN.md` | Recorded design decisions and deviations. **Append; never rewrite its history.** | English |

**`src/binaural/data/frequencies.json` is the only copy of the reference in the repo** — CONTRACT
rule 10. It currently holds **[pinned] 110 entries in 11 categories**:

| Category | `brainwave` | `schumann` | `planetary` | `solfeggio` | `tuning` | `research` | `rife` | `nasa` | `healing` | `substance` | `affect` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Entries | 12 | 5 | 10 | 9 | 5 | 4 | 40 | 7 | 7 | 4 | 7 |

Evidence totals **[pinned]**: 68 🟣 traditional, 12 🟢 well-studied, 14 🟡 reported, 16 🔵 studied.

Two implementations, one file: the Python app reads it beside its module, the Swift app through a
copy-files phase in `apple/project.yml` (`sources[].buildPhase.copyFiles`), and `build_release.sh`
re-verifies the bundled copy against the source with `shasum`. **Never duplicate it.**

## 4. Build and test — the commands and the numbers to expect

Every command below was run on `main` before this file was committed. If a number here does not
match your run, something changed — find out what before you trust either.

```bash
# Python — 488 passed, 2 skipped
QT_QPA_PLATFORM=offscreen .venv/bin/python -m pytest

# Swift — regenerate the project first; Binaural.xcodeproj is generated and gitignored
cd apple && xcodegen generate

# 208 core tests (BinauralCoreTests)
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# 141 window tests (BinauralMacTests, drives the real MainWindowController)
xcodebuild -project Binaural.xcodeproj -scheme Binaural \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# iOS — BUILD SUCCEEDED is a compile-and-link check, not a run
xcodebuild -project Binaural.xcodeproj -scheme Binaural-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# Release app → apple/dist/Binaural.app (≈2.2 MB, unsigned)
sh apple/build_release.sh          # add --smoke to launch and kill it
open apple/dist/Binaural.app
pgrep -f 'Binaural.app/Contents/MacOS/Binaural'   # launch check; pkill to stop
```

A build that crashes on launch is not a passing build. That check has caught two real crashes; see
traps 2 and 3.

## 5. Environment

| | |
|---|---|
| Machine | Mac mini M1 (`Macmini9,1`), macOS 26.7.1 |
| Xcode | 27.0 (build 27A266a), Swift 6.4 — Swift 6 language mode |
| Project generator | `xcodegen` 2.46.0 at `/opt/homebrew/bin/xcodegen` |
| Python | venv at `.venv`, Python 3.12.11, PySide6 |
| **Absent** | `tuist`, `swiftgen` — never used, do not reach for them |
| **Absent** | iOS Simulator runtimes (`xcrun simctl list runtimes` is empty) |
| **Absent** | Apple Developer identity — `security find-identity` reports **0** |

Consequences, all of them permanent on this machine:

- Every build passes `CODE_SIGNING_ALLOWED=NO`. The shipped `.app` is **unsigned**: no signature, no
  notarisation. It runs for whoever built it; Gatekeeper objects for anyone else (right-click →
  Open). Signing and the App Store are not "next", they are blocked.
- iOS can only be addressed through `-destination 'generic/platform=iOS Simulator'`. It is a compile
  check. **It must never gate macOS work.**
- `xcodebuild -downloadPlatform iOS` would upgrade iOS to a real run-on-simulator check with no
  other change.

CI (`.github/workflows/ci.yml`) runs the Python suite on a matrix of `ubuntu-latest` and
`macos-latest` × Python 3.10 / 3.12 (jobs `installer`, `test`, `strict-posix`, plus a
`workflow_dispatch`-only Linux `build-release`). **Nothing in CI runs the Swift suite** — every
`xcodebuild` check is yours to run locally.

## 6. Traps

Each of these cost real time. They are not stylistic preferences.

1. **xcodegen 2.46 has no `buildPhases` key.** It silently drops the entry, so a copy-files phase
   written the obvious way vanishes and `frequencies.json` never reaches the bundle. Copy phases go
   in `sources[].buildPhase.copyFiles`.
2. **`withUnsafeMutableBytes(of: &ids)` is a crash.** It hands CoreAudio a pointer to the Array
   *struct* instead of its storage; CoreAudio overwrites the array's metadata and ARC then faults in
   `swift_retain` on the way out — `SIGBUS`, at launch. Use the method form: `ids.withUnsafeMutableBytes`.
3. **`AVAudioSourceNode`'s render block must stay `nonisolated`.** Written inline inside the
   `@MainActor` `start()`, the closure inherits that isolation under Swift 6, so the compiler emits
   a main-actor check that trips `_dispatch_assert_queue` — `SIGTRAP` the first time real audio
   renders. It stayed hidden through M2-a because tests pulled the block from the main thread during
   `prepare()`, where the check passes.
4. **`kAudioDevicePropertyJackIsConnected` is unusable on this machine** — `err 2003332927`
   (`kAudioHardwareNotRunningError`). It was deliberately left out. Do not retry it.
5. **`src/binaural/locales/ru.py` is the i18n source of truth.**
   `apple/Sources/Core/Locales/RussianCatalogue.swift` is **generated** from it by
   `python3 apple/Tools/generate_russian_catalogue.py` and must be regenerated whenever `ru.py`
   changes. It currently carries **218 keys**. A hand-written key in `RussianWindowAdditions.swift`
   (4 keys) is legitimate only for a string `ru.py` has no call site for; **the two files must not
   overlap.** `L10nTests.testCatalogMatchesThePythonKeyCount` parses `ru.py` at test time and fails
   on any mismatch — so **the Swift suite fails if you forget to regenerate.**
6. **`L10n` is `@MainActor`** (`apple/Sources/Core/L10n.swift`). A missing translation returns the
   English key itself — visible, not silent.
7. **Do not weaken `RenderParameters` / `ParameterMailbox`.** The audio thread reads parameters
   through one `NSLock` used with a **non-blocking `try()`**: it never waits, and a lost race costs
   one block of stale parameters rather than a dropout. Do not move oscillator creation off the
   audio thread either — `StereoOscillator` is deliberately non-`Sendable`.
8. **Band boundaries are half-open**, read out of `frequencies.json`: Delta `[0.5, 4)`, Theta
   `[4, 8)`, Alpha `[8, 13)`, Beta `[13, 30)`, Gamma `[30, 100]`. Closed intervals would put 4, 8,
   13 and 30 in two bands each, and "exactly one band per preset" would be false.
9. **The reference counts are pinned hard** in `apple/Tests/CoreTests/FrequencyCatalogueTests.swift`:
   `entries.count == 110`, `categories.count == 11`, per-category counts, evidence totals. Adding
   entries breaks Swift tests **by design** — update the JSON *and* those literals *and*
   `docs/FREQUENCIES.md` in one commit.
10. **A study-backed entry must name its study.** `substance` and `affect` records cite a DOI or
    PMID in `source`, and `tests/test_frequencies.py` asserts it. Two of the eleven are
    deliberately weak and say so in their own text: the withdrawal study has no control group, and
    the colonoscopy one is from a journal of unclear standing. Do not tidy those caveats away.
    The `affect` category also carries two **null results** (`affect-null-7`, `affect-null-40`) on
    purpose — the badge is a hint and the reference must not imply a mood effect the study did not
    find. The §6.13 disclaimer says beats are sound, not a substance.

## 7. Conventions

- English identifiers and comments in code; comments explain *why*, and only where needed (CONTRACT
  rule 4). All user-facing text goes through `tr()` / `L10n.tr`.
- Document languages: `README.md`, `CONTEXT.md`, `apple/*.md` and `docs/{FREQUENCIES,SCIENCE,INSTALL}.md`
  in English; `README.ru.md`, `docs/SPEC.md`, `docs/CONTRACT.md` in Russian.
- **Port, do not redesign.** The Python tree is the reference for structure and decisions; the Swift
  app is ported from it. Where Python is wrong, follow SPEC, not Python. Two Qt/Swift widget trees
  may share data and behaviour, never source.
- **Commit per item, and never finish with uncommitted work.** This is the single most important
  process rule here — work has been lost before by agents that finished without committing. Check
  `git status` before *and* after. When you add files, confirm they are staged: untracked files do
  not show their contents in `git status`, so a new file can look clean when it is not.
- **No health claims anywhere.** `docs/SPEC.md` §6.13 governs the disclaimer; it forbids promising
  treatment, diagnosis or cure.
- Do not duplicate `frequencies.json`. Do not invent numeric facts in documentation — verify them.

## 8. Current state

`v0.1.0` is **tagged and published on GitHub** (2026-10-06), **source only**: the release has no
assets attached, because the unsigned `.app` cannot be distributed.

| Area | State |
|---|---|
| Python core | oscillator, engine, session, playback timer, `difference_lock` — implemented, tested |
| Python audio | device enumeration and classification (CoreAudio, `pactl`/`pw-cli`/`amixer`), headphone heuristics + perceptual L/R test — implemented, tested |
| Python UI | main window, F3 preset registry, reference dialog, headphone dialogs, Settings, tray — implemented, tested |
| Python suite | **488 passed, 2 skipped** |
| `apple/` core | `BinauralCore` — provably equal to Python by test, not merely compiling |
| `apple/` macOS | **All of M2**: live audio, main window, F3 preset registry (7 categories, 20 presets), the full frequency reference, headphone check, Settings, About, playback timer, menu-bar item, session persistence, the **"Lock difference"** checkbox |
| Swift suites | **208 core + 141 macOS window** |
| `apple/` Release | `apple/dist/Binaural.app`, unsigned |
| `apple/` iOS | compiles and links; **never run** |
| Windows | not started |

The preset registry (SPEC F3): 7 categories / 20 presets, all inside 1–30 Hz, each in exactly one
half-open band, a click setting both channels around the 200 Hz carrier so `fL = 200 − beat/2`,
`fR = 200 + beat/2`. The chosen category is session state.

Python is at parity with the Swift app for the interface: the F3 presets, Settings, the timer and the
"Lock difference" checkbox are implemented on both sides. Milestone plan: `apple/M2.md`.

The **About dialog** now carries four descriptive sections (SPEC §7 item 6): «Кто создал»,
«Как это работает», «Что это и зачем», «Технические детали». Every sentence is one shared `tr()`
key — `AboutContent.swift` holds the English constants, `about.py` holds the identical strings,
and `tests/test_dialogs.py::test_about_section_text_matches_the_swift_wording` parses the Swift
file and fails if either side is reworded alone. Only the platform line and the stack line differ,
for the same reason the tagline does: `apple/` is a separate product (SPEC §3), so their Russian
is the only part of the four sections in `RussianWindowAdditions.swift`. Both bodies scroll
(`QScrollArea` / `NSScrollView`) — the new sections make the dialog far taller than its window and
clipping is the failure mode a scrolling container hides, so both suites assert the sections are
inside the scroll area and in order.

## 9. Open questions and blocked work

**Approved and landed (2026-10-07).** The About dialog was expanded into four descriptive
sections — who made it, how it works, what it is and what it is for, technical details — in both
implementations, at user level and without health claims. See §8 for what that means for the
shared keys.

**Approved and landed (2026-10-07).** The proposal to add frequency entries about substances and
positive affect was approved and is in the tree: **11 entries in two new categories**, `substance`
(order 10, 4 entries) and `affect` (order 11, 7 entries), taking the reference to **110 entries in
11 categories**. An addiction-safety sentence was added to the §6.13 disclaimer in both
implementations (`about.py::DISCLAIMER_EN`, `AboutContent.disclaimerEnglish`) and to every place
that restates it. Existing category orders 1–9 did not shift. Trap 10 records the two weak studies
that keep their caveats in the entry text and the two null results the `affect` category carries on
purpose.

No other proposal is pending.

**Blocked, and not fixable here:**

- iOS tests — no Simulator runtime.
- Signing, notarisation, the App Store — no Apple Developer identity.
- WAV export — not implemented in either implementation; SPEC calls it optional (P2). It is
  deliberately absent, not forgotten.

## 10. Keeping this file honest

Read the rule at the top again: **if you change behaviour, update the affected part of this file in
the same commit.** That covers the test counts in §4, the reference in §3, the feature list in §8, the
traps in §6, the environment in §5 and the open questions in §9.

When a section of this file drifts from the tree, fix it even if your task was something else —
a two-line correction now beats a project that has lost track of itself again.