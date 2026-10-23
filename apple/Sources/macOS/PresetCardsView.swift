import AppKit
import BinauralCore

/// The presets as cards, the way the hand-drawn layout shows them: a colour, a mark,
/// the band and the range of beats.
///
/// The chips they replace said the same thing in a smaller way; a card says it with a
/// picture, and the picture is what the eye reads first. The colour belongs to the
/// **band** a preset's beat falls into, because the band is what a preset is chosen
/// for — the catalogue records it as data of the preset registry (SPEC F3), and the
/// card reads it from there instead of carrying its own copy.
@MainActor
final class PresetCardsView: NSView {

    /// The user picked a preset.
    var onPick: ((String) -> Void)?

    /// The presets on show.
    var presets: [Preset] = [] {
        didSet { rebuild() }
    }

    /// The preset that is currently playing, marked on its card.
    var markedPresetID: String? {
        didSet { rebuild() }
    }

    private let row = NSStackView()
    private var cards: [String: PresetCard] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - The cards

    private func rebuild() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        for preset in presets {
            let card = PresetCard(preset: preset)
            card.onPick = { [weak self] id in self?.onPick?(id) }
            card.isMarked = preset.id == markedPresetID
            row.addArrangedSubview(card)
            cards[preset.id] = card
        }
    }

    /// Re-read the names after a language switch: the band names are the registry's
    /// own EN/RU pair, so the cards are rebuilt rather than patched.
    func retranslate() {
        rebuild()
    }

    /// Fill the library's shelf: the shown presets as the same cards the centre shows,
    /// three in a row, the shelf itself growing downwards.
    ///
    /// The library keeps its own list of cards because it *is* the same data with a
    /// different filter — two sources of cards would be two sources of truth.
    func showPresets(_ presets: [Preset], marked: String?, into container: NSStackView) {
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var row: [NSView] = []
        var rows: [NSStackView] = []
        for preset in presets {
            let card = PresetCard(preset: preset)
            card.onPick = { [weak self] id in self?.onPick?(id) }
            card.isMarked = preset.id == marked
            row.append(card)
            if row.count == 3 {
                rows.append(self.shelfRow(row))
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { rows.append(shelfRow(row)) }
        for shelf in rows { container.addArrangedSubview(shelf) }
    }

    private func shelfRow(_ views: [NSView]) -> NSStackView {
        let shelf = NSStackView(views: views)
        shelf.orientation = .horizontal
        shelf.alignment = .leading
        shelf.spacing = 10
        return shelf
    }
}

/// One preset, as a card: a coloured field, a mark, the band and the range of beats.
@MainActor
final class PresetCard: NSView {

    /// The user picked this preset.
    var onPick: ((String) -> Void)?

    /// Whether this preset is the one that is playing.
    var isMarked = false {
        didSet { needsDisplay = true }
    }

    private let preset: Preset
    /// The band the preset's beat falls into, or `nil` when it falls into none — a
    /// value the registry cannot produce, but a hand-edited one could.
    private let band: BrainwaveBand?
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// The beat itself, the number the preset exists to set — the card's own large
    /// digit, in the unit the window speaks.
    private let beatLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")

    init(preset: Preset) {
        self.preset = preset
        self.band = BrainwaveBand.band(forBeatHz: preset.beatHz)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .white
        beatLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        beatLabel.textColor = .white
        rangeLabel.font = .systemFont(ofSize: 10)
        rangeLabel.textColor = NSColor.white.withAlphaComponent(0.85)

        let stack = NSStackView(views: [iconView, nameLabel, beatLabel, rangeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(equalToConstant: 112),
            heightAnchor.constraint(equalToConstant: 112)
        ])

        // The band's own name and range travel with the registry (SPEC F3), so the card
        // reads them rather than repeating them. The beat is the number the user set.
        nameLabel.stringValue = band?.name(for: L10n.language) ?? L10n.tr("%1 Hz", Self.beatText(preset.beatHz))
        beatLabel.stringValue = L10n.tr("%1 Hz", Self.beatText(preset.beatHz))
        rangeLabel.stringValue = Self.rangeText(for: band)
        iconView.image = NSImage(
            systemSymbolName: Self.symbol(for: band),
            accessibilityDescription: nil
        )
        setAccessibilityLabel(
            nameLabel.stringValue + " " + beatLabel.stringValue + " " + rangeLabel.stringValue
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    /// One matcher, used by the sidebar's search and the library's: a preset matches
    /// when its beat, its category, its band or the band's own range say the query.
    /// `3`, `sleep`, `delta` — all three reach the same card.
    static func matches(preset: Preset, query: String) -> Bool {
        let haystacks = [
            Self.beatText(preset.beatHz),
            preset.title(for: L10n.language),
            PresetCatalogue.category(id: preset.categoryID)?.name(for: L10n.language).lowercased() ?? "",
            preset.band?.name(for: L10n.language).lowercased() ?? "",
            preset.band?.jsonRangeLabel.lowercased() ?? ""
        ]
        return haystacks.contains { $0.contains(query) }
    }

    /// The beat without the trailing ".0" the double would print: `5 Hz`, `5.5 Hz`.
    private static func beatText(_ beatHz: Double) -> String {
        beatHz.truncatingRemainder(dividingBy: 1).isZero
            ? String(Int(beatHz))
            : String(beatHz)
    }

    /// The range a band covers, from the record itself: the registry's `Delta 0.5–4 Hz`
    /// with the band's name taken off, and the Russian decimal comma in place of the dot.
    private static func rangeText(for band: BrainwaveBand?) -> String {
        guard let band else { return "" }
        let prefix = band.nameEn + " "
        let range = band.jsonRangeLabel.hasPrefix(prefix)
            ? String(band.jsonRangeLabel.dropFirst(prefix.count))
            : band.jsonRangeLabel
        guard L10n.language == .ru else { return range }
        return range
            .replacingOccurrences(of: ".", with: ",")
            .replacingOccurrences(of: "Hz", with: "Гц")
    }

    /// The mark of a band: a moon for the deep sleep range, a still bud for theta, a leaf
    /// for alpha, a lamp for focus, a bolt for the fast ranges. Chosen because the
    /// marks read at card size, where words for the band would not.
    private static func symbol(for band: BrainwaveBand?) -> String {
        switch band {
        case .delta: return "moon.fill"
        case .theta: return "camera.macro"
        case .alpha: return "leaf.fill"
        case .beta: return "lightbulb.fill"
        case .gamma: return "bolt.fill"
        case nil: return "waveform"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // The field: the band's own colour, from a darker ground to its own hue.
        let colour = Self.colour(for: band)
        let gradient = NSGradient(
            starting: colour.withAlphaComponent(0.6),
            ending: colour.withAlphaComponent(0.2)
        )
        gradient?.draw(in: bounds, angle: -90)

        if isMarked {
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onPick?(preset.id)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The band colours, chosen apart from one another far enough to tell cards
    /// side by side apart (SPEC §7.2: colour may carry, never alone — the name and the
    /// range on the face of the card carry too).
    private static func colour(for band: BrainwaveBand?) -> NSColor {
        func srgb(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        switch band {
        case .delta: return srgb(0x3B82F6)
        case .theta: return srgb(0x8B5CF6)
        case .alpha: return srgb(0x0EA5E9)
        case .beta: return srgb(0x10B981)
        case .gamma: return srgb(0xF97316)
        case nil: return .systemGray
        }
    }
}
