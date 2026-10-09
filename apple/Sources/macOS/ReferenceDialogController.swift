import AppKit
import BinauralCore

/// The frequency reference of SPEC §6 — every record, nothing filtered out by default.
///
/// The layout is the one §6.12 tabulates: a category sidebar with counts, a search field
/// across all categories, an evidence filter that hides nothing until it is asked to, and
/// one card per record — **title → frequency → Apply → effect → badge and source**.
///
/// All the content comes from `FrequencyCatalogue`, i.e. from
/// `src/binaural/data/frequencies.json` — there is no second list of frequencies and no
/// second set of evidence levels anywhere in this file. Emoji appear only inside the
/// category icon and the evidence badge, which SPEC §7.3 explicitly allows because there
/// they are *data* from the registry rather than interface chrome.
///
/// "Apply" hands the pair back through ``onApply``, and the arithmetic lives in
/// ``ReferenceApply`` so the rule (a range plays its middle, a tonal record becomes the
/// carrier) is the same one the tests pin.
@MainActor
final class ReferenceDialogController: NSWindowController {

    /// The user pressed Apply on a record: `(left Hz, right Hz)`.
    var onApply: ((Double, Double) -> Void)?

    private let catalogue: FrequencyCatalogue
    private var filter = ReferenceFilter()

    private let searchField = NSSearchField()
    private let evidencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sidebar = NSStackView()
    private let resultsStack = NSStackView()
    private let scrollView = NSScrollView()
    // Properties rather than locals in `buildContent()`: the layout tests need to measure
    // where the two columns ended up, and a local would be gone by the time they ran.
    private let sidebarScroll = NSScrollView()
    private let body = NSStackView()
    private let resultLabel = NSTextField(labelWithString: "")
    /// The disclaimer panel is a plain bordered view, not an `NSBox`.
    ///
    /// `NSBox` lays its content view out by autoresizing, so it never picked up a height
    /// from Auto Layout and came out **0 pt tall** — the medical disclaimer was there in
    /// the view tree and nowhere on the screen. A view whose border is drawn as a layer,
    /// like the record cards, sizes itself from its content instead.
    private let disclaimerView = NSView()
    private let disclaimerLabel = NSTextField(wrappingLabelWithString: "")
    private let disclaimerButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let closeButton = NSButton()

    private var categoryButtons: [String: NSButton] = [:]
    private var allCategoriesButton: NSButton?
    private var visibleIDs: [String] = []

    init(catalogue: FrequencyCatalogue) {
        self.catalogue = catalogue
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 760, height: 500)
        super.init(window: window)
        buildContent()
        retranslate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the dialog is built in code")
    }

    // MARK: - Building

    /// A scroll view's document view with its origin at the top left.
    ///
    /// A plain `NSView` is bottom-left, and `NSClipView` parks a document taller than
    /// itself at (0, 0) — which put the **top** of the content above the top of the
    /// window. The first category chips were drawn over the search field and hit-tested as
    /// the search field, which is exactly the report that clicking a category did nothing:
    /// the chips were not inside the clip view at all. Flipping the document starts row one
    /// where the eye starts, and puts every row inside the area that takes clicks.
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private func buildContent() {
        searchField.delegate = self
        evidencePopup.target = self
        evidencePopup.action = #selector(evidenceChanged)

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 12
        resultsStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        // The document view fills the clip view horizontally, which is what lets the
        // cards be as wide as the window instead of a hard-coded number of points.
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(resultsStack)
        // The document goes into the scroll view **before** the width constraint is
        // activated: a constraint between two views with no common ancestor is illegal, and
        // `documentView` is what makes them related.
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let searchRow = NSStackView(views: [searchField, evidencePopup])
        searchRow.orientation = .horizontal
        searchRow.spacing = 12
        searchRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let sidebarScroll = self.sidebarScroll
        let sidebarDocument = FlippedDocumentView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarDocument.addSubview(sidebar)
        sidebarScroll.documentView = sidebarDocument
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        // The sidebar's width has to be constrained **inside** `body`, not before it: the
        // width constraint below compared a stack that had no common ancestor with this one,
        // and AppKit refuses to activate such a constraint — it raised
        // `NSGenericException` the moment the dialog was built, which is why opening the
        // reference could fail outright rather than merely lay out oddly. The fixed width
        // moves down to where both views exist together.
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: sidebarDocument.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarDocument.bottomAnchor),
            sidebar.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor)
        ])

        let body = self.body
        body.addArrangedSubview(sidebarScroll)
        body.addArrangedSubview(scrollView)
        body.orientation = .horizontal
        body.spacing = 12
        body.distribution = .fill
        body.alignment = .top

        buildDisclaimer()

        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor

        disclaimerButton.target = self
        disclaimerButton.action = #selector(toggleDisclaimer)
        disclaimerButton.state = .on

        closeButton.target = self
        closeButton.action = #selector(closeDialog)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let footer = NSStackView(views: [resultLabel, NSView(), disclaimerButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.alignment = .centerY

        let root = NSStackView(views: [
            headingLabel(L10n.tr("Frequency reference")),
            noteLabel(
                L10n.tr(
                    "Every record from the built-in reference, from EEG literature to "
                        + "esoteric traditions. Nothing is ranked and nothing is hidden."
                )
            ),
            searchRow,
            body,
            disclaimerView,
            footer
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        for row in [searchRow, body, scrollView, footer, disclaimerView] as [NSView] {
            row.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // `root` has 20 pt edge insets on each side, so what is left between them is
            // its width minus 40 — every row below is sized from that, not from the full
            // width, which is what left them overlapping the insets.
            searchRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            body.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 240),
            // Both columns are as tall as the row. Without this they kept whatever height
            // their own (absent) intrinsic size gave them — zero — and the sidebar spilled
            // its chips straight over the disclaimer box at the bottom of the window.
            sidebarScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            scrollView.heightAnchor.constraint(equalTo: body.heightAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            disclaimerView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40)
        ])

        window?.title = L10n.tr("Frequency reference")
        window?.contentView = content
        window?.initialFirstResponder = searchField
    }

    private func buildDisclaimer() {
        disclaimerLabel.font = .systemFont(ofSize: 11)
        disclaimerLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [headingLabel(L10n.tr(AboutContent.disclaimerTitle)), disclaimerLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        disclaimerView.wantsLayer = true
        disclaimerView.layer?.cornerRadius = 10
        disclaimerView.layer?.borderWidth = 1
        disclaimerView.layer?.borderColor = NSColor.separatorColor.cgColor
        disclaimerView.translatesAutoresizingMaskIntoConstraints = false
        disclaimerView.addSubview(stack)

        // Pinned on all four sides, so the panel takes the height of its own text — and
        // the wrapping label inside is given a width to wrap at, which is what stopped it
        // asking for the 4601 pt it wanted when nothing constrained it.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: disclaimerView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: disclaimerView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: disclaimerView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: disclaimerView.bottomAnchor)
        ])
    }

    private func headingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - Sidebar

    /// Category chips in **registry order** (`Category.order`, the single source of
    /// truth), each with its count, plus "All categories" first.
    private func rebuildSidebar() {
        for view in sidebar.arrangedSubviews {
            sidebar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        categoryButtons.removeAll()

        let all = toggle(
            title: "\(L10n.tr("All categories")) (\(catalogue.entries.count))",
            id: nil,
            tooltip: L10n.tr("Show every record of the reference")
        )
        all.setAccessibilityLabel(L10n.tr("Reference categories"))
        allCategoriesButton = all
        sidebar.addArrangedSubview(all)

        for counted in catalogue.categoriesWithCounts() {
            let category = counted.category
            let localized = Self.localizedLabel(category)
            let button = toggle(
                title: "\(category.icon) \(localized) (\(counted.count))",
                id: category.id,
                tooltip: "\(Self.localizedDescription(category))\n"
                    + "\(category.labelEn) / \(category.labelRu)"
            )
            button.setAccessibilityLabel(localized)
            categoryButtons[category.id] = button
            sidebar.addArrangedSubview(button)
        }
        applyCategorySelection()
    }

    private func toggle(title: String, id: String?, tooltip: String) -> ChipButton {
        let button = ChipButton(title: title, target: self, action: #selector(categoryClicked(_:)))
        button.setButtonType(.toggle)
        button.bezelStyle = .rounded
        button.representedID = id
        button.toolTip = tooltip
        // SPEC §7.2: 44 px minimum click target.
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private static func localizedLabel(_ category: FrequencyCategory) -> String {
        L10n.language == .ru ? category.labelRu : category.labelEn
    }

    private static func localizedDescription(_ category: FrequencyCategory) -> String {
        L10n.language == .ru ? category.descriptionRu : category.descriptionEn
    }

    private static func localizedEffect(_ entry: FrequencyEntry) -> String {
        L10n.language == .ru ? entry.effectRu : entry.effectEn
    }

    private static func otherEffect(_ entry: FrequencyEntry) -> String {
        L10n.language == .ru ? entry.effectEn : entry.effectRu
    }

    private func applyCategorySelection() {
        let all = filter.categoryID == nil
        allCategoriesButton?.state = all ? .on : .off
        allCategoriesButton?.contentTintColor = all ? .controlAccentColor : .labelColor
        for (id, button) in categoryButtons {
            let selected = id == filter.categoryID
            button.state = selected ? .on : .off
            // The toggle state alone is a hairline the eye has to hunt for, and the filter
            // this list drives is the whole point of the dialog: the chosen category is
            // filled with the accent colour instead. `state` stays on, so the selection is
            // still there for VoiceOver and the focus ring — colour is not the only carrier
            // (SPEC §7.2), the same rule the preset bar follows.
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    private func rebuildEvidenceItems() {
        evidencePopup.removeAllItems()
        evidencePopup.addItem(withTitle: L10n.tr("All evidence"))
        for level in EvidenceLevel.defined {
            evidencePopup.addItem(withTitle: "\(level.badge) \(Self.evidenceLabel(level))")
            evidencePopup.lastItem?.representedObject = level.rawValue
        }
    }

    static func evidenceLabel(_ level: EvidenceLevel) -> String {
        switch level {
        case .wellStudied: return L10n.tr("Well-studied")
        case .studied: return L10n.tr("Studied")
        case .reported: return L10n.tr("Reported")
        case .traditional: return L10n.tr("Traditional")
        case .unknown: return L10n.tr("Unknown")
        }
    }

    // MARK: - Results

    /// Rebuild the cards. Skipped when the visible set is unchanged, so typing in the
    /// search field does not churn every view on each keystroke.
    private func refresh() {
        let entries = filter.apply(to: catalogue)
        // The order the dialog shows is **not** the order the filter hands back: the filter
        // sorts ranges first and then by beat, the dialog groups by category in registry
        // order (SPEC §6.12). Everything downstream — the skip-if-unchanged guard included —
        // has to agree with what is on the screen, so the display order is worked out first
        // and that is the order recorded. Asking for "the first record" used to return a
        // record fourteen thousand points down the scroll view from the one at the top.
        let grouped = Self.group(entries, by: catalogue)
        let ids = grouped.flatMap { $0.entries.map(\.id) }
        guard ids != visibleIDs else {
            updateResultCount(shown: entries.count)
            return
        }
        visibleIDs = ids

        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if entries.isEmpty {
            resultsStack.addArrangedSubview(noteLabel(L10n.tr("Nothing matches this filter.")))
        } else {
            for (category, group) in grouped {
                if let category { resultsStack.addArrangedSubview(headerView(for: category, count: group.count)) }
                for entry in group {
                    resultsStack.addArrangedSubview(cardView(for: entry))
                }
            }
            // An entry whose category is not in the registry: `validate()` reports it and
            // it is still shown rather than dropped silently. ``group(_:by:)`` puts them
            // last, without a header.
        }
        resultsStack.addArrangedSubview(NSView())   // the trailing stretch
        // Cards only after they are in the column — see ``sizeCards(in:)``.
        sizeCards(in: resultsStack)
        updateResultCount(shown: entries.count)
    }

    /// Records grouped by category in registry order (SPEC §6.12), which is the order they
    /// are shown in. Entries whose category is not in the registry come last, under no
    /// header: `validate()` reports them, and the reference still shows them rather than
    /// dropping them silently.
    private static func group(
        _ entries: [FrequencyEntry],
        by catalogue: FrequencyCatalogue
    ) -> [(category: FrequencyCategory?, entries: [FrequencyEntry])] {
        var grouped: [(category: FrequencyCategory?, entries: [FrequencyEntry])] = []
        for category in catalogue.categories {
            let group = entries.filter { $0.category == category.id }
            if !group.isEmpty { grouped.append((category, group)) }
        }
        let known = Set(catalogue.categories.map(\.id))
        let orphans = entries.filter { !known.contains($0.category) }
        if !orphans.isEmpty { grouped.append((nil, orphans)) }
        return grouped
    }

    private func updateResultCount(shown: Int) {
        resultLabel.stringValue = L10n.tr(
            "Showing {shown} of {total} records",
            named: ["shown": String(shown), "total": String(catalogue.entries.count)]
        )
    }

    private func headerView(for category: FrequencyCategory, count: Int) -> NSView {
        let localized = Self.localizedLabel(category)
        let icon = NSTextField(labelWithString: category.icon)
        icon.font = .systemFont(ofSize: 14)

        let title = NSTextField(labelWithString: "\(localized) (\(count))")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let description = noteLabel(Self.localizedDescription(category))
        let titles = NSStackView(views: [title, description])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let row = NSStackView(views: [icon, titles])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .top
        row.setAccessibilityLabel("\(localized) (\(count))")
        return row
    }

    /// One record: title, frequency, Apply, effect, badge and source (SPEC §6.12).
    private func cardView(for entry: FrequencyEntry) -> NSView {
        let applyButton = ChipButton(
            title: L10n.tr("Apply"), target: self, action: #selector(applyEntry(_:))
        )
        applyButton.bezelStyle = .rounded
        applyButton.representedID = entry.id
        applyButton.toolTip = applyTooltip(for: entry)
        applyButton.setAccessibilityLabel(L10n.tr("Apply {label}", named: ["label": entry.label]))
        applyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let title = NSTextField(labelWithString: entry.label)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        // The stretch puts Apply at the card's right edge: it is the action the card
        // offers, not another word of its title, and next to the name it read as part of
        // the sentence rather than as the way to take the record into the main window.
        let titleRow = NSStackView(views: [title, NSView(), applyButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 12
        titleRow.alignment = .centerY

        let detail = noteLabel("\(entry.frequencyText)  ·  \(carrierHint(for: entry))")

        let effect = NSTextField(wrappingLabelWithString: Self.localizedEffect(entry))
        effect.font = .systemFont(ofSize: 12)
        effect.toolTip = Self.otherEffect(entry)
        effect.setAccessibilityLabel(Self.localizedEffect(entry))

        var meta = "\(entry.badge) \(Self.evidenceLabel(entry.evidence))"
        if !entry.source.isEmpty { meta += "  ·  \(entry.source)" }

        let stack = NSStackView(views: [titleRow, detail, effect, noteLabel(meta)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 10
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.setAccessibilityLabel(entry.label)
        return stack
    }

    /// Width of every card in the results column.
    ///
    /// The card stacks are built by ``cardView(for:)`` **before** they are added to
    /// `resultsStack`, so a card cannot pin itself to that stack's width: the two have no
    /// common ancestor yet, and AppKit refuses to activate such a constraint outright —
    /// `NSGenericException`, and the reference dialog would not open at all. The cards are
    /// therefore sized once they are in place, from the same edge-inset arithmetic the card
    /// used to do for itself.
    private func sizeCards(in stack: NSStackView) {
        for card in stack.arrangedSubviews {
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ).isActive = true
        }
    }

    private func carrierHint(for entry: FrequencyEntry) -> String {
        entry.isTonal
            ? L10n.tr(
                "Tone — applied as the carrier with a {beat} Hz beat",
                named: ["beat": FrequencyEntry.format(ReferenceApply.tonalBeatHz)]
            )
            : L10n.tr(
                "Carries {carrier} Hz",
                named: ["carrier": FrequencyEntry.format(entry.carrierHz)]
            )
    }

    private func applyTooltip(for entry: FrequencyEntry) -> String {
        let pair = ReferenceApply.frequencies(for: entry)
        return L10n.tr(
            "Set left = {left} Hz and right = {right} Hz (difference {beat})",
            named: [
                "left": FrequencyGrid.text(pair.left),
                "right": FrequencyGrid.text(pair.right),
                "beat": entry.frequencyText
            ]
        )
    }

    // MARK: - Actions

    @objc private func categoryClicked(_ sender: ChipButton) {
        filter.categoryID = sender.representedID
        applyCategorySelection()
        refresh()
    }

    @objc private func evidenceChanged() {
        let raw = evidencePopup.selectedItem?.representedObject as? String
        filter.evidence = raw.map(EvidenceLevel.init(lenient:))
        refresh()
    }

    @objc private func applyEntry(_ sender: ChipButton) {
        guard let id = sender.representedID else { return }
        apply(entryID: id)
    }

    @objc private func toggleDisclaimer() {
        disclaimerView.isHidden = disclaimerButton.state != .on
    }

    @objc private func closeDialog() {
        close()
    }

    /// Escape closes the reference — SPEC §7.2's Escape-to-close. See
    /// ``AboutDialogController/cancelOperation(_:)`` for why this is an override and not a
    /// key equivalent on the Close button.
    override func cancelOperation(_ sender: Any?) {
        closeDialog()
    }

    // MARK: - State the tests read

    /// The records currently on screen, in the order they are on screen.
    ///
    /// Read back from ``visibleEntryIDs`` rather than from the filter, because the two
    /// order things differently and only one of them is what the user sees: the filter
    /// sorts ranges first and then by beat, while the dialog groups by category in
    /// registry order (SPEC §6.12). An accessor that answered "the first record" with a
    /// different record than the one at the top of the list sent a test hunting for a
    /// button fourteen thousand points off screen.
    var visibleEntries: [FrequencyEntry] {
        visibleIDs.compactMap { catalogue.entry(id: $0) }
    }

    var visibleEntryIDs: [String] { visibleIDs }

    var selectedCategoryID: String? { filter.categoryID }

    var query: String { searchField.stringValue }

    func setQuery(_ text: String) {
        searchField.stringValue = text
        filter.query = text
        refresh()
    }

    /// Select a sidebar category by id; `nil` is "All categories".
    func selectCategory(_ id: String?) {
        filter.categoryID = id
        applyCategorySelection()
        refresh()
    }

    /// Filter by evidence level; `nil` hides nothing (SPEC §6.2).
    func selectEvidence(_ level: EvidenceLevel?) {
        filter.evidence = level
        let index = level.flatMap { EvidenceLevel.defined.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        evidencePopup.selectItem(at: index)
        refresh()
    }

    var sidebarTitles: [String] {
        sidebar.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
    }

    // The views behind ``sidebarTitles``, for the layout tests. The titles alone could not
    // catch the bug they were written for: a sidebar whose scroll view had collapsed to
    // zero height still produced the right list of titles — it just drew it over the
    // disclaimer and answered no clicks, because hit-testing walks the frames.
    var sidebarChips: [ChipButton] { sidebar.arrangedSubviews.compactMap { $0 as? ChipButton } }

    var sidebarColumn: NSStackView { sidebar }

    var sidebarScroller: NSScrollView { sidebarScroll }

    var bodyRow: NSStackView { body }


    /// The Apply buttons currently on screen, so a test can click one where the user sees
    /// it rather than calling the action behind its back.
    var applyButtons: [ChipButton] {
        resultsStack.arrangedSubviews
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? ChipButton }
    }

    var disclaimerPanel: NSView { disclaimerView }

    var evidenceTitles: [String] { evidencePopup.itemArray.map(\.title) }

    /// What the two buttons say. Both were built with an empty title and nothing ever
    /// set one, which is why the dialog showed 110 blank rectangles and a blank blue
    /// corner: there was nothing on them to read and nothing to aim at.
    var applyButtonTitles: [String] {
        applyButtons.map(\.title)
    }

    var closeButtonTitle: String { closeButton.title }

    var resultCountText: String { resultLabel.stringValue }

    var isDisclaimerVisible: Bool { !disclaimerView.isHidden }

    var disclaimerText: String { disclaimerLabel.stringValue }

    /// The tint of a category chip, so a test can assert the selection by colour rather
    /// than by toggle state — the chip used to be grey with its state set to "on".
    func categoryTint(for categoryID: String) -> NSColor? {
        categoryButtons[categoryID]?.contentTintColor
    }

    /// Apply a record as if its button had been pressed.
    @discardableResult
    func apply(entryID: String) -> (left: Double, right: Double)? {
        guard let entry = catalogue.entry(id: entryID) else { return nil }
        let pair = ReferenceApply.frequencies(for: entry)
        onApply?(pair.left, pair.right)
        return (pair.left, pair.right)
    }

    // MARK: - Language

    /// Dialogs are rebuilt on every open, but this one can stay open across a language
    /// switch, so it re-reads its captions the same way the main window does
    /// (SPEC §7.4).
    func retranslate() {
        window?.title = L10n.tr("Frequency reference")
        searchField.placeholderString = L10n.tr("Search name, frequency or effect…")
        searchField.setAccessibilityLabel(L10n.tr("Search the frequency reference"))
        evidencePopup.setAccessibilityLabel(L10n.tr("Filter by evidence level"))
        evidencePopup.setAccessibilityHelp(
            L10n.tr("Badges show how well a record is studied. Nothing is hidden by default.")
        )
        scrollView.setAccessibilityLabel(L10n.tr("Reference records"))
        closeButton.title = L10n.tr("Close")
        closeButton.setAccessibilityLabel(L10n.tr("Close the frequency reference"))
        disclaimerButton.title = L10n.tr(AboutContent.disclaimerTitle)
        disclaimerLabel.stringValue = AboutContent.disclaimerText()
        disclaimerLabel.setAccessibilityLabel(L10n.tr(AboutContent.disclaimerTitle))
        disclaimerLabel.toolTip = L10n.tr("Medical disclaimer — read it before using the application.")
        rebuildEvidenceItems()
        rebuildSidebar()
        // Force the cards to be rebuilt: every caption in them is language-dependent.
        visibleIDs = []
        refresh()
    }
}

extension ReferenceDialogController: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        filter.query = searchField.stringValue
        refresh()
    }
}
