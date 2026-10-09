import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// Escape closes every dialog (SPEC §7.2).
///
/// Only the L/R test had a key equivalent for Escape, and a key equivalent is one
/// character — Escape and Return are two chords and a button carries one of them. So the
/// Escape path is `cancelOperation(_:)`, which AppKit sends to whichever window is key, and
/// every dialog has to say what Escape means *for that dialog*: close it, close the test,
/// or continue anyway (§4.3 never blocks).
///
/// Driving it through `cancelOperation(_:)` is the honest test: it is the entry point AppKit
/// actually uses, so a dialog that forgets to route Escape fails here rather than in a
/// user's hands.
@MainActor
final class EscapeClosesDialogTests: XCTestCase {

    /// `<repo>/src/binaural/data/frequencies.json` — the one copy both implementations
    /// read, located through `#filePath` so the test always reads the file being edited.
    private static func catalogueFromCatalogueURL() throws -> FrequencyCatalogue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try FrequencyCatalogue(
            contentsOf: root.appendingPathComponent("src/binaural/data/frequencies.json")
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    /// Each dialog, its Escape meaning, and how to tell it happened. `dismiss` is the
    /// observable: a closed About dialog has no visible window, and the headphone check
    /// records that it was acknowledged.
    private struct Case {
        let name: String
        let make: () -> NSWindowController
        let dismissed: (NSWindowController) -> Bool
    }

    private func cases() -> [Case] {
        [
            Case(
                name: "About",
                make: { AboutDialogController() },
                dismissed: { ($0.window?.isVisible ?? false) == false }
            ),
            Case(
                name: "Reference",
                make: {
                    ReferenceDialogController(catalogue: try! Self.catalogueFromCatalogueURL())
                },
                dismissed: { ($0.window?.isVisible ?? false) == false }
            ),
            Case(
                name: "Update",
                make: { UpdateDialogController(mode: .upToDate) },
                dismissed: { ($0.window?.isVisible ?? false) == false }
            ),
            Case(
                name: "Headphone check",
                make: {
                    HeadphoneCheckDialogController(
                        player: LRTonePlayer(engine: AudioEngine()),
                        report: HeadphoneReport(
                            verdict: .speakers,
                            device: AudioDevice(name: "Speakers", transport: "builtin", isDefault: true),
                            confidence: .medium
                        )
                    )
                },
                dismissed: { ($0 as? HeadphoneCheckDialogController)?.acknowledged == true }
            ),
            Case(
                name: "L/R test",
                make: { LRTestDialogController(player: LRTonePlayer(engine: AudioEngine())) },
                dismissed: { ($0.window?.isVisible ?? false) == false }
            ),
        ]
    }

    func testEscapeClosesEveryDialog() {
        for testCase in cases() {
            let dialog = testCase.make()
            dialog.cancelOperation(nil)
            XCTAssertTrue(
                testCase.dismissed(dialog),
                "Escape must dismiss the \(testCase.name) dialog"
            )
        }
    }

    /// The point of routing Escape through each dialog rather than disabling it globally:
    /// §4.3's dialog has no Cancel button, so Escape there can only mean "continue anyway".
    func testEscapeInTheHeadphoneCheckIsNotADismissal() {
        let dialog = HeadphoneCheckDialogController(
            player: LRTonePlayer(engine: AudioEngine()),
            report: HeadphoneReport(
                verdict: .speakers,
                device: AudioDevice(name: "Speakers", transport: "builtin", isDefault: true),
                confidence: .medium
            )
        )
        XCTAssertFalse(dialog.acknowledged, "it starts unacknowledged")
        dialog.cancelOperation(nil)
        XCTAssertTrue(
            dialog.acknowledged,
            "§4.3 never blocks: Escape is the 'continue anyway' path, not a silent dismissal"
        )
    }
}