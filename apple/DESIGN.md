# apple/ — M1 design (the Swift foundation)

Status: **Milestone 1.** Foundation only — the parts that must be *provably* equal to the
Python implementation. UI is deliberately M2. Read `docs/SPEC.md` (behaviour) and
`docs/CONTRACT.md` (shared API) first; the Python reference is `src/binaural/`.

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