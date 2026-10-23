import AppKit

/// The card of the hand-drawn layout: a rounded surface with a hair of a border,
/// carrying one block of the window's content.
///
/// The pair of colours is the Qt theme's own (`ui/theme.py`): `surface` fills and
/// `border` strokes, so the two implementations cannot drift apart by accident.
///
/// The card paints rather than layers: a dynamic `NSColor` resolves inside `draw(_:)`
/// every redraw, which is what makes a theme switch repaint it without any hook — a
/// `CGColor` set once on a layer would keep the old appearance's values instead.
@MainActor
final class CardBox: NSView {

    /// The fill and the hairline, as the Qt tokens name them.
    private static let fill = DynamicColor.make(light: 0xFFFFFF, dark: 0x1E1A2E)
    private static let stroke = DynamicColor.make(light: 0xEFE7FC, dark: 0x322B4A)

    private let content: NSView
    private let padding: CGFloat

    init(content: NSView, padding: CGFloat = 12) {
        self.content = content
        self.padding = padding
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        path.addClip()
        Self.fill.setFill()
        path.fill()
        Self.stroke.setStroke()
        path.stroke()
    }
}
