import AppKit
import BinauralCore

/// Runs SPEC §4 at launch and keeps the window's indicator honest afterwards.
///
/// The order is Python's (`app.py::_run_headphone_check`): the window is on screen first,
/// then the check runs, because a modal dialog over a window that has not painted yet is a
/// dialog over nothing. The dialogs are run **modally** — `NSApp.runModal(for:)` is the
/// AppKit counterpart of Python's `dialog.exec()`, and it is what makes the launch check a
/// real step rather than a window that happens to be on screen.
///
/// **What happens at launch, in full:**
///
/// 1. `HeadphoneDetector.detect()` — the CoreAudio heuristic, using the device name and
///    transport type only. Silent, no questions, never an error (§4.1).
/// 2. If it is **sure**: headphones → the indicator turns green and nothing is asked.
/// 3. If it is **unsure** — `.unknown`, `.virtual` or a low-confidence verdict — the
///    perceptual L/R test runs *first*, and the §4.3 dialog then opens on its answer. The
///    user is asked the one question that decides it instead of being told "cannot tell".
/// 4. If headphones are **not confirmed**, the §4.3 dialog explains and offers
///    "Continue anyway", which is never disabled.
/// 5. `channelsSwapped` and `headphoneCheckAcknowledged` are stored (SPEC §5 F4/F5) and the
///    indicator is fed the report.
///
/// **Detection runs on every start; the dialog does not.** The user may have plugged in
/// headphones since yesterday, and detection is a couple of CoreAudio property reads — but
/// a startup dialog on every single launch is exactly the nag SPEC §4.3 refuses to be. So
/// the dialog appears when the verdict is not headphones **and** the user has not yet
/// acknowledged the warning, or when they ask for it (*Help → Check headphones*, the
/// window's own button, Settings).
@MainActor
final class HeadphoneCheckCoordinator {

    /// The window's indicator and session state, behind a tiny protocol so the sequence
    /// can be tested without an `NSWindow`.
    @MainActor
    protocol Target: AnyObject {
        /// Show the verdict on the always-visible status line (SPEC §7).
        func apply(headphoneReport: HeadphoneReport)
        /// Persist `headphoneCheckAcknowledged` / `channelsSwapped`.
        func persistHeadphoneState(acknowledged: Bool, channelsSwapped: Bool)
    }

    /// Shows a dialog and returns when it is done.
    ///
    /// Behind a protocol because `NSApp.runModal(for:)` **never returns on its own** — it
    /// spins a nested event loop until the dialog ends. Injected, the launch sequence can be
    /// driven to completion in a test without a modal loop; the app passes the real one.
    @MainActor
    protocol Presenting: AnyObject {
        func present(_ dialog: HeadphoneCheckDialogController)
        func present(_ dialog: LRTestDialogController)
    }

    /// The real presenter: a modal window, the AppKit counterpart of Python's
    /// `dialog.exec()`.
    ///
    /// `MainActor` like every AppKit operation in this file; the protocol is too, so the
    /// conformance is checked with the isolation it is meant to run under rather than
    /// needing `assumeIsolated` at every call.
    @MainActor
    final class ModalPresenter: Presenting {

        func present(_ dialog: HeadphoneCheckDialogController) {
            run(dialog)
        }

        func present(_ dialog: LRTestDialogController) {
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

    private let player: LRTonePlayer
    private weak var target: (any Target)?
    /// Injected for tests; the app passes nothing and gets the CoreAudio backend. Takes the
    /// previous report so a re-read keeps an L/R answer the user already gave —
    /// `HeadphoneDetector.detect(previous:)`'s own rule.
    private let detect: (HeadphoneReport?) -> HeadphoneReport
    private let presenter: any Presenting

    /// The most recent report, so the menu, the window button and Settings can show the
    /// same verdict without re-reading the device.
    private(set) var report: HeadphoneReport = .unknown

    /// Guards against re-entry. A modal loop re-enters this file's code — the answer
    /// callback lands while the loop is still on the stack — and a second modal loop there
    /// would leave the app unable to come back to its own event loop.
    private var isPresenting = false

    /// Injected for tests: the L/R sequence as a whole. The app leaves it `nil` and gets
    /// the real modal ``LRTestDialogController``; a test supplies a closure that answers
    /// immediately, so §4's branch ("unsure → ask perceptually") is exercised without a
    /// 3.3-second tone sequence and without a modal loop in the test host.
    private let perceptualStep: ((HeadphoneCheckCoordinator) -> HeadphoneReport)?

    /// What the last `runPerceptualTest()` call was given, for tests.
    private(set) var lastLRAnswer: LRTestResult?

    init(
        player: LRTonePlayer,
        target: any Target,
        detect: ((HeadphoneReport?) -> HeadphoneReport)? = nil,
        perceptualStep: ((HeadphoneCheckCoordinator) -> HeadphoneReport)? = nil,
        presenter: (any Presenting)? = nil
    ) {
        self.player = player
        self.target = target
        self.detect = detect ?? { previous in HeadphoneDetector.detect(previous: previous) }
        self.perceptualStep = perceptualStep
        self.presenter = presenter ?? ModalPresenter()
    }

    // MARK: - The sequence

    /// Run the check at launch. Returns the report so a caller (or a test) can see it.
    @discardableResult
    func runAtLaunch(acknowledged: Bool) -> HeadphoneReport {
        report = detect(report.lrTest == nil ? nil : report)

        // Unsure: settle it perceptually before saying anything. §4.2's whole purpose is
        // to show the real result rather than guess about the hardware.
        if needsPerceptualTest(report) {
            report = runPerceptualTest()
        }

        if report.isHeadphones {
            // Nothing to warn about, and nothing to acknowledge.
            target?.apply(headphoneReport: report)
            target?.persistHeadphoneState(
                acknowledged: true,
                channelsSwapped: report.channelsSwapped
            )
            return report
        }

        if acknowledged {
            // Already warned once. The indicator still says "Speakers detected" — SPEC
            // §4.3 wants the warning visible for as long as it is true — but the user is
            // not nagged on every start.
            target?.apply(headphoneReport: report)
            return report
        }

        return presentDialog()
    }

    /// Show the §4.3 dialog and store the outcome.
    ///
    /// The one entry point for every manual re-check: the *Help* menu item, the window's
    /// own check button (SPEC §7) and Settings all land here, so they cannot drift apart.
    @discardableResult
    func presentDialog() -> HeadphoneReport {
        guard let target, !isPresenting else { return report }
        isPresenting = true
        defer { isPresenting = false }

        let dialog = HeadphoneCheckDialogController(player: player, report: report) { [weak self] in
            guard let self else { return .unknown }
            return self.detect(self.report.lrTest == nil ? nil : self.report)
        }
        // An injected perceptual step answers the §4.2 question without a modal loop. The
        // real one has already been folded into `report` by the sequence's own callback,
        // and the dialog opens on that report either way.
        if perceptualStep != nil, let answer = lastLRAnswer {
            dialog.setLRResult(answer)
        }
        presenter.present(dialog)

        self.report = dialog.report
        // `acknowledged` is true when the user chose to continue — the dialog's only way
        // out besides the window's close button, which means the same thing.
        target.persistHeadphoneState(
            acknowledged: dialog.acknowledged || dialog.report.isHeadphones,
            channelsSwapped: dialog.report.channelsSwapped
        )
        target.apply(headphoneReport: dialog.report)
        return dialog.report
    }

    /// Re-run from the menu or the window's button: re-read the device first, then ask.
    @discardableResult
    func rerunFromUser() -> HeadphoneReport {
        report = detect(report.lrTest == nil ? nil : report)
        return presentDialog()
    }

    /// Play the §4.2 sequence alone and fold the answer in — what Settings offers when the
    /// user wants to settle the channel question without the rest of the dialog.
    @discardableResult
    func runPerceptualTest() -> HeadphoneReport {
        guard !isPresenting else { return report }
        isPresenting = true
        defer { isPresenting = false }

        if let perceptualStep {
            lastLRAnswer = nil
            return perceptualStep(self)
        }

        let dialog = LRTestDialogController(player: player)
        dialog.onAnswer = { [weak self] answer in
            guard let self else { return }
            self.lastLRAnswer = answer
            self.report = HeadphoneDetector.withLRResult(answer, in: self.report)
        }
        presenter.present(dialog)
        if let answer = dialog.answer {
            lastLRAnswer = answer
            report = HeadphoneDetector.withLRResult(answer, in: report)
        }
        return report
    }

    /// Feed an L/R answer in as if the user had given it — Settings' "test now" and the
    /// tests both use this, and neither has to go near a modal loop.
    @discardableResult
    func applyLRAnswer(_ answer: LRTestResult) -> HeadphoneReport {
        lastLRAnswer = answer
        report = HeadphoneDetector.withLRResult(answer, in: report)
        return report
    }

    /// The heuristic is unsure when it has no opinion, or when its opinion came from a
    /// device that says nothing about the physical setup.
    ///
    /// `low` confidence is included because `HeadphoneDetector.detect` reports `low`
    /// exactly when the verdict is `.unknown` or no device could be read — stated rather
    /// than implied, so the rule can be asserted in a test.
    func needsPerceptualTest(_ report: HeadphoneReport) -> Bool {
        report.verdict == .unknown || report.verdict == .virtual || report.confidence == .low
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
