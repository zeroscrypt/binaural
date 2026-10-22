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

    /// Called on every frame, so that whatever else shows the same waves can be
    /// redrawn with them.
    var onFrame: (() -> Void)?

    /// Where the beat's wave is on the ring right now, as a fraction of the way round.
    var beatWavePhase: CGFloat { AuraWave.beatPhase(travel: streamTravel, beatHz: beatHz) }

    /// The beat the aura pulses to, in hertz.
    ///
    /// The wave it makes is slowed down — the eye cannot follow twenty-one pulses a
    /// second — but it is this beat and not some other number, so a faster beat makes
    /// a faster wave.
    var beatHz: Double = ChakraSequence.defaultBeatHz {
        didSet { needsDisplay = true }
    }

    /// How long one step of the journey lasts, in seconds.
    ///
    /// The step's wave goes round the ring exactly once per step, so the picture says
    /// how much of the step is left.
    var stepSeconds: Int = ChakraSequence.defaultStepSeconds {
        didSet { needsDisplay = true }
    }

    /// When the current step began.
    ///
    /// The figure keeps the clock rather than being told the time: the wave moves
    /// every frame, and a number pushed thirty times a second is a number that can be
    /// a frame out of step with the wave it belongs to.
    var stepStartedAt: Date? {
        didSet { needsDisplay = true }
    }

    /// How far the current step has gone, from 0 to 1.
    var stepProgress: CGFloat = 0 {
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

        /// The trunk's outline: neck, shoulders, ribs, waist, hips, and back up.
        static let trunk: [(x: CGFloat, y: CGFloat)] = [
            (0, neckTop),
            (neckHalfWidth, neckBottom),
            (slopeHalfWidth, slopeY),
            (shoulderHalfWidth, shoulderY),
            (chestHalfWidth, chestY),
            (waistHalfWidth, waistY),
            (hipHalfWidth, hipY),
            (0, crotchY),
            (-hipHalfWidth, hipY),
            (-waistHalfWidth, waistY),
            (-chestHalfWidth, chestY),
            (-shoulderHalfWidth, shoulderY),
            (-slopeHalfWidth, slopeY),
            (-neckHalfWidth, neckBottom)
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
            (0.000, 1.075),
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
        static let cocoonBottom: CGFloat = 1.075
        /// The point the shells close in on: the middle of the body.
        static let cocoonCentreY: CGFloat = 0.500
        /// The ground the figure stands on: the sole of the foot.
        ///
        /// The curve through the foot's points overshoots a little at the turn, and a
        /// figure whose feet sink below the ground is a figure sunk into it.
        static let groundY: CGFloat = 0.980

        /// How far the aura reaches in toward the spine at a height.
        ///
        /// The dents are at the chakras: the aura goes into each of them and comes back
        /// out, and the one being played reaches in deepest.
        static func reachIn(at y: CGFloat, activeY: CGFloat?) -> CGFloat {
            var deepest: CGFloat = 0
            for mark in marks {
                let distance = abs(mark.y - y)
                guard distance < 0.030 else { continue }
                let depth = 1 - distance / 0.030
                let weight: CGFloat = mark.y == activeY ? 2.0 : 1.0
                deepest = max(deepest, depth * depth * weight)
            }
            return min(deepest, 0.26)
        }
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
        drawBodyGrains()
        drawMarks()
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

    // MARK: - The aura

    /// A grain of the streams.
    ///
    /// A grain is born on the ring and travels round it, in the wave: up the left side,
    /// out through the crown, down the right and into the earth under the feet, where
    /// it is absorbed and another takes its place. Its colour is the colour of the
    /// chakra it is passing at the time, so the ring shows the rainbow climbing on the
    /// left and coming down again on the right.
    private struct Grain {
        /// Where it was born, as a fraction of the way round its round.
        let birth: CGFloat
        /// Which side it takes when it comes out of the top: 0 is the left, 1 the right.
        let side: Int
        /// The way it wanders when there is no sound.
        let wander: CGPoint
    }

    /// A grain of the body.
    ///
    /// The figure is drawn with grains and not with a line: they float around the
    /// contour while there is no sound, and they assemble onto it when the sound
    /// comes, so the body gathers itself out of the dust and holds an edge.
    private struct BodyGrain {
        /// Where it sits on the contour.
        let home: CGPoint
        /// The way it wanders while the sound is off.
        let wander: CGPoint
    }

    /// Points along a polyline, one every `spacing` units.
    private static func sample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 1 else { return [] }
        var out: [CGPoint] = []
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int((length / spacing).rounded()))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    /// The figure's contour, sampled: the places the grains sit when the body is
    /// assembled.
    private static let contour: [CGPoint] = {
        var points: [CGPoint] = []
        for step in 0..<30 {
            let angle = CGFloat(step) / 30 * 2 * .pi
            points.append(CGPoint(
                x: cos(angle) * Figure.headHalfWidth,
                y: Figure.headCentreY + sin(angle) * Figure.headHalfHeight
            ))
        }
        points += sample(ChakraFigureView.smoothedShape(Figure.trunk), spacing: 0.011)
        for side in [1.0, -1.0] as [CGFloat] {
            points += sample(
                ChakraFigureView.smoothedShape(Figure.arm.map { (x: side * $0.x, y: $0.y) }),
                spacing: 0.014
            )
            points += sample(
                ChakraFigureView.smoothedShape(Figure.leg.map { (x: side * $0.x, y: $0.y) }),
                spacing: 0.014
            )
        }
        // The feet stand on the ground and do not sink into it.
        let clipped = points.map { CGPoint(x: $0.x, y: min($0.y, Figure.groundY)) }
        return clipped
    }()

    /// The same curve the figure was drawn with, worked out in the figure's own units.
    ///
    /// The grains and the shape have to be the same curve: a body drawn of grains that
    /// gather onto a slightly different line is a body that never quite closes.
    private static func smoothedShape(_ points: [(x: CGFloat, y: CGFloat)]) -> [CGPoint] {
        guard points.count > 2 else { return [] }
        let tension = 0.8
        var out: [CGPoint] = []
        let steps = 8
        for index in points.indices {
            let p0 = points[(index - 1 + points.count) % points.count]
            let p1 = points[index]
            let p2 = points[(index + 1) % points.count]
            let p3 = points[(index + 2) % points.count]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) * tension / 6,
                y: p1.y + (p2.y - p0.y) * tension / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) * tension / 6,
                y: p2.y - (p3.y - p1.y) * tension / 6
            )
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                let u = 1 - t
                let u2 = u * u
                let t2 = t * t
                // The weights of a cubic Bézier. They have to be these and not the
                // quadratic ones: a quadratic weighting does not sum to one, so the
                // curve stops passing through the points and the shape comes apart.
                out.append(CGPoint(
                    x: u2 * u * p1.x
                        + 3 * u2 * t * c1.x
                        + 3 * u * t2 * c2.x
                        + t2 * t * p2.x,
                    y: u2 * u * p1.y
                        + 3 * u2 * t * c1.y
                        + 3 * u * t2 * c2.y
                        + t2 * t * p2.y
                ))
            }
        }
        return out
    }

    /// The grains the body is made of.
    ///
    /// A fixed set, like the streams': the body gathers itself out of the same grains
    /// every time, and nothing is created when the sound comes.
    private static let bodyGrains: [BodyGrain] = {
        contour.enumerated().map { index, home in
            let hash = mix(index &+ 7_001)
            let angle = CGFloat(Double(hash % 4096) / 4096.0) * 2 * .pi
            let reach = 0.35 + CGFloat(Double((hash >> 13) % 1024) / 1024.0) * 0.9
            return BodyGrain(home: home, wander: CGPoint(x: cos(angle) * reach, y: sin(angle) * reach))
        }
    }()

    /// How far the body's grains float when there is no sound.
    private static let bodyFloat: CGFloat = 0.028

    /// How many grains the streams are made of.
    ///
    /// A fixed pool, worked out once and never grown: the grains do not appear out of
    /// nothing as the aura plays, they are the same few hundred grains going round for
    /// ever. A chakra's grain is absorbed into the earth at the bottom of the ring and
    /// the next one takes its place, so the number never changes and the memory never
    /// grows.
    private static let streamGrainCount = 420

    /// How long the round takes, in seconds: the middle of the twelve to twenty the
    /// aura was asked for. Slow enough to watch, fast enough to see.
    private static let streamPeriod: CGFloat = 16

    /// How far the grains travel in one frame at thirty frames a second.
    private static let streamStep: CGFloat = 1 / (streamPeriod * 30)

    /// How much slower everything moves when the system asks for reduced motion.
    ///
    /// The streams do not stop: they crawl. A still picture would say the same thing
    /// more clearly, but the movement was asked for, only slower.
    private static let reducedMotionScale: CGFloat = 0.25

    /// How far the grains wander when there is no sound, in the figure's own units.
    ///
    /// Enough to break the outline of the flow: the streams are still there, but they
    /// are not a shape yet.
    private static let chaos: CGFloat = 0.055

    /// A well-mixed number for a grain's index.
    ///
    /// The dust has to look random and be the same every run: a picture that changed
    /// from frame to frame would be a flicker, and one that changed from launch to
    /// launch would be a different picture each time.
    private static func mix(_ value: Int) -> UInt64 {
        var h = UInt64(truncatingIfNeeded: value) &* 0x9E37_79B9_7F4A_7C15
        h ^= h >> 29
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        return h
    }

    /// The lengths of a polyline's segments.
    private static func lengths(of points: [CGPoint]) -> [CGFloat] {
        var lengths: [CGFloat] = []
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            lengths.append(hypot(next.x - points[index].x, next.y - points[index].y))
        }
        return lengths
    }

    /// A point a fraction of the way along a polyline, and the way it is heading there.
    private static func along(
        _ points: [CGPoint],
        _ lengths: [CGFloat],
        _ total: CGFloat,
        _ fraction: CGFloat
    ) -> (point: CGPoint, tangent: CGPoint) {
        guard !points.isEmpty, total > 0 else { return (CGPoint.zero, CGPoint(x: 0, y: -1)) }
        let target = max(0, min(1, fraction)) * total
        var walked: CGFloat = 0
        for index in points.indices {
            let length = lengths[index]
            if walked + length >= target {
                let t = length > 0 ? (target - walked) / length : 0
                let next = points[(index + 1) % points.count]
                let dx = next.x - points[index].x
                let dy = next.y - points[index].y
                let norm = hypot(dx, dy)
                return (
                    CGPoint(
                        x: points[index].x + dx * t,
                        y: points[index].y + dy * t
                    ),
                    norm > 0 ? CGPoint(x: dx / norm, y: dy / norm) : CGPoint(x: 0, y: -1)
                )
            }
            walked += length
        }
        return (points[0], CGPoint(x: 0, y: -1))
    }

    /// The spine: the way up through every chakra, from the earth's mark to the top.
    ///
    /// The chakras are the source: the grains leave them, rise through all of them,
    /// come out through the crown and spread to the sides, and the sides draw the aura
    /// back down into the earth — where they are absorbed and the next ones take their
    /// place. The round closes on itself.
    private static let spine: [CGPoint] = {
        var points: [CGPoint] = []
        // The earth's mark first: the flow starts below the soles.
        for mark in Figure.marks.reversed() {
            points.append(CGPoint(x: mark.x, y: mark.y))
        }
        points.append(CGPoint(x: 0, y: Figure.cocoonTop))
        return points
    }()

    /// The two sides: the way down from the top to the bottom point, on the left and on
    /// the right. They are the cocoon's own sides, so the stream runs where the shell
    /// is.
    private static let sides: [[CGPoint]] = {
        let outline = Figure.cocoon.map { CGPoint(x: $0.x, y: $0.y) }
        guard outline.count > 3 else { return [outline, outline] }
        let bottom = outline.indices.min { outline[$0].y > outline[$1].y } ?? 0
        // The right half: the top, down the right side, to the bottom.
        let right = Array(outline[0...bottom])
        // The left half: the top, down the left side, to the bottom.
        var left = [outline[0]]
        left += outline[(bottom + 1)...].reversed()
        left.append(outline[bottom])
        return [left, right]
    }()

    private static let spineLengths = lengths(of: spine)
    private static let spineTotal = spineLengths.reduce(0, +)
    private static let sideLengths = sides.map { lengths(of: $0) }
    private static let sideTotals = sideLengths.map { $0.reduce(0, +) }

    /// Where a grain is on its round, and which way it is going.
    ///
    /// The round has two halves: up the spine, and down one side. The spine is shared
    /// by every grain — they all rise through the same chakras — and the side a grain
    /// takes is the one it chose when it came out of the top.
    private static func pointOnFlow(
        _ fraction: CGFloat,
        side: Int,
        travel: CGFloat,
        wave: CGFloat,
        ripple: CGFloat,
        reach: (CGFloat) -> CGFloat
    ) -> (point: CGPoint, tangent: CGPoint) {
        let sideIndex = side % max(1, sides.count)
        let sideTotal = sideTotals[sideIndex]
        let round = spineTotal + sideTotal
        guard round > 0 else { return (CGPoint.zero, CGPoint(x: 0, y: -1)) }
        let travelled = (fraction - fraction.rounded(.down)) * round
        let spot: (point: CGPoint, tangent: CGPoint)
        if travelled <= spineTotal {
            spot = along(spine, spineLengths, spineTotal, travelled / spineTotal)
        } else {
            let onSide = (travelled - spineTotal) / max(1, sideTotal)
            spot = along(sides[sideIndex], sideLengths[sideIndex], sideTotal, onSide)
        }
        var point = spot.point
        var normal = CGPoint(x: spot.tangent.y, y: -spot.tangent.x)
        // Point the normal away from the spine: the path turns round twice, so the
        // perpendicular alone is not enough to say which way is out.
        if normal.x * point.x + normal.y * (point.y - Figure.cocoonCentreY) < 0 {
            normal = CGPoint(x: -normal.x, y: -normal.y)
        }
        // The path reaches in toward the spine where the chakras are: the aura goes
        // into each of them and comes back out.
        point.x *= 1 - reach(point.y)
        // The wave: a slow swell running round. The ripple: a finer shiver along it.
        let offset = wave * sin(2 * .pi * (3 * fraction - 4 * travel))
            + ripple * sin(2 * .pi * (26 * fraction - 9 * travel))
        point.x += normal.x * offset
        point.y += normal.y * offset
        return (point, spot.tangent)
    }

    /// The colour at a height, in bands.
    ///
    /// The blend of the two marks the height is between, worked out once per band. A
    /// hard switch would flicker as a grain crossed the boundary; a blend does not,
    /// and the marks are neighbours in the rainbow, so the mix is between neighbours in
    /// hue as well.
    private static let colourBands: [NSColor] = {
        let heights = Figure.marks.map(\.y)
        let bottom = heights.min() ?? 0
        let top = heights.max() ?? 1
        return (0...48).map { step in
            blendedColour(forHeight: bottom + (top - bottom) * CGFloat(step) / 48)
        }
    }()

    /// Two colours mixed in the space the screen has.
    private static func blend(_ from: NSColor, _ to: NSColor, _ amount: CGFloat) -> NSColor {
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }
        guard let a = from.usingColorSpace(.sRGB), let b = to.usingColorSpace(.sRGB) else { return to }
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * amount,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * amount
        )
    }

    /// The colour of the height: the two marks it is between, mixed.
    private static func blendedColour(forHeight y: CGFloat) -> NSColor {
        var lower: (index: Int, y: CGFloat)?
        var upper: (index: Int, y: CGFloat)?
        for (visualIndex, mark) in Figure.marks.enumerated() {
            let step = Figure.marks.count - 1 - visualIndex
            if mark.y <= y, lower == nil || mark.y > lower!.y {
                lower = (step, mark.y)
            }
            if mark.y >= y, upper == nil || mark.y < upper!.y {
                upper = (step, mark.y)
            }
        }
        guard let lower, let upper else { return .secondaryLabelColor }
        guard lower.y != upper.y else { return ChakraPalette.color(forStepIndex: lower.index) }
        let amount = (y - lower.y) / (upper.y - lower.y)
        return blend(
            ChakraPalette.color(forStepIndex: lower.index),
            ChakraPalette.color(forStepIndex: upper.index),
            amount
        )
    }

    /// The colour at a height, from the bands.
    private static func colour(forHeight y: CGFloat) -> NSColor {
        let heights = Figure.marks.map(\.y)
        let bottom = heights.min() ?? 0
        let top = heights.max() ?? 1
        let span = max(0.0001, top - bottom)
        let step = Int(((y - bottom) / span * 48).rounded())
        let index = min(48, max(0, step))
        return colourBands[index]
    }

    /// How much of the aura stays in the lower part of the body when there is no sound.
    ///
    /// From the earth up to the root, through the legs: the flow starts there, and the
    /// body's weight is there too. The upper part of the figure keeps less of it — the
    /// aura is still everywhere, but the ground holds most of it.
    private static func lowBodyWeight(y: CGFloat) -> CGFloat {
        let bottom: CGFloat = 0.470   // the root
        let top: CGFloat = 1.075      // the earth
        guard y > bottom else { return 0 }
        let t = min(1, (y - bottom) / (top - bottom))
        return t * t
    }

    /// The grains of the streams, worked out once.
    private static let streamGrains: [Grain] = {
        var grains: [Grain] = []
        for index in 0..<streamGrainCount {
            let hash = mix(index)
            let birth = CGFloat(Double(hash % 4096) / 4096.0)
            let side = Int((hash >> 13) & 1)
            let angle = CGFloat(Double((hash >> 24) % 4096) / 4096.0) * 2 * .pi
            let wander = CGPoint(x: cos(angle), y: sin(angle))
            grains.append(Grain(birth: birth, side: side, wander: wander))
        }
        return grains
    }()

    /// The shells of the cocoon, worked out once: the outline scaled down, each with
    /// its own colour and its own wave.
    ///
    /// They are the quiet background the streams run over — seven of them, one for
    /// each chakra, the rainbow from the root outside to the crown in.
    private struct Shell {
        /// The grains on it, in the order they go round.
        let grains: [(home: CGPoint, normal: CGPoint, around: CGFloat, dust: CGPoint)]
        /// The colour it wears.
        let colour: NSColor
        /// How fast its wave goes round, in cycles per round of the flow.
        ///
        /// A whole number, like every other rate in the aura: the round has to close
        /// on itself, or the animation is a loop whose ends do not meet.
        let speed: Int
        /// Where its wave starts.
        let phase: Double
    }

    /// How many shells the cocoon has: one for each of the seven chakras.
    private static let layerCount = 7

    /// How far apart the shells sit, as a fraction of the outer one.
    private static let layerStep: CGFloat = (1 - 0.48) / CGFloat(layerCount - 1)

    /// How many grains a shell is made of.
    private static let grainsPerShell = 40

    /// The shells of the cocoon.
    ///
    /// Each is the same outline scaled down, and each has its own wave. The wave is
    /// what makes the aura look alive: each shell's light travels round it at its own
    /// speed, so the shells never beat together. One pulse running through all of
    /// them at once would be a rhythm, and this is meant to look like a living thing
    /// rather than a metronome.
    private static let shells: [Shell] = {
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

        var shells: [Shell] = []
        for layer in 0..<layerCount {
            let scale = 1 - CGFloat(layer) * layerStep
            var grains: [(home: CGPoint, normal: CGPoint, around: CGFloat, dust: CGPoint)] = []
            for step in 0..<grainsPerShell {
                let target = total * CGFloat(step) / CGFloat(grainsPerShell)
                var walked: CGFloat = 0
                var home = outline[0]
                var normal = CGPoint(x: 0, y: -1)
                for index in outline.indices {
                    let length = lengths[index]
                    if walked + length >= target {
                        let t = (target - walked) / length
                        let next = outline[(index + 1) % outline.count]
                        let raw = CGPoint(
                            x: outline[index].x + (next.x - outline[index].x) * t,
                            y: outline[index].y + (next.y - outline[index].y) * t
                        )
                        home = CGPoint(
                            x: raw.x * scale,
                            y: Figure.cocoonCentreY + (raw.y - Figure.cocoonCentreY) * scale
                        )
                        let dx = next.x - outline[index].x
                        let dy = next.y - outline[index].y
                        let norm = hypot(dx, dy)
                        // The outline runs clockwise on screen, so the outward normal is
                        // the direction turned the other way.
                        normal = norm > 0 ? CGPoint(x: dy / norm, y: -dx / norm) : .zero
                        break
                    }
                    walked += length
                }
                let hash = mix(layer * grainsPerShell + step + 91_237)
                let angle = CGFloat(Double(hash % 4096) / 4096.0) * 2 * .pi
                let radius = 0.22 + CGFloat(Double((hash >> 12) % 4096) / 4096.0) * 0.82
                let dust = CGPoint(
                    x: cos(angle) * radius * 0.64,
                    y: 0.44 + sin(angle) * radius * 0.78
                )
                grains.append((home, normal, CGFloat(step) / CGFloat(grainsPerShell), dust))
            }
            shells.append(Shell(
                grains: grains,
                // The earth is the ground the seven stand on, not one of them, so the
                // shells start at the root: the rainbow, from the outside in.
                colour: ChakraPalette.color(forStepIndex: layer + 1),
                speed: 4 + layer,
                phase: Double(layer) * 0.37
            ))
        }
        return shells
    }()

    /// How far the grains have travelled round the path, as a fraction of it.
    ///
    /// Accumulated rather than read from the clock, so that changing the speed — which
    /// is what the reduced-motion setting does — does not teleport the aura.
    fileprivate var streamTravel: CGFloat = 0

    /// How far the grains have assembled into the aura: 0 is dust, 1 is the streams.
    fileprivate var formation: CGFloat = 0

    /// Roughly thirty frames a second. The cocoon shivers; it does not animate.
    private static let vibrationInterval: TimeInterval = 1.0 / 30.0

    /// The rate while there is no sound.
    ///
    /// The streams are there with or without it — only weaker and wandering — so they
    /// keep moving. Slower, though: there is no beat to follow and no reason to spend
    /// the machine on it.
    private static let idleInterval: TimeInterval = 1.0 / 10.0

    /// The cocoon's clock, in a box of its own.
    ///
    /// A `@MainActor` type's `deinit` is not isolated, and it may not reach the actor's
    /// own properties — so the one thing that has to be switched off on the way out
    /// lives in plain `Sendable` state.
    private final class Clock: @unchecked Sendable {
        var timer: Timer?
    }

    /// The clock that makes the cocoon form and shiver.
    private let clock = Clock()

    /// Whether the figure is on screen.
    ///
    /// The aura only moves where it can be seen, and the clock that moves it stops
    /// when the panel is hidden — so the figure has to be told when it comes back,
    /// or the aura would stay as dust for the rest of the session.
    private var isVisible: Bool = true

    /// Tell the figure that it has come on screen or gone off it.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        updateVibration()
    }

    /// Whether the system asks for reduced motion (SPEC §7.2).
    ///
    /// The tests answer for themselves: the setting belongs to the machine the suite
    /// runs on, and a test that depended on it would pass on one machine and fail on
    /// another.
    var reducedMotionOverride: Bool?

    private var isReducedMotion: Bool {
        reducedMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Start or stop the shiver, according to the state and the system's setting.
    private func updateVibration() {
        if isReducedMotion {
            // Nothing moves, so the grains are simply in one place or the other.
            clock.timer?.invalidate()
            clock.timer = nil
            formation = isPlaying ? 1 : 0
            return
        }
        guard isVisible else {
            // Off screen there is nothing to animate. The aura forms when the figure
            // comes back — which it says so by telling the figure.
            clock.timer?.invalidate()
            clock.timer = nil
            return
        }
        // The clock runs for as long as the aura is on screen: the streams are there
        // with or without the sound, only weaker, and they keep drifting either way.
        startVibration()
    }

    /// The clock that makes the cocoon form and shiver.
    private func startVibration() {
        clock.timer?.invalidate()
        let interval = isPlaying ? Self.vibrationInterval : Self.idleInterval
        clock.timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isHiddenOrHasHiddenAncestor else {
                    // The aura is off screen with the rest of the panel, and waking
                    // the app for it thirty times a second is waste.
                    self.clock.timer?.invalidate()
                    self.clock.timer = nil
                    return
                }
                // The step is scaled by the rate, so the streams travel at the same
                // speed whatever the clock's rate is.
                let step = Self.streamStep
                    * (Self.vibrationInterval / interval)
                    * (self.isReducedMotion ? Self.reducedMotionScale : 1)
                self.streamTravel = (self.streamTravel + step)
                    .truncatingRemainder(dividingBy: 1)
                if let started = self.stepStartedAt {
                    let length = Double(max(1, self.stepSeconds))
                    self.stepProgress = min(1, Date().timeIntervalSince(started) / length)
                }
                let formationStep: CGFloat = self.isPlaying ? 0.08 : -0.08
                if self.formation > 0 || self.isPlaying {
                    self.formation = min(max(self.formation + formationStep, 0), 1)
                }
                self.needsDisplay = true
                self.onFrame?()
            }
        }
    }

    /// The height of the chakra being played, if there is one.
    private var activeMarkY: CGFloat? {
        guard let current = currentIndex else { return nil }
        let visual = Figure.marks.count - 1 - current
        return Figure.marks[visual].y
    }

    /// The body, made of grains.
    ///
    /// Without the sound they float around the contour and the figure is only a
    /// suggestion of one; with it they settle onto it, and the body holds an edge and
    /// takes the colour of the chakras it passes.
    private func drawBodyGrains() {
        let alive = isPlaying
        let active = activeMarkY
        let float = (1 - formation) * Self.bodyFloat
        for grain in Self.bodyGrains {
            let centre = point(
                grain.home.x + grain.wander.x * float,
                grain.home.y + grain.wander.y * float
            )
            // Where the body is near the chakra being played, it is brighter.
            let reach = Figure.reachIn(at: grain.home.y, activeY: active)
            let alpha = (alive ? 0.85 : 0.60) * (0.45 + 0.55 * reach)
            let size = figureHeight * (alive ? 0.0070 : 0.0062)
            Self.colour(forHeight: grain.home.y).withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: centre.x - size, y: centre.y - size,
                width: size * 2, height: size * 2
            )).fill()
        }
    }

    /// Draw the aura: the shells underneath, the streams over them.
    private func drawCocoon() {
        drawShells()
        drawStreams()
    }

    /// The shells: the quiet background the streams run over.
    private func drawShells() {
        let alive = isPlaying
        // The shells are driven by the same clock as the streams, so the whole aura
        // comes back to where it started after one round.
        let travel = streamTravel
        for shell in Self.shells {
            for (index, grain) in shell.grains.enumerated() {
                let lit = alive
                    ? pow(0.5 + 0.5 * sin(
                        2 * .pi * (3 * grain.around - Double(shell.speed) * travel + shell.phase)
                    ), 1.4)
                    : 0.30
                let shake = alive
                    ? CGFloat(sin(
                        2 * .pi * (3 * travel + shell.phase + CGFloat(index) * 0.013)
                    )) * 0.006
                    : 0
                let homeX = grain.home.x + grain.normal.x * shake
                let homeY = grain.home.y + grain.normal.y * shake
                let centre = point(
                    grain.dust.x + (homeX - grain.dust.x) * formation,
                    grain.dust.y + (homeY - grain.dust.y) * formation
                )
                let size = figureHeight * (alive ? 0.0046 : 0.0034) * (0.8 + 0.4 * lit)
                // The shells are a background: they are quiet even when the sound is
                // on, and the streams are what the eye is meant to follow.
                let alpha = (alive ? 0.30 : 0.12) * (0.40 + 0.60 * lit)
                shell.colour.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: centre.x - size, y: centre.y - size,
                    width: size * 2, height: size * 2
                )).fill()
            }
        }
    }

    /// The streams: the grains that travel round the figure in a wave.
    ///
    /// The colour is the colour of the chakra the grain is passing, so the ring shows
    /// the rainbow climbing on the left and coming down again on the right, and the
    /// path reaches in toward the spine where the chakras are.
    ///
    /// Without the sound the streams are still there, but weak and wandering — enough
    /// of them to see, not enough to call a shape.
    private func drawStreams() {
        let alive = isPlaying
        let travel = streamTravel
        let active = activeMarkY
        for grain in Self.streamGrains {
            let t = (grain.birth + travel).truncatingRemainder(dividingBy: 1)
            let spot = Self.pointOnFlow(
                t,
                side: grain.side,
                travel: travel,
                wave: 0.030,
                ripple: 0.007
            ) { y in
                Figure.reachIn(at: y, activeY: active)
            }

            // Without the sound the grains wander: the streams are there, but there is
            // no outline to them. The lower body keeps more of the movement and more
            // of the light — the flow starts at the earth and the ground holds it.
            let weight = Self.lowBodyWeight(y: spot.point.y)
            let chaos = (1 - formation) * Self.chaos * (1 + weight)
            let centre = point(
                spot.point.x + grain.wander.x * chaos,
                spot.point.y + grain.wander.y * chaos
            )

            // The waves, summed: the beat's pulse, the step's swell, and the idle
            // shimmer under both. They do not argue with each other — what the eye
            // sees is the sum, in the colour of the step being played.
            //
            // The idle shimmer's rate is a whole number of cycles per round, and so is
            // the number of crests along the path. That is what makes the round close:
            // after one round the wave's phase has moved by a whole number of cycles,
            // so the last frame of a round is the first frame of the next. A rate that
            // is not a whole number leaves the wave a fraction of a turn out of place
            // at the seam, and the animation looks like a loop whose ends do not meet.
            let shimmer = 0.5 + 0.5 * sin(2 * .pi * (3 * t - 4 * travel))
            let beatBump = AuraWave.bump(
                at: t,
                phase: AuraWave.beatPhase(travel: travel, beatHz: beatHz),
                sharpness: 8
            )
            let stepBump = AuraWave.bump(at: t, phase: stepProgress, sharpness: 2)
            let band = min(1, shimmer * 0.5 + beatBump * 0.35 + stepBump * 0.35)
            // Where the flow reaches into a chakra it is brighter, and brightest of
            // all at the one being played.
            let reach = Figure.reachIn(at: spot.point.y, activeY: active)
            // Without the sound the aura is weak — but it is there. It was too weak to
            // see at all, and an aura that cannot be seen is not an aura.
            let alpha = (alive ? 0.60 : 0.34 + 0.30 * weight)
                * (0.30 + 0.70 * band)
                * (1 + reach * 1.8)
            let size = figureHeight * (alive ? 0.0056 : 0.0048 + 0.0020 * weight)
                * (0.85 + 0.3 * band)

            // The waves push the path itself, so the beat's pulse is something the
            // grain of light carries with it, not only a change of brightness.
            let radial = CGPoint(x: spot.point.x, y: spot.point.y - Figure.cocoonCentreY)
            let radialLength = hypot(radial.x, radial.y)
            var moved = centre
            if radialLength > 0 {
                let push = (beatBump * 0.010 + stepBump * 0.016) * figureHeight
                moved = point(
                    spot.point.x + radial.x / radialLength * push
                        + grain.wander.x * chaos,
                    spot.point.y + radial.y / radialLength * push
                        + grain.wander.y * chaos
                )
            }
            drawGrain(at: moved, colour: Self.colour(forHeight: spot.point.y), alpha: alpha, size: size)
        }
    }

    /// One grain of the aura.
    private func drawGrain(at centre: CGPoint, colour: NSColor, alpha: CGFloat, size: CGFloat) {
        colour.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: centre.x - size, y: centre.y - size,
            width: size * 2, height: size * 2
        )).fill()
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

    // The tabs on the right of the figure: what is playing, how the journey goes, the
    // waves themselves, and the preset chips. The figure and its aura are never
    // covered by them — the panel is the app's face, and the tabs only change what is
    // written beside it.
    private let tabSelector = NSSegmentedControl()
    private let tabContent = NSStackView()
    private let chakraTab = NSView()
    private let stepTab = NSView()
    private let pulseTab = NSView()
    private let presetTab = NSView()
    /// Where the preset chips go.
    private let presetSlotView = NSStackView()
    /// The slot the preset chips go in — the panel's last tab.
    var presetSlot: NSStackView { presetSlotView }
    /// The scheme of the waves, and what they are doing.
    private let schemeView = WaveSchemeView()
    private let holdCaptionLabel = NSTextField(labelWithString: "")
    private let holdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let beatWaveCaption = NSTextField(labelWithString: "")
    private let beatWaveValue = NSTextField(labelWithString: "")
    private let stepWaveCaption = NSTextField(labelWithString: "")
    private let stepWaveValue = NSTextField(labelWithString: "")

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
    /// Which step the session settles on and holds, or nil for the automatic choice.
    private var holdIndex: Int?
    private var direction: ChakraSequence.Direction = .up
    private var beatHz: Double = ChakraSequence.defaultBeatHz
    private var isSyncing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The panel is always on screen: the figure and its aura are the app's face,
        // and the mode only changes what is written beside them.
        isHidden = false
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    /// The panel is the mode's whole face: when it is hidden the figure is off screen
    /// with it, and the aura stops moving until it is back.
    override var isHidden: Bool {
        didSet { figure.setVisible(!isHidden) }
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
        holdCaptionLabel.font = .systemFont(ofSize: 13)
        holdCaptionLabel.textColor = .secondaryLabelColor

        holdPopup.controlSize = .regular
        holdPopup.font = .systemFont(ofSize: 13)
        holdPopup.target = self
        holdPopup.action = #selector(holdChanged)
        holdPopup.setAccessibilityLabel(L10n.tr("Hold"))
        rebuildHoldItems()

        beatWaveCaption.font = .systemFont(ofSize: 12)
        beatWaveCaption.textColor = .secondaryLabelColor
        beatWaveValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        beatWaveValue.textColor = .secondaryLabelColor
        stepWaveCaption.font = .systemFont(ofSize: 12)
        stepWaveCaption.textColor = .secondaryLabelColor
        stepWaveValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        stepWaveValue.textColor = .secondaryLabelColor

        // The tabs.
        tabSelector.segmentStyle = .rounded
        tabSelector.trackingMode = .selectOne
        tabSelector.target = self
        tabSelector.action = #selector(tabChanged)
        tabSelector.segmentCount = 4
        for (index, title) in [
            L10n.tr("Chakras"), L10n.tr("Step"), L10n.tr("Pulse"), L10n.tr("Presets")
        ].enumerated() {
            tabSelector.setLabel(title, forSegment: index)
        }
        tabSelector.selectedSegment = 0

        // "Чакра": what is playing now — and the beat, which is the sound itself.
        //
        // The beat and the pulse are two different things and they are not confused
        // here: the beat is the difference between the two channels, the thing the ear
        // hears as a pulse, and it is a setting; the pulse is the picture of it, and it
        // is on the next tab.
        let chakraStack = NSStackView(views: [
            frequencyLabel, nameLabel, descriptionLabel, beatRow
        ])
        chakraStack.orientation = .vertical
        chakraStack.alignment = .leading
        chakraStack.spacing = 4
        chakraStack.translatesAutoresizingMaskIntoConstraints = false
        chakraTab.addSubview(chakraStack)

        // "Шаг": how the journey goes.
        let holdRow = NSStackView(views: [holdCaptionLabel, holdPopup])
        holdRow.orientation = .horizontal
        holdRow.alignment = .centerY
        holdRow.spacing = 8
        let stepStack = NSStackView(views: [
            durationRow, directionCheckbox, holdRow, noteLabel
        ])
        stepStack.orientation = .vertical
        stepStack.alignment = .leading
        stepStack.spacing = 6
        stepStack.translatesAutoresizingMaskIntoConstraints = false
        stepTab.addSubview(stepStack)

        // "Пульс": the picture of the waves, and what they are doing. Nothing here is a
        // setting — the pulse is what the waves look like, not a thing to choose.
        let waveNumbers = NSStackView(views: [
            beatWaveCaption, beatWaveValue, NSView(),
            stepWaveCaption, stepWaveValue
        ])
        waveNumbers.orientation = .horizontal
        waveNumbers.alignment = .centerY
        waveNumbers.spacing = 6
        let pulseStack = NSStackView(views: [schemeView, waveNumbers])
        pulseStack.orientation = .vertical
        pulseStack.alignment = .leading
        pulseStack.spacing = 8
        pulseStack.translatesAutoresizingMaskIntoConstraints = false
        pulseTab.addSubview(pulseStack)

        // "Пресеты": the chips that choose a pair of frequencies.
        presetSlotView.orientation = .vertical
        presetSlotView.alignment = .leading
        presetSlotView.spacing = 6
        let presetStack = NSStackView(views: [presetSlotView])
        presetStack.orientation = .vertical
        presetStack.alignment = .leading
        presetStack.translatesAutoresizingMaskIntoConstraints = false
        presetTab.addSubview(presetStack)

        tabContent.orientation = .vertical
        tabContent.alignment = .leading
        tabContent.spacing = 8
        tabContent.addArrangedSubview(chakraTab)
        tabContent.addArrangedSubview(stepTab)
        tabContent.addArrangedSubview(pulseTab)
        tabContent.addArrangedSubview(presetTab)

        let rightColumn = NSStackView(views: [tabSelector, tabContent])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 8

        let row = NSStackView(views: [figure, rightColumn])
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
            figure.widthAnchor.constraint(equalToConstant: 190),
            figure.heightAnchor.constraint(equalToConstant: 200),
            chakraStack.leadingAnchor.constraint(equalTo: chakraTab.leadingAnchor),
            chakraStack.trailingAnchor.constraint(equalTo: chakraTab.trailingAnchor),
            chakraStack.topAnchor.constraint(equalTo: chakraTab.topAnchor),
            stepStack.leadingAnchor.constraint(equalTo: stepTab.leadingAnchor),
            stepStack.trailingAnchor.constraint(equalTo: stepTab.trailingAnchor),
            stepStack.topAnchor.constraint(equalTo: stepTab.topAnchor),
            pulseStack.leadingAnchor.constraint(equalTo: pulseTab.leadingAnchor),
            pulseStack.trailingAnchor.constraint(equalTo: pulseTab.trailingAnchor),
            pulseStack.topAnchor.constraint(equalTo: pulseTab.topAnchor),
            presetStack.leadingAnchor.constraint(equalTo: presetTab.leadingAnchor),
            presetStack.trailingAnchor.constraint(equalTo: presetTab.trailingAnchor),
            presetStack.topAnchor.constraint(equalTo: presetTab.topAnchor),
            schemeView.widthAnchor.constraint(equalToConstant: 200),
            schemeView.heightAnchor.constraint(equalToConstant: 70),
            // The description is a sentence, and a sentence's natural width is the whole
            // sentence on one line. Without a ceiling the column would ask for that
            // width and the window would grow to fit it.
            descriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            // SPEC §7.2: 44 px minimum click target. The field is the height of its own
            // text, and `TallTargetTextField` adds the missing band back as hit slop.
            durationPopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            holdPopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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
        showTab(0)
        linkSchemeToFigure()
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

    /// The steps on offer to hold, and the automatic choice.
    ///
    /// The list is rebuilt rather than patched: the captions are translated, and a
    /// translated list that is patched in place keeps the language of the day it was
    /// built.
    private func rebuildHoldItems() {
        holdPopup.removeAllItems()
        holdPopup.addItem(withTitle: L10n.tr("Auto"))
        holdPopup.item(at: 0)?.representedObject = -1
        for (index, step) in ChakraSequence.steps.enumerated() {
            holdPopup.addItem(withTitle: ChakraSequence.name(of: step))
            holdPopup.lastItem?.representedObject = index
        }
        holdPopup.selectItem(at: 0)
    }

    /// The step the session settles on and holds, or nil for the automatic choice.
    var selectedHoldIndex: Int? { holdIndex }

    @objc private func holdChanged() {
        let raw = holdPopup.selectedItem?.representedObject as? Int ?? -1
        holdIndex = raw >= 0 ? raw : nil
        onHoldChange?(holdIndex)
    }

    /// The user chose which step the session holds.
    var onHoldChange: ((Int?) -> Void)?

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

    /// Tell the panel what the waves are doing: the beat, the step, and when the step
    /// began.
    ///
    /// The same three numbers drive the aura on the figure and the scheme of the waves
    /// beside it, so the picture and its explanation cannot disagree.
    func setWaves(beatHz: Double, stepSeconds: Int, startedAt: Date?) {
        figure.beatHz = beatHz
        figure.stepSeconds = stepSeconds
        figure.stepStartedAt = startedAt
        updateWaveLabels()
    }

    /// The colour the waves wear: the colour of the chakra being played.
    func setWaveTint(_ colour: NSColor) {
        schemeView.tint = colour
    }

    /// The tab the user picked.
    var selectedTab: Int { tabSelector.selectedSegment }

    /// Show one of the tabs: the chakra being played, the journey, the waves, or the
    /// preset chips.
    func selectTab(_ index: Int) {
        tabSelector.selectedSegment = min(max(0, index), max(0, tabSelector.segmentCount - 1))
        showTab(tabSelector.selectedSegment)
    }

    /// Show one of the tabs and hide the others.
    private func showTab(_ index: Int) {
        for (position, view) in [chakraTab, stepTab, pulseTab, presetTab].enumerated() {
            view.isHidden = position != index
        }
    }

    @objc private func tabChanged() {
        showTab(tabSelector.selectedSegment)
    }

    /// The scheme of the waves reads everything from the figure, so that the picture and
    /// its explanation are the same waves and not two clocks that drift apart.
    private func linkSchemeToFigure() {
        schemeView.source = figure
        figure.onFrame = { [weak self] in
            self?.schemeView.needsDisplay = true
        }
    }

    /// The numbers under the scheme: how long each of the waves takes to go round.
    private func updateWaveLabels() {
        let beatPeriod = AuraWave.beatPeriod(beatHz: figure.beatHz)
        // `L10n.tr` substitutes the positional placeholder itself. `String(format:)`
        // would not: "%1 s" is not a C format, and handing a Swift string to `%s`
        // crashes the process.
        beatWaveValue.stringValue = L10n.tr("%1 s", FrequencyGrid.text(beatPeriod))
        stepWaveValue.stringValue = L10n.tr(
            "%1 s",
            FrequencyGrid.text(AuraWave.stepPeriod(stepSeconds: figure.stepSeconds))
        )
    }

    /// Show the pair that is playing, for the times when the mode is not running.
    ///
    /// The tab is there whatever the mode is doing, so it has something to say in the
    /// ordinary case as well: the carrier that is on the wire.
    func showCurrentPair(carrierHz: Double) {
        frequencyLabel.stringValue = FrequencyGrid.text(carrierHz)
        frequencyLabel.textColor = .controlAccentColor
        nameLabel.stringValue = ""
        descriptionLabel.stringValue = ""
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
        let titles = [
            L10n.tr("Chakras"), L10n.tr("Step"), L10n.tr("Pulse"), L10n.tr("Presets")
        ]
        for (index, title) in titles.enumerated() where index < tabSelector.segmentCount {
            tabSelector.setLabel(title, forSegment: index)
        }
        beatWaveCaption.stringValue = L10n.tr("BEAT")
        stepWaveCaption.stringValue = L10n.tr("Step")
        holdCaptionLabel.stringValue = L10n.tr("Hold")
        holdPopup.setAccessibilityLabel(L10n.tr("Hold"))
        rebuildHoldItems()
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
