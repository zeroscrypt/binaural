import AppKit
import BinauralCore

/// The two-level preset control of SPEC §5 F3: category chips, and inside the selected
/// category the presets themselves.
///
/// Two levels, not one flat list, because F3 makes the category part of the state:
/// `Session.presetCategory` is persisted, so the chips have to be a control the user
/// chooses rather than a heading. Selecting a category never changes a frequency — only
/// choosing a preset does, and it sets **both** channels at once through
/// ``PresetCatalogue/frequencies(for:carrierHz:)``.
///
/// The chip captions are data, not catalogue keys: F3's own table carries the English
/// and the Russian name of every category and every band, exactly like
/// `FrequencyCategory.labelEn/labelRu` does for the reference. That is also why no
/// `L10n` key is involved — there is no third language and no free text to translate.
///
/// The rows are wrapped by hand because AppKit has no flow layout: seven chips
/// ("Сосредоточенность" next to four others) do not fit on one line in a 760 pt window,
/// and Russian is the long one.
/// A chip that knows which catalogue entry it stands for.
///
/// `NSMenuItem` has a `representedObject`; `NSButton` does not, and the ids here are
/// `String`s that come straight out of ``PresetCatalogue``, so they live on a
/// three-line subclass rather than being encoded into an `Int` tag and decoded again.
@MainActor
final class ChipButton: NSButton {
    /// The category or preset id this chip stands for.
    var representedID: String?
}

@MainActor
final class PresetBarView: NSView {

    /// The user picked a category. Not sent by ``select(categoryID:)``.
    var onCategorySelected: ((String) -> Void)?
    /// The user picked a preset; it has **not** been applied yet.
    var onPresetSelected: ((Preset) -> Void)?

    private let captionLabel = NSTextField(labelWithString: "")
    /// One vertical container per level. Each holds as many horizontal rows as the width
    /// needs — an `NSStackView` is horizontal or vertical, never both, so wrapping needs a
    /// column of rows rather than one row that overflows.
    private let categoryColumn = NSStackView()
    private let presetColumn = NSStackView()

    private var categoryButtons: [String: ChipButton] = [:]
    private var presetButtons: [ChipButton] = []
    private var selectedCategoryID = PresetCatalogue.defaultCategoryID
    private var lastPresetID: String?
    private var isSyncing = false
    /// Width each row was last wrapped at, so `layout()` can stay idempotent.
    ///
    /// **One value per row, not one for the view.** The two rows are wrapped by
    /// independent calls at the same width; a single shared value made the second call a
    /// no-op every time, and the preset row stayed permanently empty — chips that were
    /// built, tracked and clickable but never added to the row.
    private var lastWrapWidths: [ObjectIdentifier: CGFloat] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Building

    private func setUp() {
        captionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        captionLabel.textColor = .secondaryLabelColor

        for column in [categoryColumn, presetColumn] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 8
            column.translatesAutoresizingMaskIntoConstraints = false
        }

        let stack = NSStackView(views: [captionLabel, categoryColumn, presetColumn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // SPEC §7.2: 44 px minimum click target — one chip row tall at the very least.
            categoryColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            presetColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520)
        ])

        // The caption is set here as well as in `retranslate()`: a view built on its own
        // (a test, or a second window) must not wait for the first language change to
        // show a label.
        captionLabel.stringValue = L10n.tr("Presets")
        setAccessibilityLabel(L10n.tr("Presets"))
        rebuildCategories()
        select(categoryID: selectedCategoryID, notify: false)
    }

    /// Recreate the category chips. Seven buttons is nothing, so rebuilding beats
    /// mutating in place when the language changes.
    private func rebuildCategories() {
        // Same forced re-wrap as `rebuildPresets` — new buttons need a rebuilt row even
        // when the width has not changed.
        lastWrapWidths[ObjectIdentifier(categoryColumn)] = nil
        clear(categoryColumn)
        categoryButtons.removeAll()

        for category in PresetCatalogue.categories {
            let button = chip(title: category.name(for: L10n.language))
            button.target = self
            button.action = #selector(categoryClicked(_:))
            button.representedID = category.id
            button.setAccessibilityLabel(category.name(for: L10n.language))
            categoryButtons[category.id] = button
        }
        wrap(categoryButtons: PresetCatalogue.categories.map { categoryButtons[$0.id]! },
             into: categoryColumn)
    }

    /// Recreate the preset chips of the selected category.
    private func rebuildPresets() {
        // A *forced* re-wrap, not just "remove and hope". `wrap` skips the work when the
        // width has not moved, which is right for `layout()` and wrong here: the chips are
        // new objects, so the row has to be rebuilt even at an unchanged width. Without
        // this the row kept the previous category's arranged subviews while `presetButtons`
        // already held the new ones — captions correct, row stale, and the column reported
        // one empty line.
        lastWrapWidths[ObjectIdentifier(presetColumn)] = nil
        clear(presetColumn)
        presetButtons = []

        let presets = PresetCatalogue.presets(inCategory: selectedCategoryID)
        for preset in presets {
            let button = chip(title: preset.title(for: L10n.language))
            button.target = self
            button.action = #selector(presetClicked(_:))
            button.representedID = preset.id
            button.setAccessibilityHelp(
                L10n.tr("Sets both channels around a %1 Hz carrier so the difference is %2 Hz.",
                        FrequencyGrid.text(BeatMath.defaultCarrierHz),
                        preset.beatText)
            )
            presetButtons.append(button)
        }
        wrap(categoryButtons: presetButtons, into: presetColumn)
        markSelectedPreset()
    }

    private func chip(title: String) -> ChipButton {
        let button = ChipButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setButtonType(.toggle)
        button.font = .systemFont(ofSize: 13)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    // MARK: - Layout

    /// Lay chips out left to right, wrapping at `availableWidth`.
    ///
    /// `intrinsicContentSize` is asked for rather than a fixed width per chip: chip titles
    /// differ between English and Russian and between the seven categories, so any hard
    /// width would either clip "Сосредоточенность" or leave "Work" floating in a gap.
    private func wrap(categoryButtons buttons: [NSButton], into column: NSStackView) {
        let key = ObjectIdentifier(column)
        // A column whose chips are gone must be cleared even when the width has not moved:
        // rebuilding one level's chips must never leave another level's on screen.
        if buttons.isEmpty {
            guard !column.arrangedSubviews.isEmpty else { return }
            lastWrapWidths[key] = nil
            clear(column)
            return
        }
        let limit = max(240, availableWidth())
        // Rebuilding arranged subviews from inside `layout()` would schedule another
        // layout pass, so a no-op wrap must stay a no-op or the two feed each other.
        guard limit != lastWrapWidths[key] else { return }
        lastWrapWidths[key] = limit
        clear(column)

        var current: [NSButton] = []
        var currentWidth: CGFloat = 0

        for button in buttons {
            let width = button.intrinsicContentSize.width + chipSpacing
            if !current.isEmpty, currentWidth + width > limit {
                addRow(current, to: column)
                current = []
                currentWidth = 0
            }
            current.append(button)
            currentWidth += width
        }
        addRow(current, to: column)
    }

    private func clear(_ column: NSStackView) {
        for row in column.arrangedSubviews {
            column.removeArrangedSubview(row)
            for view in row.subviews { view.removeFromSuperview() }
            row.removeFromSuperview()
        }
    }

    /// One horizontal line of chips, with the Python row's trailing stretch.
    private func addRow(_ buttons: [NSButton], to column: NSStackView) {
        guard !buttons.isEmpty else { return }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = chipSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        row.addArrangedSubview(NSView())   // the trailing stretch of the Python row
        column.addArrangedSubview(row)
    }

    /// Gap between chips and between wrapped lines — the Python row's `SPACE_SM`.
    private let chipSpacing: CGFloat = 8

    /// Width the wrapping may use, from the Auto Layout pass already made against us.
    private func availableWidth() -> CGFloat {
        guard let window else { return 700 }
        return max(240, window.contentView?.bounds.width ?? 700) - 48
    }

    override func layout() {
        super.layout()
        // A resize can make a wrapped column fit on one line; re-wrap at the new width.
        wrap(categoryButtons: PresetCatalogue.categories.map { categoryButtons[$0.id]! },
             into: categoryColumn)
        wrap(categoryButtons: presetButtons, into: presetColumn)
    }

    // MARK: - Selection

    /// Select a category without telling anyone — used while restoring the session.
    func select(categoryID: String, notify: Bool = false) {
        let wanted = PresetCatalogue.resolvedCategoryID(categoryID)
        selectedCategoryID = wanted

        isSyncing = true
        for (id, button) in categoryButtons {
            let selected = id == wanted
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
        isSyncing = false

        rebuildPresets()
        if notify { onCategorySelected?(wanted) }
    }

    /// The category currently shown.
    var selectedCategory: String { selectedCategoryID }

    /// Highlight the preset that produced the frequencies on screen, when it belongs to
    /// the category being shown.
    func markPreset(_ presetID: String?) {
        lastPresetID = presetID
        markSelectedPreset()
    }

    private func markSelectedPreset() {
        for button in presetButtons {
            let selected = button.representedID == lastPresetID
            button.state = selected ? .on : .off
            // `state = .on` alone was too quiet to read: a toggle chip at rest and a toggle
            // chip that is on differ by a hairline, which is not enough to answer "which
            // preset produced these frequencies?" at a glance. The selected chip is filled
            // with the accent colour instead, so the answer is a colour rather than a
            // border. Colour is never the only carrier — `state` stays on, so VoiceOver and
            // the focus ring still report it (SPEC §7.2).
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            button.font = selected
                ? .systemFont(ofSize: 13, weight: .semibold)
                : .systemFont(ofSize: 13)
        }
        // The category row reads the same way, so "which category am I in" is answerable
        // without counting rows.
        for (id, button) in categoryButtons {
            let selected = id == selectedCategoryID
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    // MARK: - Actions

    @objc private func categoryClicked(_ sender: ChipButton) {
        guard !isSyncing, let id = sender.representedID else { return }
        select(categoryID: id)
        onCategorySelected?(id)
    }

    @objc private func presetClicked(_ sender: ChipButton) {
        guard let id = sender.representedID,
              let preset = PresetCatalogue.presets.first(where: { $0.id == id })
        else { return }
        lastPresetID = preset.id
        markSelectedPreset()
        onPresetSelected?(preset)
    }

    /// Press a preset chip by id, as a click does.
    ///
    /// The window tests need to go through the *button* rather than call
    /// `onPresetSelected` themselves — otherwise a chip wired to the wrong selector would
    /// still pass. Unknown ids are ignored, exactly as a chip with no `representedID` is.
    @discardableResult
    func tapPreset(id: String) -> Bool {
        guard let button = presetButtons.first(where: { $0.representedID == id }) else { return false }
        presetClicked(button)
        return true
    }

    /// Press a category chip by id, as a click does. Unknown ids are ignored.
    @discardableResult
    func tapCategory(id: String) -> Bool {
        guard let button = categoryButtons[id] else { return false }
        categoryClicked(button)
        return true
    }

    // MARK: - What the tests read

    /// The tint of the chip standing for `presetID`, and of every other chip, so the
    /// selected one can be told apart **by colour** and not only by a toggle border.
    ///
    /// `state` is what VoiceOver and the focus ring report, and it is enough for a test to
    /// pass while the user still cannot see it — so these assertions are about the colour
    /// specifically: `markSelectedPreset` must actually change it.
    func presetTint(for presetID: String) -> NSColor? {
        presetButtons.first { $0.representedID == presetID }?.contentTintColor
    }

    var anyOtherPresetTint: NSColor? {
        presetButtons.first { $0.representedID != lastPresetID }?.contentTintColor
    }

    func categoryTint(for categoryID: String) -> NSColor? {
        categoryButtons[categoryID]?.contentTintColor
    }

    /// The ids of the presets in the selected category, in registry order — what the
    /// selection tests address chips by.
    var presetIDs: [String] {
        presetButtons.compactMap(\.representedID)
    }

    /// Whether a chip is toggled on, which is what VoiceOver and the focus ring report —
    /// the non-colour half of the selection.
    func isPresetMarkedAsOn(_ presetID: String) -> Bool {
        presetButtons.first { $0.representedID == presetID }?.state == .on
    }

    var anyOtherCategoryTint: NSColor? {
        categoryButtons.first { $0.key != selectedCategoryID }?.value.contentTintColor
    }

    /// The preset chips on screen, as captions — "what the user can pick right now".
    var visiblePresetTitles: [String] { presetButtons.map(\.title) }

    /// The category chips, as captions.
    var categoryTitles: [String] {
        PresetCatalogue.categories.compactMap { categoryButtons[$0.id]?.title }
    }

    /// The id of the highlighted preset chip, if any.
    var selectedPresetID: String? {
        presetButtons.first { $0.state == .on }?.representedID
    }

    // MARK: - State the layout tests read

    /// The chip rows actually on screen, one entry per wrapped line, as counts.
    ///
    /// `presetButtons` says which chips *exist*; this says how many made it into the
    /// column. The two differed once — the preset row's chips were built and tracked but
    /// never arranged, so the row rendered empty while every caption-based test passed.
    var arrangedCategoryChipCount: Int { arrangedChipCount(in: categoryColumn) }

    var arrangedPresetChipCount: Int { arrangedChipCount(in: presetColumn) }

    /// Chips minus the one trailing stretch each wrapped line carries.
    private func arrangedChipCount(in column: NSStackView) -> Int {
        let lines = column.arrangedSubviews.compactMap { $0 as? NSStackView }
        return lines.reduce(0) { $0 + $1.arrangedSubviews.count } - lines.count
    }

    /// How many wrapped lines each level occupies — 1 when it fits, more when it does not.
    var categoryLineCount: Int { categoryColumn.arrangedSubviews.count }
    var presetLineCount: Int { presetColumn.arrangedSubviews.count }

    // MARK: - Language

    /// Re-read every caption after a language switch (SPEC §7.4). Both chip rows are
    /// rebuilt, so the wrapping is redone for the new caption widths.
    func retranslate() {
        captionLabel.stringValue = L10n.tr("Presets")
        setAccessibilityLabel(L10n.tr("Presets"))
        rebuildCategories()
        isSyncing = true
        for (id, button) in categoryButtons {
            let category = PresetCatalogue.category(id: id)
            button.title = category?.name(for: L10n.language) ?? button.title
            button.state = id == selectedCategoryID ? .on : .off
        }
        isSyncing = false
        rebuildPresets()
    }
}
