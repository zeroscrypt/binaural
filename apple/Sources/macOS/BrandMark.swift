import AppKit

/// The app's mark: a wave that comes to a point and carries on, the way the sound does.
///
/// It is drawn rather than a picture so it takes the interface's colour and stays sharp
/// at any size.
@MainActor
final class BrandMark: NSView {

    /// The colour of the stroke.
    var strokeColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        let height = bounds.height
        let middle = bounds.midY

        let path = NSBezierPath()
        path.lineWidth = max(1.5, height * 0.09)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // A sine that pinches in the middle: two waves meeting.
        let samples = 120
        for step in 0...samples {
            let t = CGFloat(step) / CGFloat(samples)
            let x = t * width
            let envelope = 0.35 + 0.65 * abs(cos(t * .pi))
            let y = middle + sin(t * 4 * .pi) * height * 0.42 * envelope
            if step == 0 {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        strokeColor.setStroke()
        path.stroke()
    }
}
