import AppKit
import BinauralCore

/// One chakra as a button: a filled circle in the chakra's colour.
///
/// The marks on the figure are small, and a small mark is a hard mark to hit. These are
/// the same eight steps as real buttons — a whole finger's worth of each — and choosing
/// one is what the mode plays from.
final class ChakraButton: NSButton {

    /// The colour of the step this button stands for.
    var fill: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    /// Whether this is the step being played.
    var isCurrent: Bool = false {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        // The step in hand is a bigger circle with a ring around it; the rest are
        // smaller and plain. The size does the work, so the difference survives a
        // greyscale print and a colour-blind reader.
        let inset: CGFloat = isCurrent ? 2 : 5
        let circle = NSRect(
            x: inset,
            y: inset,
            width: bounds.width - inset * 2,
            height: bounds.height - inset * 2
        )
        let path = NSBezierPath(ovalIn: circle)
        (isHighlighted ? ChakraPalette.bright(fill) : fill).setFill()
        path.fill()
        if isCurrent {
            NSColor.labelColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}
