import AppKit
import BinauralCore
import QuartzCore

/// The body of the chakra mode: a schematic figure with the seven chakras on its spine.
///
/// The figure is a **line drawing**, the way a body is drawn in a chart: an outline
/// with nothing inside it, so the marks on the spine are the only things on it that
/// carry colour. A filled silhouette would compete with them, and a glow behind it
/// would pull the eye away from the spine — the one place anything is supposed to
/// happen.
///
/// Around it is the **cocoon**: a shell of particles that the sound assembles around
/// the body. Silent, the particles are pale and still and the shell is barely there —
/// a switched-off shell must not be mistaken for a switched-on one. Playing, they
/// drift and pulse, and the shell reads as something assembled out of them.
///
/// The movement is decoration on top of a picture that is already complete, so it
/// obeys the system's reduced-motion setting (SPEC §7.2) — and the state is carried
/// by the brightness as well as by the movement, so a still cocoon still says whether
/// the sound is on.
@MainActor
final class ChakraFigureView: NSView {

    /// The step being played, as an index into ``ChakraSequence/steps`` (root first).
    var currentIndex: Int? {
        didSet { needsDisplay = true }
    }

    /// How far the sequence has come. Every step up to this one is lit.
    var reachedIndex: Int = -1 {
        didSet { needsDisplay = true }
    }

    /// Whether the sound is playing. The cocoon comes alive with it.
    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateVibration()
            needsDisplay = true
        }
    }

    /// The user clicked a chakra, and wants the journey to start there. Reported as a
    /// step index in the sequence's order — root first, not crown first.
    var onPick: ((Int) -> Void)?

    /// How close a click has to be to count, as a fraction of the figure's height. The
    /// marks are small, and a click that lands between two of them should not pick the
    /// nearer one by accident.
    private static let pickRadius: CGFloat = 0.05

    /// The mark nearest to a point, if it is close enough to be a click.
    private func mark(near location: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (visualIndex, normalised) in Figure.marks.enumerated() {
            let centre = point(normalised.x, normalised.y)
            let distance = hypot(centre.x - location.x, centre.y - location.y)
            if best == nil || distance < best!.distance {
                best = (Figure.marks.count - 1 - visualIndex, distance)
            }
        }
        guard let best, best.distance < radius(Self.pickRadius) else { return nil }
        return best.index
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = mark(near: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(index)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        let overAMark = mark(near: convert(event.locationInWindow, from: nil)) != nil
        (overAMark ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// A length as a fraction of the figure's height.
    private func radius(_ fraction: CGFloat) -> CGFloat {
        figureHeight * fraction
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The reduced-motion setting is watched, not read once: it can be changed while
        // the app is running, and a cocoon that keeps vibrating after the user has
        // asked it to stop is exactly what they asked it to stop.
        //
        // A selector-based observer rather than a block with a token: the notification
        // centre keeps only a weak reference to the object, so there is nothing to
        // remove later and nothing to leak if the view goes first.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    deinit {
        clock.timer?.invalidate()
        clock.timer = nil
    }

    /// The system's accessibility settings changed. The cocoon obeys them at once.
    @objc private func accessibilityOptionsChanged() {
        updateVibration()
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The figure, in units of its own height — `H` from the crown to the soles.
    ///
    /// The proportions are Leonardo's: eight heads, and the seven chakras where the
    /// tradition puts them. The numbers come from measurements of the *Homo ad
    /// circulum* sheet rather than from a drawing book, and the standing pose is not a
    /// stylistic choice — a seated figure is 3.9 heads tall against the standing
    /// figure's 8, so the same seven marks would be half as far apart and would run
    /// into each other.
    private enum Figure {
        /// The head: from the crown to the chin is an eighth of the height.
        static let headCentreY: CGFloat = 0.062
        static let headHalfWidth: CGFloat = 0.047
        static let headHalfHeight: CGFloat = 0.062

        /// The trunk: neck, shoulders, ribs, waist, hips.
        static let neckTop: CGFloat = 0.112
        static let neckBottom: CGFloat = 0.170
        static let neckHalfWidth: CGFloat = 0.026
        /// The slope from the neck to the shoulder — without it the shoulders come out
        /// as a flat shelf, which is a hanger, not a person.
        static let slopeY: CGFloat = 0.180
        static let slopeHalfWidth: CGFloat = 0.062
        static let shoulderY: CGFloat = 0.200
        static let shoulderHalfWidth: CGFloat = 0.100
        static let chestY: CGFloat = 0.252
        static let chestHalfWidth: CGFloat = 0.078
        static let waistY: CGFloat = 0.375
        static let waistHalfWidth: CGFloat = 0.072
        static let hipY: CGFloat = 0.500
        static let hipHalfWidth: CGFloat = 0.088
        static let crotchY: CGFloat = 0.530

        /// The arms, hanging down beside the body.
        ///
        /// They were raised in a V, which is Leonardo's *second* pose and clears the
        /// third eye, the throat and the heart — but a person standing with their arms
        /// up is not standing at rest, and the drawing is of a person, not of a diagram
        /// of one. Down, the arms keep the marks on the spine clear anyway: they fall
        /// outside the line the chakras sit on.
        ///
        /// Drawn as a shape, like the legs: an arm is thicker at the shoulder than at
        /// the wrist, and one line cannot say that.
        static let arm: [(x: CGFloat, y: CGFloat)] = [
            (0.096, 0.200),   // the shoulder, tucked under the trunk's own shoulder
            (0.124, 0.258),   // the upper arm
            (0.130, 0.372),   // the elbow
            (0.126, 0.482),   // the forearm
            (0.116, 0.566),   // the wrist
            (0.128, 0.614),   // the hand
            (0.098, 0.634),   // the fingertips
            (0.082, 0.580),   // the wrist, inner
            (0.076, 0.470),   // the forearm, inner
            (0.078, 0.366),   // the elbow, inner
            (0.078, 0.244)    // the armpit
        ]

        /// The legs, drawn as a shape rather than as a line: a thigh is thicker than
        /// an ankle, and a leg drawn as one stroke cannot say that.
        ///
        /// They are close together — the standing figure's legs are not spread, and
        /// wide apart they would take the width away from the marks, which are all on
        /// the centre line and are the only thing the drawing is for.
        static let leg: [(x: CGFloat, y: CGFloat)] = [
            (0.088, 0.478),   // the hip, at the trunk's own width
            (0.100, 0.610),   // the thigh
            (0.090, 0.735),   // the knee
            (0.074, 0.828),   // the calf
            (0.052, 0.876),   // the ankle
            (0.092, 0.914),   // the toe
            (0.052, 0.982),   // the ball of the foot
            (0.012, 0.966),   // the heel
            (0.016, 0.872),   // the ankle, inner
            (0.026, 0.818),   // the calf, inner
            (0.034, 0.728),   // the knee, inner
            (0.032, 0.608),   // the thigh, inner
            (0.014, 0.520)    // the crotch
        ]

        /// The seven chakras and the earth below the feet, as heights down the body.
        ///
        /// The heights are the traditional ones — the crown at the top of the head,
        /// the third eye between the brows, the throat at the base of the throat, the
        /// heart at the centre of the chest, the solar plexus under the ribcage, the
        /// sacral below the navel, the root at the base of the spine — and they are
        /// Leonardo's own measurements of where those points fall on a human body.
        ///
        /// The gaps are 0.055–0.102 of the height: the tight pairs are the crown
        /// and the third eye, and the sacral and the root, and both are clear of a
        /// marker 0.012 wide.
        static let marks: [(x: CGFloat, y: CGFloat)] = [
            (0, 0.012),   // crown
            (0, 0.055),   // third eye
            (0, 0.157),   // throat
            (0, 0.250),   // heart
            (0, 0.341),   // solar plexus
            (0, 0.420),   // sacral
            (0, 0.470),   // root
            (0, 1.075)    // earth, below the soles
        ]

        /// The cocoon's outline: a closed curve around the figure.
        ///
        /// An egg: narrow above the head, widest at the shoulders, drawn in towards
        /// the feet. The sound assembles the grains into this shape.
        static let cocoon: [(x: CGFloat, y: CGFloat)] = [
            (0.000, -0.080),
            (0.135, -0.035),
            (0.245, 0.045),
            (0.305, 0.175),
            (0.315, 0.345),
            (0.300, 0.525),
            (0.272, 0.705),
            (0.215, 0.875),
            (0.120, 1.020),
            (0.000, 1.115),
            (-0.120, 1.020),
            (-0.215, 0.875),
            (-0.272, 0.705),
            (-0.300, 0.525),
            (-0.315, 0.345),
            (-0.305, 0.175),
            (-0.245, 0.045),
            (-0.135, -0.035)
        ]

        /// How far the cocoon reaches above the crown and below the soles.
        static let cocoonTop: CGFloat = -0.080
        static let cocoonBottom: CGFloat = 1.115
    }

    /// The figure's height in points.
    ///
    /// The width is what sizes it: the hands are level with the crown and the cocoon
    /// has to clear them, so the drawing is nearly as wide as it is tall. The height
    /// then follows, with room left above the crown and below the earth for the
    /// cocoon to reach.
    private var figureHeight: CGFloat {
        // The width is no longer the limit: with the arms down the figure is narrow,
        // and the cocoon around it is narrower still. The height decides.
        min(bounds.height * 0.82, bounds.width / 0.68)
    }

    /// Where the crown of the head sits, in points from the top of the view.
    ///
    /// The drawing is centred as a whole — the cocoon reaches past the head at the top
    /// and past the earth at the bottom — so the body itself sits slightly high.
    private var crownY: CGFloat {
        let above = -Figure.cocoonTop * figureHeight
        let below = Figure.cocoonBottom * figureHeight
        return max(above, (bounds.height - below) / 2)
    }

    /// A point given as a half-width in units of the figure's height and a height down
    /// from its crown. The units are the same everywhere, so the proportions are the
    /// drawing's.
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: bounds.midX + x * figureHeight,
            y: crownY + y * figureHeight
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawCocoon()

        let ink = NSColor.secondaryLabelColor
        let line = NSBezierPath()
        line.lineWidth = max(1.0, figureHeight * 0.006)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        // The head.
        let head = point(0, Figure.headCentreY)
        let headWidth = Figure.headHalfWidth * figureHeight
        let headHeight = Figure.headHalfHeight * figureHeight
        line.appendOval(in: NSRect(
            x: head.x - headWidth,
            y: head.y - headHeight,
            width: headWidth * 2,
            height: headHeight * 2
        ))

        // The trunk: neck, shoulders, ribs, waist, hips.
        line.append(smoothPath([
            (0, Figure.neckTop),
            (Figure.neckHalfWidth, Figure.neckBottom),
            (Figure.slopeHalfWidth, Figure.slopeY),
            (Figure.shoulderHalfWidth, Figure.shoulderY),
            (Figure.chestHalfWidth, Figure.chestY),
            (Figure.waistHalfWidth, Figure.waistY),
            (Figure.hipHalfWidth, Figure.hipY),
            (0, Figure.crotchY),
            (-Figure.hipHalfWidth, Figure.hipY),
            (-Figure.waistHalfWidth, Figure.waistY),
            (-Figure.chestHalfWidth, Figure.chestY),
            (-Figure.shoulderHalfWidth, Figure.shoulderY),
            (-Figure.slopeHalfWidth, Figure.slopeY),
            (-Figure.neckHalfWidth, Figure.neckBottom)
        ]))

        // The arms and the legs: shapes, like the trunk. A limb is thicker at the top
        // than at the wrist, and one line round it cannot say that.
        for side in [1.0, -1.0] as [CGFloat] {
            line.append(smoothPath(Figure.arm.map { (x: side * $0.x, y: $0.y) }))
            line.append(smoothPath(Figure.leg.map { (x: side * $0.x, y: $0.y) }))
        }

        ink.setStroke()
        line.stroke()

        drawMarks()
    }

    /// A closed path through the given points, smoothed.
    ///
    /// The curve runs *through* the points rather than between them. Smoothing through
    /// the midpoints is the cheaper trick, but it pulls the shape in towards its own
    /// centre: a torso drawn that way loses its shoulders, and the figure comes out
    /// narrower than the marks on it. A spline through the points keeps the figure's
    /// extent and only softens the corners.
    private func smoothPath(_ points: [(x: CGFloat, y: CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        let p = points.map { point($0.x, $0.y) }
        guard p.count > 2 else { return path }
        // How much of the neighbouring segment the curve borrows. Below 1 it rounds the
        // corners without the overshoot a full Catmull-Rom puts at a sharp turn.
        let tension = 0.8
        path.move(to: p[0])
        for index in p.indices {
            let p0 = p[(index - 1 + p.count) % p.count]
            let p1 = p[index]
            let p2 = p[(index + 1) % p.count]
            let p3 = p[(index + 2) % p.count]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension / 6,
                y: p1.y + (p2.y - p0.y) * tension / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension / 6,
                y: p2.y - (p3.y - p1.y) * tension / 6
            )
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    /// The seven marks: a dot in each chakra's colour, on the spine.
    private func drawMarks() {
        for (visualIndex, normalised) in Figure.marks.enumerated() {
            // The visual order is crown-first; the sequence runs earth-first.
            let stepIndex = Figure.marks.count - 1 - visualIndex
            let centre = point(normalised.x, normalised.y)
            let colour = ChakraPalette.color(forStepIndex: stepIndex)
            let isCurrent = currentIndex == stepIndex
            let isReached = stepIndex <= reachedIndex
            // The step in hand is brighter than the ones around it, so the eye finds it
            // before it reads anything.
            let markColour = isCurrent
                ? ChakraPalette.brightColor(forStepIndex: stepIndex)
                : colour

            // The marker is sized against the *figure*, not the panel: the tightest pair
            // is the crown and the third eye, five hundredths of the height apart, and a
            // dot wider than that would run into its neighbour.
            let base = figureHeight * 0.014
            let radius = isCurrent ? base * 1.5 : base

            if isCurrent {
                // A soft halo, drawn as a few concentric circles of falling alpha. It is
                // the one thing on screen that moves the eye — and it has to stay small:
                // at the size of the figure a bigger halo swallowed the two marks below
                // it, which is the opposite of what a highlight is for.
                let halos: [(scale: CGFloat, alpha: CGFloat)] = [
                    (1.6, 0.14), (1.2, 0.22)
                ]
                for halo in halos {
                    let grown = radius * halo.scale
                    markColour.withAlphaComponent(halo.alpha).setFill()
                    NSBezierPath(ovalIn: NSRect(
                        x: centre.x - grown, y: centre.y - grown,
                        width: grown * 2, height: grown * 2
                    )).fill()
                }
            }

            markColour.withAlphaComponent(isReached ? 0.75 : 0.28).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            )).fill()
        }
    }

    // MARK: - The cocoon

    /// Roughly thirty frames a second. The cocoon shivers; it does not animate.
    private static let vibrationInterval: TimeInterval = 1.0 / 30.0

    /// How many particles the shell is made of.
    private static let particleCount = 132

    /// The cocoon's clock, in a box of its own.
    ///
    /// A `@MainActor` type's `deinit` is not isolated, and it may not reach the actor's
    /// own properties — so the one thing that has to be switched off on the way out
    /// lives in plain `Sendable` state.
    private final class Clock: @unchecked Sendable {
        var timer: Timer?
    }

    /// The clock that makes the cocoon breathe.
    private let clock = Clock()

    /// Whether the system asks for reduced motion (SPEC §7.2).
    ///
    /// The tests answer for themselves: the setting belongs to the machine the suite
    /// runs on, and a test that depended on it would pass on one machine and fail on
    /// another.
    var reducedMotionOverride: Bool?

    private var isReducedMotion: Bool {
        reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The grains' two places: where they belong in the cocoon, and where they lie when
    /// there is no sound.
    ///
    /// The outline does not move, so the places are worked out once: the vibration is a
    /// small displacement of a position that is already known. The grains are spread by
    /// arc length rather than by index, so they cannot bunch wherever the outline's
    /// points happen to be close together.
    private static let particles: [(home: CGPoint, normal: CGPoint, dust: CGPoint)] = {
        let outline = Figure.cocoon.map { CGPoint(x: $0.x, y: $0.y) }
        guard outline.count > 2 else { return [] }
        var lengths: [CGFloat] = []
        var total: CGFloat = 0
        for index in outline.indices {
            let next = outline[(index + 1) % outline.count]
            let length = hypot(next.x - outline[index].x, next.y - outline[index].y)
            lengths.append(length)
            total += length
        }
        guard total > 0 else { return [] }

        var particles: [(home: CGPoint, normal: CGPoint, dust: CGPoint)] = []
        for step in 0..<particleCount {
            let target = total * CGFloat(step) / CGFloat(particleCount)
            var walked: CGFloat = 0
            var home = outline[0]
            var normal = CGPoint(x: 0, y: -1)
            for index in outline.indices {
                let length = lengths[index]
                if walked + length >= target {
                    let t = (target - walked) / length
                    let next = outline[(index + 1) % outline.count]
                    home = CGPoint(
                        x: outline[index].x + (next.x - outline[index].x) * t,
                        y: outline[index].y + (next.y - outline[index].y) * t
                    )
                    let dx = next.x - outline[index].x
                    let dy = next.y - outline[index].y
                    let norm = hypot(dx, dy)
                    // The outline runs clockwise on screen, so the outward normal is the
                    // direction turned the other way.
                    normal = norm > 0 ? CGPoint(x: dy / norm, y: -dx / norm) : .zero
                    break
                }
                walked += length
            }
            // The dust: a cloud around the figure, in no particular shape. The number
            // is derived from the grain's own index, so every run of the app scatters
            // the same way — a picture that changed every frame would be a flicker.
            let hash = UInt64(truncatingIfNeeded: step &* 2_654_435_761)
            let angle = CGFloat(Double(hash % 1024) / 1024.0) * 2 * .pi
            let radius = 0.22 + CGFloat(Double((hash >> 10) % 1024) / 1024.0) * 0.85
            let dust = CGPoint(
                x: cos(angle) * radius * 0.66,
                y: 0.42 + sin(angle) * radius * 0.80
            )
            particles.append((home, normal, dust))
        }
        return particles
    }()

    /// How far the grains have assembled into the cocoon: 0 is scattered dust, 1 is the
    /// shape. It moves a step at a time while the sound plays, so the cocoon *forms*
    /// rather than appearing.
    fileprivate var formation: CGFloat = 0

    /// Start or stop the shiver, according to the state and the system's setting.
    private func updateVibration() {
        if isReducedMotion {
            // Nothing moves, so the grains are simply in one place or the other.
            clock.timer?.invalidate()
            clock.timer = nil
            formation = isPlaying ? 1 : 0
            return
        }
        if clock.timer == nil { startVibration() }
        if !isPlaying, formation == 0 {
            // The dust has settled; there is nothing left to animate.
            clock.timer?.invalidate()
            clock.timer = nil
        }
    }

    /// The clock that makes the cocoon form and shiver.
    private func startVibration() {
        clock.timer?.invalidate()
        clock.timer = Timer.scheduledTimer(
            withTimeInterval: Self.vibrationInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isHiddenOrHasHiddenAncestor else {
                    // The cocoon is off screen with the rest of the panel, and waking
                    // the app for it thirty times a second is waste.
                    self.clock.timer?.invalidate()
                    self.clock.timer = nil
                    return
                }
                let step: CGFloat = self.isPlaying ? 0.05 : -0.05
                if self.formation > 0 || self.isPlaying {
                    self.formation = min(max(self.formation + step, 0), 1)
                }
                if !self.isPlaying, self.formation == 0 {
                    self.clock.timer?.invalidate()
                    self.clock.timer = nil
                    return
                }
                self.needsDisplay = true
            }
        }
    }

    /// The shell of grains around the figure.
    ///
    /// Silent, they are dust: scattered, faint, and in no shape at all, so a switched-off
    /// cocoon cannot be mistaken for a live one. Playing, they assemble into the
    /// cocoon's outline, in the colour of the chakra being played, and shiver.
    private func drawCocoon() {
        let alive = isPlaying
        // The clock only runs while the sound does. With reduced motion the shell is
        // drawn in its still state — the brightness still says the sound is on.
        let time = alive && !isReducedMotion ? CACurrentMediaTime() : 0
        // The cocoon wears the colour of the step being played: the shell and the mark
        // on the spine are the same thing, said twice.
        let tint = currentIndex.map { ChakraPalette.brightColor(forStepIndex: $0) }
            ?? NSColor.controlAccentColor
        let colour = alive ? tint : NSColor.secondaryLabelColor

        for (index, particle) in Self.particles.enumerated() {
            // Each grain has its own phase, so the shell shimmers instead of breathing
            // as one piece.
            let phase = CGFloat(index) * 0.618
            // The shiver, in the figure's own units: a hundredth of the height is about
            // a point and a half — enough to see, too little to move the figure.
            let shake = alive
                ? CGFloat(sin(time * 2.3 + phase)) * 0.010
                : 0
            let homeX = particle.home.x + particle.normal.x * shake
            let homeY = particle.home.y + particle.normal.y * shake
            let centre = point(
                particle.dust.x + (homeX - particle.dust.x) * formation,
                particle.dust.y + (homeY - particle.dust.y) * formation
            )
            let pulse = alive
                ? 1 + CGFloat(sin(time * 3.1 + phase * 1.7)) * 0.28
                : 1
            let size = figureHeight * (alive ? 0.0062 : 0.0040) * pulse
            let alpha = 0.10 + 0.42 * formation
            colour.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: centre.x - size, y: centre.y - size,
                width: size * 2, height: size * 2
            )).fill()
        }
    }
}

extension CGPoint {
    /// The point mirrored across the vertical centre line.
    func mirrored() -> CGPoint {
        CGPoint(x: 1 - x, y: y)
    }
}

/// The panel of the chakra mode: the figure, what the current step is, and the two
/// controls — how long a step lasts, and the beat.
///
/// The beat is a free-text field rather than a popup because the offered durations are
/// a short list and the beat is not: 0.5–40 Hz is a range, and the value that suits a
/// listener is theirs to pick. The default of 21 Hz is on screen from the start, and
/// the note under the field says where it came from, so a number that looks arbitrary
/// is not.
@MainActor
final class ChakraView: NSView {

    /// The user typed a new beat, in Hz.
    var onBeatChange: ((Double) -> Void)?
    /// The user picked a new length for one step, in seconds.
    var onStepSecondsChange: ((Int) -> Void)?
    /// The user chose which way the journey walks first.
    var onDirectionChange: ((ChakraSequence.Direction) -> Void)?
    /// The user clicked a chakra on the figure, and wants the journey to start there.
    var onChakraPicked: ((Int) -> Void)?

    private let figure = ChakraFigureView()
    private let frequencyLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let durationCaptionLabel = NSTextField(labelWithString: "")
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let directionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let beatCaptionLabel = NSTextField(labelWithString: "")
    private let beatField = TallTargetTextField()
    private let beatStepper = NSStepper()
    private let noteLabel = NSTextField(labelWithString: "")

    private var stepSeconds: Int = ChakraSequence.defaultStepSeconds
    private var direction: ChakraSequence.Direction = .up
    private var beatHz: Double = ChakraSequence.defaultBeatHz
    private var isSyncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The mode is off until the user asks for it, and the block is hidden until
        // then — but a hidden view still lays out, so it has to start hidden rather
        // than be hidden after the first pass.
        isHidden = true
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Building

    private func setUp() {
        frequencyLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        frequencyLabel.textColor = .controlAccentColor

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 2

        durationCaptionLabel.font = .systemFont(ofSize: 13)
        durationCaptionLabel.textColor = .secondaryLabelColor

        durationPopup.controlSize = .regular
        durationPopup.font = .systemFont(ofSize: 13)
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)
        durationPopup.setAccessibilityLabel(L10n.tr("Step"))

        directionCheckbox.target = self
        directionCheckbox.action = #selector(directionToggled)
        directionCheckbox.setAccessibilityLabel(L10n.tr("Direction"))

        beatCaptionLabel.font = .systemFont(ofSize: 13)
        beatCaptionLabel.textColor = .secondaryLabelColor

        beatField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        // Left edge, not right: a number that changes has to be read at a fixed place,
        // and the right edge of a short field is a different place for every value.
        beatField.alignment = .left
        // The text sits in the middle of the field's height, not at the top of it. A
        // single-line bezeled cell centres itself, but only if the cell knows the
        // field's height — so the line height is fixed to the font's, and the extra
        // room the 44 px target leaves is split above and below.
        beatField.cell?.usesSingleLineMode = true
        beatField.cell?.lineBreakMode = .byClipping
        beatField.cell?.wraps = false
        beatField.delegate = self
        beatField.target = self
        beatField.action = #selector(beatCommitted)
        beatField.formatter = Self.beatFormatter()
        beatField.setAccessibilityLabel(ChakraSequence.beatCaption)

        // The arrows beside the beat. The `↑`/`↓` keys move the *frequency*; the beat
        // had no mouse path at all, and a number that can only be changed by typing is a
        // number nobody changes. Half a hertz a click, which is the difference between
        // the alpha band and the edge of it.
        beatStepper.minValue = ChakraSequence.minBeatHz
        beatStepper.maxValue = ChakraSequence.maxBeatHz
        beatStepper.increment = 0.5
        beatStepper.valueWraps = false
        beatStepper.target = self
        beatStepper.action = #selector(beatStepperMoved)
        beatStepper.setAccessibilityLabel(ChakraSequence.beatCaption)

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.stringValue = ChakraSequence.defaultBeatNote

        let durationRow = NSStackView(views: [durationCaptionLabel, durationPopup])
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.spacing = 8

        let beatRow = NSStackView(views: [beatCaptionLabel, beatField, beatStepper])
        beatRow.orientation = .horizontal
        beatRow.alignment = .centerY
        beatRow.spacing = 8

        // The controls share one row. The panel has to fit between the timer and the
        // bottom of the window, and two rows of controls was what pushed the note off
        // the screen.
        //
        // The trailing view is a spacer: a stack with `.fill` gives the slack to its
        // lowest-priority child, and a plain view has a far lower content-hugging
        // priority than a row of controls. Without it the slack went to the beat row
        // and pushed the caption to the far edge of the window.
        let controls = NSStackView(views: [durationRow, beatRow, NSView()])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 16

        let text = NSStackView(views: [
            frequencyLabel, nameLabel, descriptionLabel, controls,
            directionCheckbox, noteLabel
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let row = NSStackView(views: [figure, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            figure.widthAnchor.constraint(equalToConstant: 170),
            figure.heightAnchor.constraint(equalToConstant: 192),
            // SPEC §7.2: 44 px minimum click target. The field is the height of its own
            // text, and `TallTargetTextField` adds the missing band back as hit slop.
            durationPopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // As wide as the widest beat the mode accepts — `40.0` — and no wider.
            beatField.widthAnchor.constraint(
                equalToConstant: FieldMetrics.width(
                    for: "40.0",
                    font: beatField.font ?? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                )
            ),
        ])

        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildDurationItems()
        setStepSeconds(stepSeconds)
        setDirection(direction)
        setBeatHz(beatHz)
    }

    /// One decimal place, and a range that matches the mode's own limits.
    ///
    /// The locale is fixed to POSIX so the field reads `21.0` and not `21,0`: the
    /// frequencies on screen are written with a dot whatever the system locale is, and
    /// the beat belongs next to them.
    private static func beatFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.minimum = NSNumber(value: ChakraSequence.minBeatHz)
        formatter.maximum = NSNumber(value: ChakraSequence.maxBeatHz)
        formatter.usesGroupingSeparator = false
        return formatter
    }

    /// The offered lengths are data, and translating them changes every caption, so the
    /// list is rebuilt rather than patched.
    private func rebuildDurationItems() {
        durationPopup.removeAllItems()
        for choice in ChakraSequence.stepSecondsChoices {
            durationPopup.addItem(withTitle: ChakraSequence.stepText(choice))
            durationPopup.lastItem?.representedObject = choice
        }
    }

    // MARK: - Value

    /// Tell the panel whether the sound is playing. The cocoon around the figure comes
    /// alive with it and goes quiet with it.
    func setPlaying(_ playing: Bool) {
        figure.isPlaying = playing
    }

    /// Show a step: its frequency, its name, what it is about, and how far the sequence
    /// has come.
    func show(step: ChakraStep, index: Int, reachedIndex: Int) {
        frequencyLabel.stringValue = FrequencyGrid.text(step.hz)
        // The number wears its chakra's colour: the colour is what the eye reads first,
        // and it is the same colour as the mark on the figure.
        frequencyLabel.textColor = ChakraPalette.brightColor(forStepIndex: index)
        nameLabel.stringValue = ChakraSequence.name(of: step)
        descriptionLabel.stringValue = ChakraSequence.description(of: step)
        figure.currentIndex = index
        figure.reachedIndex = reachedIndex
        setAccessibilityValue("\(ChakraSequence.name(of: step)), \(FrequencyGrid.text(step.hz)) Hz")
    }

    /// Select a length without telling anyone — used while restoring.
    func setStepSeconds(_ value: Int) {
        stepSeconds = value
        let index = ChakraSequence.stepSecondsChoices.firstIndex(of: value)
            ?? Self.closestChoice(to: value)
        isSyncing = true
        durationPopup.selectItem(at: index)
        isSyncing = false
    }

    private static func closestChoice(to value: Int) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, choice) in ChakraSequence.stepSecondsChoices.enumerated() {
            let distance = abs(choice - value)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Show which way the journey walks first.
    func setDirection(_ value: ChakraSequence.Direction) {
        direction = value
        isSyncing = true
        directionCheckbox.state = value == .up ? .on : .off
        isSyncing = false
    }

    /// Show a beat without telling anyone.
    func setBeatHz(_ value: Double) {
        beatHz = value
        isSyncing = true
        beatField.doubleValue = value
        beatStepper.doubleValue = value
        isSyncing = false
    }

    /// The length of one step, in seconds.
    var selectedStepSeconds: Int { stepSeconds }

    /// Which way the journey walks first.
    var selectedDirection: ChakraSequence.Direction { direction }

    /// The beat currently shown, in Hz.
    var selectedBeatHz: Double { beatHz }

    // MARK: - State the tests read

    var durationChoiceTitles: [String] { durationPopup.itemArray.map(\.title) }
    var frequencyText: String { frequencyLabel.stringValue }
    /// The colour of the number on screen, so a test can check that it wears its
    /// chakra's colour.
    var frequencyColour: NSColor { frequencyLabel.textColor ?? .labelColor }
    var nameText: String { nameLabel.stringValue }
    var descriptionText: String { descriptionLabel.stringValue }
    var beatFieldText: String { beatField.stringValue }
    var figureCurrentIndex: Int? { figure.currentIndex }
    var figureReachedIndex: Int { figure.reachedIndex }
    /// Whether the cocoon is alive: the sound's shape, around the figure.
    var figureIsPlaying: Bool { figure.isPlaying }
    /// How far the grains have assembled into the cocoon: 0 is dust, 1 is the shape.
    var cocoonFormation: CGFloat { figure.formation }
    /// The same seam the figure has: the tests reach the figure through the panel.
    var reducedMotionOverride: Bool? {
        get { figure.reducedMotionOverride }
        set { figure.reducedMotionOverride = newValue }
    }

    // MARK: - Actions

    @objc private func durationChanged() {
        guard !isSyncing,
              let raw = durationPopup.selectedItem?.representedObject as? Int,
              raw != stepSeconds
        else { return }
        stepSeconds = raw
        onStepSecondsChange?(raw)
    }

    @objc private func directionToggled() {
        guard !isSyncing else { return }
        direction = directionCheckbox.state == .on ? .up : .down
        onDirectionChange?(direction)
    }

    @objc private func beatStepperMoved() {
        guard !isSyncing else { return }
        let clamped = min(
            ChakraSequence.maxBeatHz,
            max(ChakraSequence.minBeatHz, beatStepper.doubleValue)
        )
        beatStepper.doubleValue = clamped
        beatHz = clamped
        onBeatChange?(clamped)
    }

    @objc private func beatCommitted() {
        guard !isSyncing else { return }
        let value = beatField.doubleValue
        let clamped = min(
            ChakraSequence.maxBeatHz,
            max(ChakraSequence.minBeatHz, value)
        )
        beatHz = clamped
        // Write the clamped value back, so the field never shows a number the mode is
        // not using.
        isSyncing = true
        beatField.doubleValue = clamped
        isSyncing = false
        onBeatChange?(clamped)
    }

    // MARK: - Language

    /// Re-read every caption after a language switch (SPEC §7.4), keeping the values.
    func retranslate() {
        durationCaptionLabel.stringValue = L10n.tr("Step")
        durationPopup.setAccessibilityLabel(L10n.tr("Step"))
        directionCheckbox.title = direction.name(for: L10n.language)
        directionCheckbox.setAccessibilityLabel(L10n.tr("Direction"))
        beatCaptionLabel.stringValue = ChakraSequence.beatCaption
        beatField.setAccessibilityLabel(ChakraSequence.beatCaption)
        noteLabel.stringValue = ChakraSequence.defaultBeatNote
        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildDurationItems()
        setStepSeconds(stepSeconds)
        setDirection(direction)
    }
}

extension ChakraView: NSTextFieldDelegate {

    /// Commit on focus loss as well as on Return — a half-typed beat must not stay in
    /// the field while the mode is using another one.
    func controlTextDidEndEditing(_ obj: Notification) {
        beatCommitted()
    }
}
