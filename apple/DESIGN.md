# apple/ — design notes

This file is the contract for the next milestone. Read `docs/SPEC.md` (behaviour) and
`docs/CONTRACT.md` (shared API) first; the Python reference is `src/binaural/`.

* **§1–§6 — M1, the Swift foundation.** Unchanged, still the record of that milestone.
* **§7 onwards — M2.** Appended as each phase lands; M1's history above is not rewritten.

---

# Part I — M1 (the Swift foundation)

Status: **Milestone 1.** Foundation only — the parts that must be *provably* equal to the
Python implementation. UI is deliberately M2.

## 1. Modules and responsibilities

```
apple/
├── project.yml          # xcodegen; generates apple/Binaural.xcodeproj (never committed)
├── DESIGN.md            # this file — the contract for M2
├── Sources/
│   ├── Core/            # BinauralCore.framework — no AppKit, no SwiftUI, no UIKit
│   │   ├── BeatMath.swift          # from core/oscillator.py (constants, pair_from_beat)
│   │   ├── StereoOscillator.swift  # from core/oscillator.py::StereoOscillator
│   │   ├── Synthesizer.swift       # offline render (Python has no counterpart)
│   │   ├── FrequencyCatalogue.swift# from data/frequencies.py
│   │   └── Session.swift           # from core/session.py
│   ├── macOS/           # AppKit app target `Binaural`
│   └── iOS/             # SwiftUI app target `Binaural-iOS`
└── Tests/CoreTests/     # XCTest bundle `BinauralCoreTests` (macOS)
```

`BinauralCore` is one **multiplatform** target (`supportedDestinations: [macOS, iOS]`),
so both apps and the tests run the same code. `Core` is pure maths + data (CONTRACT rule
5); the app shells only read it and display.

## 2. Swift types introduced in M1

```swift
// BeatMath — CONTRACT §1
public enum BeatMath {
    static let defaultCarrierHz = 200.0; static let minFrequencyHz = 1.0
    static let maxFrequencyHz = 20000.0; static let maxBeatHz = 100.0
    static let recommendedBeatRangeHz = 0.5...100.0
    static let defaultRampSeconds = 0.03; static let defaultSampleRate = 48000
    static func beatFrequency(leftHz:rightHz:) -> Double              // |fL - fR|
    static func carrierFrequency(leftHz:rightHz:) -> Double            // (fL + fR) / 2
    static func pair(fromBeat:carrier:) throws -> (left: Double, right: Double)
    static func validated(_:name:) throws -> Double
}
public enum FrequencyError: Error, Equatable { case notFinite, outOfRange, negativeBeat, invalidSampleRate }

// StereoOscillator — CONTRACT §1. A class on purpose: mutable state owned by the thread
// that drives it. Deliberately NOT Sendable, and not @unchecked Sendable.
public final class StereoOscillator {
    init(sampleRate: Int = 48000) throws
    var sampleRate: Int; var leftHz: Double; var rightHz: Double
    var phase: (left: Double, right: Double)   // fractions of a cycle, always 0..<1
    var gain: Double; var targetGain: Double; var pan: (left: Double, right: Double)
    func setFrequencies(leftHz:rightHz:) throws
    func setSampleRate(_:) throws
    func setFade(_ gain: Double, rampSeconds: Double = 0.03)   // accumulating fade
    func setPan(left:right:)                                  // hard-pan, for the L/R test
    func render(frames: Int) -> (left: [Float], right: [Float])
}

// Synthesizer — the one Sendable convenience type over the oscillator
public struct Synthesizer: Sendable {
    init(rampSeconds: Double = BeatMath.defaultRampSeconds)
    func render(beatHz: Double, carrierHz: Double = 200.0, duration: Double,
                sampleRate: Int = 48000) throws -> StereoBuffer
    func render(leftHz: Double, rightHz: Double, duration: Double,
                sampleRate: Int = 48000) throws -> StereoBuffer
}
public struct StereoBuffer: Sendable, Equatable { var left: [Float]; var right: [Float] }

// FrequencyCatalogue — CONTRACT §5. An immutable value: load once, share across threads.
public enum EvidenceLevel: String, CaseIterable, Codable, Sendable {
    case wellStudied = "well-studied", studied, reported, traditional, unknown
    var badge: String                                  // 🟢 🔵 🟡 🟣 ⚪
    static var defined: [EvidenceLevel]                // the four of SPEC §6.2
    init(lenient: String)                              // anything else -> .unknown
}
public struct FrequencyCategory: Codable, Sendable, Equatable, Identifiable
    // id, order, icon, color, labelEn, labelRu, descriptionEn, descriptionRu
public struct FrequencyEntry: Sendable, Equatable, Identifiable
    // id, category, label, beatHz?, beatMin?, beatMax?, carrierHz, effectEn, effectRu,
    // evidence, source, tags; plus isRange, isTonal, badge, frequencyText
public struct CategoryCount: Sendable, Equatable { let category: FrequencyCategory; let count: Int }
public enum CatalogueIssue: Sendable, Equatable     // duplicateID, unknownCategory,
    // invalidEvidence, badBeatValue, badRange, mixedBeatForms, badCarrier, emptyField, badColor
public enum CatalogueError: Error { case missingResource, unreadable, malformed }
public struct FrequencyCatalogue: Sendable, Equatable {
    init(contentsOf url: URL) throws
    static func load(bundle: Bundle = .main) throws -> FrequencyCatalogue
    var version: Int
    var categories: [FrequencyCategory]              // sorted by `order`
    var entries: [FrequencyEntry]                    // ranges first, then beat, then id
    func entry(id:) / category(id:) / entries(inCategory:) -> ...
    func categoriesWithCounts() -> [CategoryCount]
    func totalsByEvidence() -> [EvidenceLevel: Int]
    func search(_ query: String, category: String? = nil) -> [FrequencyEntry]
    func validate() -> [CatalogueIssue]              // empty == honours SPEC §6
}

// Session — CONTRACT §7. JSON keys are the Python field names verbatim.
public struct Session: Sendable, Equatable, Codable {
    var leftHz = 205.0; var rightHz = 215.0; var volume = 0.7
    var channelsSwapped = false; var headphoneCheckAcknowledged = false
    var lastPreset: String? = nil
    var timerMinutes = 15                            // DEFAULT_TIMER_MINUTES
    var presetCategory = "relaxation"
    static let timerOff = 0, defaultTimerMinutes = 15, maxTimerMinutes = 1440
    static let timerChoices: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
    static let standard: Session                     // == Session(), the Python defaults
    var beatHz / carrierHz: Double                   // derived
    func jsonData() throws -> Data
    func save(to url: URL) throws
    static func load(from url: URL) throws -> Session // lenient: bad key -> default
}
```

## 3. How `frequencies.json` reaches the code

One file, one truth: `src/binaural/data/frequencies.json`. Never copied into `apple/` by
hand.

* **Apps** (`Binaural`, `Binaural-iOS`): an xcodegen Copy Files phase with one entry,
  `../src/binaural/data/frequencies.json` = `$(SRCROOT)/../src/binaural/data/frequencies.json`.
  It lands in the bundle as `frequencies.json`, read via
  `FrequencyCatalogue.load(bundle: .main)`. In the spec this is a `sources` entry, **not**
  a `buildPhases` entry — xcodegen 2.46 has no `buildPhases` key and silently drops it:
  ```yaml
  sources:
    - path: ../src/binaural/data/frequencies.json
      buildPhase:
        copyFiles:
          destination: resources
  ```
  Verified byte-identical (SHA-256) to the source file in both bundles.
* **Tests** use no bundle: `ReferenceFile.url` in `TestSupport.swift` rebuilds the source
  path from `#filePath` (up four levels from `apple/Tests/CoreTests/`), so a count always
  reflects the file under edit.
* `BinauralCore` bundles no resources at all — the dependency stays app → framework →
  caller-supplied URL.

## 4. M1 vs M2

**In M1:** beat/carrier maths with audible-range validation; the oscillator with
continuous phase and accumulating fade; `Synthesizer` offline render; the catalogue
(decode, index, lookup, search, validate, evidence totals); `Session` with the Python
defaults, clamps and JSON round-trip; two launchable shells reporting catalogue and
session facts; 73 XCTest parity tests.

**Deferred to M2** (nothing above depends on it):

* live audio output — an `AVAudioEngine`/`AudioUnit` render callback calling
  `render(frames:)`; the oscillator API is already the right shape;
* headphone detection (`DeviceClass`, `AudioDevice`, heuristic + perceptual L/R test,
  `channels_swapped`) and `AudioEngine`;
* the real UI: two frequency fields, beat/carrier display, preset chips, reference
  browser, timer, volume, i18n (EN/RU) — `timerMinutes`/`presetCategory` exist to be
  driven by it, and so does `setPan` for the L/R test;
* `WavWriter` / WAV export. **Checked, not assumed:** Python has no WAV writer — `grep`
  for `wav` across `src/` finds only `frequencies.json` and Russian prose, and SPEC §F5
  calls export "optional (P2)". There is nothing to port, so M1 invents no file format;
* running the tests on the simulator (see §6).

## 5. Deviations from `docs/CONTRACT.md`

1. **§7 `Session` storage.** Python persists through `QSettings` under `session/<key>`.
   Swift has no QSettings and Core must stay platform-independent, so `Session` is
   `Codable` and M1 round-trips JSON at an explicit URL. Field names, defaults and the
   load-time clamps (`volume` → 0…1, `timer_minutes` → 0…1440, missing key → default) are
   unchanged. Which file the app opens (`UserDefaults` vs Application Support) is an M2
   decision.
2. **§5 evidence level.** Python keeps `evidence` as a raw string and badges anything
   outside the four known levels with ⚪. Swift models it as `EvidenceLevel` with an
   explicit `.unknown` case carrying that ⚪ badge, so the leniency survives; only the
   unknown spelling is dropped, and nothing in Python's query paths reads it.
3. **§1 `render` returns `Float`.** The contract says "float32-like samples"; the buffers
   are `[Float]` while the maths stays `Double`. Consequence for tests: Python asserts the
   closed-form sine at `abs=1e-12` (doubles), the port asserts `1e-6` — single-precision
   resolution, nothing looser.
4. **A gap in the reference, not a choice.** `preset_category` has the default
   `"relaxation"` and *no* enumeration anywhere in `src/`: `session.py` points at
   `main_window.PRESET_CATEGORIES`, which does not exist yet. Inventing an allowed set
   would be inventing product behaviour, so `Session.presetCategory` is a free `String`
   exactly as in Python and the registry belongs to the M2 UI. `TIMER_CHOICES` *is* real
   data and is ported verbatim.

## 6. Build and verify

Xcode 27.0 (27A266a), Swift 6.4, `xcodegen` 2.46. `tuist`/`swiftgen` are not installed
and not used. There is **no Apple Developer account** on this machine
(`security find-identity` → 0 identities), so every command passes
`CODE_SIGNING_ALLOWED=NO`, and iOS is only ever addressed through the `iphonesimulator`
SDK — never a device. Swift 6 language mode (`SWIFT_VERSION = 6.0`): the model types,
`FrequencyCatalogue`, `Session`, `Synthesizer` and `StereoBuffer` are `Sendable` value
types; `StereoOscillator` is intentionally left un-`Sendable` rather than annotated
`@unchecked Sendable`.

```
cd apple && xcodegen generate
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Binaural.xcodeproj -scheme Binaural -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Binaural.xcodeproj -scheme Binaural-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

**Known environment limit:** the iOS command uses `generic/platform=iOS Simulator`
instead of `name=iPhone 17`, because no simulator *runtime* is installed here —
`xcrun simctl list runtimes` prints nothing and `simctl list devices available` lists no
devices, so a named destination cannot resolve and nothing can be booted. The
`iphonesimulator` SDK (27.0) is present, so the app compiles, links and embeds the JSON
for the simulator. `xcodebuild -downloadPlatform iOS` turns this into a run-on-simulator
check; no other change is needed. Adding `iOS` to the test target's
`supportedDestinations` is a one-line spec change for whoever has a runtime.
---

# Part II — M2

> **Progress.** §7 is M2-a. §9 is M2-b item 1 (the timer). Items 2–5 are appended below
> as they land; nothing above this line has been rewritten.

## 7. M2-a: live audio, i18n, main window

### 7.1 What landed

```
Sources/Core/
├── AudioEngine.swift          # AVAudioEngine + AVAudioSourceNode, RenderParameters,
│                              # ParameterMailbox, AudioRenderContext, AudioFailure
├── FrequencyGrid.swift        # 1–20000 Hz, 0.1 step, slider mapping, frequency text
├── L10n.swift                 # LanguageCode, PreferenceStore, L10n
├── SessionStore.swift         # where the session document lives (see §7.5)
├── Locales/
│   ├── RussianCatalogue.swift     # generated from src/binaural/locales/ru.py
│   └── RussianWindowAdditions.swift  # the one key ru.py does not have yet
└── StereoOscillator.swift     # + render(frames:into:intoRight:) — see §7.2
Sources/macOS/
├── BinauralMacApp.swift       # @main, delegate, menu bar, View → Language
├── MainWindowController.swift # §7 window + MainWindow (Space / ↑↓ / ←→)
├── FrequencyControlView.swift # one ear: caption, display, exact field, log slider
├── BeatDisplayView.swift      # BEAT / CARRIER + the §F1 hint
└── HeadphoneIndicatorView.swift
Tools/generate_russian_catalogue.py   # regenerates the catalogue from ru.py
Tests/CoreTests/               # + L10nTests, L10nKeysTests, AudioEngineTests,
                               #   FrequencyGridTests, SessionStoreTests,
                               #   StereoOscillatorBufferTests  → 148 tests
Tests/MacTests/                # BinauralMacTests — 21 window tests, new target
```

`148 + 21 = 169` tests, of which the 73 M1 parity tests are a strict subset.

### 7.2 The audio thread handover — the design and why it is correct

**The problem.** The main thread mutates frequencies, gain, pan and the sample rate while
`AVAudioEngine`'s render callback reads them. `StereoOscillator` is deliberately non-`Sendable`
(M1) and CONTRACT rule 5 forbids reaching into it from elsewhere, so something has to carry
those four values across.

**The mechanism.** Two pieces, and only two:

1. `RenderParameters` — a `Sendable` value type of `Double`/`Int`. Nothing else crosses.
2. `ParameterMailbox` — one writer (main), one reader (audio), guarded by a single
   `NSLock` used with **`lock.try()`**, a non-blocking try.

**Why it is correct.**

* The reader copies the *whole struct* while holding the lock, so it can never observe a
  half-updated pair of frequencies. No torn read, no version counter, no ABA problem.
* If the try fails the callback does **not** block and does **not** spin: it renders the
  previous block's parameters. The failure window is the few nanoseconds `publish` spends
  copying 32 bytes, so the cost is at most one stale block (~5 ms at 512 frames/44.1 kHz)
  on the rarest interleaving. Blocking the real-time thread instead is how you get a
  dropout, which is far worse than one block of a parameter arriving late.
* The lock is `NSLock`, documented thread-safe, so `Sendable` is *derived* rather than
  asserted — the only `@unchecked Sendable` in the file is `ParameterMailbox`'s own
  storage claim, and its comment carries the memory-safety argument. `StereoOscillator`
  stays un-`Sendable` and un-annotated.

**Where the oscillator lives.** `AudioRenderContext` is the render block's captured state,
and it **creates the `StereoOscillator` itself, on first use — which is the audio thread.**
`init` takes no oscillator, so no reference can be smuggled in from the main thread. Every
read and write of the oscillator therefore happens on one thread, and `AVAudioEngine` never
runs a node's render block concurrently. `AudioRenderContext` is `@unchecked Sendable`
purely so a `@Sendable` block can capture it, and its comment explains exactly that.

**The allocation rule.** `render(frames:)` allocates two arrays per call, which is fine for
tests and offline rendering but not for a real-time thread. M2 adds
`render(frames:into:intoRight:)` — same maths, same state, writes into caller-owned
storage. `render(frames:)` now delegates to it, so there is **one** implementation and the
73 M1 tests still prove what the audio thread actually runs
(`StereoOscillatorBufferTests.testBufferRenderMatchesTheArrayRender` pins the equality).
`AudioRenderContext` keeps one pair of scratch buffers and grows them only when a larger
block arrives.

**No AppKit, no long locks.** The render block touches nothing but the context, the mailbox
and its own scratch memory. The gain is applied by the oscillator, not by scaling buffers.

### 7.3 Click-free play/stop and frequency changes

Both go through the M1 accumulating fade, never a jump:

* **Frequency change** → `setFrequencies`, which never resets phase. `testFrequencyChangeKeepsPhaseContinuous`
  checks the sample either side of the seam against the tone's own slew.
* **Play** → the published gain goes 0 → `volume`; the oscillator ramps it in over
  `BeatMath.defaultRampSeconds` (30 ms, inside SPEC F2's 20–50 ms).
* **Stop** → the published gain goes to 0 and the engine **keeps running**, so the tail
  fades out instead of being cut. Tearing the engine down and re-creating the oscillator
  would restart the phase from zero — precisely the discontinuity F2 rules out.
  `shutdown()` (on quit) is what actually detaches the node.
* **Mute** → the gain target, same path. It is deliberately *not* session state: `Session`
  has no such field and none was invented.

### 7.4 i18n

`L10n.tr(_:_:)` in `Sources/Core`, main-actor isolated (it is UI state; only the UI reads
it). English is the source language and has **no table**, which is how "a missing EN key
returns the key itself" is structural rather than a check someone has to remember.

* `RussianCatalogue.swift` is **generated** from `src/binaural/locales/ru.py` by
  `Tools/generate_russian_catalogue.py`, which parses the Python AST (so implicit string
  concatenation is resolved exactly as `i18n.tr` sees it) and keeps ru.py's order and
  section comments. **171 keys**, asserted by count. Never hand-edit it.
* `RussianWindowAdditions.swift` holds `{"Mute": "Без звука"}` — the one key the Swift
  window needs that `ru.py` does not have, because `main_window.py` has no mute button.
  Two dictionaries rather than one so the generated file stays byte-identical to a
  regeneration; `L10n.tr` tries the additions first, then the port, then the key.
* Language persists in `UserDefaults` under `ui/language` — the same key Python uses in
  `QSettings`. First run falls back to the system locale, then English
  (`resolveInitialLanguage(locale:)`).
* Switchable live: `setLanguage` posts `L10n.languageDidChange`; the window and the menu
  bar re-read their captions through it. No relaunch.

**The parity test** mirrors `tests/test_i18n.py` and closes the loop in both directions:
`L10nKeysTests` scans `Sources/**/*.swift` for every literal that reaches `tr(`, plus the
`AudioFailure` keys (which are named constants, the `_ERROR_SOURCES` rule), and fails if a
literal is not on the referenced-key list *or* if a listed key is referenced nowhere. An
untranslated string cannot be added quietly.

### 7.5 Session storage — the M2 decision DESIGN §5.1 left open

**`~/Library/Application Support/app.binaural.mac/session.json`**, written atomically.

*Why not `UserDefaults`:* the session is a **document**, not a preference. CONTRACT §7 pins
its fields and their clamps, it grows (presets, timer), and it is the thing a future
export/import would move. `UserDefaults` is for small preferences whose storage format the
app should not depend on, and it would mean a second on-disk shape next to the documented
JSON one. Application Support is the documented macOS home for exactly this: backed up,
not synced, not cluttering `~`.

*Why not the QSettings ini Python uses:* Swift has no QSettings and Core must stay
platform-independent, so `Session` stays `Codable` (M1 deviation 1, unchanged). Only the
location is decided here.

Reads never throw: a missing or damaged file yields `Session.standard`, per CONTRACT §7.
Writes return `Bool` — persistence is a convenience, never a blocker.

### 7.6 The main window (SPEC §7)

Two `FrequencyControlView`s that share nothing, so changing one cannot move the other
(`testChangingOneChannelLeavesTheOtherAlone`). Each is caption + large display +
exact-entry field + logarithmic slider; all the value rules live in `FrequencyGrid`, so they
are testable without AppKit. `BeatDisplayView` recomputes `|fL − fR|` and `(fL + fR) / 2` on
every change and shows the §F1 hint outside 0.5–100 Hz. Transport row: Play/Stop, volume,
mute. `HeadphoneIndicatorView` is always visible.

**Keyboard.** `MainWindow.performKeyEquivalent` handles Space, `↑`/`↓` (nudge the active
channel by 0.1 Hz) and `←`/`→` (switch channel) — *in the window*, not as menu key
equivalents, because a menu item cannot promise that a focused text field keeps the same
keys, which is what SPEC §7.2 requires. The window defers to `NSTextInput` for Space and to
`NSSlider` for the arrows.

**`FrequencyGrid.quantized` uses `%.1f`, not `(hz * 10).rounded() / 10`.** The
multiplication shortcut disagrees with CPython on ties, and ties are common here: every
`x.x5` value is one, and `4.35 * 10` lands one ulp above the halfway point, so it rounds to
4.4 where `round(4.35, 1)` says 4.3. `%.1f` prints the correctly rounded decimal form of
the double — the same thing CPython computes. Verified equal on 50 000 random values and on
all 57 144 `x.x5` ties in 1–20000 Hz; `FrequencyGridTests` pins the representative cases.
The format allocates, which is why it is never on the audio thread.

### 7.7 Testing notes

* `AudioEngineTests` drives `AudioRenderContext` directly with hand-built `AudioBufferList`s
  (planar, interleaved, mono, surround) — hermetic, no device, no sound. `AudioBufferList`
  ends in a flexible trailing array, so the fixture allocates by buffer count; an
  `AVAudioPCMBuffer` cannot express the 4-channel planar case.
* The two tests that touch a real `AVAudioEngine` **skip** when there is no device, and the
  sample-rate test releases its probe engine before starting the one under test — two live
  engines contend over the HAL and the second one to start stalls the test host.
* `BinauralMacTests` is a new target: `BinauralMacTests` runs *inside* the app
  (`TEST_HOST`), so `AppDelegate` detects XCTest and does nothing — otherwise the delegate
  would put a real window on screen during the run, where a stray event reaches a slider and
  **writes to the user's own session file**. Found the hard way; the guard is a test now
  (`testSavingAnUnwritableStoreDoesNotBreakTheWindow` and the session round-trip tests all
  use a temporary directory).

### 7.8 Deviations recorded in M2-a

1. **`StereoOscillator.render(frames:)` allocates.** CONTRACT §1 says render is "called
   only from the audio stream, without allocations in the hot loop". The M1 signature
   returns `[Float]`, so it must allocate; Python's `readData` has the same shape. Fixed by
   *adding* `render(frames:into:intoRight:)`, which is allocation-free and which the M1
   method now delegates to — one implementation, both callers, no behavioural change and no
   divergence the tests could miss.
2. **`AudioRenderContext` is `@unchecked Sendable`.** The only such annotation among the new
   types, and it is there so a `@Sendable` render block can capture the context. The
   argument is in its doc comment: the oscillator is created on the audio thread and touched
   only there, so no other thread can observe it. `StereoOscillator` itself remains
   un-`Sendable`, as M1 intended.
3. **`ParameterMailbox` is `@unchecked Sendable`.** It holds an `NSLock` plus a
   `RenderParameters` value; the lock is documented thread-safe and the payload is a value
   type, so the annotation restates a fact the compiler cannot see through the class
   boundary. Its doc comment carries the same argument.
4. **`Mute` is a Swift-only catalogue key.** SPEC F2 requires mute; `ru.py` has no such key
   because `main_window.py` has no mute button. Recorded in
   `RussianWindowAdditions.swift` rather than by editing the generated file.
5. **`FrequencyGrid.quantized` is `%.1f`-based, not multiply-based.** Not a divergence from
   Python — it is the *fix* that makes it match Python where a naive port would not (§7.6).

### 7.9 What M2-a does NOT do (all M2-b)

Presets (SPEC F3), the frequency reference dialog (§6), the headphone check and the
perceptual L/R test (§4, `audio/platform/macos.py` + `audio/headphones.py`), Settings,
About, the timer (F5), the menu-bar item, and the Release build. The seams they need are
in place and named:

| M2-b piece | Where it attaches |
|---|---|
| Presets | `Session.presetCategory`, `AudioEngine.setFrequencies`, the window's spare row |
| Headphone check | `MainWindowController.setHeadphoneState(_:deviceName:)`, `AudioEngine.setPan(left:right:)` |
| Reference dialog | `FrequencyCatalogue` — unchanged since M1 |
| Timer | `Session.timerMinutes`; a smooth stop is `engine.stop()`, which already fades |
| Menu bar | `TrayController`'s Python counterpart |
| Language in Settings | `L10n.setLanguage(_:)` — already live from the menu |

The headphone indicator shows **"Unknown device"** until M2-b supplies detection: it is the
honest state for "nothing has looked at the device yet", it is what the Python window
starts with, and the indicator is never hidden.

## 9. M2-b item 1: the playback timer (SPEC §5 F5)

`TimerControlView` existed from M2-b's groundwork but nothing instantiated it. The row now
sits under the transport, and the three data rules of F5 are the **session's**, not the
view's: the offered durations are `Session.timerChoices` verbatim (`0` first, captioned
`Off`, every other one `N min`), the default is `Session.defaultTimerMinutes` = 15, and
`0` means "play until stopped" — which is why an off timer hides the countdown instead of
reading `00:00`, and why `PlaybackTimer.remaining(at:)` is `infinity` rather than `0` for it.

**The countdown is text, not a ring or a bar.** SPEC §7.2 requires reduced-motion to be
respected, and a `NSTextField` is the one representation that needs no animation at all:
nothing pulses, so "reduce motion" is satisfied by there being no motion to reduce. The
label uses `monospacedDigitSystemFont`, so the digits do not shuffle sideways once a
second.

**The tick is one second, in `.common` run loop mode.** A timer registered only in the
default mode stops firing the moment the user opens a menu — which is exactly how they
change the duration. `.common` includes `NSEventTrackingRunLoopMode`, so the countdown
keeps running while a menu is open.

**Expiry is the same fade as the Stop button.** `MainWindowController.stopPlayback()` is
the single place playback ends — the button, `Space` and the timer all call it — so
expiry cannot grow its own cut-off. `AudioEngine.stop()` publishes a gain of **zero with
the ramp**, which is F5's «плавное затухание, чтобы остановка не была щелчком» and
§2.1's smooth end of session: the amplitude slides to silence over
`BeatMath.defaultRampSeconds` (30 ms, inside F2's 20–50 ms band) while the engine keeps
running, so the tail fades and the phase survives for the next play.
`testExpiryStopsPlaybackThroughTheFade` asserts both halves — that playback stopped, and
that the *published* `RenderParameters` carry `gain == 0` **and** `rampSeconds > 0`,
because a stop that ramps is a fade and a step would click. It skips where there is no
output device.

**Testability without waiting.** `tickTimer(at:)` and `armTimer(at:)` take the clock as a
parameter, so a 15-minute countdown and its expiry are exercised in microseconds; only the
engine-starting test needs real hardware.

**Session.** `currentSession.timerMinutes` now reads `timerView.selectedMinutes` rather
than the stored value, so picking a duration is persisted like any other control
(`testTimerChoiceIsSavedForTheNextLaunch`). A stored value that is in range but not on the
offer list (`Session` clamps to 0…1440, the popup offers ten durations) selects the
nearest offered one — the number is clamped by the session, the control shows what can be
clicked.

### 9.1 i18n parity, closed in both directions (this was incomplete)

`L10nKeysTests` documented two tests — `testEveryTrStringIsCoveredHere` and
`testEveryListedKeyIsUsed` — that **did not exist**. The scan helpers were present and
unused, so a new `tr("…")` key could have been added without a Russian translation and the
suite would still have been green. Both tests now exist and the referenced-key list is
complete for every key in `Sources/`.

Making them work needed two fixes to the scan itself, because it disagreed with the
compiler:

* **Joined string literals.** `ReferenceDialogController` writes a long caption over two
  lines with `"… " + "…"`. The compiler makes that one key; the old scan reported two
  fragments, neither of which is in `ru.py`, so both directions of the check failed on
  correct code. The scan now joins a run of literals — with whitespace, or with `+` —
  the way the compiler does.
* **The `named:` overload.** `tr(key, named: ["label": …])` has dictionary *keys* as
  literals after the label. The scan now cuts the argument list there, so `"label"` is not
  mistaken for a catalogue key.

**`AboutContent` moved from `Sources/macOS` into `BinauralCore`.** The About/disclaimer
wording is the one text SPEC §6.13 requires in two places, and `BinauralCoreTests` has to
check it against `ru.py` — which it can only do from inside Core. It has no AppKit: three
strings, the licence holder, and `L10n.tr`. It is now `public enum AboutContent` in
`Sources/Core/AboutContent.swift`, with `AboutContentText` as its translated view. Its
`namedKeys` list joins `AudioFailure.all` in the scan, so a named constant is no longer a
way around the catalogue.

**`RussianWindowAdditions` grew from one entry to eight** (`Timer`, `Off`, `%1 min`,
`Settings`, the macOS-only tagline, the macOS version line, the status-item tooltip and
the earlier `Mute`). Each is a key `ru.py` has no call site for. The M2-a test pinned the
dictionary literally (`["Mute": "Без звука"]`), which meant editing a test on every
milestone; it now asserts the *rules* instead — few entries, each really translated
(Cyrillic), each really referenced by a source (`testEveryAdditionsKeyIsReferenced`) —
which is the property the hard-coded copy was standing in for.

**The licence notice is `about.py::LICENSE_SUMMARY_EN` verbatim**, not the full MIT text.
Python's catalogue keys the abbreviated form, so a full-text key would have produced an
English licence paragraph inside a Russian dialog. Recorded here because the shorter text
is a choice, and the next reader will wonder.

## 10. M2-b item 2: the headphone check at launch (SPEC §4)

Three pieces, in the order Python has them:

| File | Role | Python counterpart |
|---|---|---|
| `Sources/Core/LRTonePlayer.swift` | plays the §4.2 tones over the existing `setPan` hook | `LrTestSequence`'s engine half |
| `Sources/macOS/LRTestDialogController.swift` | the §4.2 dialog — owns the question | `ui/dialogs/lr_test.py` |
| `Sources/macOS/HeadphoneCheckDialogController.swift` | the §4.3 dialog — explain and allow continuing | `ui/dialogs/headphone_check.py` |
| `Sources/macOS/HeadphoneCheckCoordinator.swift` | the launch sequence itself | `app.py::_run_headphone_check` |

**The launch sequence.** Detect → if the heuristic is sure and says headphones, do nothing
else → if it is *unsure* (`.unknown`, `.virtual`, or `low` confidence), run the perceptual
L/R test **first** and open the §4.3 dialog on its answer → otherwise, if headphones are
not confirmed and the user has not acknowledged the warning yet, open the §4.3 dialog →
store `channelsSwapped` and `headphoneCheckAcknowledged`.

**Detection runs on every start; the dialog does not.** SPEC §4.3 wants the warning visible
and repeatable, and §4's own text says the check is "обязательный этап". Re-reading two
CoreAudio properties per launch costs nothing and catches the user plugging in headphones
yesterday; a startup dialog on every launch is exactly the nag §4.3 refuses to be. So the
indicator always follows the fresh verdict ("Speakers detected" stays on screen for as long
as it is true) while the *dialog* only appears until the user has acknowledged it once.

**Only the generator swaps.** `HeadphoneDetector.swapChannels` is applied where the
frequencies are handed to the engine, so the window keeps displaying the pair the user
typed and the session keeps the **unswapped** numbers. A stored session therefore means the
same thing on any machine, and the swap is a property of the output, not of the document.
A stored swap is honoured on the very first push after launch, not only after an edit.

**The test tone is the same graph, not a second one.** `LRTonePlayer` puts both oscillators
on 440 Hz, hard-pans one side, and starts the engine if it was not running; `silenceTestTone`
puts the previous frequencies, the previous pan and the previous play state back. Tearing
the graph down to play a test tone would restart the phase — the discontinuity F2 rules out
— and stopping a session that was already playing because the user answered a question
would be worse than anything the test does. `AudioEngine` gained two **read-only**
accessors (`currentFrequencies`, `currentPan`) so the player can restore what was there;
no setter, so there is still exactly one writer per value.

### 10.1 What it took to make the check runnable at all

Three things had to be true before the dialog could appear, and each was found by running
the app rather than by reading the code:

1. **The coordinator's target was a `weak var` with no owner.** `HeadphoneTarget` was built
   inline and released immediately, so `guard let target` failed and the whole check
   silently did nothing — a green build, an indicator that never left "Unknown device". The
   window now owns the target; the coordinator holds it weakly so a menu item cannot keep a
   closed window alive.
2. **`NSApp.runModal(for:)` does not unwind when its window closes.** The dialog vanished on
   "Continue anyway" and the nested event loop kept spinning, so nothing after the presenter
   ever ran: no `apply`, no persistence. Every dialog now ends with
   `NSWindowController.endModalSessionAndClose()`, which calls `NSApp.stopModal(withCode:)`
   — the documented way — and is a plain `close()` when there is no modal session, so the
   same button handler works in a test.
3. **Two launch crashes**, both pre-existing and both now fixed and pinned: see the commit
   `apple/: fix two crashes that made the app unusable at launch`. In short — a SIGBUS in
   `deviceIDs()` from `withUnsafeMutableBytes(of:)` on this toolchain, and a SIGTRAP because
   the `AVAudioSourceNode` render block inherited `@MainActor` isolation from `start()`.
   The second one is the more interesting: it means M2-a's thread handover had a runtime
   isolation check in the render block, which is exactly what §7.2 says must not be there.

### 10.2 Testing the launch sequence

`NSApp.runModal` never returns on its own, so `Presenting` is a protocol and the tests
inject a `ScriptedPresenter` that acknowledges the §4.3 dialog and answers the §4.2 dialog
from a script. The **branches** are therefore tested hermetically — unsure → ask; speakers →
warn; confident headphones → do not ask; swap → stored — while the real `ModalPresenter`
stays a three-line `runModal` call. The presentation itself was verified by driving the
running app: launch → the §4.3 dialog with the SPEC wording → *Continue anyway* → the
indicator switches to "Speakers detected" and `session.json` gains
`headphone_check_acknowledged: true` → relaunch shows no dialog and still detects.

### 10.3 Deviations

1. **Python repeats the dialog at every start** (`app.py` shows it unconditionally;
   §4.3's own comment says "the check must not be repeated on every start", which its code
   contradicts). Swift follows the comment and SPEC §4.3's intent: detect every launch, warn
   once. Flagged for the coordinator — if the repeated dialog was deliberate, it belongs in
   Python, not here.
2. **`&Check headphones…` is `Ctrl+Shift+H` and the reference is `Cmd+O`**, as in Python.
   `NSMenuItem.keyEquivalentModifierMask` is explicit because the default is Command-only.
3. **The window carries its own "Check headphones…" button** (SPEC §7 asks for it; Python
   only has the menu item), and it goes through the same coordinator, so there is one check.

## 11. M2-b item 3: the Settings dialog (SPEC §7)

`Sources/macOS/SettingsDialogController.swift`. Python has **no settings layer at all**, so
this is not a port: the four things SPEC §7's dialog list names are the four rows —
language, headphone check, timer, volume — and nothing else was invented.

**No OK button, because there is nothing to apply.** Every control writes through to the
live window:

| Row | Writes to | Live effect |
|---|---|---|
| Language | `L10n.setLanguage` — the *same* call the *View → Language* menu makes | the whole app, including the open dialog (§7.4) |
| Timer | `MainWindowController.selectTimerMinutes` | a running session re-arms with the new duration |
| Volume | `MainWindowController.setVolume` | the engine's gain; persisted by the window's own save |
| Headphone check | `HeadphoneCheckCoordinator.rerunFromUser` | the §4.3 dialog, then the verdict comes back into the row |

**The window builds its own Settings dialog** (`makeSettingsDialog()`), rather than the app
delegate wiring four closures. The wiring is then in exactly one place, so the menu item
and a test cannot end up with a dialog whose sliders move nothing — which is precisely the
bug the first version of the test had, and which the factory made impossible. `Presenting`
and `NSWindowController.endModalSessionAndClose` moved out of the coordinator into
`DialogPresentation.swift`: by now three dialogs need both halves of modality, and
"present" and "end" living in one file is what keeps them paired.

**Cancel restores the language.** With no OK button there is no commit, so closing the
dialog after switching the language would otherwise leave a silent, permanent change. The
dialog remembers the language it opened with and puts it back on `cancel()`; the unit test
pins that.

**The timer popup offers `Session.timerChoices`**, exactly as the main window does — a
settings dialog offering a different set of durations would be a second source of truth for
a value that already has one. Out-of-range stored values snap to the nearest offered one, as
in §9.

**Placed in the application menu with `Cmd-,`**, which is where macOS puts it; Python has
no menu for it because it has no dialog.

## 12. M2-b item 4: About and the §6.13 disclaimer

`Sources/macOS/AboutDialogController.swift` plus `Sources/Core/AboutContent.swift`.
`Help → About` (Ctrl+Shift+I, as in Python) opens it.

**The disclaimer is one constant, shown in two places.** SPEC §6.13 requires the text in the
app *and* in the README, so `AboutContent.disclaimerEnglish` is the single source and both
the About dialog and the frequency reference read it. The English string is **byte-identical
to `about.py::DISCLAIMER_EN`**, verified mechanically, and it is a key of the shared
catalogue — so the Russian comes from `ru.py` and the two implementations cannot say
different things about a medical disclaimer.

`AboutContent` lives in `BinauralCore` (not in the app target) precisely so
`BinauralCoreTests` can check that key against the catalogue; see §9.1.

**The tests are about the wording, not the widget.** `AboutTests` asserts that every clause
SPEC §6.13 names is still present — "not a medical device", "diagnosis, treatment or
prevention", epilepsy, pacemaker, pregnancy, photosensitive, consulting a doctor, volume —
and that the text promises nothing: a banned-claim list (cures, heals, treats, improves,
guarantees, proven, safe for) that fails if a sentence is ever added. Dropping the pacemaker
line and inventing a health benefit both break the suite by name.

**Rebuilt, not patched.** `retranslate()` rebuilds the whole body: a dialog holds no state
worth preserving, and rebuilding is the only version that cannot leave one label in the
previous language. The dialog also observes `L10n.languageDidChange`, so a switch from the
*View* menu reaches it while it is open — the same choice Settings makes.

**Two bugs the About tests found, both in pre-existing code:**

* `document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)` was
  activated **before** `scrollView.documentView = document`, i.e. between two views with no
  common ancestor — illegal, and it raises `NSGenericException` rather than merely warning.
  **The reference dialog had the same bug** (`ReferenceDialogController`), so both were
  fixed: hand the document over first, then constrain.
* `visibleLines` collected `NSTextField`s only, so the project link — an `NSButton` — was
  invisible to the assertion that it is shown.

### 12.1 SPEC finding: the Russian disclaimer is a paraphrase, not verbatim

SPEC §6.13 reads:

> Эти частоты и описания **эффектов** происходят из **исследований**, а также из эзотерических,
> энергетических и альтернативных практик. **Приложение** не является медицинским изделием и
> **не предназначено** для диагностики, лечения или профилактики заболеваний.
> Не используйте при эпилепсии, кардиостимуляторе, во время беременности и при повышенной
> светочувствительности без консультации врача. Не превышайте громкость.

`ru.py` ships:

> Эти частоты и описания **их** эффектов происходят из **исследовательской литературы**, …
> **Это** приложение не является медицинским изделием … диагностики, лечения **или**
> профилактики заболеваний. Не используйте **его** при эпилепсии **или** кардиостимуляторе, …
> **а также** при повышенной светочувствительности … **Не превышайте разумную громкость.**

All five substantive clauses survive; **no claim is added and none is removed**, and the
only semantic change is the added qualifier «разумную» / "reasonable". This app shows the
catalogue text — the same one Python shows — because two implementations of one product
must not disagree about a disclaimer, and because the coordinator owns `src/` and `docs/`.
For the coordinator: either `ru.py` should be brought to the SPEC wording, or SPEC §6.13
should state that the catalogue wording is the canonical one.

## 13. M2-b item 5: the menu-bar status item

`Sources/macOS/StatusItemController.swift` — the Swift counterpart of Python's
`TrayController` (`src/binaural/ui/tray.py`). Installed from launch, by the app delegate,
right after the window is on screen.

**The role is remote control.** The window can be hidden while the tone keeps playing, so
what the window offers has to stay reachable. M2.md §9 asks for show/hide and Quit; Python's
tray also carries Play/Stop, the headphone check and the frequency reference, and so does
this one — a closed window must not take the app's controls with it. Every action asks the
window or the coordinator; **the tray never touches the audio engine**, which is Python's
"the window stays the single source of truth" rule.

**The icon is an SF Symbol** (`waveform`, a template image), not artwork: nothing to ship,
nothing to tint by hand, and it follows light/dark for free. SPEC §7.3 asks for SVG rather
than emoji in the interface; a system symbol is the native form of that idea.

**The captions are already in `ru.py`** — "Show Binaural", "Hide Binaural", "Frequency
reference…" and both tooltips (`⏹ %1 / %2 Hz`, `▶ %1 / %2 Hz — beat %3 Hz`) were written
for the Python tray, so **no new Russian was needed** for this item. The tooltip shows the
window's own numbers, pushed out through `MainWindowController.setStatusItemHandler` — a
second copy of the frequencies in the tray would be a second source of truth.

### 13.1 What the tray required of the window

Three changes, all of them the tray's price of admission:

1. **`isReleasedWhenClosed = false`.** Otherwise `close()` destroys the window and the item's
   *Show* has nothing to show.
2. **A close hides instead of closing.** `windowShouldClose` answers `false` and the app
   delegate turns the close into an `orderOut`. The window keeps the session state, the
   running countdown and the engine's view of the world — all three must survive the window
   being out of sight.
3. **`applicationShouldTerminateAfterLastWindowClosed` returns `false`** *when the item is
   installed*, which is Python's `app.setQuitOnLastWindowClosed(False)` decision. Without a
   status item it still returns `true`, so a build that failed to install one quits normally
   rather than becoming an invisible background process. The two "terminate" questions are
   written next to each other on purpose: *closing the last window is not quitting; asking
   to quit is quitting* — so `applicationShouldTerminate` is stated explicitly as well.

**Verified live, not only in tests:** launch → the item installs (`hasStatusItem == true`
traced at `applicationDidFinishLaunching`) → the window is closed → the process is still
running with no window, which is only possible because the item exists.

### 13.2 Testing a status item

`NSStatusBar` needs a real login session, so the tests do **not** install an item. They
drive the two halves separately: `buildMenu()` (captions, translation, routing, and a
no-handler no-op) with no status bar at all, and the *window contract* the tray depends on
(hide survives, close does not destroy, the transport is published). The install itself was
verified by launching the app. Python's "never fatal" rule is why this split is honest rather
than convenient: `isInstalled` is false until `install()`, and every action is a no-op
without a handler.

## 14. M2-b item 6: the preset bar in the window (SPEC §5 F3)

`PresetBarView` existed and had been reviewed, but nothing ever instantiated it — the
grep `PresetBarView` outside its own file returned nothing, so SPEC §7's preset row was
a drawing in a design document rather than part of the app. This item puts it in
`MainWindowController`, and adds the tests that make "it is in the window" a checked fact
rather than an assumption.

### 14.1 `PresetCatalogue` already implemented F3 — verified, not rewritten

The registry was checked against the F3 table as corrected in `f474189` before anything
was wired, and it was already correct: seven categories in table order, 20 presets, every
beat inside 1–30 Hz, every beat in exactly one half-open band, no Gamma, `relaxation` as
the default matching `Session.defaultPresetCategory`, and `<band> <beat>` labels in both
languages from `BrainwaveBand.name(for:)`. **Nothing in the registry needed fixing.**
What was missing was any *test* of it, so `PresetCatalogueTests` now states F3's rules as
assertions — 20 presets, the whole F3 table transcribed, exactly-one-band for each of the
20, the half-open endpoints (4 → Theta, 8 → Alpha, 13 → Beta, 30 → Gamma, 100.1 → none),
and `frequencies(for:)` landing on the beat and the carrier for every entry.

### 14.2 Where the bar sits, and the window had to grow

SPEC §7's ASCII sketch puts the chips on the last row of the window, below a stretch —
Python's `addStretch(1)` then `_build_presets()`. So the bar is a vertical block after
the timer row: `PresetBarView` (categories, then presets) plus one transient status
label, and nothing was added to the transport row, which §7 defines as Play, volume,
mute.

Adding a row of 44 px targets to a window whose content already fills 600 pt means the
default frame had to change: `contentRect` 760×**780** and `minSize` 720×**700**. The
stack hugs the top and only bounds the bottom with `lessThanOrEqualTo`, so a window
smaller than the content would have pushed the preset chips off-screen — hence the
minimum rather than leaving 540.

### 14.3 Category is state, preset is a pair of frequencies

Two levels, two different jobs, and the code keeps them apart:

* **A category chip** changes what is *offered*. It writes `presetCategoryID` and asks for
  a save — that is all. `currentSession` reads the field, and `restoreSession()` feeds
  the stored value back to the chips through `PresetCatalogue.resolvedCategoryID`, so a
  hand-edited `preset_category` degrades to `relaxation` for the UI while the document
  keeps whatever it said (CONTRACT §7 allows a free string on the way in).
* **A preset click** sets **both** controls with `notify: false` and then calls
  `frequenciesChanged()` once. `notify: false` on both matters: the controls push on every
  notified change, so notifying each in turn would push an intermediate state in which the
  beat is half the preset's. The pair comes from `PresetCatalogue.frequencies(for:)`
  (`BeatMath.pair(fromBeat:carrier:)` around the 200 Hz default carrier) — the same
  arithmetic the reference dialog uses.

`Session.lastPreset` now carries the **preset id** (`relaxation-10`) rather than Python's
display label. The id is stable across a language switch and across a re-translation,
which is what makes the chip come back highlighted on the next launch; a localised label
would not survive being stored in one language and read in another. This is a deviation
from Python's `apply_preset`, which stores `PRESETS[index][0]`.

### 14.4 "Shows what it did"

F3 asks the control to show the outcome. Two things do, and they do not duplicate the
beat card: the applied chip stays highlighted, and a status line below the bar says
`Preset applied: difference 9 Hz` for three seconds — Python's
`statusBar().showMessage(…, 3000)` with the same catalogue key (already in `ru.py`, so
no new Russian). It is re-translated on a language switch while visible, and `tearDown()`
invalidates its timer.

### 14.5 The preset row rendered empty — a bug the captions could not see

Wiring the bar in was not enough; launching it was. The category chips appeared and the
**preset** row was blank, and every caption-based test passed, because the failing part was
not which chips existed but which ones were *arranged* into the row. Two independent
causes, both invisible from `presetButtons`:

1. **`lastWrapWidth` was one value for the whole view.** `layoutRows` skips the rebuild when
   the width has not moved, and the category row — laid out first at the same width — had
   already stored it. The preset row's call was therefore always a no-op. It is now a
   dictionary keyed by the row.
2. **`rebuildPresets` did not force a re-wrap.** Even with per-row state, "same width" is
   the right answer for `layout()` and the wrong one for a rebuild: the chips are new
   objects. Both rebuilds now clear the column and invalidate the stored width first.

The wrapping was also rebuilt while I was in there: `NSStackView` is horizontal *or*
vertical, so a "wrapping row" built from one horizontal stack could only squeeze its
chips, never break the line. Each level is now a vertical **column** of horizontal lines,
which is what `layout()`'s re-wrap actually needs.

The lesson is recorded because it generalises: `arrangedCategoryChipCount` /
`arrangedPresetChipCount` now exist so "the chips are on screen" is a number a test can
read, next to the captions that were right all along.

### 14.6 Tests

`PresetBarTests` drives the real `MainWindowController`: the bar is in the content view
and laid out (a zero-height bar is invisible, so the frame is asserted, not just
`isDescendant(of:)`); **both rows are checked for arranged chips, not just for existing
ones** (§14.5 — that is the assertion that caught the empty row); chips are in registry
order; every one of the 20 presets sets `200 ± beat/2`; the beat card follows; the category
and the applied preset survive a relaunch; changing a category moves no frequency; the
language switch swaps both languages' captions; and the wrapping itself is tested — seven
category chips wrap onto more than one line in a 560 pt window without losing any, and
unwrap again when the window is widened.

Clicks go through `PresetBarView.tapPreset(id:)` / `tapCategory(id:)`, which call the same
private `@objc` actions a mouse press reaches. That is deliberate: a test that called
`onPresetSelected` itself would pass while the button the user presses was wired to the
wrong selector.

One case is a test finding rather than a design choice. `testStoredPresetInAnotherCategoryIsNotHighlighted`
pins the rule that a stored preset from a category the bar is not showing is **not**
highlighted — showing it would require a chip that does not exist. It exists because the
naive version of the relaunch test ("apply a preset, relaunch, expect it highlighted")
passes only when the saved category happens to be the one containing the preset.

## 8. Build and verify (M2)

The M1 commands (§6) still hold, plus one:

```
cd apple && xcodegen generate
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test   # 190
xcodebuild -project Binaural.xcodeproj -scheme Binaural     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test   # +114 window tests
xcodebuild -project Binaural.xcodeproj -scheme Binaural     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Binaural.xcodeproj -scheme Binaural-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

**Smoke test** (a build that crashes on launch is not a passing build):

```
APP=$(find ~/Library/Developer/Xcode/DerivedData/Binaural-*/Build/Products/Debug -maxdepth 1 -name 'Binaural.app' | head -1)
open "$APP" && sleep 4 && pgrep -fl 'Binaural.app/Contents/MacOS' && pkill -f 'Binaural.app/Contents/MacOS'
```

The iOS command keeps `generic/platform=iOS Simulator` for the reason in §6: no runtime is
installed. iOS compiles, links and embeds the JSON; it never gates macOS.
