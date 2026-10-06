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
    private let categoryRow = NSStackView()
    private let presetRow = NSStackView()

    private var categoryButtons: [String: ChipButton] = [:]
    private var presetButtons: [ChipButton] = []
    private var selectedCategoryID = PresetCatalogue.defaultCategoryID
    private var lastPresetID: String?
    private var isSyncing = false
    /// Width the chips were last wrapped at, so `layout()` can stay idempotent.
    private var lastWrapWidth: CGFloat = 0

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

        for row in [categoryRow, presetRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
        }

        let stack = NSStackView(views: [captionLabel, categoryRow, presetRow])
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
            // SPEC §7.2: 44 px minimum click target.
            categoryRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            presetRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520)
        ])

        setAccessibilityLabel(L10n.tr("Presets"))
        rebuildCategories()
        select(categoryID: selectedCategoryID, notify: false)
    }

    /// Recreate the category chips. Seven buttons is nothing, so rebuilding beats
    /// mutating in place when the language changes.
    private func rebuildCategories() {
        for button in categoryButtons.values { button.removeFromSuperview() }
        categoryButtons.removeAll()

        for category in PresetCatalogue.categories {
            let button = chip(title: category.name(for: L10n.language))
            button.target = self
            button.action = #selector(categoryClicked(_:))
            button.representedID = category.id
            button.setAccessibilityLabel(category.name(for: L10n.language))
            categoryButtons[category.id] = button
        }
        layoutRows(categoryRow, with: PresetCatalogue.categories.map { categoryButtons[$0.id]! })
    }

    /// Recreate the preset chips of the selected category.
    private func rebuildPresets() {
        for button in presetButtons { button.removeFromSuperview() }
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
        layoutRows(presetRow, with: presetButtons)
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
    private func layoutRows(_ row: NSStackView, with buttons: [NSButton]) {
        guard !buttons.isEmpty else { return }
        let limit = max(240, availableWidth())
        // Rebuilding arranged subviews from inside `layout()` would schedule another
        // layout pass, so a no-op wrap must stay a no-op or the two feed each other.
        guard limit != lastWrapWidth else { return }
        lastWrapWidth = limit

        for view in row.arrangedSubviews { row.removeArrangedSubview(view); view.removeFromSuperview() }

        var current: [NSButton] = []
        var currentWidth: CGFloat = 0

        for button in buttons {
            let width = button.intrinsicContentSize.width + row.spacing
            if !current.isEmpty, currentWidth + width > limit {
                addRow(current, to: row)
                current = []
                currentWidth = 0
            }
            current.append(button)
            currentWidth += width
        }
        addRow(current, to: row)
    }

    private func addRow(_ buttons: [NSButton], to row: NSStackView) {
        guard !buttons.isEmpty else { return }
        for button in buttons { row.addArrangedSubview(button) }
        row.addArrangedSubview(NSView())   // the trailing stretch of the Python row
    }

    /// Width the wrapping may use, from the Auto Layout pass already made against us.
    private func availableWidth() -> CGFloat {
        guard let window else { return 700 }
        return max(240, window.contentView?.bounds.width ?? 700) - 48
    }

    override func layout() {
        super.layout()
        // A resize can make a wrapped row fit on one line; re-wrap at the new width.
        layoutRows(categoryRow, with: PresetCatalogue.categories.map { categoryButtons[$0.id]! })
        layoutRows(presetRow, with: presetButtons)
    }

    // MARK: - Selection

    /// Select a category without telling anyone — used while restoring the session.
    func select(categoryID: String, notify: Bool = false) {
        let wanted = PresetCatalogue.resolvedCategoryID(categoryID)
        selectedCategoryID = wanted

        isSyncing = true
        for (id, button) in categoryButtons {
            button.state = id == wanted ? .on : .off
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
            button.state = button.representedID == lastPresetID ? .on : .off
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

    // MARK: - State the tests read

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
