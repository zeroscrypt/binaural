import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The chakra mode: a journey up the body and back, with the sound playing the whole
/// time.
///
/// The mode is a *program*: it sets both channels, it keeps setting them, and it starts
/// the sound itself. So the tests are about the pair it plays, the order it plays it in,
/// and the fact that it does not walk on with the playback stopped — a journey that
/// advanced in silence was a light show on a timer.
@MainActor
final class ChakraModeTests: XCTestCase {

    private var store: SessionStore!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-chakras-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
    }

    override func tearDown() async throws {
        L10n.bootstrap(locale: Locale(identifier: "en_US"), store: MemoryPreferenceStore())
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A controller whose "is the sound playing" the test answers for itself: there is no
    /// audio device here to play through.
    private func makeController(playing: Bool = true) -> MainWindowController {
        let controller = MainWindowController(engine: AudioEngine(), store: store)
        controller.playbackRunningOverride = playing
        return controller
    }

    // MARK: - The cocoon

    /// The cocoon is the sound's own shape: it is around the figure while the sound
    /// plays, and it is not there when the sound stops.
    func testTheCocoonFollowsTheSound() {
        let controller = makeController(playing: true)
        controller.setChakraMode(true)
        XCTAssertTrue(
            controller.chakraControl.figureIsPlaying,
            "the cocoon is the sound's shape; it forms with the sound"
        )

        controller.playbackRunningOverride = false
        controller.setChakraMode(false)
        XCTAssertFalse(
            controller.chakraControl.figureIsPlaying,
            "and it falls apart when the sound stops"
        )
    }

    /// The grains do not jump into the shape: they assemble into it, over about half a
    /// second, which is the difference between a shell and a picture of one.
    func testTheCocoonAssemblesRatherThanAppearing() {
        let controller = makeController(playing: true)
        controller.chakraControl.reducedMotionOverride = false
        controller.setChakraMode(true)

        XCTAssertLessThan(
            controller.chakraControl.cocoonFormation, 1,
            "the shape forms over time, not in one step"
        )

        let formed = expectation(description: "the cocoon assembles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if controller.chakraControl.cocoonFormation >= 1 { formed.fulfill() }
        }
        wait(for: [formed], timeout: 5)
    }

    /// SPEC §7.2: reduced motion is honoured. The grains are simply in place — no
    /// assembling, no shivering — and the cocoon is still there, because the brightness
    /// says whether the sound is on whether it moves or not.
    func testReducedMotionPutsTheCocoonInPlaceWithoutAnimatingIt() {
        let controller = makeController(playing: true)
        controller.chakraControl.reducedMotionOverride = true
        controller.setChakraMode(true)

        XCTAssertEqual(
            controller.chakraControl.cocoonFormation, 1,
            "with reduced motion the grains are in place at once, and stay there"
        )
    }

    // MARK: - It is a mode, and it is off to begin with

    /// The mode is a program of its own. A user who has not asked for it should get the
    /// plain frequency controls and the preset bar.
    func testTheModeIsOffUntilItIsAskedFor() {
        let controller = makeController()
        XCTAssertFalse(controller.isChakraModeActive)
        XCTAssertTrue(controller.chakraControl.isHidden, "the panel starts hidden")
        XCTAssertFalse(controller.presetBlockControl.isHidden, "the presets are not hidden by it")
    }

    func testTurningItOnShowsThePanelAndStandsThePresetsDown() {
        let controller = makeController()
        controller.setChakraMode(true)

        XCTAssertTrue(controller.isChakraModeActive)
        XCTAssertFalse(controller.chakraControl.isHidden)
        XCTAssertTrue(
            controller.presetBlockControl.isHidden,
            "the two are alternative programs; both on screen at once would fight"
        )
    }

    func testTurningItOffPutsThePresetsBack() {
        let controller = makeController()
        controller.setChakraMode(true)
        controller.setChakraMode(false)

        XCTAssertFalse(controller.isChakraModeActive)
        XCTAssertTrue(controller.chakraControl.isHidden)
        XCTAssertFalse(controller.presetBlockControl.isHidden)
    }

    // MARK: - The journey

    /// The journey starts at the earth, the lowest step: 174 Hz, the lowest tone of the
    /// extended Solfeggio set.
    func testItStartsOnTheEarthStep() {
        let controller = makeController()
        controller.setChakraMode(true)

        XCTAssertEqual(controller.currentChakraStepID, "earth")
        let (left, right) = controller.displayedFrequencies
        XCTAssertEqual((left + right) / 2, 174, accuracy: 0.05)
    }

    /// The journey goes up the body and comes back down, and then the mode switches
    /// itself off. A walk that ended at the crown would leave the sound playing with
    /// nowhere left to go.
    func testTheJourneyGoesUpAndBackAndThenStops() {
        let controller = makeController()
        controller.setChakraMode(true)

        let journey = controller.chakraJourneyIndices
        XCTAssertEqual(journey.first, 0, "it starts at the earth")
        XCTAssertEqual(journey.last, 0, "and comes back to where it started")
        XCTAssertEqual(journey.prefix(4), [0, 1, 2, 3], "upwards first")
        XCTAssertEqual(journey.suffix(4), [3, 2, 1, 0], "and downwards afterwards")
        XCTAssertEqual(Set(journey), Set(0..<ChakraSequence.steps.count))

        // Walking the whole journey switches the mode off at the end.
        for _ in journey { controller.advanceChakraStepForTests() }
        XCTAssertFalse(controller.isChakraModeActive, "the journey ends by itself")
    }

    /// The other direction starts at the crown and comes back down to the earth.
    func testTheDirectionCanBeTheOtherWayRound() {
        let controller = makeController()
        controller.setChakraMode(true)
        controller.chakraControl.setDirection(.down)
        controller.chakraControl.onDirectionChange?(.down)

        let journey = controller.chakraJourneyIndices
        XCTAssertEqual(journey.first, ChakraSequence.steps.count - 1, "it starts at the crown")
        XCTAssertEqual(journey.last, ChakraSequence.steps.count - 1)
        XCTAssertEqual(journey.suffix(4).map { $0 }, [4, 5, 6, 7], "and comes back up")
    }

    /// The journey only moves while there is sound. It used to walk on a timer whatever
    /// the playback was doing, so the chakras on screen changed in silence — a light
    /// show with no music under it.
    func testTheJourneyDoesNotMoveWithoutSound() {
        let controller = makeController(playing: false)
        controller.setChakraMode(true)
        let before = controller.currentChakraStepID

        controller.advanceChakraStepForTests()
        XCTAssertEqual(controller.currentChakraStepID, before, "silence does not move it")
    }

    /// The journey moves when the sound is playing.
    func testTheJourneyMovesWithSound() {
        let controller = makeController(playing: true)
        controller.setChakraMode(true)
        let before = controller.currentChakraStepID

        controller.advanceChakraStepForTests()
        XCTAssertNotEqual(controller.currentChakraStepID, before)
    }

    /// Choosing where the walk starts is not a request for a sound. The switch asks for
    /// one; a click on a chakra on the figure does not.
    func testPickingAChakraDoesNotAskForASound() {
        let controller = makeController()
        controller.setChakraMode(true)
        let afterTheSwitch = controller.chakraPlaybackRequests

        controller.pickChakraForTests(3)
        XCTAssertEqual(
            controller.chakraPlaybackRequests, afterTheSwitch,
            "picking a chakra must not start the sound"
        )
    }

    /// The switch does **not** start the sound. The mode is a program the user steps
    /// into; starting to make noise is the Play button's job, and a button that starts
    /// playing on its own is a button that can surprise someone.
    func testTheSwitchDoesNotStartTheSound() {
        let controller = makeController()
        controller.setChakraMode(true)
        XCTAssertEqual(controller.chakraPlaybackRequests, 0)
    }

    // MARK: - The controls

    /// A new beat has to be heard at once, not at the next step.
    func testTheBeatControlChangesThePairImmediately() {
        let controller = makeController()
        controller.setChakraMode(true)

        controller.chakraControl.setBeatHz(8)
        controller.chakraControl.onBeatChange?(8)

        let (left, right) = controller.displayedFrequencies
        XCTAssertEqual(right - left, 8, accuracy: 0.05)
        XCTAssertEqual((left + right) / 2, 174, accuracy: 0.05, "the carrier did not move")
    }

    /// The offered step lengths are data, and the default is among them.
    func testTheStepLengthsAreOffered() {
        let controller = makeController()
        let titles = controller.chakraControl.durationChoiceTitles
        XCTAssertEqual(titles.count, ChakraSequence.stepSecondsChoices.count)
        XCTAssertTrue(
            titles.contains("30 s"),
            "half a minute is the shortest step worth taking: \(titles)"
        )
        XCTAssertTrue(
            titles.contains("1 min"),
            "the default has to be one of the offered choices: \(titles)"
        )
    }

    // MARK: - The panel's own text

    /// The panel says which chakra is playing, its frequency and what it is about. A
    /// panel that only showed a number would not say what the mode is.
    func testThePanelShowsTheStepItIsOn() {
        let controller = makeController()
        controller.setChakraMode(true)

        XCTAssertEqual(controller.chakraControl.frequencyText, "174")
        XCTAssertEqual(controller.chakraControl.nameText, "Earth")
        XCTAssertFalse(controller.chakraControl.descriptionText.isEmpty)
    }

    /// The figure lights the point of the step being played.
    func testTheFigurePointsAtTheCurrentStep() {
        let controller = makeController()
        controller.setChakraMode(true)

        XCTAssertEqual(controller.chakraControl.figureCurrentIndex, 0, "the earth is the first")
        XCTAssertEqual(controller.chakraControl.figureReachedIndex, 0)

        controller.advanceChakraStepForTests()
        XCTAssertEqual(controller.chakraControl.figureCurrentIndex, 1)
        XCTAssertEqual(controller.chakraControl.figureReachedIndex, 1)
    }

    // MARK: - The colours

    /// The colours follow the rainbow from the root to the crown, with the earth a
    /// stone grey. It is the order everyone already knows, so a reader can tell which
    /// chakra they are looking at from the colour alone.
    func testThePaletteIsTheRainbowFromRootToCrown() {
        XCTAssertEqual(ChakraPalette.colors.count, ChakraSequence.steps.count)
        var hexes: Set<String> = []
        for index in 0..<ChakraSequence.steps.count {
            hexes.insert(Self.hex(of: ChakraPalette.color(forStepIndex: index), in: .aqua))
        }
        XCTAssertEqual(hexes.count, ChakraSequence.steps.count, "no two steps share a colour")
    }

    /// The shades are muted on purpose: a saturated red on a dark background is a
    /// glare, and seven of them at once is a rainbow of noise. The values are pinned so
    /// a change to them is a decision rather than an accident, and so the Qt side's
    /// `theme.TOKENS` cannot drift away from them.
    func testThePaletteValuesArePinned() {
        let lightExpected = [
            "#7A6E5C", "#C8503F", "#C06A22", "#A1810F", "#3F8A4C", "#2E88A8", "#4E63C4", "#8149B0"
        ]
        let darkExpected = [
            "#B3A692", "#F0877A", "#F0A45F", "#E3C453", "#6FBE7C", "#5FB6D2", "#8A9BEA", "#B183DE"
        ]
        for index in 0..<ChakraSequence.steps.count {
            let colour = ChakraPalette.color(forStepIndex: index)
            XCTAssertEqual(Self.hex(of: colour, in: .aqua), lightExpected[index], "light, step \(index)")
            XCTAssertEqual(Self.hex(of: colour, in: .darkAqua), darkExpected[index], "dark, step \(index)")
        }
    }

    /// The hex of a colour as it resolves in a given appearance.
    ///
    /// A dynamic colour resolves against the *current* appearance, so a test that simply
    /// read the colour would get whichever of the two the test machine happens to be
    /// in. Both are asked for by name.
    private static func hex(of colour: NSColor, in appearanceName: NSAppearance.Name) -> String {
        guard let appearance = NSAppearance(named: appearanceName) else { return "" }
        var result = ""
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = colour.usingColorSpace(.sRGB) else { return }
            result = String(
                format: "#%02X%02X%02X",
                Int((srgb.redComponent * 255).rounded()),
                Int((srgb.greenComponent * 255).rounded()),
                Int((srgb.blueComponent * 255).rounded())
            )
        }
        return result
    }

    // MARK: - It does not fight the rest of the window

    /// The mode sets both channels, so a locked difference would fight it. The lock is
    /// released rather than silently overridden.
    func testALockedDifferenceIsReleasedWhenTheModeStarts() {
        let controller = makeController()
        controller.tapDifferenceLock(true)
        XCTAssertTrue(controller.differenceLockIsLocked)

        controller.setChakraMode(true)
        XCTAssertFalse(controller.differenceLockIsLocked)
    }
}
