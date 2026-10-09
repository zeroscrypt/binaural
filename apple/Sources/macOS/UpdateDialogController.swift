import AppKit
import BinauralCore

/// The update check's result: up to date, an update to offer, or a failure.
///
/// One dialog for every answer the check can give, so the About button and the launch
/// check show the same wording in the same order. The buttons are the user's confirmation
/// — nothing downloads or installs from this dialog alone; the coordinator acts on the
/// answer after the modal session ends.
@MainActor
final class UpdateDialogController: NSWindowController {

    /// What the dialog reports and offers.
    enum Mode {
        /// Nothing newer than the running version.
        case upToDate
        /// A newer release exists, with the archive to install.
        case updateAvailable(release: GitHubRelease)
        /// The check failed; `message` says why, in words the user can read.
        case failed(message: String)
    }

    private let mode: Mode

    /// Fired when the user chooses *Download and install*, before the dialog closes.
    var onDownload: (() -> Void)?
    /// Fired when the user chooses *Skip this version*, before the dialog closes.
    var onSkip: (() -> Void)?

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = NSButton()
    private let skipButton = NSButton()
    /// *Later* when there is an update to put off, *Close* when there is nothing to act
    /// on — the same answer either way: the dialog goes away and nothing is installed.
    private let dismissButton = NSButton()
    private let releasePageButton = NSButton()

    init(mode: Mode) {
        self.mode = mode
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 420, height: 180)
        super.init(window: window)
        buildContent()
        retranslate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the dialog is built in code")
    }

    // MARK: - Building

    private func buildContent() {
        messageLabel.font = .systemFont(ofSize: 13)

        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"

        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.bezelStyle = .rounded

        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.bezelStyle = .rounded

        // The release page is a link, like the project link in About: the release notes
        // are the one thing worth reading before installing.
        releasePageButton.bezelStyle = .inline
        releasePageButton.isBordered = false
        releasePageButton.contentTintColor = .linkColor
        releasePageButton.target = self
        releasePageButton.action = #selector(releasePageTapped)
        releasePageButton.setAccessibilityLabel(L10n.tr(AboutContent.releasePageButton))

        let buttons = NSStackView(views: [downloadButton, skipButton, NSView(), dismissButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [messageLabel, releasePageButton, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // SPEC §7.2: 44 px minimum click target, every button.
            downloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            skipButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dismissButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            releasePageButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.contentView = content
    }

    // MARK: - Actions

    @objc private func downloadTapped() {
        onDownload?()
        endModalSessionAndClose()
    }

    @objc private func skipTapped() {
        onSkip?()
        endModalSessionAndClose()
    }

    @objc private func dismissTapped() {
        endModalSessionAndClose()
    }

    /// Escape means "not now", the same as *Later* — SPEC §7.2's Escape-to-close, and the
    /// update flow is the one place where it matters most, since the dialog appears on its
    /// own at launch. See ``AboutDialogController/cancelOperation(_:)`` for why this is an
    /// override rather than a key equivalent.
    override func cancelOperation(_ sender: Any?) {
        dismissTapped()
    }

    @objc private func releasePageTapped() {
        guard case .updateAvailable(let release) = mode,
              let url = release.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Language

    func retranslate() {
        switch mode {
        case .upToDate:
            messageLabel.stringValue = L10n.tr(AboutContent.upToDateMessage)
            window?.title = L10n.tr(AboutContent.upToDateMessage)
            downloadButton.isHidden = true
            skipButton.isHidden = true
            releasePageButton.isHidden = true
        case .updateAvailable(let release):
            messageLabel.stringValue = L10n.tr(
                AboutContent.updateAvailableTemplate,
                named: ["version": release.version?.description ?? release.tagName]
            )
            window?.title = L10n.tr(AboutContent.checkForUpdatesButton)
            downloadButton.isHidden = false
            skipButton.isHidden = false
            releasePageButton.isHidden = release.htmlURL == nil
        case .failed(let message):
            messageLabel.stringValue = message
            window?.title = L10n.tr(AboutContent.checkFailedMessage)
            downloadButton.isHidden = true
            skipButton.isHidden = true
            releasePageButton.isHidden = true
        }
        downloadButton.title = L10n.tr(AboutContent.downloadAndInstallButton)
        skipButton.title = L10n.tr(AboutContent.skipThisVersionButton)
        dismissButton.title = L10n.tr(
            downloadButton.isHidden ? "Close" : AboutContent.laterButton
        )
        releasePageButton.title = L10n.tr(AboutContent.releasePageButton)
        window?.setAccessibilityLabel(messageLabel.stringValue)
    }

    // MARK: - State the tests read

    var messageText: String { messageLabel.stringValue }
    var isDownloadHidden: Bool { downloadButton.isHidden }
    var isSkipHidden: Bool { skipButton.isHidden }
    var downloadButtonTitle: String { downloadButton.title }
    var skipButtonTitle: String { skipButton.title }
    var dismissButtonTitle: String { dismissButton.title }

    /// The buttons, so a test (or a scripted presenter) can press them.
    var download: NSButton { downloadButton }
    var skip: NSButton { skipButton }
    var dismiss: NSButton { dismissButton }
}
