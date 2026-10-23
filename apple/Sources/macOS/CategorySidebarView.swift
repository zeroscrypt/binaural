import AppKit
import BinauralCore

/// The catalogue down the left of the window: the preset categories and how many
/// presets each of them holds.
///
/// The mock-up puts the catalogue in a column of its own and the presets in the
/// middle, and that is the right split: choosing *what kind* of sound is the left-hand
/// decision, and choosing *which* one is the middle one.
@MainActor
final class CategorySidebarView: NSView {

    /// The user picked a category. `nil` means "all of them".
    var onSelect: ((String?) -> Void)?

    private let column = NSStackView()
    private var buttons: [String?: CategoryButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    private func setUp() {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
        rebuild()
    }

    /// The list, in the catalogue's own order.
    private func rebuild() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        addRow(id: nil, title: L10n.tr("All presets"), count: PresetCatalogue.presets.count)
        for category in PresetCatalogue.categories {
            addRow(id: category.id, title: category.name(for: L10n.language), count: category.presets.count)
        }
    }

    /// The mark beside a category, the way the mock-up shows it.
    ///
    /// The categories are not frequencies, so the marks are pictures of what the
    /// categories are for rather than numbers: sleep, a still mind, a leaf, a lamp.
    private static func symbol(for id: String?) -> String? {
        switch id {
        case nil: return "square.grid.2x2.fill"
        case "sleep": return "moon.zzz.fill"
        case "meditation": return "camera.macro"
        case "relaxation": return "leaf.fill"
        case "awareness": return "sun.max.fill"
        case "concentration": return "brain.head.profile"
        case "energy": return "bolt.fill"
        case "user": return "person.fill"
        default: return nil
        }
    }

    private func addRow(id: String?, title: String, count: Int) {
        let button = CategoryButton(
            checkboxWithTitle: title,
            target: self,
            action: #selector(rowClicked(_:))
        )
        button.categoryID = id
        button.setAccessibilityLabel(title)
        if let symbol = Self.symbol(for: id) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading
        }
        button.font = .systemFont(ofSize: 13)
        // The count is part of the row's caption, so a reader knows what a category
        // holds before clicking it.
        button.attributedTitle = NSAttributedString(
            string: title + "  " + String(count),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        button.controlSize = .small
        column.addArrangedSubview(button)
        buttons[id] = button
    }

    /// Tick the row that is showing.
    func select(categoryID: String?) {
        for (id, button) in buttons {
            button.state = (id == categoryID) ? .on : .off
        }
    }

    /// Re-read the captions after a language switch.
    func retranslate() {
        rebuild()
    }

    @objc private func rowClicked(_ sender: CategoryButton) {
        onSelect?(sender.categoryID)
    }
}


/// A row of the catalogue. The category's id rides along with the button, because
/// `NSButton` has nowhere to put a string of our own.
final class CategoryButton: NSButton {
    /// The category this row stands for; `nil` is "all of them".
    var categoryID: String?
}
