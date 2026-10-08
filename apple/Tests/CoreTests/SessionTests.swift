import XCTest

@testable import BinauralCore

/// Parity with `tests/test_session.py` plus the two fields added later
/// (`timer_minutes`, `preset_category`, both read out of `src/binaural/core/session.py`).
///
/// The Python tests isolate `QSettings` to a temp directory; the Swift port is given a
/// temp file per test instead — same intent, no user settings touched.
final class SessionTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-session-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
        url = nil
    }

    // MARK: - Defaults

    func testDefaultsMatchPython() {
        let session = Session()
        XCTAssertEqual(session.leftHz, 205.0)
        XCTAssertEqual(session.rightHz, 215.0)
        XCTAssertEqual(session.volume, 0.7)
        XCTAssertFalse(session.channelsSwapped)
        XCTAssertFalse(session.headphoneCheckAcknowledged)
        XCTAssertNil(session.lastPreset)
        XCTAssertEqual(session.timerMinutes, 15)
        XCTAssertEqual(session.presetCategory, "relaxation")
        // SPEC §7's lock: off until the user ticks it.
        XCTAssertFalse(session.differenceLocked)
        XCTAssertEqual(session, Session.standard)
    }

    func testTimerConstantsMatchPython() {
        XCTAssertEqual(Session.timerOff, 0)
        XCTAssertEqual(Session.defaultTimerMinutes, 15)
        XCTAssertEqual(
            Session.timerChoices,
            [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
        )
        XCTAssertEqual(Session.maxTimerMinutes, 1440)
        XCTAssertTrue(Session.timerChoices.contains(Session.defaultTimerMinutes))
    }

    func testDerivedBeatAndCarrier() {
        let session = Session(leftHz: 205, rightHz: 215)
        assertClose(session.beatHz, 10.0, accuracy: 1e-12)
        assertClose(session.carrierHz, 210.0, accuracy: 1e-12)
    }

    // MARK: - Round trip

    func testSaveLoadRoundTripsEveryField() throws {
        let original = Session(
            leftHz: 210.5,
            rightHz: 198.25,
            volume: 0.35,
            channelsSwapped: true,
            headphoneCheckAcknowledged: true,
            lastPreset: "alpha-10",
            timerMinutes: 30,
            presetCategory: "focus",
            differenceLocked: true
        )
        try original.save(to: url)
        XCTAssertEqual(try Session.load(from: url), original)
    }

    func testRoundTripWithNilPreset() throws {
        let original = Session(lastPreset: nil)
        try original.save(to: url)
        XCTAssertNil(try Session.load(from: url).lastPreset)
    }

    func testSaveOverwritesPreviousState() throws {
        try Session(leftHz: 100, rightHz: 110).save(to: url)
        try Session(leftHz: 300, rightHz: 320, volume: 0.1).save(to: url)

        let restored = try Session.load(from: url)
        XCTAssertEqual(restored.leftHz, 300)
        XCTAssertEqual(restored.rightHz, 320)
        assertClose(restored.volume, 0.1, accuracy: 1e-12)
    }

    func testJSONKeysAreThePythonFieldNames() throws {
        // The skipped version is set because a `nil` one is omitted, like `last_preset`:
        // the key set of a default session is the one `testMissingKeysFallBackToDefaults`
        // reads.
        try Session(skippedUpdateVersion: "0.2.0").save(to: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let keys = Set((object as? [String: Any])?.keys.map(\.self) ?? [])
        XCTAssertEqual(
            keys,
            ["left_hz", "right_hz", "volume", "channels_swapped",
             "headphone_check_acknowledged", "timer_minutes", "preset_category",
             "difference_locked", "skipped_update_version"]
        )
    }

    func testLoadWithoutSavedStateThrowsInsteadOfInventing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-absent-\(UUID().uuidString).json")
        XCTAssertThrowsError(try Session.load(from: missing))
    }

    // MARK: - Load-time clamps, as in the Python `load()`

    func testVolumeIsClampedOnLoad() throws {
        try Session(volume: 4.0).save(to: url)
        XCTAssertEqual(try Session.load(from: url).volume, 1.0)

        try Session(volume: -1.0).save(to: url)
        XCTAssertEqual(try Session.load(from: url).volume, 0.0)
    }

    func testTimerIsClampedOnLoad() throws {
        try Session(timerMinutes: 9999).save(to: url)
        XCTAssertEqual(try Session.load(from: url).timerMinutes, Session.maxTimerMinutes)

        try Session(timerMinutes: -5).save(to: url)
        XCTAssertEqual(try Session.load(from: url).timerMinutes, 0)
    }

    func testMissingKeysFallBackToDefaults() throws {
        try Data(#"{"left_hz": 300.0}"#.utf8).write(to: url)
        let session = try Session.load(from: url)
        XCTAssertEqual(session.leftHz, 300)
        XCTAssertEqual(session.rightHz, Session.standard.rightHz)
        XCTAssertEqual(session.volume, Session.standard.volume)
        XCTAssertEqual(session.timerMinutes, Session.defaultTimerMinutes)
        XCTAssertEqual(session.presetCategory, Session.defaultPresetCategory)
        // A document written before SPEC §7's lock existed has no such key: it loads, and
        // the lock comes back off rather than the whole session being refused.
        XCTAssertFalse(session.differenceLocked)
    }

    /// The additive rule in full: the *exact* JSON of a pre-lock build still loads, with
    /// every old field intact and only the new one defaulted.
    func testASessionSavedBeforeTheLockExistedStillLoads() throws {
        let legacy = """
        {
          "left_hz": 231.5,
          "right_hz": 240.5,
          "volume": 0.42,
          "channels_swapped": true,
          "headphone_check_acknowledged": true,
          "last_preset": "alpha-10",
          "timer_minutes": 30,
          "preset_category": "concentration"
        }
        """
        try Data(legacy.utf8).write(to: url)

        let session = try Session.load(from: url)
        XCTAssertEqual(session.leftHz, 231.5)
        XCTAssertEqual(session.rightHz, 240.5)
        XCTAssertEqual(session.volume, 0.42, accuracy: 1e-12)
        XCTAssertTrue(session.channelsSwapped)
        XCTAssertTrue(session.headphoneCheckAcknowledged)
        XCTAssertEqual(session.lastPreset, "alpha-10")
        XCTAssertEqual(session.timerMinutes, 30)
        XCTAssertEqual(session.presetCategory, "concentration")
        XCTAssertFalse(session.differenceLocked)
    }

    func testTheLockSurvivesARoundTrip() throws {
        try Session(leftHz: 200, rightHz: 260, differenceLocked: true).save(to: url)
        XCTAssertTrue(try Session.load(from: url).differenceLocked)
    }

    /// The skipped update is remembered, and a session written before the field existed
    /// loads with it unset rather than being refused.
    func testTheSkippedUpdateVersionSurvivesARoundTrip() throws {
        try Session(skippedUpdateVersion: "0.2.0").save(to: url)
        XCTAssertEqual(try Session.load(from: url).skippedUpdateVersion, "0.2.0")

        try Data(#"{"left_hz": 300.0}"#.utf8).write(to: url)
        XCTAssertNil(try Session.load(from: url).skippedUpdateVersion)
    }

    /// A hand-edited document can hold anything; Python coerces booleans, so `"on"` is a
    /// lock and a nonsense string falls back rather than failing the whole load.
    func testTheLockCoercesLikeTheOtherBooleans() throws {
        try Data(#"{"difference_locked": "on"}"#.utf8).write(to: url)
        XCTAssertTrue(try Session.load(from: url).differenceLocked)

        try Data(#"{"difference_locked": "maybe"}"#.utf8).write(to: url)
        XCTAssertFalse(try Session.load(from: url).differenceLocked)
    }

    func testUnreadableValuesFallBackToDefaults() throws {
        // A settings file written by an older build can hold anything; Python coerces or
        // falls back, never crashes.
        let junk = """
        {
          "left_hz": "not a number",
          "volume": null,
          "channels_swapped": "yes",
          "headphone_check_acknowledged": 0,
          "timer_minutes": "20",
          "preset_category": ""
        }
        """
        try Data(junk.utf8).write(to: url)

        let session = try Session.load(from: url)
        XCTAssertEqual(session.leftHz, Session.defaultLeftHz)
        XCTAssertEqual(session.volume, Session.defaultVolume)
        XCTAssertTrue(session.channelsSwapped)              // "yes" is true, as in Python
        XCTAssertFalse(session.headphoneCheckAcknowledged)  // 0 is false
        XCTAssertEqual(session.timerMinutes, 20)            // "20" is coerced
        XCTAssertEqual(session.presetCategory, Session.defaultPresetCategory)
    }

    func testMalformedJSONFallsBackToDefaults() throws {
        try Data("not json at all".utf8).write(to: url)
        XCTAssertEqual(try Session.load(from: url), Session.standard)
    }
}