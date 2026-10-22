import AppKit

/// The scheme of the waves: a small ring with the waves on it, and what they are doing.
///
/// The panel's picture is the real thing at full size; this is the explanation of it —
/// where the beat's pulse is, how far the step's wave has come, and how long each of
/// them takes to go round.
@MainActor
final class WaveSchemeView: NSView {

    /// The figure whose waves are being shown. The scheme reads the phase from it
    /// rather than keeping a clock of its own: two clocks would drift apart, and the
    /// scheme would be explaining a wave that is not the one on screen.
    weak var source: ChakraFigureView?

    /// The colour the waves are drawn in: the colour of the chakra being played.
    var tint: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.42

        // The ring.
        let ring = NSBezierPath(ovalIn: NSRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))
        ring.lineWidth = 1
        NSColor.separatorColor.setStroke()
        ring.stroke()

        // The two waves, at the phases the figure is running them at.
        let beatPhase = source?.beatWavePhase ?? 0
        let stepProgress = source?.stepProgress ?? 0
        drawBump(
            on: ring,
            phase: beatPhase,
            sharpness: 8,
            colour: tint,
            radius: radius
        )
        drawBump(
            on: ring,
            phase: stepProgress,
            sharpness: 2,
            colour: tint.withAlphaComponent(0.6),
            radius: radius
        )

        // Where the step's wave has got to, as a mark on the ring.
        let angle = 2 * .pi * stepProgress
        let mark = CGPoint(
            x: centre.x + cos(angle) * radius,
            y: centre.y + sin(angle) * radius
        )
        NSColor.secondaryLabelColor.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: mark.x - 2.5, y: mark.y - 2.5, width: 5, height: 5
        )).fill()
    }

    /// A bump travelling round the ring, drawn as a bright arc.
    private func drawBump(
        on ring: NSBezierPath,
        phase: CGFloat,
        sharpness: CGFloat,
        colour: NSColor,
        radius: CGFloat
    ) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let steps = 72
        var path = NSBezierPath()
        var started = false
        for step in 0...steps {
            let s = CGFloat(step) / CGFloat(steps)
            let angle = 2 * .pi * (s - phase)
            let value = pow((cos(angle) + 1) / 2, sharpness)
            guard value > 0.02 else {
                started = false
                continue
            }
            let point = CGPoint(
                x: centre.x + cos(2 * .pi * s) * radius,
                y: centre.y + sin(2 * .pi * s) * radius
            )
            if started {
                path.line(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        path.lineWidth = 3
        path.lineCapStyle = .round
        colour.setStroke()
        path.stroke()
    }
}
