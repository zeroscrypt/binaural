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

/// Keeps a non-modal dialog alive for as long as its window is on screen.
///
/// AppKit holds a control's target **weakly**. A controller that exists only in a local
/// variable is deallocated the instant the method that created it returns — and every
/// button in its window keeps its place, its caption and its layout, with a `nil` target.
/// The dialog is on screen, translated, and answers nothing: no category chip, no Apply, no
/// Close, no Escape. That is not a subtle degradation, it is the whole dialog.
///
/// ``ModalPresenter`` never saw it, because its nested event loop keeps the caller's local
/// alive for the entire modal session. A dialog shown with `showWindow(_:)` and nothing
/// else gets no such accident of scope — the reference, About and the L/R test inside the
/// headphone check were all shown that way, and all three were dead on arrival.
///
/// A kept dialog is held until `NSWindow.willCloseNotification`, so one the user has
/// finished with is not retained for the life of the process.
@MainActor
final class WindowKeeper {

    static let shared = WindowKeeper()

    private var kept: [ObjectIdentifier: NSWindowController] = [:]
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Show `controller`, centred, and hold it until its window closes.
    func show(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.center()
        keep(controller)
    }

    /// Hold `controller` until its window closes, without showing it.
    ///
    /// Separate from ``show(_:)`` because a test host cannot call `showWindow(_:)` — it
    /// would run the real window server against the test runner and restart the whole
    /// suite. `window` is read without showing, which is enough to make the window exist
    /// and give the keeper something to observe.
    func keep(_ controller: NSWindowController) {
        guard let window = controller.window else { return }

        let key = ObjectIdentifier(controller)
        kept[key] = controller
        guard observers[key] == nil else { return }
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.kept[key] = nil
            self.observers[key] = nil
        }
    }

    /// How many dialogs are being kept right now — a test hook, and the quickest way to
    /// see a keeper that never lets go.
    var count: Int { kept.count }

    /// Drop everything being held. A test case that does not do this leaks its dialog into
    /// the next one.
    func resetForTest() {
        for token in observers.values {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        kept.removeAll()
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
