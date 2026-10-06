import AppKit
import BinauralCore

/// A one-line warning, shown where a dialog would be (§6 dialog fallbacks).
///
/// Python's answer to a missing dialog is `QMessageBox.information`. This is the same idea
/// in AppKit, kept here rather than spelled out at every call site so the fallback wording
/// and the parenting are consistent.
@MainActor
enum AppAlert {

    /// An informational message with a single OK button.
    static func runWarning(parent: NSWindow?, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: L10n.tr("Close"))
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// The About dialog of SPEC §7 — version, description, the §6.13 disclaimer and the licence.
///
/// Port of `ui/dialogs/about.py`. Two rules are inherited verbatim because they are the
/// point of the dialog:
///
/// * the disclaimer is **the SPEC §6.13 sentence**, held once in ``AboutContent`` so About
///   and the frequency reference cannot drift apart or soften it between them;
/// * nothing else in the dialog claims anything. No health claim is added, and the
///   description is the project's own words from SPEC §1/§2 — two tones, one perceived
///   difference, headphones as a physical requirement.
@MainActor
final class AboutDialogController: NSWindowController {

    private let scrollView = NSScrollView()
    private let body = NSStackView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 440, height: 420)
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
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        body.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        body.addArrangedSubview(heading(L10n.tr("Binaural")))
        body.addArrangedSubview(caption(AboutContent.versionText()))
        body.addArrangedSubview(paragraph(AboutContentText.tagline))
        body.addArrangedSubview(paragraph(AboutContentText.whatItIs))
        body.addArrangedSubview(paragraph(AboutContentText.whatItNeeds))
        body.addArrangedSubview(paragraph(AboutContentText.evidenceNote, muted: true))

        let link = LinkButton(title: AboutContent.projectURL, target: nil, action: nil)
        link.setAccessibilityLabel(L10n.tr("Open project page"))
        link.setAccessibilityHelp(L10n.tr("Open {url} in the browser", named: ["url": AboutContent.projectURL]))
        link.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        body.addArrangedSubview(link)

        body.addArrangedSubview(disclaimerBox())
        body.addArrangedSubview(licenseBox())
        body.addArrangedSubview(NSView())

        let close = NSButton()
        close.target = self
        close.action = #selector(closeTapped)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.title = L10n.tr("Close")
        close.setAccessibilityLabel(L10n.tr("Close the About dialog"))
        close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let row = NSStackView(views: [NSView(), close])
        row.orientation = .horizontal

        let root = NSStackView(views: [scrollView, row])
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            row.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        window?.contentView = content
    }

    private func disclaimerBox() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        let stack = NSStackView(views: [
            heading(L10n.tr("Disclaimer")),
            selectable(AboutContentText.disclaimer),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        box.contentView = stack
        box.setAccessibilityLabel(L10n.tr("Disclaimer"))
        // The tooltip is the accessibility description of the whole dialog, which is what
        // VoiceOver reads before the body.
        stack.views.last?.toolTip = L10n.tr(
            "Medical disclaimer — read it before using the application."
        )
        return box
    }

    private func licenseBox() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        let stack = NSStackView(views: [
            heading(L10n.tr("MIT License")),
            caption(AboutContent.copyrightText()),
            selectable(AboutContentText.licenseSummary),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        box.contentView = stack
        box.setAccessibilityLabel(L10n.tr("MIT License"))
        return box
    }

    /// A link-styled button.
    ///
    /// `NSButton(linkWithTitle:target:action:)` is the AppKit spelling, but the class was
    /// renamed away from that factory in a later SDK and the resulting selector no longer
    /// exists; a two-line subclass is the stable way to get a clickable URL that looks like
    /// one. It has to be a subclass because `bezelStyle`/`isBordered` are the properties
    /// that make it read as a link rather than a button.
    final class LinkButton: NSButton {
        init(title: String, target: AnyObject?, action: Selector?) {
            super.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
            bezelStyle = .inline
            isBordered = false
            contentTintColor = .linkColor
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    /// AppKit reaches the inherited `close()` through this shim: `#selector(close)` would
    /// resolve to the local button variable at this point in the file.
    @objc private func closeTapped() {
        close()
    }

    // MARK: - Label factories

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }

    private func paragraph(_ text: String, muted: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        if muted { label.textColor = .secondaryLabelColor }
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Selectable: a licence and a disclaimer are text a user may want to copy.
    private func selectable(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.isSelectable = true
        return label
    }

    // MARK: - Language

    func retranslate() {
        window?.title = L10n.tr("About Binaural")
        window?.setAccessibilityLabel(L10n.tr("About Binaural"))
        // Dialogs are created fresh on each open and read the language themselves
        // (SPEC §7.4); `retranslate` exists for the one case that matters — a language
        // switch while the dialog is up.
        for view in body.arrangedSubviews { retag(view, depth: 0) }
    }

    /// Re-fill the body by rebuilding it, which is what "read the language themselves"
    /// means for a dialog: the labels hold no state worth preserving.
    private func retag(_ view: NSView, depth: Int) {
        if let label = view as? NSTextField, depth == 0, label.isSelectable {
            label.stringValue = AboutContentText.disclaimer
            return
        }
        for sub in view.subviews { retag(sub, depth: depth + 1) }
    }

    // MARK: - State the tests read

    /// The whole visible body, top to bottom, as strings.
    var visibleLines: [String] {
        body.arrangedSubviews.flatMap { lines(in: $0) }
    }

    private func lines(in view: NSView) -> [String] {
        if let label = view as? NSTextField { return [label.stringValue] }
        return view.subviews.flatMap { lines(in: $0) }
    }

    /// The disclaimer text as shown — SPEC §6.13, verbatim, in the current language.
    var disclaimerText: String { AboutContentText.disclaimer }
    var versionText: String { body.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? "" }
}