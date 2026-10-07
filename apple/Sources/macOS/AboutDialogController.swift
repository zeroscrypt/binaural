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
    private var languageObserver: (any NSObjectProtocol)?

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

        // SPEC §7.4 says a dialog is built fresh on each open and reads the language itself.
        // It does not say what happens when the language changes while one is open, and the
        // answer that costs least and reads best is: it follows. The Settings dialog does
        // the same, so *View → Language* works from anywhere.
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retranslate() }
        }
    }

    /// Stop observing. `deinit` cannot do it: a `deinit` is nonisolated and the token is
    /// not `Sendable`.
    func tearDown() {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
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
        // The document goes into the scroll view **before** the width constraint is
        // activated: a constraint between two views that have no common ancestor is illegal,
        // and `documentView` is what makes them related.
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        rebuildBody()

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
            row.widthAnchor.constraint(equalTo: root.widthAnchor),
            // A vertical `NSStackView` sizes an arranged subview to its **intrinsic**
            // width, and `NSScrollView` has none. Without this the scroll view lays out
            // at zero width, every label inside it collapses to a few points, and the
            // whole body renders blank — with the text still present in the
            // accessibility tree, which is why a label-based test cannot see it.
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor)
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

    /// One titled section of SPEC §7 item 6: a heading and its body lines.
    ///
    /// A heading in `heading()`'s 16pt would compete with the `Binaural` title, so the
    /// section heading gets its own size — visible as a heading, clearly below the title.
    /// The body lines are plain paragraphs: nothing here is legal text, so they are not
    /// `selectable()` and not 11pt caption type the way the disclaimer and licence are.
    private func sectionBox(title: String, lines: [String]) -> NSView {
        let stack = NSStackView(views: [
            sectionHeading(title),
        ])
        for line in lines {
            stack.addArrangedSubview(paragraph(line))
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // Autoresizing, not Auto Layout, like every other label in this dialog. An
        // `NSStackView` has no intrinsic content size, so pinning it into constraints
        // gives it an undetermined — in practice zero — height and the section renders
        // as empty space. The parent `body` stack sizes it from its arranged subviews.
        return stack
    }

    /// The four sections, in the order ``AboutContent`` declares them.
    ///
    /// A table rather than four `addArrangedSubview` calls at the call site: the order is
    /// part of what the dialog says, and one list is the one place to change it. Each
    /// entry is `(title, body)` with the title already translated, because the headings
    /// go through ``AboutContentText``.
    private var sections: [(title: String, body: [String])] {
        [
            (AboutContentText.whoMadeItTitle,
             [AboutContentText.creditsLine, AboutContentText.creditsWhere]),
            (AboutContentText.howItWorksTitle,
             [AboutContentText.mechanismLine, AboutContentText.termsLine,
              AboutContentText.headphonesWhyLine, AboutContentText.appDoesLine]),
            (AboutContentText.whatItIsForTitle,
             [AboutContentText.scopeLine, AboutContentText.notMedicalLine]),
            (AboutContentText.technicalTitle,
             [AboutContentText.platformLicenceLine, AboutContentText.stackLine,
              AboutContentText.unsignedLine]),
        ]
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

    /// A section heading: semibold, but smaller than `heading()` so the `Binaural`
    /// title at the top of the dialog stays the largest thing on screen.
    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
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
        window?.title = AboutContentText.aboutTitle
        window?.setAccessibilityLabel(AboutContentText.aboutTitle)
        rebuildBody()
    }

    /// Fill the body from ``AboutContent``, in the current language.
    ///
    /// Rebuilt rather than patched. SPEC §7.4 says a dialog is created fresh on each open
    /// and reads the language itself — there is no state here worth preserving, and
    /// rebuilding is the only version that cannot leave one label in the previous language
    /// after a switch. The **disclaimer is rebuilt from the same constant** the frequency
    /// reference shows, so the two cannot drift apart or soften between them.
    private func rebuildBody() {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        body.addArrangedSubview(heading(L10n.tr("Binaural")))
        body.addArrangedSubview(caption(AboutContent.versionText()))
        body.addArrangedSubview(paragraph(AboutContentText.tagline))
        body.addArrangedSubview(paragraph(AboutContentText.whatItIs))
        body.addArrangedSubview(paragraph(AboutContentText.whatItNeeds))
        body.addArrangedSubview(paragraph(AboutContentText.evidenceNote, muted: true))

        let link = LinkButton(title: AboutContent.projectURL, target: nil, action: nil)
        link.setAccessibilityLabel(L10n.tr("Open project page"))
        link.setAccessibilityHelp(
            L10n.tr("Open {url} in the browser", named: ["url": AboutContent.projectURL])
        )
        link.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        body.addArrangedSubview(link)

        // The four sections of SPEC §7 item 6, between the link and the disclaimer: what
        // it is, how it works, who made it and the technical facts come before the legal
        // text, which is the order a reader arriving at the dialog wants them in. Same
        // position as in `about.py`, so the two dialogs read identically.
        for section in sections {
            body.addArrangedSubview(sectionBox(title: section.title, lines: section.body))
        }

        body.addArrangedSubview(disclaimerBox())
        body.addArrangedSubview(licenseBox())
        body.addArrangedSubview(NSView())
    }

    // MARK: - State the tests read

    /// The whole visible body, top to bottom, as strings.
    var visibleLines: [String] {
        body.arrangedSubviews.flatMap { lines(in: $0) }
    }

    /// Labels **and** buttons: the project link is a button whose title is the URL, and a
    /// "visible body" that omitted it would make the link untestable.
    private func lines(in view: NSView) -> [String] {
        if let label = view as? NSTextField { return [label.stringValue] }
        if let button = view as? NSButton, !button.title.isEmpty { return [button.title] }
        return view.subviews.flatMap { lines(in: $0) }
    }

    /// The disclaimer text as shown — SPEC §6.13, verbatim, in the current language.
    var disclaimerText: String { AboutContentText.disclaimer }
    var versionText: String { body.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? "" }
}