import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The headphone check of SPEC §4: the launch sequence, the §4.3 dialog and the §4.2
/// perceptual test.
///
/// The detection backend and the L/R answer are both **injected**, which is the whole
/// reason this suite is hermetic: the heuristic reads a fake device, the perceptual test
/// answers immediately instead of playing 3.3 seconds of tone, and nothing here needs a
/// headphone, a speaker or a modal loop. What is verified is the app's behaviour — which
/// branch runs, what it stores, what the indicator says — not the CoreAudio property reads
/// that `DeviceModelTests` already covers.
@MainActor
final class HeadphoneCheckTests: XCTestCase {

    // MARK: - Fixtures

    /// `L10n` is process-wide state, and several tests here switch it to check that captions
    /// follow. Resetting it here rather than at the end of each test means a test that fails
    /// half-way through cannot leave Russian behind for the rest of the suite.
    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    /// The window, plus a record of what the coordinator asked it to do.
    private final class TargetSpy: HeadphoneCheckCoordinator.Target {
        var applied: [HeadphoneReport] = []
        var acknowledgements: [Bool] = []
        var swaps: [Bool] = []

        func apply(headphoneReport: HeadphoneReport) { applied.append(headphoneReport) }
        func persistHeadphoneState(acknowledged: Bool, channelsSwapped: Bool) {
            acknowledgements.append(acknowledged)
            swaps.append(channelsSwapped)
        }
        var lastAcknowledged: Bool? { acknowledgements.last }
        var lastSwapped: Bool? { swaps.last }
    }

    private func report(
        verdict: DeviceClass,
        confidence: DetectionConfidence,
        lrTest: LRTestResult? = nil,
        name: String = "Test Device"
    ) -> HeadphoneReport {
        HeadphoneReport(
            verdict: verdict,
            device: AudioDevice(name: name, transport: "usb", isDefault: true, identifier: "t"),
            confidence: confidence,
            lrTest: lrTest
        )
    }

    private func makeCoordinator(
        fresh: HeadphoneReport,
        answer: LRTestResult? = nil,
        target: TargetSpy = TargetSpy()
    ) -> (HeadphoneCheckCoordinator, TargetSpy) {
        let coordinator = HeadphoneCheckCoordinator(
            player: LRTonePlayer(engine: AudioEngine()),
            target: target,
            detect: { _ in fresh },
            // The §4.2 question, answered without a modal loop — the same branch the real
            // dialog takes, minus the 3.3 seconds of tone.
            perceptualStep: { coordinator in
                guard let answer else { return coordinator.report }
                return coordinator.applyLRAnswer(answer)
            },
            presenter: ScriptedPresenter(answer: answer)
        )
        return (coordinator, target)
    }

    /// A presenter that answers immediately instead of spinning a modal event loop.
    ///
    /// `NSApp.runModal(for:)` returns only when the dialog closes, which in a test host
    /// means it would never return at all. This stands in for the user: the §4.3 dialog is
    /// acknowledged (its only exit) and the §4.2 dialog gets the scripted answer.
    /// A presenter that answers immediately instead of spinning a modal event loop.
    ///
    /// `NSApp.runModal(for:)` returns only when the dialog closes, which in a test host
    /// means it would never return at all. This stands in for the user: the §4.3 dialog is
    /// acknowledged (its only exit) and the §4.2 dialog gets the scripted answer.
    ///
    @MainActor
    private final class ScriptedPresenter: Presenting {
        let answer: LRTestResult?

        init(answer: LRTestResult?) {
            self.answer = answer
        }

        func present(_ dialog: NSWindowController) {
            switch dialog {
            case let check as HeadphoneCheckDialogController: check.continueAnyway()
            case let test as LRTestDialogController:
                if let answer { test.submit(answer) }
            default: break
            }
        }
    }

    // MARK: - The launch sequence

    /// §4.1 + §4.3: sure headphones → nothing is asked, nothing is stored but the flag.
    func testConfirmedHeadphonesAskNothing() {
        let (coordinator, target) = makeCoordinator(
            fresh: report(verdict: .headphones, confidence: .high)
        )
        coordinator.runAtLaunch(acknowledged: false)

        XCTAssertTrue(coordinator.report.isHeadphones)
        XCTAssertEqual(target.acknowledgements, [true], "confirmed headphones need no warning")
        XCTAssertTrue(coordinator.needsPerceptualTest(coordinator.report) == false)
    }

    /// §4.3: speakers are not headphones, and the dialog is the answer — with a way through.
    func testSpeakersOpenTheWarningDialog() {
        let (coordinator, target) = makeCoordinator(
            fresh: report(verdict: .speakers, confidence: .medium, name: "Динамики Mac mini")
        )
        coordinator.runAtLaunch(acknowledged: false)

        // The dialog was shown and acknowledged by its very construction in this harness:
        // it has one exit, which is "continue".
        XCTAssertEqual(target.lastAcknowledged, true, "SPEC §4.3: the user must be able to continue")
        XCTAssertEqual(coordinator.report.verdict, .speakers)
        XCTAssertEqual(coordinator.report.deviceName, "Динамики Mac mini")
    }

    /// §4.2 first: an unsure heuristic asks the perceptual question *before* saying anything.
    func testUnsureHeuristicRunsThePerceptualTestFirst() {
        let (coordinator, target) = makeCoordinator(
            fresh: report(verdict: .unknown, confidence: .low),
            answer: .leftThenRight
        )
        coordinator.runAtLaunch(acknowledged: false)

        XCTAssertEqual(coordinator.lastLRAnswer, .leftThenRight)
        XCTAssertTrue(coordinator.report.isHeadphones, "the test overrides the unknown verdict")
        XCTAssertEqual(target.lastSwapped, false)
    }

    /// §4.2's important answer: `Right → Left` means the channels are swapped, and that has
    /// to reach the session — this is the whole reason the perceptual test exists.
    func testSwappedChannelsAreStored() {
        let (coordinator, target) = makeCoordinator(
            fresh: report(verdict: .unknown, confidence: .low),
            answer: .rightThenLeft
        )
        coordinator.runAtLaunch(acknowledged: false)

        XCTAssertTrue(coordinator.report.channelsSwapped)
        XCTAssertEqual(target.lastSwapped, true)
        XCTAssertTrue(coordinator.report.isHeadphones)
    }

    /// §4.2: "если эвристика не дала «наверняка»" — a *confident* headphones verdict is the
    /// one case the spec does not question, so no tone is played at all.
    func testAConfidentHeadphonesVerdictIsNotQuestioned() {
        let (coordinator, _) = makeCoordinator(
            fresh: report(verdict: .headphones, confidence: .high),
            answer: .indeterminate
        )
        coordinator.runAtLaunch(acknowledged: false)
        XCTAssertNil(coordinator.lastLRAnswer, "SPEC §4.2 only asks when unsure")
        XCTAssertTrue(coordinator.report.isHeadphones)
    }

    /// …and the other way round: "both at once" is a positive answer for speakers and it
    /// outranks a name or transport hint — `HeadphoneDetector.applying`'s rule, reached from
    /// the menu for a user who doubts a positive heuristic.
    func testIndeterminateBeatsAPositiveHeuristic() {
        let (coordinator, _) = makeCoordinator(
            fresh: report(verdict: .headphones, confidence: .high)
        )
        coordinator.rerunFromUser()          // the heuristic now says headphones…
        XCTAssertTrue(coordinator.report.isHeadphones)
        coordinator.applyLRAnswer(.indeterminate)   // …the user disagrees
        XCTAssertFalse(coordinator.report.isHeadphones, "the perceptual test is definitive")
        XCTAssertEqual(coordinator.report.verdict, .speakers)
        XCTAssertEqual(coordinator.report.confidence, .high)
    }

    /// Which verdicts count as unsure. Stated as a test rather than left implicit.
    func testNeedsPerceptualTestCoversTheUnsureCases() {
        let (coordinator, _) = makeCoordinator(fresh: .unknown)
        XCTAssertTrue(coordinator.needsPerceptualTest(report(verdict: .unknown, confidence: .low)))
        XCTAssertTrue(coordinator.needsPerceptualTest(report(verdict: .virtual, confidence: .high)))
        XCTAssertFalse(coordinator.needsPerceptualTest(report(verdict: .headphones, confidence: .high)))
        XCTAssertFalse(coordinator.needsPerceptualTest(report(verdict: .speakers, confidence: .medium)))
    }

    /// §4.3's "may be repeated at any time" and the anti-nag rule: once acknowledged, the
    /// detection still runs but the dialog does not appear again.
    func testAcknowledgedWarningIsNotRepeatedButDetectionStillRuns() {
        let (coordinator, target) = makeCoordinator(
            fresh: report(verdict: .speakers, confidence: .medium)
        )
        coordinator.runAtLaunch(acknowledged: true)

        XCTAssertFalse(target.acknowledgements.isEmpty == false, "no dialog, no new flag")
        XCTAssertEqual(target.acknowledgements.count, 0, "already acknowledged: nothing to store")
        XCTAssertEqual(target.applied.count, 1, "but the indicator still shows the truth")
        XCTAssertEqual(coordinator.report.verdict, .speakers)
    }

    /// An L/R answer the user already gave survives a device change: `detect(previous:)`
    /// carries it over, so plugging in a monitor does not lose "the channels are swapped".
    func testAPreviousAnswerSurvivesADeviceChange() {
        let coordinator = HeadphoneCheckCoordinator(
            player: LRTonePlayer(engine: AudioEngine()),
            target: TargetSpy(),
            detect: { previous in
                guard let previous else { return self.report(verdict: .speakers, confidence: .medium) }
                return HeadphoneDetector.detect(
                    backend: StubBackend(verdict: .speakers, confidence: .medium),
                    previous: previous
                )
            },
            presenter: ScriptedPresenter(answer: nil)
        )
        coordinator.applyLRAnswer(.rightThenLeft)
        coordinator.rerunFromUser()

        XCTAssertEqual(coordinator.report.lrTest, .rightThenLeft)
        XCTAssertTrue(coordinator.report.channelsSwapped, "the swap must not be forgotten")
    }

    // MARK: - The window's side

    /// §4.2 in the window: only the **generator** swaps. The display and the stored document
    /// keep the unswapped pair, so the session means the same thing on any machine.
    func testTheWindowSwapsOnlyWhatItSendsToTheEngine() {
        let engine = AudioEngine()
        let controller = MainWindowController(engine: engine, store: temporaryStore())
        controller.setFrequency(205, for: .left)
        controller.setFrequency(215, for: .right)

        controller.recordHeadphoneState(acknowledged: true, channelsSwapped: true)

        XCTAssertEqual(controller.displayedFrequencies.left, 205, "the display shows what was asked")
        XCTAssertEqual(controller.displayedFrequencies.right, 215)
        let published = engine.mailbox.load(fallback: RenderParameters())
        XCTAssertEqual(published.leftHz, 215, accuracy: 1e-9, "the generator swaps")
        XCTAssertEqual(published.rightHz, 205, accuracy: 1e-9)

        controller.saveNow()
        XCTAssertTrue(controller.currentSession.channelsSwapped, "and the session remembers it")
        XCTAssertEqual(controller.currentSession.leftHz, 205, "with the unswapped numbers")
        controller.tearDown()
    }

    /// A stored swap is honoured on the first push after launch, not only after an edit.
    func testAStoredSwapAppliesImmediatelyOnLaunch() {
        let store = temporaryStore()
        store.save(Session(leftHz: 205, rightHz: 215, channelsSwapped: true))
        let engine = AudioEngine()
        let controller = MainWindowController(engine: engine, store: store)

        let published = engine.mailbox.load(fallback: RenderParameters())
        XCTAssertEqual(published.leftHz, 215, accuracy: 1e-9)
        XCTAssertEqual(published.rightHz, 205, accuracy: 1e-9)
        XCTAssertEqual(controller.displayedFrequencies.left, 205, "while the display is unchanged")
        controller.tearDown()
    }

    /// The always-visible indicator follows the report, in both languages.
    func testTheIndicatorFollowsTheReport() {
        let controller = MainWindowController(engine: AudioEngine(), store: temporaryStore())
        controller.apply(headphoneReport: report(verdict: .headphones, confidence: .high, name: "AirPods Pro"))
        XCTAssertEqual(controller.statusText, "Headphones detected")
        XCTAssertTrue(controller.statusToolTip.contains("AirPods Pro"))

        controller.apply(headphoneReport: report(verdict: .speakers, confidence: .medium))
        XCTAssertTrue(controller.statusText.contains("Speakers detected"))

        L10n.setLanguage("ru")
        controller.apply(headphoneReport: report(verdict: .speakers, confidence: .medium))
        XCTAssertTrue(controller.statusText.contains("Обнаружены динамики"))
        L10n.setLanguage("en")
        controller.tearDown()
    }

    /// SPEC §7: the window carries its own check button, so the check is not start-up only.
    func testTheWindowHasItsOwnCheckButton() {
        let controller = MainWindowController(engine: AudioEngine(), store: temporaryStore())
        var pressed = 0
        controller.setHeadphoneCheckHandler { pressed += 1 }
        controller.tapHeadphoneCheckButton()
        XCTAssertEqual(pressed, 1, "the button must reach the handler the app installs")
        controller.tearDown()
    }

    // MARK: - The §4.3 dialog

    func testTheDialogExplainsAndNeverGates() {
        let dialog = HeadphoneCheckDialogController(
            player: LRTonePlayer(engine: AudioEngine()),
            report: report(verdict: .speakers, confidence: .medium, name: "Динамики Mac mini")
        )
        XCTAssertEqual(dialog.headlineText, "Headphones recommended")
        XCTAssertEqual(dialog.statusText, "Speakers detected")
        XCTAssertTrue(dialog.isContinueEnabled, "SPEC §4.3: continuing is always allowed")
        XCTAssertEqual(dialog.continueButtonTitle, "Continue anyway")
        XCTAssertTrue(
            dialog.detailTexts.contains { $0.contains("Динамики Mac mini") },
            "the device name is shown: \(dialog.detailTexts)"
        )
        XCTAssertTrue(dialog.detailTexts.contains { $0.hasPrefix("Confidence:") })
    }

    func testTheDialogReportsHeadphonesWithItsOwnHeadline() {
        let dialog = HeadphoneCheckDialogController(
            player: LRTonePlayer(engine: AudioEngine()),
            report: report(verdict: .headphones, confidence: .high)
        )
        XCTAssertEqual(dialog.headlineText, "Headphones detected")
        XCTAssertTrue(dialog.isHeadphones)
    }

    /// *Retry check* re-reads the device, and an L/R answer already given is folded back in
    /// — losing it would make the user answer the question twice.
    func testRetryKeepsThePerceptualAnswer() {
        var answer = HeadphoneReport(
            verdict: .unknown,
            device: AudioDevice(name: "X", transport: "usb", isDefault: true),
            confidence: .low,
            lrTest: .rightThenLeft
        )
        let dialog = HeadphoneCheckDialogController(
            player: LRTonePlayer(engine: AudioEngine()),
            report: answer,
            detect: {
                answer = HeadphoneDetector.withLRResult(
                    .rightThenLeft,
                    in: HeadphoneReport(
                        verdict: .speakers,
                        device: AudioDevice(name: "Y", transport: "builtin", isDefault: true),
                        confidence: .medium
                    )
                )
                return answer
            }
        )
        dialog.retry()
        XCTAssertEqual(dialog.lrResult, .rightThenLeft)
        XCTAssertTrue(dialog.isShowingLRResult)
        XCTAssertTrue(dialog.channelsSwapped)
    }

    /// SPEC §7.4: a dialog is created fresh on each open and reads the language itself, so
    /// `retranslate()` is what a host calls — and the test calls it directly rather than
    /// waiting for a notification no dialog subscribes to.
    func testTheDialogFollowsTheLanguage() {
        let dialog = HeadphoneCheckDialogController(
            player: LRTonePlayer(engine: AudioEngine()),
            report: report(verdict: .speakers, confidence: .medium)
        )
        XCTAssertEqual(dialog.continueButtonTitle, "Continue anyway")
        L10n.setLanguage("ru")
        dialog.retranslate()
        XCTAssertEqual(dialog.continueButtonTitle, "Продолжить всё равно")
        XCTAssertEqual(dialog.lrButtonTitle, "Запустить тест L/R")
        XCTAssertEqual(dialog.retryButtonTitle, "Проверить снова")
        L10n.setLanguage("en")
        dialog.retranslate()
        XCTAssertEqual(dialog.continueButtonTitle, "Continue anyway")
    }

    // MARK: - The §4.2 dialog

    /// The three answers of SPEC §4.2, in the order the dialog shows them.
    func testTheLRDialogOffersTheThreeAnswersOfTheSpec() {
        let dialog = LRTestDialogController(player: LRTonePlayer(engine: AudioEngine()))
        XCTAssertEqual(
            dialog.answerTitles,
            ["Left → Right", "Right → Left", "Both at once / Can't tell"]
        )
        XCTAssertTrue(dialog.isAsking == false, "the question appears only after the tones")
    }

    /// Answering right-to-left is the answer that changes the session.
    func testTheLRDialogRecordsASwappedAnswer() {
        let dialog = LRTestDialogController(player: LRTonePlayer(engine: AudioEngine()))
        dialog.submit(.rightThenLeft)
        XCTAssertEqual(dialog.answer, .rightThenLeft)
        XCTAssertTrue(dialog.confirmationText.contains("swapped"))
    }

    func testTheLRDialogTakesTheIndeterminateAnswer() {
        let dialog = LRTestDialogController(player: LRTonePlayer(engine: AudioEngine()))
        dialog.submit(.indeterminate)
        XCTAssertEqual(dialog.answer, .indeterminate)
        XCTAssertTrue(dialog.confirmationText.contains("speakers"))
    }

    /// Cancelling is always safe and leaves no answer behind.
    func testCancellingTheLRDialogIsHarmless() {
        let dialog = LRTestDialogController(player: LRTonePlayer(engine: AudioEngine()))
        dialog.cancel()
        XCTAssertNil(dialog.answer)
        dialog.cancel()
        XCTAssertNil(dialog.answer)
    }

    // MARK: - The tone itself

    /// §4.2 is a *channel* test: both oscillators at the same frequency, one side silenced.
    /// A different pair would make a beat, and the user would be answering the wrong
    /// question.
    func testTheTestToneHardPansOneChannelAtATime() throws {
        let engine = AudioEngine()
        let player = LRTonePlayer(engine: engine)

        player.playTestTone(channel: .left, frequencyHz: 440)
        defer { player.silenceTestTone() }

        let parameters = engine.mailbox.load(fallback: RenderParameters())
        XCTAssertEqual(parameters.leftHz, 440, accuracy: 1e-9)
        XCTAssertEqual(parameters.rightHz, 440, accuracy: 1e-9, "the same tone both sides: no beat")
        XCTAssertEqual(parameters.panLeft, 1, accuracy: 1e-9)
        XCTAssertEqual(parameters.panRight, 0, accuracy: 1e-9)
    }

    /// The player's whole contract with the session: whatever was there comes back.
    func testTheTestToneRestoresTheSession() throws {
        let engine = AudioEngine()
        try engine.setFrequencies(leftHz: 205, rightHz: 215)
        let player = LRTonePlayer(engine: engine)

        player.playTestTone(channel: .right, frequencyHz: 440)
        player.silenceTestTone()

        let parameters = engine.mailbox.load(fallback: RenderParameters())
        XCTAssertEqual(parameters.leftHz, 205, accuracy: 1e-9)
        XCTAssertEqual(parameters.rightHz, 215, accuracy: 1e-9)
        XCTAssertEqual(parameters.panLeft, 1, accuracy: 1e-9, "full stereo is restored")
        XCTAssertEqual(parameters.panRight, 1, accuracy: 1e-9)
    }

    /// With no output device the player reports rather than crashes (Python's rule: a broken
    /// engine must never crash the test).
    func testTheTestToneSurvivesNoDevice() {
        let player = LRTonePlayer(engine: AudioEngine())
        player.playTestTone(channel: .left, frequencyHz: 440)
        player.silenceTestTone()   // must not throw, trap or hang
        XCTAssertFalse(player.isPlayingTone)
    }

    // MARK: - Helpers

    private func temporaryStore() -> SessionStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-headphone-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
    }

    /// A backend that answers with a fixed verdict, so `HeadphoneDetector.detect` can be
    /// exercised end to end without CoreAudio.
    private struct StubBackend: AudioDeviceBackend {
        let verdict: DeviceClass
        let confidence: DetectionConfidence

        func listOutputs() -> [AudioDevice] {
            [AudioDevice(name: "Stub", transport: "builtin", isDefault: true, identifier: "1")]
        }
        func defaultOutput() -> AudioDevice? { listOutputs().first }
        func classify(_ device: AudioDevice) -> DeviceClass { verdict }
        func heuristicVerdict() -> (verdict: DeviceClass, device: AudioDevice?) {
            (verdict, defaultOutput())
        }
    }
}