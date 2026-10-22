import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The chakra mode: seven solfeggio steps, root to crown, advanced by a timer.
///
/// The mode is a *program*: it sets both channels and keeps setting them. So the tests
/// are about the pair it plays, the order it plays it in, and the fact that it does not
/// fight the rest of the window — the preset bar stands down while it is on, because a
/// preset click would be overwritten by the next step.
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

    private func makeController(session: Session? = nil) -> MainWindowController {
        if let session { store.save(session) }
        return MainWindowController(engine: AudioEngine(), store: store)
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

    // MARK: - The pair it plays

    /// The first step is the earth: 174 Hz, the lowest tone of the extended Solfeggio
    /// set — the one called *the foundation*. The sequence starts on the ground and
    /// rises from there.
    func testItStartsOnTheEarthStep() {
        let controller = makeController()
        controller.setChakraMode(true)

        XCTAssertEqual(controller.currentChakraStepID, "earth")
        let (left, right) = controller.displayedFrequencies
        XCTAssertEqual((left + right) / 2, 174, accuracy: 0.05)
    }

    /// The beat is the difference between the ears, and the default is the measured
    /// 21 Hz.
    func testTheDefaultBeatIsTheDifferenceBetweenTheEars() {
        let controller = makeController()
        controller.setChakraMode(true)

        let (left, right) = controller.displayedFrequencies
        XCTAssertEqual(right - left, 21, accuracy: 0.05)
    }

    /// The sequence rises. That is the whole point of the mode.
    func testTheStepsRise() {
        let controller = makeController()
        controller.setChakraMode(true)

        var carriers: [Double] = []
        for _ in 0..<ChakraSequence.steps.count {
            let (left, right) = controller.displayedFrequencies
            carriers.append((left + right) / 2)
            controller.advanceChakraStepForTests()
        }
        XCTAssertEqual(carriers, carriers.sorted())
        XCTAssertEqual(carriers.first, 174)
        XCTAssertEqual(carriers.last, 963)
    }

    /// Every step is a solfeggio frequency, and the sequence visits all seven.
    func testItVisitsEveryStepInOrder() {
        let controller = makeController()
        controller.setChakraMode(true)

        var ids: [String] = [controller.currentChakraStepID ?? ""]
        for _ in 1..<ChakraSequence.steps.count {
            controller.advanceChakraStepForTests()
            ids.append(controller.currentChakraStepID ?? "")
        }
        XCTAssertEqual(ids, ChakraSequence.steps.map(\.id))
    }

    /// After the crown it starts again. A sound app that stopped at the top would leave
    /// the user with silence and no way to say so.
    func testItStartsAgainAfterTheCrown() {
        let controller = makeController()
        controller.setChakraMode(true)
        for _ in 0..<ChakraSequence.steps.count {
            controller.advanceChakraStepForTests()
        }
        XCTAssertEqual(controller.currentChakraStepID, "earth")
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

    /// The offered step durations are data, and the default is among them.
    func testTheStepDurationsAreOffered() {
        let controller = makeController()
        let titles = controller.chakraControl.stepChoiceTitles
        XCTAssertEqual(titles.count, ChakraSequence.stepSecondsChoices.count)
        XCTAssertTrue(
            titles.contains(ChakraSequence.stepSecondsText(ChakraSequence.defaultStepSeconds)),
            "the default has to be one of the offered choices"
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

        XCTAssertEqual(controller.chakraControl.figureCurrentIndex, 0, "the root is the first")
        XCTAssertEqual(controller.chakraControl.figureReachedIndex, 0)

        controller.advanceChakraStepForTests()
        XCTAssertEqual(controller.chakraControl.figureCurrentIndex, 1)
        XCTAssertEqual(controller.chakraControl.figureReachedIndex, 1)
    }

    // MARK: - The colours

    /// The colours follow the rainbow from the root of the body to the top: red, orange,
    /// yellow, green, light blue, blue, violet. It is the order everyone already knows,
    /// so a reader can tell which chakra they are looking at from the colour alone.
    func testThePaletteIsTheRainbowFromRootToCrown() {
        XCTAssertEqual(ChakraPalette.colors.count, ChakraSequence.steps.count)
        // Seven distinct colours: the point of the palette is that the eye can tell
        // the chakras apart, and two shared colours would undo that.
        var hexes: Set<String> = []
        for index in 0..<ChakraSequence.steps.count {
            hexes.insert(Self.hex(of: ChakraPalette.color(forStepIndex: index), in: .aqua))
        }
        XCTAssertEqual(hexes.count, ChakraSequence.steps.count)
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
            XCTAssertEqual(Self.hex(of: colour, in: .aqua), lightExpected[index], "light, chakra \(index)")
            XCTAssertEqual(Self.hex(of: colour, in: .darkAqua), darkExpected[index], "dark, chakra \(index)")
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

    /// The number on screen wears its chakra's colour, and so does the point on the
    /// figure — the same colour in two places is what ties them together.
    func testTheNumberWearsTheChakrasColour() {
        let controller = makeController()
        controller.setChakraMode(true)

        let earth = ChakraPalette.color(forStepIndex: 0)
        XCTAssertEqual(
            controller.chakraControl.frequencyColour.description,
            earth.description,
            "the earth's number is the earth's colour"
        )

        controller.advanceChakraStepForTests()
        let sacral = ChakraPalette.color(forStepIndex: 1)
        XCTAssertEqual(controller.chakraControl.frequencyColour.description, sacral.description)
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
