import AppKit
import BinauralCore

/// A progress window shown while the update downloads.
///
/// Non-modal on purpose: the download runs while it is open, the downloader reports
/// progress on its own queue, and the window closes itself when the download ends. A
/// modal dialog here would mean running the download inside a nested event loop, which
/// is the one thing the rest of the app's dialogs never have to do.
@MainActor
final class UpdateProgressController: NSWindowController {

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
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

        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [messageLabel, progressIndicator])
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
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.contentView = content
    }

    // MARK: - Progress

    /// How much of the download has arrived, 0...1. Called on the downloader's queue.
    func setProgress(_ fraction: Double) {
        progressIndicator.doubleValue = min(max(fraction, 0), 1)
    }

    // MARK: - Language

    func retranslate() {
        messageLabel.stringValue = L10n.tr(AboutContent.downloadingMessage)
        window?.title = L10n.tr(AboutContent.downloadingMessage)
        window?.setAccessibilityLabel(messageLabel.stringValue)
    }

    // MARK: - State the tests read

    var messageText: String { messageLabel.stringValue }
    var progress: Double { progressIndicator.doubleValue }
}
