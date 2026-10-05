# apple/ — M1 design (the Swift foundation)

Status: **Milestone 1.** Foundation only — the parts that must be *provably* equal to
the Python implementation. UI is deliberately M2.

Read `docs/SPEC.md` (behaviour) and `docs/CONTRACT.md` (shared API) first. The Python
reference lives in `src/binaural/`; every number below was read out of it.

---

## 1. Layout and modules

```
apple/
├── project.yml          # xcodegen; generates apple/Binaural.xcodeproj (never committed)
├── DESIGN.md            # this file — the contract for M2
├── Sources/
│   ├── Core/            # BinauralCore.framework — no AppKit, no SwiftUI, no UIKit
│   │   ├── BeatMath.swift
│   │   ├── StereoOscillator.swift
│   │   ├── Synthesizer.swift
│   │   ├── FrequencyCatalogue.swift
│   │   └── Session.swift
│   ├── macOS/           # AppKit app target `Binaural`
│   └── iOS/             # SwiftUI app target `Binaural-iOS`
└── Tests/CoreTests/     # XCTest bundle `BinauralCoreTests` (macOS)
```

`BinauralCore` is a single **multiplatform** target (`supportedDestinations:
[macOS, iOS]`) so the two apps link the exact same binary code and the tests run
against the macOS slice of it.

### Responsibilities

| Module | Ported from | Responsibility |
|---|---|---|
| `BeatMath` | `core/oscillator.py` (constants + `pair_from_beat`) | beat/carrier arithmetic, audible-range validation |
| `StereoOscillator` | `core/oscillator.py::StereoOscillator` | block render with continuous phase and accumulating fade |
| `Synthesizer` | — (Python has no offline render) | render a whole `(beat, carrier, duration)` pair into two `Float` buffers |
| `FrequencyCatalogue` | `data/frequencies.py` | decode + index `frequencies.json`, lookups, search, validation |
| `Session` | `core/session.py` | the eight persisted fields, defaults, clamping, JSON load/save |

## 2. Swift types introduced in M1

```swift
// BeatMath.swift
public enum BeatMath {
    static let defaultCarrierHz = 200.0            // DEFAULT_CARRIER_HZ
    static let minFrequencyHz = 1.0               // MIN_FREQ_HZ
    static let maxFrequencyHz = 20000.0           // MAX_FREQ_HZ
    static let maxBeatHz = 100.0                  // MAX_BEAT_HZ
    static let recommendedBeatRangeHz = 0.5...100.0
    static let defaultRampSeconds = 0.03
    static let defaultSampleRate = 48000
    static func beatFrequency(leftHz:rightHz:) -> Double            // |fL - fR|
    static func carrierFrequency(leftHz:rightHz:) -> Double          // (fL + fR) / 2
    static func pair(fromBeat:carrier:) throws -> (left: Double, right: Double)
}
public enum FrequencyError: Error, Equatable { case notFinite, outOfRange, negativeBeat }

// StereoOscillator.swift — a class on purpose: mutable state owned by the thread
// that drives it. Deliberately NOT Sendable; there is no audio thread in M1.
public final class StereoOscillator {
    init(sampleRate: Int = 48000)
    var sampleRate: Int; var leftHz: Double; var rightHz: Double
    var phase: (left: Double, right: Double)      // fractions of a cycle, always 0..<1
    var gain: Double; var targetGain: Double
    func setFrequencies(leftHz:rightHz:) throws
    func setSampleRate(_:) throws
    func setFade(_ gain: Double, rampSeconds: Double = 0.03)
    func setPan(left:right:)                     // hard-pan, for the L/R test (M2)
    func render(frames: Int) -> (left: [Float], right: [Float])
}

// Synthesizer.swift — the only Sendable convenience type over the oscillator
public struct Synthesizer: Sendable {
    init(rampSeconds: Double = BeatMath.defaultRampSeconds)
    func render(beatHz: Double, carrierHz: Double = 200.0,
                duration: Double, sampleRate: Int = 48000) throws -> StereoBuffer
}
public struct StereoBuffer: Sendable, Equatable { let left: [Float]; let right: [Float] }

// FrequencyCatalogue.swift
public enum EvidenceLevel: String, CaseIterable, Codable, Sendable {
    case wellStudied = "well-studied", studied, reported, traditional
    case unknown                                // not in SPEC §6.2; badge ⚪ as in Python
    var badge: String                           // 🟢 🔵 🟡 🟣 ⚪
}
public struct FrequencyCategory: Sendable, Equatable, Codable  // id/order/icon/color/labelEn/Ru/descriptionEn/Ru
public struct FrequencyEntry: Sendable, Equatable              // CONTRACT §5, beats optional
public struct CategoryCount: Sendable, Equatable { let category: FrequencyCategory; let count: Int }
public enum CatalogueIssue: Sendable, Equatable { case duplicateID, unknownCategory, invalidEvidence,
                                                  badBeatValue, badRange, mixedBeatForms,
                                                  badCarrier, emptyText(String) }
public struct FrequencyCatalogue: Sendable, Equatable {
    init(contentsOf url: URL) throws
    static func load(bundle: Bundle = .main) throws -> FrequencyCatalogue
    var version: Int
    var categories: [FrequencyCategory]          // sorted by `order`
    var entries: [FrequencyEntry]                // ranges first, then beat, then id
    func entry(id: String) -> FrequencyEntry?
    func entries(inCategory: String) -> [FrequencyEntry]
    func categoriesWithCounts() -> [CategoryCount]
    func totalsByEvidence() -> [EvidenceLevel: Int]
    func search(_ query: String, category: String? = nil) -> [FrequencyEntry]
    func validate() -> [CatalogueIssue]
}

// Session.swift
public struct Session: Sendable, Equatable {
    var leftHz = 205.0; var rightHz = 215.0; var volume = 0.7
    var channelsSwapped = false; var headphoneCheckAcknowledged = false
    var lastPreset: String? = nil
    var timerMinutes = 15                       // DEFAULT_TIMER_MINUTES
    var presetCategory = "relaxation"
    static let timerOff = 0
    static let defaultTimerMinutes = 15
    static let maxTimerMinutes = 1440            // load-time clamp, as in Python
    static let timerChoices: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
    static let standard: Session                 // == Session(), the Python defaults
    func jsonData() throws -> Data
    func save(to url: URL) throws
    static func load(from url: URL) throws -> Session   // lenient; missing/bad key -> default
}
```

JSON keys are the Python field names verbatim (`left_hz`, `timer_minutes`,
`preset_category`, …) so one document shape is readable by both implementations.

## 3. How `frequencies.json` reaches the code

One file, one truth: `src/binaural/data/frequencies.json`. It is never copied into
`apple/` by hand.

* **App targets** (`Binaural`, `Binaural-iOS`) get it from an xcodegen Copy Files phase
  whose single entry points at `../src/binaural/data/frequencies.json`, i.e.
  `$(SRCROOT)/../src/binaural/data/frequencies.json`. It lands in the bundle as
  `frequencies.json` and is read with `FrequencyCatalogue.load(bundle: .main)`.
  In the spec this is a `sources` entry, not a `buildPhases` entry — xcodegen 2.46 has
  no `buildPhases` key and silently ignores it:
  ```yaml
  sources:
    - path: ../src/binaural/data/frequencies.json
      buildPhase:
        copyFiles:
          destination: resources
  ```
  Verified byte-for-byte identical to the source file in both bundles (same SHA-256).
* **Tests** never use the bundle. They rebuild the source path from `#filePath`
  (`Tests/CoreTests/X.swift` → up four levels → `src/binaural/data/frequencies.json`),
  so a failing count always reflects the file under edit.
* `BinauralCore` itself has **no** resources: the framework never bundles the JSON,
  which keeps the dependency direction right (app → framework → caller-supplied URL).

## 4. M1 vs M2

**In M1:** beat/carrier math with audible-range validation; the oscillator with
continuous phase and accumulating fade; `Synthesizer` offline render; the catalogue
(decode, index, lookup, search, validation, evidence totals); `Session` with Python
defaults, clamping and JSON round-trip; two launchable shells that show catalogue
and session facts; XCTest parity tests.

**Deferred to M2** (nothing above depends on it):
* real audio output — `AVAudioEngine`/`AudioUnit` render callback replacing the
  `Synthesizer` buffer with a live `render(frames:)` call (the oscillator API is
  already the right shape);
* headphone detection (`DeviceClass`, `AudioDevice`, heuristic + perceptual L/R test,
  `channels_swapped` handling) and `AudioEngine`;
* the real UI: two frequency fields, beat/carrier display, preset chips, reference
  browser, timer, volume, i18n (EN/RU) — `Session.timerMinutes`/`presetCategory`
  already exist to be driven by it;
* `WavWriter` / WAV export. **Checked, not assumed:** the Python side has no WAV
  writer — `grep -i wav` over `src/` finds only `frequencies.json` and Russian
  prose, and SPEC §F5 calls export "optional (P2)". There is therefore nothing to
  port and M1 invents no file format of its own;
* `main_window.PRESET_CATEGORIES` — the Swift side does **not** invent an enum for
  `presetCategory`, see §5;
* running `BinauralCoreTests` on the iOS simulator. `BinauralCore` is already
  multiplatform; the test target is macOS-only because this machine has **no iOS
  simulator runtime installed** (`xcrun simctl list runtimes` is empty), so nothing
  iOS-shaped can be executed or tested here. Adding `iOS` to the test target's
  `supportedDestinations` is a one-line spec change for whoever has a runtime.

## 5. Deviations from `docs/CONTRACT.md` (and why)

1. **§7 `Session` storage.** Python persists through `QSettings` under
   `session/<key>`. Swift has no QSettings and Core must stay platform-independent,
   so `Session` is `Codable` and M1 round-trips JSON at an explicit URL. Field
   names, defaults and the load-time clamps (`volume` → 0…1, `timer_minutes` →
   0…1440, missing key → default) are unchanged. Where the file *lives*
   (`UserDefaults` vs `~/Library/Application Support`) is an M2 decision.
2. **§5 evidence level.** Python keeps `evidence` as a raw `str` and badges anything
   outside the four known levels with ⚪. Swift models it as `EvidenceLevel` with an
   explicit `.unknown` case that carries that ⚪ badge, so leniency is preserved; only
   the unknown *string* itself is dropped, and nothing in Python's query paths reads it.
3. **§1 `render` returns `Float`.** The contract says "float32-like samples"; the
   Swift buffers are `[Float]` while all maths stays `Double`. Consequence for tests:
   Python asserts the closed-form sine at `abs=1e-12` (doubles), the Swift port
   asserts `abs=1e-6` because the buffer is single precision.
4. **Not a deviation, a gap in the reference:** `preset_category` has the default
   `"relaxation"` and *no* enumeration anywhere in `src/` — `session.py` points at
   `main_window.PRESET_CATEGORIES`, which does not exist yet. Inventing an allowed set
   would be inventing product behaviour, so `Session.presetCategory` is a free `String`
   exactly as in Python, and the registry belongs to the M2 UI. `TIMER_CHOICES` *is*
   real data and is ported verbatim.

## 6. Build and verify

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, `xcodegen` 2.46. `tuist`/`swiftgen` are
not installed and are not used. There is **no Apple Developer account** on this
machine (`security find-identity` → 0 identities), so every command passes
`CODE_SIGNING_ALLOWED=NO`, and iOS is only ever addressed with the
`iphonesimulator` SDK — never a device.

```
cd apple && xcodegen generate
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' \
           CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Binaural.xcodeproj -scheme BinauralCore -destination 'platform=macOS' \
           CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Binaural.xcodeproj -scheme Binaural -destination 'platform=macOS' \
           CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Binaural.xcodeproj -scheme Binaural-iOS \
           -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

**Known environment limit:** the last command uses `generic/platform=iOS Simulator`
rather than `-destination 'platform=iOS Simulator,name=iPhone 17'` because no simulator
*runtime* is installed on this machine — `xcrun simctl list runtimes` prints nothing and
`simctl list devices available` lists no devices, so a named destination cannot resolve
and nothing can be booted. The `iphonesimulator` SDK (27.0) is present, so the iOS app
compiles, links and embeds `frequencies.json` for the simulator as
`generic/platform=iOS Simulator` does. Installing a runtime
(`xcodebuild -downloadPlatform iOS`) turns this into a run-on-simulator check; no other
change is needed.

Swift 6 language mode (`SWIFT_VERSION = 6.0`), so `Sendable` is real: `FrequencyCatalogue`,
`Session`, `Synthesizer`, `StereoBuffer` and the model types are `Sendable` value
types; `StereoOscillator` is a mutable reference type and is intentionally left
un-`Sendable` rather than annotated `@unchecked Sendable`.