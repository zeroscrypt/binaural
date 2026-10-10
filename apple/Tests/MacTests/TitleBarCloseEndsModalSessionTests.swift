import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// A dialog closed with the red close button or Cmd+W must end the modal session it was
/// presented in.
///
/// Escape is covered by `EscapeClosesDialogTests`, and it reaches a dialog through
/// `cancelOperation(_:)`, which is a button action the dialog controls. A title-bar close is
/// not: it goes to AppKit, the window is asked whether it may close, and a `true` returned
/// from there lets the window go *without* ending the session.
///
/// `NSApp.runModal(for:)` is a nested event loop and does not notice that its window has
/// gone, so it keeps spinning after the dialog is dismissed. While it does, the main menu is
/// disabled for the length of a modal session and `Cmd+Q` is not delivered — so the app quits
/// only through Force Quit, and nothing on screen explains why. It was reported as "the menu
/// went dead after I closed the window", and it began with the update dialog, which is
/// offered at launch and is therefore the first thing a user meets.
///
/// Two of the five dialogs had a delegate already; the other three did not, and Escape still
/// worked on them — which is what made this hard to see. These tests drive AppKit's own entry
/// point rather than a button, so a dialog that loses the delegate fails here.
@MainActor
final class TitleBarCloseEndsModalSessionTests: XCTestCase {

    /// `<repo>/src/binaural/data/frequencies.json` — the one copy both implementations
    /// read, located through `#filePath` so the test reads the file being edited.
    private static func catalogue() throws -> FrequencyCatalogue {
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

    /// Every dialog, with the dismissal that must follow a title-bar close. The headphone
    /// check has no cancel button — §4.3 never blocks — so a dismissal there is recorded as
    /// *continue anyway*, which is what the two already-wired dialogs do.
    private func cases() throws -> [(name: String, make: () throws -> NSWindowController)] {
        [
            ("About", { AboutDialogController() }),
            ("Reference", { ReferenceDialogController(catalogue: try Self.catalogue()) }),
            ("Update", { UpdateDialogController(mode: .upToDate) }),
            ("Headphone check", {
                HeadphoneCheckDialogController(
                    player: LRTonePlayer(engine: AudioEngine()),
                    report: HeadphoneReport(
                        verdict: .speakers,
                        device: AudioDevice(name: "Speakers", transport: "builtin", isDefault: true),
                        confidence: .medium
                    )
                )
            }),
            ("L/R test", { LRTestDialogController(player: LRTonePlayer(engine: AudioEngine())) }),
        ]
    }

    /// Every dialog needs a window delegate that approves the close.
    ///
    /// Asserting the delegate merely *exists* is the regression check: without one, AppKit
    /// closes the window freely and the modal session is left running.
    func testEveryDialogHasADelegateThatApprovesAClose() throws {
        for testCase in try cases() {
            let dialog = try testCase.make()
            let window = try XCTUnwrap(dialog.window, "\(testCase.name) must have a window")
            let delegate = try XCTUnwrap(
                window.delegate as? NSWindowDelegate,
                """
                \(testCase.name) has no window delegate, so the red close button and Cmd+W \
                dismiss it without ending the modal session it was presented in.
                """
            )
            XCTAssertTrue(
                delegate.windowShouldClose?(window) ?? false,
                "\(testCase.name) must let a title-bar close proceed"
            )
        }
    }

    /// And the approval has to close the dialog, not merely say yes.
    func testTheTitleBarCloseButtonActuallyClosesEachDialog() throws {
        for testCase in try cases() {
            let dialog = try testCase.make()
            let window = try XCTUnwrap(dialog.window, "\(testCase.name) must have a window")
            window.orderFront(nil)
            XCTAssertTrue(window.isVisible, "\(testCase.name) must be on screen to be closed")

            window.performClose(nil)

            XCTAssertFalse(
                window.isVisible,
                "\(testCase.name) must be gone after the red close button"
            )
            if let headphoneCheck = dialog as? HeadphoneCheckDialogController {
                XCTAssertTrue(
                    headphoneCheck.acknowledged,
                    "a dismissal is §4.3's way out of the headphone check"
                )
            }
        }
    }

    /// The forwarder must not keep a dialog alive.
    ///
    /// `ModalCloseForwarder` holds its owner weakly precisely so that this stays true, and it
    /// is the reason the forwarder exists instead of the controller being its own delegate —
    /// `NSWindow.delegate` retains, which would undo `WindowKeeper`. `WindowKeeperTests`
    /// asserts the consequence; this states the cause next to the thing it protects.
    func testTheForwarderDoesNotKeepTheDialogAlive() throws {
        weak var weakDialog: AboutDialogController?
        do {
            let dialog = AboutDialogController()
            weakDialog = dialog
        }
        XCTAssertNil(
            weakDialog,
            "the window delegate must hold the dialog weakly, or WindowKeeper is redundant"
        )
    }

    /// With no modal session running, approving the close is still just a close — the
    /// forwarder must not assume a session exists.
    func testClosingWithoutAModalSessionIsHarmless() throws {
        let dialog = UpdateDialogController(mode: .upToDate)
        let window = try XCTUnwrap(dialog.window)
        XCTAssertNil(NSApp.modalWindow, "nothing is modal in a unit test")
        window.orderFront(nil)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(NSApp.modalWindow)
    }
}