import AppKit

/// Showing a dialog, and ending it again — the two halves of modality, in one file.
///
/// Split out of ``HeadphoneCheckCoordinator`` because by M2-b item 3 the Settings dialog
/// needs them too: every modal dialog in the app presents through one presenter and ends
/// through one method, which is what keeps "close" and "stop the modal loop" from drifting
/// apart (see ``NSWindowController/endModalSessionAndClose(code:)`` — closing the window
/// alone does *not* unwind `NSApp.runModal(for:)`).

/// Shows a dialog and returns when it is done.
///
/// Behind a protocol because `NSApp.runModal(for:)` **never returns on its own** — it
/// spins a nested event loop until the dialog ends. Injected, the launch sequence can be
/// driven to completion in a test without a modal loop; the app passes the real one.
@MainActor
protocol Presenting: AnyObject {
    func present(_ dialog: NSWindowController)
}

/// The real presenter: a modal window, the AppKit counterpart of Python's
/// `dialog.exec()`.
///
/// `MainActor` like every AppKit operation in this file; the protocol is too, so the
/// conformance is checked with the isolation it is meant to run under rather than
/// needing `assumeIsolated` at every call.
@MainActor
final class ModalPresenter: Presenting {

    func present(_ dialog: NSWindowController) {
        run(dialog)
    }

    private func run(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.center()
        guard let window = controller.window else { return }
        NSApp.runModal(for: window)
        controller.close()
    }
}

/// Ending a modal session — the one piece every dialog here needs.
///
/// `NSApp.runModal(for:)` is a **nested event loop**, and closing its window from the
/// inside does not reliably unwind it: the dialog disappears while the loop keeps
/// spinning, so whatever presented the dialog never continues. `NSApp.stopModal(withCode:)`
/// is the documented way to end it, and it only applies while *this* window is the modal
/// one — a dialog that was merely shown, or that is running under a test's stub presenter,
/// is closed plainly.
extension NSWindowController {

    /// End the modal session this window is running in, then close it.
    ///
    /// Safe to call unconditionally: with no modal session the effect is `close()`. That is
    /// what lets one button handler serve a real modal dialog, a sheet parent and a test
    /// without the dialog knowing which of them it is in.
    func endModalSessionAndClose(code: NSApplication.ModalResponse = .OK) {
        if let window, NSApp.modalWindow === window {
            NSApp.stopModal(withCode: code)
        }
        close()
    }
}
