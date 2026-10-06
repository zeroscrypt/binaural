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

## 8. Build and verify (M2)

The M1 commands (§6) still hold, plus one:

```
cd apple && xcodegen generate
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test   # 167
xcodebuild -project Binaural.xcodeproj -scheme Binaural     -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test   # +31 window tests
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
