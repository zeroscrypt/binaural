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

    /// The update check this dialog's button runs. Injected by the app delegate, which
    /// owns the one coordinator that also runs at launch; a dialog built without one (a
    /// test) gets its own.
    private let coordinator: UpdateCheckCoordinator

    private let checkUpdatesButton = NSButton()

    init(coordinator: UpdateCheckCoordinator? = nil) {
        self.coordinator = coordinator ?? UpdateCheckCoordinator()
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
        // The body is full of **wrapping** labels, and a wrapping label only wraps if
        // something gives it a width — see ``fillWidth(_:)``, which is what pins them.
        body.alignment = .leading
        body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        body.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        // Auto Layout, not autoresizing — and that is the whole fix for this dialog coming up
        // as a 16 pt wide strip. Left on autoresizing, AppKit sized the document view to the
        // clip view **in both directions**, so the body (four sections, the disclaimer, the
        // licence) had to fit into one viewport's height. Auto Layout compressed it, the
        // `Stack.Min` chain broke, and the width collapsed to the width of a scrollbar.
        //
        // The width is pinned to the clip view so the text wraps at the window's width; the
        // **height is deliberately not pinned to anything**, because a document taller than
        // the viewport is what scrolling *is*. No bottom constraint either — the document is
        // exactly as tall as the body.
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        // The document goes into the scroll view **before** the constraints are
        // activated: a constraint between two views that have no common ancestor is
        // illegal, and `documentView` is what makes them related.
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            // The document is exactly as tall as the body — and that is what makes the
            // scroll range non-zero. Pinning the body to the document's bottom is not the
            // same as pinning the document to the viewport: the document stays free to grow
            // past it, which is the whole point of a scrolling body.
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor)
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

        // The update check, in the dialog it belongs to: the same check the app runs at
        // launch, offered here so the user does not have to wait to be told.
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdatesTapped)
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.title = AboutContentText.checkForUpdatesButton
        checkUpdatesButton.setAccessibilityLabel(AboutContentText.checkForUpdatesButton)
        checkUpdatesButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let row = NSStackView(views: [checkUpdatesButton, NSView(), close])
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
            contentWidth(of: root, for: row),
            // A vertical `NSStackView` sizes an arranged subview to its **intrinsic**
            // width, and `NSScrollView` has none. Without this the scroll view lays out
            // at zero width, every label inside it collapses to a few points, and the
            // whole body renders blank — with the text still present in the
            // accessibility tree, which is why a label-based test cannot see it.
            contentWidth(of: root, for: scrollView)
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        fillWidth(stack)
        box.setAccessibilityLabel(L10n.tr("Disclaimer"))
        // The tooltip is the accessibility description of the whole dialog, which is what
        // VoiceOver reads before the body.
        stack.views.last?.toolTip = L10n.tr(
            "Medical disclaimer — read it before using the application."
        )
        return box
    }

    /// Pin every arranged subview to the stack's own width.
    ///
    /// A vertical `NSStackView` hands its arranged subviews their **fitting** width, and the
    /// fitting width of a wrapping `NSTextField` is the whole paragraph laid out on one line.
    /// Left alone, every label in the About body asks for the width of the licence text, the
    /// document outgrows the scroll view sideways and the layout resolves the contradiction by
    /// squeezing everything — which is how the dialog came up as a 16 pt wide strip instead
    /// of wrapping its text.
    ///
    /// Spelled out rather than left to an alignment value on purpose: `NSStackView`'s
    /// cross-axis behaviour is not something to depend on for correctness.
    private func fillWidth(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentWidth(of: stack, for: view).isActive = true
        }
    }

    /// `stack.widthAnchor` is the stack **including** its edge insets, so pinning an arranged
    /// subview to it asks for more width than the stack has left to give: with 12 pt insets
    /// each side every label came out wider than the space between them, Auto Layout
    /// compressed the stack to reconcile it, and the sections drew on top of each other.
    /// The width an arranged subview may use is what is left after the insets.
    private func contentWidth(of stack: NSStackView, for view: NSView) -> NSLayoutConstraint {
        let insets = stack.edgeInsets
        return view.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(insets.left + insets.right)
        )
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
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        fillWidth(stack)
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

    /// *Check for updates* — the same check the app runs at launch, on request.
    @objc private func checkForUpdatesTapped() {
        Task { await coordinator.checkFromAbout() }
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
        // The button row is built once, not part of the rebuilt body, so its caption is
        // re-read here with everything else.
        checkUpdatesButton.title = AboutContentText.checkForUpdatesButton
        checkUpdatesButton.setAccessibilityLabel(AboutContentText.checkForUpdatesButton)
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
            body.addArrangedSubview(sectionHeading(section.title))
            for line in section.body {
                body.addArrangedSubview(paragraph(line))
            }
        }

        body.addArrangedSubview(disclaimerBox())
        body.addArrangedSubview(licenseBox())
        body.addArrangedSubview(NSView())
        fillWidth(body)
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

    /// The update-check button, so a test can confirm it is there and reads the language.
    var checkForUpdatesButton: NSButton { checkUpdatesButton }
}