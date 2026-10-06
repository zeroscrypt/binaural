import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The main window as a user meets it (SPEC §7, §5 F1/F2/F5).
///
/// These drive the real `MainWindowController` — AppKit included, because the things
/// under test *are* the AppKit glue: two controls that must not interfere, a readout that
/// must follow the inputs, Space, the language switch and the session round-trip.
/// Everything numeric underneath is already covered by `BinauralCoreTests`; what is
/// being verified here is that the window wires it up correctly.
///
/// Each test builds its own controller with its own engine and its own temporary session
/// file, so nothing here can see or disturb the real `~/Library/Application Support`.
@MainActor
final class MainWindowControllerTests: XCTestCase {

    private var store: SessionStore!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        // An in-memory language store: `setLanguage` writes process-wide preferences, so
        // without this the suite would leave "ru" in the real defaults of the machine it
        // runs on, and the next launch of the test host would start in Russian.
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
    }

    override func tearDown() async throws {
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeController(session: Session? = nil) -> MainWindowController {
        if let session { store.save(session) }
        return MainWindowController(engine: AudioEngine(), store: store)
    }

    // MARK: - Two independent frequencies (SPEC F1)

    /// The core promise of F1: changing the left never moves the right.
    func testChangingOneChannelLeavesTheOtherAlone() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))

        controller.setFrequency(311.5, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 311.5)
        XCTAssertEqual(controller.displayedFrequencies.right, 215.0)

        controller.setFrequency(96.3, for: .right)
        XCTAssertEqual(controller.displayedFrequencies.left, 311.5)
        XCTAssertEqual(controller.displayedFrequencies.right, 96.3)
    }

    func testValuesAreClampedToTheSpecRange() {
        let controller = makeController()
        controller.setFrequency(0.2, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 1.0)
        controller.setFrequency(50_000, for: .right)
        XCTAssertEqual(controller.displayedFrequencies.right, 20_000.0)
    }

    func testFrequenciesSnapToTheTenthStep() {
        let controller = makeController()
        controller.setFrequency(205.04, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 205.0)
        controller.setFrequency(205.06, for: .left)
        XCTAssertEqual(controller.displayedFrequencies.left, 205.1)
    }

    /// The nudge of SPEC §7's `↑`/`↓`: one 0.1 Hz step of the active channel.
    func testNudgeMovesByOneStep() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        controller.setFrequency(205, for: .left)
        controller.switchChannelFromKeyboard()          // right becomes active
        controller.nudgeFromKeyboard(0.1)
        XCTAssertEqual(controller.displayedFrequencies.right, 215.1, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 205.0, accuracy: 1e-9)
    }

    // MARK: - Live beat and carrier (SPEC F1)

    func testBeatAndCarrierFollowTheInputs() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        XCTAssertEqual(controller.beat.hz, 10.0, accuracy: 1e-9)
        XCTAssertEqual(controller.beat.carrier, 210.0, accuracy: 1e-9)

        controller.setFrequency(300, for: .right)
        XCTAssertEqual(controller.beat.hz, 95.0, accuracy: 1e-9)
        XCTAssertEqual(controller.beat.carrier, 252.5, accuracy: 1e-9)
    }

    /// The §F1 hint appears outside 0.5–100 Hz and disappears inside it.
    func testOutOfRangeHintTracksTheBeat() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 210))
        XCTAssertFalse(controller.isShowingBeatHint, "a 10 Hz beat is inside the range")

        controller.setFrequency(400, for: .right)   // 200 Hz beat
        XCTAssertTrue(controller.isShowingBeatHint, "a 200 Hz beat is out of range")
        XCTAssertTrue(
            controller.beatHintText.contains("outside"),
            "the hint must say so: \(controller.beatHintText)"
        )

        controller.setFrequency(210, for: .right)   // back inside
        XCTAssertFalse(controller.isShowingBeatHint)
    }

    func testHintAppearsBelowHalfHertzToo() {
        let controller = makeController(session: Session(leftHz: 200, rightHz: 200.4))
        XCTAssertTrue(controller.isShowingBeatHint, "0.4 Hz is below the perceived range")
    }

    // MARK: - Transport (SPEC F2)

    func testVolumeAndMuteAreIndependentOfTheFrequencies() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215, volume: 0.5))
        controller.setVolume(0.25)
        XCTAssertEqual(controller.displayedVolume, 0.25, accuracy: 1e-9)

        controller.setMuted(true)
        XCTAssertTrue(controller.isMuted)
        controller.setMuted(false)
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(controller.displayedVolume, 0.25, accuracy: 1e-9)
    }

    func testVolumeIsClamped() {
        let controller = makeController()
        controller.setVolume(5)
        XCTAssertEqual(controller.displayedVolume, 1.0, accuracy: 1e-9)
        controller.setVolume(-3)
        XCTAssertEqual(controller.displayedVolume, 0.0, accuracy: 1e-9)
    }

    /// The window starts silent: nothing may blast audio on launch before Play.
    func testWindowStartsNotPlaying() {
        let controller = makeController()
        XCTAssertFalse(controller.isPlaying)
    }

    /// Space reaches the window: the closure AppKit invokes is the same action the button
    /// runs. A full key event needs a running app, so this asserts the wiring.
    func testSpaceIsWiredToTheTransport() {
        let controller = makeController()
        let window = try! XCTUnwrap(controller.window as? MainWindow)
        XCTAssertNotNil(window.onTogglePlayback, "Space must reach a handler")
        XCTAssertNotNil(window.onNudge, "↑/↓ must reach a handler")
        XCTAssertNotNil(window.onSwitchChannel, "←/→ must reach a handler")
    }

    func testTogglingPlaybackNeverThrowsWithoutADevice() {
        let controller = makeController()
        // On a machine with a device this starts the engine; without one it reports an
        // error. Both must leave the window in a coherent state, never crash.
        controller.togglePlaybackFromKeyboard()
        XCTAssertEqual(controller.currentSession.leftHz, 205.0)
        controller.togglePlaybackFromKeyboard()
        controller.tearDown()
    }

    // MARK: - Language (SPEC §7.4)

    func testLanguageSwitchRetranslatesTheWindowLive() {
        let controller = makeController()
        XCTAssertEqual(controller.playButtonTitle, "Play")

        L10n.setLanguage("ru")
        XCTAssertEqual(controller.playButtonTitle, "Воспроизвести")
        XCTAssertEqual(controller.leftCaption, "ЛЕВОЕ УХО")
        XCTAssertEqual(controller.rightCaption, "ПРАВОЕ УХО")
        XCTAssertEqual(controller.volumeCaptionTitle, "Громкость")
        XCTAssertEqual(controller.muteTitle, "Без звука")
        XCTAssertEqual(controller.window?.title, "Binaural")

        L10n.setLanguage("en")
        XCTAssertEqual(controller.playButtonTitle, "Play")
        XCTAssertEqual(controller.leftCaption, "LEFT EAR")
    }

    /// No relaunch: the same window instance shows Russian, then English again.
    func testLanguageRoundTripsOnOneWindow() {
        let controller = makeController()
        for language in ["ru", "en", "ru", "en"] {
            L10n.setLanguage(language)
            XCTAssertEqual(
                controller.leftCaption,
                L10n.language == .ru ? "ЛЕВОЕ УХО" : "LEFT EAR"
            )
        }
    }

    /// The indicator is visible from launch and follows the language (SPEC §7: "индикатор
    /// состояния наушников всегда виден").
    func testHeadphoneIndicatorIsAlwaysPresent() {
        let controller = makeController()
        XCTAssertFalse(controller.statusText.isEmpty, "the status indicator must show something")
        // M2-a ships no detection, so the honest state is "unknown" — and the indicator
        // still says so out loud rather than hiding itself.
        XCTAssertEqual(controller.statusText, "Unknown device")

        L10n.setLanguage("ru")
        XCTAssertEqual(controller.statusText, "Устройство не определено")
    }

    func testHeadphoneIndicatorCanBeSetFromEitherDirection() {
        let controller = makeController()

        controller.setHeadphoneState(.headphones, deviceName: "AirPods Pro")
        XCTAssertEqual(controller.statusText, "Headphones detected")
        XCTAssertTrue(controller.statusToolTip.contains("AirPods Pro"), "the device name is kept")

        controller.setHeadphoneState(.speakers)
        XCTAssertTrue(controller.statusText.contains("Speakers detected"))
        XCTAssertFalse(controller.statusText.contains("AirPods"), "a stale name must not linger")

        // Switching language re-reads the *current* state, not a remembered one.
        controller.setHeadphoneState(.headphones)
        L10n.setLanguage("ru")
        XCTAssertEqual(controller.statusText, "Наушники обнаружены")
        L10n.setLanguage("en")
        XCTAssertEqual(controller.statusText, "Headphones detected")
    }

    // MARK: - Session (SPEC F5)

    func testStoredSessionIsRestoredOnLaunch() {
        let stored = Session(
            leftHz: 231.5, rightHz: 240.5, volume: 0.42,
            timerMinutes: 30, presetCategory: "concentration"
        )
        store.save(stored)

        let controller = makeController()
        XCTAssertEqual(controller.displayedFrequencies.left, 231.5)
        XCTAssertEqual(controller.displayedFrequencies.right, 240.5)
        XCTAssertEqual(controller.displayedVolume, 0.42, accuracy: 1e-9)
        // Fields M2-a has no UI for are carried through untouched, not reset.
        XCTAssertEqual(controller.currentSession.timerMinutes, 30)
        XCTAssertEqual(controller.currentSession.presetCategory, "concentration")
    }

    func testChangesAreSavedForTheNextLaunch() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        controller.setFrequency(333.3, for: .right)
        controller.setVolume(0.66)
        controller.saveNow()

        let reloaded = MainWindowController(engine: AudioEngine(), store: store)
        XCTAssertEqual(reloaded.displayedFrequencies.left, 205.0)
        XCTAssertEqual(reloaded.displayedFrequencies.right, 333.3)
        XCTAssertEqual(reloaded.displayedVolume, 0.66, accuracy: 1e-9)
    }

    /// Mute is a live control, not session state — `Session` has no such field, so it
    /// must not leak into the saved document.
    func testMuteIsNotPersisted() {
        let controller = makeController(session: Session(leftHz: 205, rightHz: 215))
        controller.setMuted(true)
        controller.saveNow()

        let data = try! Data(contentsOf: store.url)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("mute"), "Session has no mute field: \(json)")
    }

    func testSavingAnUnwritableStoreDoesNotBreakTheWindow() {
        let file = directory.appendingPathComponent("in-the-way")
        try! Data("x".utf8).write(to: file)
        let blocked = SessionStore(url: file.appendingPathComponent(SessionStore.fileName))

        let controller = MainWindowController(engine: AudioEngine(), store: blocked)
        controller.setFrequency(400, for: .left)
        controller.saveNow()   // must not throw
        XCTAssertEqual(controller.displayedFrequencies.left, 400.0)
    }

    // MARK: - Timer (SPEC §5 F5)

    /// F5's data rule: the offered durations are `Session.timerChoices` verbatim, `0`
    /// first and captioned as "off".
    func testTimerOffersTheSessionChoicesWithOffFirst() {
        let controller = makeController()
        XCTAssertEqual(controller.timerChoiceTitles.count, Session.timerChoices.count)
        XCTAssertEqual(controller.timerChoiceTitles.first, "Off")
        XCTAssertEqual(controller.timerChoiceTitles.last, "\(Session.timerChoices.last!) min")
        XCTAssertEqual(
            Set(controller.timerChoiceTitles.dropFirst()),
            Set(Session.timerChoices.dropFirst().map { "\($0) min" })
        )
    }

    func testDefaultTimerIsFifteenMinutes() {
        let controller = makeController()
        XCTAssertEqual(controller.selectedTimerMinutes, Session.defaultTimerMinutes)
        XCTAssertEqual(controller.selectedTimerMinutes, 15)
    }

    /// The stored duration comes back with the session (F5: remember the timer).
    func testStoredTimerIsRestored() {
        let controller = makeController(session: Session(timerMinutes: 45))
        XCTAssertEqual(controller.selectedTimerMinutes, 45)
    }

    /// …and a change is written for the next launch.
    func testTimerChoiceIsSavedForTheNextLaunch() {
        let controller = makeController()
        controller.selectTimerMinutes(30)
        controller.saveNow()

        let reloaded = MainWindowController(engine: AudioEngine(), store: store)
        XCTAssertEqual(reloaded.selectedTimerMinutes, 30)
    }

    /// A duration that is in range but not on the offer list shows the nearest one, so
    /// the popup and the document cannot disagree about what the timer is.
    func testOffTimerShowsNoCountdown() {
        let controller = makeController()
        controller.selectTimerMinutes(Session.timerOff)
        XCTAssertEqual(controller.selectedTimerMinutes, 0)
        XCTAssertFalse(controller.isShowingCountdown, "0 minutes means 'play until stopped'")
    }

    /// The countdown is live text, in `mm:ss`, counting down once a second.
    func testCountdownCountsDownWhilePlaying() {
        let controller = makeController()
        controller.selectTimerMinutes(15)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        controller.armTimer(at: start)

        XCTAssertTrue(controller.isShowingCountdown)
        XCTAssertEqual(controller.countdownText, "15:00")

        controller.tickTimer(at: start.addingTimeInterval(60))
        XCTAssertEqual(controller.countdownText, "14:00")

        controller.tickTimer(at: start.addingTimeInterval(60 * 14 + 30))
        XCTAssertEqual(controller.countdownText, "00:30")
    }

    /// F5: "по истечении плавное затухание, чтобы остановка не была щелчком" — the session
    /// stops by itself, and it stops through the *same* fading stop the Stop button uses,
    /// not by cutting the engine.
    func testExpiryStopsPlaybackThroughTheFade() throws {
        let controller = makeController()
        controller.selectTimerMinutes(5)
        let engine = AudioEngine()
        let wired = MainWindowController(engine: engine, store: store)
        wired.selectTimerMinutes(5)

        let start = Date()
        wired.armTimer(at: start)
        try XCTSkipIf(!engine.start(), "no audio output device in this environment")
        wired.armTimer(at: start)
        XCTAssertTrue(wired.isPlaying)

        // Two seconds past the deadline: the ticker may have arrived late, so the check
        // is "expired by now", never "exactly at the deadline".
        wired.tickTimer(at: start.addingTimeInterval(5 * 60 + 2))
        XCTAssertFalse(wired.isPlaying, "the timer ends the session by itself")
        XCTAssertFalse(wired.isShowingCountdown)
        XCTAssertEqual(wired.playButtonTitle, "Play")

        // And it stopped by ramping the gain, not by jumping it: the published gain is
        // zero *with* the ramp SPEC F2 asks for, which is what makes it inaudible.
        let published = engine.mailbox.load(fallback: RenderParameters())
        XCTAssertEqual(published.gain, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(
            published.rampSeconds, 0,
            "a stop that ramps is a fade; a step would click"
        )
        XCTAssertEqual(published.rampSeconds, BeatMath.defaultRampSeconds, accuracy: 1e-12)
        wired.tearDown()
        engine.shutdown()
        controller.tearDown()
    }

    /// Expiry with nothing playing must still be safe — the countdown ends and the window
    /// stays coherent (this is the path a test run and a device-less machine take).
    func testExpiryWithoutPlaybackIsHarmless() {
        let controller = makeController()
        controller.selectTimerMinutes(5)
        let start = Date()
        controller.armTimer(at: start)
        XCTAssertTrue(controller.isShowingCountdown)

        controller.tickTimer(at: start.addingTimeInterval(301))
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isShowingCountdown)
    }

    /// Stopping by hand ends the countdown but keeps the chosen duration, so pressing Play
    /// again gives the session the time the user picked rather than none.
    func testManualStopKeepsTheChosenDuration() {
        let controller = makeController()
        controller.selectTimerMinutes(20)
        controller.armTimer(at: Date())

        controller.togglePlaybackFromKeyboard()   // stop; no device here, so a no-op
        controller.disarmTimer()

        XCTAssertFalse(controller.isShowingCountdown)
        XCTAssertEqual(controller.selectedTimerMinutes, 20)
    }

    /// The timer follows the language like everything else (SPEC §7.4).
    func testTimerCaptionsFollowTheLanguage() {
        let controller = makeController()
        XCTAssertEqual(controller.timerCaptionTitle, "Timer")

        L10n.setLanguage("ru")
        XCTAssertEqual(controller.timerCaptionTitle, "Таймер")
        XCTAssertEqual(controller.timerChoiceTitles.first, "Выкл.")

        L10n.setLanguage("en")
        XCTAssertEqual(controller.timerChoiceTitles.last, "120 min")
    }

    // MARK: - Cleanup

    func testTearDownIsSafeToCallTwice() {
        let controller = makeController()
        controller.tearDown()
        controller.tearDown()
    }
}

/// A throwaway preference store, so the language tests cannot touch the machine's
/// real `UserDefaults`.
final class MemoryPreferenceStore: PreferenceStore, @unchecked Sendable {

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
