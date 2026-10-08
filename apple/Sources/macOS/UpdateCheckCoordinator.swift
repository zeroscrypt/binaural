import AppKit
import BinauralCore

/// Checks GitHub for a newer release and walks the user through installing it.
///
/// Two entry points, one implementation:
///
/// * ``runAtLaunch()`` — a silent background check. Nothing is shown unless a newer
///   release exists; a failure is silence, not a dialog, and a skipped version stays
///   skipped.
/// * ``checkFromAbout()`` — the About button. Whatever the answer — up to date, an
///   update, a failure — it is reported.
///
/// When an update is offered the user confirms each step: *Download and install* starts
/// the download (progress shown in its own window), and the install — which restarts the
/// app — is confirmed on its own. *Skip this version* remembers the release in the
/// session and stays silent about it until a newer one exists.
///
/// The checker, downloader and installer are injected, so the whole sequence is testable
/// without the network and without touching the real bundle.
@MainActor
final class UpdateCheckCoordinator {

    /// The session's memory of the release the user skipped.
    @MainActor
    protocol Target: AnyObject {
        /// The version to stay silent about, or `nil` for "ask about everything".
        func skippedUpdateVersion() -> String?
        /// Remember `version` as the one to skip; `nil` forgets it.
        func persistSkippedUpdateVersion(_ version: String?)
    }

    /// What the check produced.
    private enum Outcome {
        /// An answer: up to date, or a release to offer.
        case availability(UpdateAvailability)
        /// The check ran and failed; `message` says why in words a person can read.
        case failed(String)
        /// The running bundle has no version to compare, so there is nothing to check.
        case noVersion
    }

    /// The user's answer to the result dialog.
    private enum Choice {
        case download
        case skip
        case later
    }

    private let checker: UpdateChecker
    private let downloader: UpdateDownloader
    private let installer: UpdateInstaller
    private weak var target: (any Target)?
    private let presenter: any Presenting
    private let currentVersion: () -> AppVersion?
    /// The "the app will restart" confirmation. Injected so a test can answer it.
    private let confirmInstall: () -> Bool

    /// The last check's answer, for the tests and for the dialogs to read.
    private(set) var availability: UpdateAvailability?

    /// True while a check or a download is running, so the two entry points cannot
    /// overlap: a second modal dialog over the first is a dialog over nothing.
    private var isBusy = false

    init(
        checker: UpdateChecker = UpdateChecker(),
        downloader: UpdateDownloader = UpdateDownloader(),
        installer: UpdateInstaller = UpdateInstaller(),
        target: (any Target)? = nil,
        presenter: (any Presenting)? = nil,
        currentVersion: (() -> AppVersion?)? = nil,
        confirmInstall: (() -> Bool)? = nil
    ) {
        self.checker = checker
        self.downloader = downloader
        self.installer = installer
        self.target = target
        self.presenter = presenter ?? ModalPresenter()
        self.currentVersion = currentVersion ?? { AppVersion.running() }
        self.confirmInstall = confirmInstall ?? { UpdateCheckCoordinator.confirmInstall() }
    }

    // MARK: - The two entry points

    /// The launch check: silent unless there is an update to offer.
    func runAtLaunch() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // Only an update worth telling about interrupts the launch; a failure, an
        // up-to-date answer and a skipped version are all silence.
        guard case .availability(let availability) = await check(),
              availability.isWorthTelling else { return }
        self.availability = availability
        await present(availability)
    }

    /// The About button: check and report whatever the answer is.
    func checkFromAbout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch await check() {
        case .availability(let availability):
            self.availability = availability
            await present(availability)
        case .failed(let message):
            presentFailure(message)
        case .noVersion:
            presentFailure(L10n.tr(AboutContent.checkFailedMessage))
        }
    }

    /// Run the check and turn it into an outcome the entry points can act on.
    private func check() async -> Outcome {
        guard let current = currentVersion() else { return .noVersion }
        let skipped = target?.skippedUpdateVersion().flatMap(AppVersion.init)
        do {
            return .availability(try await checker.check(currentVersion: current, skipping: skipped))
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    // MARK: - The result dialog

    /// Present the result of a check and act on the user's answer.
    private func present(_ availability: UpdateAvailability) async {
        var choice: Choice = .later
        let mode: UpdateDialogController.Mode
        switch availability {
        case .upToDate:
            mode = .upToDate
        case .updateAvailable(_, let release), .skipped(_, let release):
            mode = .updateAvailable(release: release)
        }
        let dialog = UpdateDialogController(mode: mode)
        dialog.onDownload = { choice = .download }
        dialog.onSkip = { choice = .skip }
        presenter.present(dialog)
        switch choice {
        case .download:
            await downloadAndInstall()
        case .skip:
            // Remembered, and the launch check stays silent about this release until a
            // newer one exists.
            target?.persistSkippedUpdateVersion(availability.release?.version?.description)
        case .later:
            break
        }
    }

    private func presentFailure(_ message: String) {
        let dialog = UpdateDialogController(mode: .failed(message: message))
        presenter.present(dialog)
    }

    // MARK: - Download and install

    /// Download the offered release and install it, with the user's confirmation.
    ///
    /// The progress window is non-modal: the download runs while it is open and it closes
    /// itself when the download ends. The install is the dangerous step, so it is confirmed
    /// on its own and only then runs.
    func downloadAndInstall() async {
        guard let release = availability?.release,
              let version = release.version,
              let asset = release.macOSArchive() else { return }

        let progress = UpdateProgressController()
        progress.showWindow(nil)
        progress.window?.center()
        do {
            let archive = try await downloader.download(asset.downloadURL) { fraction in
                // The downloader reports on its own queue; the indicator is main-actor.
                // `assumeIsolated` would trap here — this closure is not on the main actor.
                Task { @MainActor in progress.setProgress(fraction) }
            }
            progress.close()
            guard confirmInstall() else { return }
            try installer.install(archive: archive, expectedVersion: version)
        } catch {
            progress.close()
            presentFailure(Self.message(for: error))
        }
    }

    // MARK: - Wording

    /// An error as a sentence the user can read.
    ///
    /// The app never shows a raw HTTP body or an `NSError`: every failure the update flow
    /// can produce is one of these, and each is a sentence with the cause in it. A check
    /// failure is one sentence; a download failure and an install failure are different
    /// ones, because the user's next move is different in each.
    private static func message(for error: Error) -> String {
        switch error {
        case is UpdateError:
            return L10n.tr(AboutContent.checkFailedMessage)
        case UpdateInstaller.UpdateInstallError.versionMismatch,
             UpdateInstaller.UpdateInstallError.replaceFailed,
             UpdateInstaller.UpdateInstallError.notThisApp:
            return L10n.tr(AboutContent.installFailedMessage)
        default:
            return L10n.tr(AboutContent.downloadFailedMessage)
        }
    }

    /// The "the app will restart" confirmation, as an `NSAlert` — the AppKit counterpart
    /// of Python's `QMessageBox.question`.
    private static func confirmInstall() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr(AboutContent.installConfirmMessage)
        alert.addButton(withTitle: L10n.tr(AboutContent.installAndRestartButton))
        alert.addButton(withTitle: L10n.tr(AboutContent.laterButton))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
