import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// The update check: the launch sequence, the About button, and the install flow.
///
/// The checker, downloader and installer are all injected, so the whole sequence runs
/// without the network and without touching the real bundle — the same hermetic rule as
/// `HeadphoneCheckTests`. What is verified is the app's behaviour: which dialog appears
/// for which answer, what the user's answer leads to, and what gets remembered.
@MainActor
final class UpdateCheckTests: XCTestCase {

    /// A lock-protected recorder for values a `@Sendable` closure captures — the MacTests
    /// counterpart of the `Recorder` in `CoreTests/TestSupport.swift`.
    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []

        func append(_ value: Value) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        var snapshot: [Value] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        L10n.setLanguage("en")
    }

    override func tearDown() async throws {
        L10n.setLanguage("en")
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The session's memory of the skipped release.
    private final class TargetSpy: UpdateCheckCoordinator.Target {
        var skipped: String?
        private(set) var persisted: [String?] = []

        func skippedUpdateVersion() -> String? { skipped }
        func persistSkippedUpdateVersion(_ version: String?) {
            skipped = version
            persisted.append(version)
        }
    }

    /// A presenter that answers the result dialog immediately instead of spinning a modal
    /// event loop — the `ScriptedPresenter` of `HeadphoneCheckTests`, for the same reason.
    @MainActor
    private final class ScriptedPresenter: Presenting {
        enum Action { case download, skip, dismiss }
        /// `nil` records the dialog and leaves it open, so a test can read what was shown.
        let action: Action?
        private(set) var presented: UpdateDialogController?

        init(action: Action?) { self.action = action }

        func present(_ dialog: NSWindowController) {
            guard let dialog = dialog as? UpdateDialogController else { return }
            presented = dialog
            switch action {
            case .download: dialog.download.performClick(nil)
            case .skip: dialog.skip.performClick(nil)
            case .dismiss: dialog.dismiss.performClick(nil)
            case nil: break
            }
        }
    }

    /// A canned release document, the way `UpdateCheckerTests` builds one.
    private static func releaseJSON(tag: String) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "name": "\(tag)",
          "html_url": "https://github.com/zeroscrypt/binaural/releases/tag/\(tag)",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "binaural-\(tag)-macos-arm64.tar.gz", "size": 2400000, \
        "browser_download_url": "https://github.com/zeroscrypt/binaural/releases/download/\(tag)/binaural-\(tag)-macos-arm64.tar.gz", \
        "content_type": "application/gzip"}
          ]
        }
        """.utf8)
    }

    /// A checker that answers with the release tagged `tag`.
    private func checker(tag: String) -> UpdateChecker {
        let document = Self.releaseJSON(tag: tag)
        return UpdateChecker(fetch: { _ in document })
    }

    /// A real release archive: a minimal `Binaural.app` with `CFBundleShortVersionString`
    /// set to `version`, tarred the way the release pipeline tars it. The installer
    /// extracts before it replaces, so the mock has to be a valid archive — a file of
    /// junk would fail in `extract` and never reach the replace and relaunch under test.
    private nonisolated static func archiveData(version: String) -> Data {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-test-archive-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Binaural.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try? Data("binary".utf8).write(to: macOS.appendingPathComponent("Binaural"))
        let info = app.appendingPathComponent("Contents/Info.plist")
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleShortVersionString</key>
                <string>\(version)</string>
                <key>CFBundleExecutable</key>
                <string>Binaural</string>
                <key>CFBundleIdentifier</key>
                <string>app.binaural.mac</string>
            </dict>
            </plist>
            """
        try? plist.write(to: info, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-czf", "-", "-C", root.path, "Binaural.app"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? FileManager.default.removeItem(at: root)
        return data
    }

    /// A downloader that writes a valid release archive and reports the whole range.
    private func downloader(version: String) -> UpdateDownloader {
        UpdateDownloader(load: { url, progress in
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("binaural-update-test-\(UUID().uuidString)-\(url.lastPathComponent)")
            progress?(0.5)
            progress?(1.0)
            try Self.archiveData(version: version).write(to: file)
            return file
        })
    }

    /// An installer that records what it was asked to do.
    private func installer(events: Recorder<String>) -> UpdateInstaller {
        UpdateInstaller(
            replace: { _, _ in events.append("replace") },
            relauncher: { _ in events.append("relaunch") }
        )
    }

    private func makeCoordinator(
        tag: String = "v0.2.0",
        current: String = "0.1.0",
        target: TargetSpy = TargetSpy(),
        presenter: ScriptedPresenter,
        confirmInstall: @escaping () -> Bool = { true },
        events: Recorder<String>? = nil
    ) -> UpdateCheckCoordinator {
        UpdateCheckCoordinator(
            checker: checker(tag: tag),
            downloader: downloader(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag),
            installer: events.map { installer(events: $0) } ?? UpdateInstaller(
                replace: { _, _ in },
                relauncher: { _ in }
            ),
            target: target,
            presenter: presenter,
            currentVersion: { AppVersion(current) },
            confirmInstall: confirmInstall
        )
    }

    // MARK: - The launch check

    /// Up to date at launch: silence, no dialog.
    func testLaunchCheckIsSilentWhenUpToDate() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = makeCoordinator(tag: "v0.1.0", presenter: presenter)
        await coordinator.runAtLaunch()
        XCTAssertNil(presenter.presented, "up to date is silence at launch")
    }

    /// A failure at launch: silence, not a dialog.
    func testLaunchCheckIsSilentWhenTheCheckFails() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = UpdateCheckCoordinator(
            checker: UpdateChecker(fetch: { _ in throw UpdateError.transport("offline") }),
            presenter: presenter,
            currentVersion: { AppVersion("0.1.0") }
        )
        await coordinator.runAtLaunch()
        XCTAssertNil(presenter.presented, "a failed check is silence at launch")
    }

    /// A skipped version at launch: silence.
    func testLaunchCheckIsSilentWhenTheVersionIsSkipped() async {
        let presenter = ScriptedPresenter(action: nil)
        let target = TargetSpy()
        target.skipped = "0.2.0"
        let coordinator = makeCoordinator(tag: "v0.2.0", target: target, presenter: presenter)
        await coordinator.runAtLaunch()
        XCTAssertNil(presenter.presented, "a skipped version is silence at launch")
    }

    /// A newer release at launch: the update is offered, with the version in the message.
    func testLaunchCheckOffersTheUpdate() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = makeCoordinator(tag: "v0.2.0", presenter: presenter)
        await coordinator.runAtLaunch()
        let dialog = try? XCTUnwrap(presenter.presented)
        XCTAssertEqual(dialog?.messageText, "Version 0.2.0 is available")
        XCTAssertFalse(dialog?.isDownloadHidden ?? true)
        XCTAssertFalse(dialog?.isSkipHidden ?? true)
    }

    // MARK: - The About button

    /// Up to date from About: reported, with nothing to download.
    func testAboutCheckReportsUpToDate() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = makeCoordinator(tag: "v0.1.0", presenter: presenter)
        await coordinator.checkFromAbout()
        let dialog = try? XCTUnwrap(presenter.presented)
        XCTAssertEqual(dialog?.messageText, "You are up to date")
        XCTAssertTrue(dialog?.isDownloadHidden ?? false)
        XCTAssertTrue(dialog?.isSkipHidden ?? false)
    }

    /// An update from About: reported, with the version and the way to install it.
    func testAboutCheckReportsTheUpdate() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = makeCoordinator(tag: "v0.2.0", presenter: presenter)
        await coordinator.checkFromAbout()
        let dialog = try? XCTUnwrap(presenter.presented)
        XCTAssertEqual(dialog?.messageText, "Version 0.2.0 is available")
        XCTAssertEqual(dialog?.downloadButtonTitle, "Download and install")
        XCTAssertEqual(dialog?.skipButtonTitle, "Skip this version")
        XCTAssertEqual(dialog?.dismissButtonTitle, "Later")
    }

    /// A failure from About: reported, because the user asked.
    func testAboutCheckReportsAFailure() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = UpdateCheckCoordinator(
            checker: UpdateChecker(fetch: { _ in throw UpdateError.transport("offline") }),
            presenter: presenter,
            currentVersion: { AppVersion("0.1.0") }
        )
        await coordinator.checkFromAbout()
        let dialog = try? XCTUnwrap(presenter.presented)
        XCTAssertEqual(dialog?.messageText, "Could not check for updates")
        XCTAssertTrue(dialog?.isDownloadHidden ?? false)
    }

    // MARK: - The user's answer

    /// *Download and install* runs the download, the confirmation and the install, in
    /// that order.
    func testDownloadAndInstallRunsTheSequence() async {
        let events = Recorder<String>()
        let presenter = ScriptedPresenter(action: .download)
        let coordinator = makeCoordinator(tag: "v0.2.0", presenter: presenter, events: events)
        await coordinator.checkFromAbout()
        XCTAssertEqual(events.snapshot, ["replace", "relaunch"])
    }

    /// Declining the restart confirmation leaves the app as it was.
    func testDecliningTheRestartConfirmationInstallsNothing() async {
        let events = Recorder<String>()
        let presenter = ScriptedPresenter(action: .download)
        let coordinator = makeCoordinator(
            tag: "v0.2.0", presenter: presenter, confirmInstall: { false }, events: events
        )
        await coordinator.checkFromAbout()
        XCTAssertTrue(events.snapshot.isEmpty, "nothing is installed when the user declines")
    }

    /// *Skip this version* remembers the release, and the launch check stays silent about
    /// it afterwards.
    func testSkipRemembersTheVersion() async {
        let target = TargetSpy()
        let presenter = ScriptedPresenter(action: .skip)
        let coordinator = makeCoordinator(tag: "v0.2.0", target: target, presenter: presenter)
        await coordinator.checkFromAbout()
        XCTAssertEqual(target.skipped, "0.2.0")
        XCTAssertEqual(target.persisted, ["0.2.0"])

        // The next launch check with the same release is silent.
        let launchPresenter = ScriptedPresenter(action: nil)
        let launchCoordinator = makeCoordinator(tag: "v0.2.0", target: target, presenter: launchPresenter)
        await launchCoordinator.runAtLaunch()
        XCTAssertNil(launchPresenter.presented, "the skipped version stays silent at launch")
    }

    /// *Later* is the same as closing the dialog: nothing happens, nothing is remembered.
    func testLaterInstallsNothingAndRemembersNothing() async {
        let target = TargetSpy()
        let events = Recorder<String>()
        let presenter = ScriptedPresenter(action: .dismiss)
        let coordinator = makeCoordinator(tag: "v0.2.0", target: target, presenter: presenter, events: events)
        await coordinator.checkFromAbout()
        XCTAssertTrue(events.snapshot.isEmpty)
        XCTAssertNil(target.skipped)
        XCTAssertTrue(target.persisted.isEmpty)
    }

    // MARK: - The dialogs

    /// The result dialog follows the language, like every other dialog in the app.
    func testTheResultDialogFollowsTheLanguage() async {
        let presenter = ScriptedPresenter(action: nil)
        let coordinator = makeCoordinator(tag: "v0.2.0", presenter: presenter)
        await coordinator.checkFromAbout()
        let english = try? XCTUnwrap(presenter.presented)
        XCTAssertEqual(english?.messageText, "Version 0.2.0 is available")

        L10n.setLanguage("ru")
        let russianPresenter = ScriptedPresenter(action: nil)
        let russianCoordinator = makeCoordinator(tag: "v0.2.0", presenter: russianPresenter)
        await russianCoordinator.checkFromAbout()
        let russian = try? XCTUnwrap(russianPresenter.presented)
        XCTAssertEqual(russian?.messageText, "Доступна версия 0.2.0")
        XCTAssertEqual(russian?.downloadButtonTitle, "Скачать и установить")
        L10n.setLanguage("en")
    }

    /// The progress window reports what the downloader reports, clamped to 0...1.
    func testTheProgressWindowReportsProgress() {
        let progress = UpdateProgressController()
        progress.setProgress(0.5)
        XCTAssertEqual(progress.progress, 0.5)
        progress.setProgress(1.5)
        XCTAssertEqual(progress.progress, 1.0, "progress cannot run past the end")
        progress.setProgress(-1)
        XCTAssertEqual(progress.progress, 0, "progress cannot go backwards below zero")
        XCTAssertEqual(progress.messageText, "Downloading update…")
    }

    /// The About dialog carries the button, and it is the app's coordinator behind it.
    func testTheAboutDialogCarriesTheCheckForUpdatesButton() {
        let dialog = AboutDialogController()
        XCTAssertEqual(dialog.checkForUpdatesButton.title, AboutContentText.checkForUpdatesButton)
        XCTAssertFalse(dialog.checkForUpdatesButton.isHidden)
    }
}
