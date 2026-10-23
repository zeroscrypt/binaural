import AppKit
import BinauralCore

/// The full preset library, in one window: every category, every preset, a search field
/// and a category picker — the place the header's quick button and the sidebar's
/// "All presets" row both point to.
///
/// The window is a browser, not a second editor: a click on a card applies the preset
/// through the window's own `applyPreset` path — the same code the centre's cards call —
/// so there is one way to become the sound and no second one to drift. The model
/// persists the *name* of the last chosen or named pair (`lastPreset`); renaming or
/// deleting stored presets is not something the model holds, so the library never
/// claims to.
@MainActor
final class PresetLibraryController: NSObject, NSWindowDelegate {

    private weak var owner: MainWindowController?

    private var window: NSWindow?
    private let searchField = NSSearchField()
    private let categoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cardsStack = NSStackView()

    /// The presets currently on show: the category's, or every matching one.
    private var shown: [Preset] = []
    private var isSyncing = false

    init(owner: MainWindowController) {
        self.owner = owner
        super.init()
    }

    // MARK: - Presenting

    func present() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        searchField.stringValue = ""
        refresh()
    }

    /// The window was closed and the app's app-menu item opened again: same window,
    /// values re-read — a library of stale data would be worse than no window.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("All presets")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 400, height: 360)

        searchField.placeholderString = L10n.tr("Search presets…")
        searchField.delegate = self
        searchField.setAccessibilityLabel(L10n.tr("Search presets…"))
        searchField.font = .systemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: 30).isActive = true

        categoryPopup.controlSize = .regular
        categoryPopup.font = .systemFont(ofSize: 13)
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChosen)
        categoryPopup.setAccessibilityLabel(L10n.tr("Presets"))
        categoryPopup.translatesAutoresizingMaskIntoConstraints = false
        categoryPopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
        rebuildCategories()

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 10
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        let filterRow = NSStackView(views: [searchField, categoryPopup])
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 10
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = cardsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(filterRow)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            filterRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            filterRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            filterRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            // The shelf is flipped (an `NSStackView` is), so once the documents's own
            // height is free the stack grows downwards as rows are added.
            cardsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            cardsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            cardsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        window.contentView = content
        return window
    }

    /// `NSWindowDelegate`: the window stays alive, hidden, so reopening is instant.
    func windowWillClose(_ notification: Notification) {}

    // MARK: - Data

    /// Rebuild the category picker from the registry: `All presets` first, then every
    /// category with its real count — the counts are data, never captions someone wrote.
    func rebuildCategories() {
        isSyncing = true
        categoryPopup.removeAllItems()
        categoryPopup.addItem(withTitle: L10n.tr("All presets"))
        for category in PresetCatalogue.categories {
            let title = String(
                format: "%@ — %d",
                category.name(for: L10n.language),
                category.presets.count
            )
            categoryPopup.addItem(withTitle: title)
            categoryPopup.lastItem?.representedObject = category.id
        }
        isSyncing = false
    }

    /// Re-read what is on show: the query, the category and the mark of the preset that
    /// is playing.
    func refresh() {
        guard let owner else { return }
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let categoryID = categoryPopup.selectedItem?.representedObject as? String

        var candidates: [Preset]
        switch (categoryID, query.isEmpty ? nil : query) {
        // A category with no text: exactly that category, in registry order.
        case (.some(let id), nil):
            candidates = PresetCatalogue.presets(inCategory: id)
        // Anything else: the whole registry, filtered.
        default:
            candidates = PresetCatalogue.presets
        }
        if !query.isEmpty {
            candidates = candidates.filter { PresetCard.matches(preset: $0, query: query) }
        }

        shown = candidates
        owner.presetCards.showPresets(candidates, marked: owner.lastPresetID, into: cardsStack)
        categoryPopup.setAccessibilityValue(categoryPopup.titleOfSelectedItem ?? "")
    }

    /// The language changed while the library may be open: the categories and the
    /// cards re-read themselves, the window can stay.
    func retranslate() {
        rebuildCategories()
        if let window {
            window.title = L10n.tr("All presets")
            searchField.placeholderString = L10n.tr("Search presets…")
            searchField.setAccessibilityLabel(L10n.tr("Search presets…"))
            categoryPopup.setAccessibilityLabel(L10n.tr("Presets"))
            if window.isVisible { refresh() }
        }
    }

    @objc private func categoryChosen() {
        guard !isSyncing else { return }
        refresh()
    }

    // MARK: - For the tests

    /// What the shelf holds now, as stable ids — the filter's effect, readable.
    var shownIDs: [String] { shown.map(\.id) }

    /// Type into the library's search field and let the shelf re-read itself.
    func typeLibraryQuery(_ text: String) {
        searchField.stringValue = text
        refresh()
    }

    /// Pick a category by its registry id — `nil` means `All presets`.
    func chooseLibraryCategory(id: String?) {
        let row = categoryPopup.itemArray.firstIndex {
            ($0.representedObject as? String) == id
        } ?? (id == nil ? 0 : nil)
        guard let row, row < categoryPopup.numberOfItems else { return }
        categoryPopup.selectItem(at: row)
        categoryChosen()
    }
}

extension PresetLibraryController: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        refresh()
    }
}
