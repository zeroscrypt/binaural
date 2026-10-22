import AppKit
import BinauralCore

/// The body of the chakra mode: a schematic figure with the seven chakras on its spine.
///
/// The figure is a **line drawing**, the way a body is drawn in a chart: an outline
/// with nothing inside it, so the marks on the spine are the only things on it that
/// carry colour. A filled silhouette would compete with them, and a glow behind it
/// would pull the eye away from the spine — the one place anything is supposed to
/// happen.
///
/// Nothing here animates. SPEC §7.2 requires reduced-motion to be respected, and a
/// still figure with a lit mark says the same thing as a moving one — so the motion
/// would be decoration on top of a picture that is already complete.
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
        for (visualIndex, normalised) in Body.marks.enumerated() {
            let centre = point(normalised.x, normalised.y)
            let distance = hypot(centre.x - location.x, centre.y - location.y)
            if best == nil || distance < best!.distance {
                best = (Body.marks.count - 1 - visualIndex, distance)
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
        bounds.height * fraction
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Geometry

    /// The body, in normalised coordinates: 0…1 down, and 0…1 across the body's own
    /// width. The proportions are a standing figure seen from the front — a head, narrow
    /// shoulders, arms hanging clear of the torso, and two separate legs.
    private enum Body {
        /// The body's width as a fraction of its height. A figure in the lotus pose is
        /// wider than it is tall at the knees, and the whole shape has to fit the panel.
        static let aspect: CGFloat = 0.46

        /// The head: an oval from the crown to the chin.
        static let headCentreY: CGFloat = 0.100
        static let headHalfWidth: CGFloat = 0.048
        static let headHalfHeight: CGFloat = 0.080

        /// The trunk, upright: neck, shoulders, ribs, waist, hips.
        static let neckTop: CGFloat = 0.170
        static let neckBottom: CGFloat = 0.235
        static let neckHalfWidth: CGFloat = 0.026
        static let shoulderY: CGFloat = 0.250
        static let shoulderHalfWidth: CGFloat = 0.112
        static let armpitY: CGFloat = 0.320
        static let waistY: CGFloat = 0.430
        static let waistHalfWidth: CGFloat = 0.090
        static let hipY: CGFloat = 0.500
        static let hipHalfWidth: CGFloat = 0.106
        static let lapY: CGFloat = 0.570

        /// The crossed legs: a wide, low mound with the knees at the sides and the feet
        /// crossed in front.
        static let base: [(x: CGFloat, y: CGFloat)] = [
            (0.000, 0.545),
            (0.155, 0.560),
            (0.296, 0.645),   // right knee
            (0.312, 0.760),
            (0.248, 0.840),
            (0.118, 0.868),
            (0.000, 0.858),   // the crossed feet at the front
            (-0.118, 0.868),
            (-0.248, 0.840),
            (-0.312, 0.760),
            (-0.296, 0.645),
            (-0.155, 0.560)
        ]

        /// The feet, crossed in front of the lap.
        static let feet: [(x: CGFloat, y: CGFloat)] = [
            (0.000, 0.790),
            (0.058, 0.812),
            (0.052, 0.850),
            (0.000, 0.856),
            (-0.052, 0.850),
            (-0.058, 0.812)
        ]

        /// The arm, from the shoulder joint to the hand resting on the knee.
        static let arm: [(x: CGFloat, y: CGFloat)] = [
            (0.104, 0.258),   // shoulder joint
            (0.168, 0.400),   // upper arm
            (0.232, 0.540),   // elbow
            (0.268, 0.650),   // forearm
            (0.282, 0.700),   // wrist
            (0.292, 0.730),   // hand
            (0.268, 0.748),   // fingertips
            (0.242, 0.716),   // palm
            (0.232, 0.660),   // inner wrist
            (0.196, 0.552),   // inner elbow
            (0.140, 0.412),   // inner upper arm
            (0.108, 0.320)    // armpit
        ]

        /// The seven chakras and the earth below them, as heights down the body.
        ///
        /// The heights are the traditional ones: the crown at the top of the head, the
        /// third eye between the brows, the throat at the base of the throat, the heart
        /// in the centre of the chest, the solar plexus in the upper abdomen under the
        /// ribcage, the sacral just below the navel, the root at the base of the spine.
        /// The earth is below the body, not on it.
        static let marks: [(x: CGFloat, y: CGFloat)] = [
            (0, 0.055),   // crown
            (0, 0.135),   // third eye
            (0, 0.205),   // throat
            (0, 0.330),   // heart
            (0, 0.440),   // solar plexus
            (0, 0.515),   // sacral
            (0, 0.590),   // root
            (0, 0.960)    // earth, below the body
        ]
    }

    /// A point given as a half-width in units of the body's height and a height down
    /// the body. The body's height is the view's height, and it is centred, so the
    /// units are the same everywhere and the proportions are the drawing's.
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(
            x: bounds.midX + x * bounds.height,
            y: y * bounds.height
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ink = NSColor.secondaryLabelColor
        let line = NSBezierPath()
        line.lineWidth = max(1.0, bounds.height * 0.006)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        // The head.
        let head = point(0, Body.headCentreY)
        let headWidth = Body.headHalfWidth * bounds.height
        let headHeight = Body.headHalfHeight * bounds.height
        line.appendOval(in: NSRect(
            x: head.x - headWidth,
            y: head.y - headHeight,
            width: headWidth * 2,
            height: headHeight * 2
        ))

        // The trunk, upright.
        line.append(smoothPath([
            (0, Body.neckTop),
            (Body.neckHalfWidth, Body.neckBottom),
            (Body.shoulderHalfWidth, Body.shoulderY),
            (Body.shoulderHalfWidth * 0.92, Body.armpitY),
            (Body.waistHalfWidth, Body.waistY),
            (Body.hipHalfWidth, Body.hipY),
            (0, Body.lapY),
            (-Body.hipHalfWidth, Body.hipY),
            (-Body.waistHalfWidth, Body.waistY),
            (-Body.shoulderHalfWidth * 0.92, Body.armpitY),
            (-Body.shoulderHalfWidth, Body.shoulderY),
            (-Body.neckHalfWidth, Body.neckBottom)
        ]))

        // The crossed legs, the feet in front of them, and the arms.
        line.append(smoothPath(Body.base))
        line.append(smoothPath(Body.feet))
        line.append(smoothPath(Body.arm))
        line.append(smoothPath(Body.arm.map { (-$0.x, $0.y) }))

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
        for (visualIndex, normalised) in Body.marks.enumerated() {
            // The visual order is crown-first; the sequence runs earth-first.
            let stepIndex = Body.marks.count - 1 - visualIndex
            let centre = point(normalised.x, normalised.y)
            let colour = ChakraPalette.color(forStepIndex: stepIndex)
            let isCurrent = currentIndex == stepIndex
            let isReached = stepIndex <= reachedIndex
            // The step in hand is brighter than the ones around it, so the eye finds it
            // before it reads anything.
            let markColour = isCurrent
                ? ChakraPalette.brightColor(forStepIndex: stepIndex)
                : colour

            let base = bounds.height * 0.0135
            let radius = isCurrent ? base * 1.35 : base

            if isCurrent {
                // A soft halo, drawn as a few concentric circles of falling alpha. It is
                // the one thing on screen that moves the eye — and it has to stay small:
                // at the size of the figure a bigger halo swallowed the two marks below
                // it, which is the opposite of what a highlight is for.
                let halos: [(scale: CGFloat, alpha: CGFloat)] = [
                    (1.7, 0.12), (1.3, 0.20)
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
    /// The eight steps as buttons. The marks on the figure are small, and a small mark
    /// is a hard mark to hit; these are the same steps with a whole finger each.
    private var chakraButtons: [ChakraButton] = []
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

        // The steps as buttons, in the order the sequence walks them.
        chakraButtons = ChakraSequence.steps.indices.map { index in
            let button = ChakraButton(frame: .zero)
            button.fill = ChakraPalette.color(forStepIndex: index)
            button.setAccessibilityLabel(
                ChakraSequence.name(of: ChakraSequence.steps[index])
            )
            button.setAccessibilityHelp(
                L10n.tr("Play this chakra from here.")
            )
            button.target = self
            button.action = #selector(chakraButtonTapped(_:))
            button.tag = index
            return button
        }
        let chakraRow = NSStackView(views: chakraButtons)
        chakraRow.orientation = .horizontal
        chakraRow.alignment = .centerY
        chakraRow.spacing = 6

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
            frequencyLabel, nameLabel, descriptionLabel, chakraRow, controls,
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
            figure.widthAnchor.constraint(equalToConstant: 76),
            figure.heightAnchor.constraint(equalToConstant: 176),
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
            // SPEC §7.2: the steps are buttons, so they are click targets.
            chakraRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
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
        for (buttonIndex, button) in chakraButtons.enumerated() {
            button.isCurrent = buttonIndex == index
        }
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

    // MARK: - Actions

    /// A step was chosen. The journey starts there.
    @objc private func chakraButtonTapped(_ sender: NSButton) {
        onChakraPicked?(sender.tag)
    }

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
