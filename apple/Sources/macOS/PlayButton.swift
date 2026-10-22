import AppKit

/// The play button: a disc, the way a transport's play button is a disc.
///
/// AppKit has no round bezel, so the button draws itself: a filled circle in the
/// accent colour with the glyph on it — a triangle for play, two bars for pause. While
/// the sound is on the disc carries a soft halo, so the state is legible without
/// reading the glyph.
@MainActor
final class PlayButton: NSButton {

    /// Whether the sound is playing: the disc glows and the glyph becomes a pause.
    var isPlaying = false {
        didSet { needsDisplay = true }
    }

    /// The size of the disc itself, in points.
    private var discSide: CGFloat {
        max(24, min(bounds.width, bounds.height) - 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = discSide
        let rect = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )

        // The halo: a bigger, fainter disc behind the button, so a playing app reads
        // as lit from across the room.
        if isPlaying {
            let halo = rect.insetBy(dx: -6, dy: -6)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn: halo).fill()
        }

        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // The glyph.
        NSColor.white.setFill()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        if isPlaying {
            let barWidth = max(2, side * 0.10)
            let barHeight = side * 0.36
            let gap = side * 0.12
            for offset in [-gap / 2, gap / 2] {
                NSBezierPath(
                    rect: NSRect(
                        x: centre.x + offset - barWidth / 2,
                        y: centre.y - barHeight / 2,
                        width: barWidth,
                        height: barHeight
                    )
                ).fill()
            }
        } else {
            let size = side * 0.36
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centre.x - size * 0.45, y: centre.y - size * 0.6))
            path.line(to: NSPoint(x: centre.x - size * 0.45, y: centre.y + size * 0.6))
            path.line(to: NSPoint(x: centre.x + size * 0.7, y: centre.y))
            path.close()
            path.fill()
        }
    }

    /// A click anywhere on the button is a click on the disc.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let side = discSide
        let rect = NSRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
        return rect.contains(convert(point, from: superview)) ? self : nil
    }
}
