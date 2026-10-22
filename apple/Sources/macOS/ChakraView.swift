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
    private func mark(near point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (visualIndex, normalised) in Body.marks.enumerated() {
            let centre = self.point(normalised)
            let distance = hypot(centre.x - point.x, centre.y - point.y)
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
        /// The body's width as a fraction of its height. A standing figure is about
        /// two and a half times as tall as it is wide.
        static let aspect: CGFloat = 0.40

        /// The head and the neck. The head is a small oval, wider at the temples than at
        /// the jaw, and the neck is a short column between the jaw and the shoulders.
        static let head: [CGPoint] = [
            CGPoint(x: 0.500, y: 0.000),   // crown
            CGPoint(x: 0.560, y: 0.014),
            CGPoint(x: 0.606, y: 0.052),
            CGPoint(x: 0.626, y: 0.090),   // temple
            CGPoint(x: 0.606, y: 0.128),
            CGPoint(x: 0.560, y: 0.152),
            CGPoint(x: 0.530, y: 0.164),   // jaw corner
            CGPoint(x: 0.524, y: 0.196),   // neck
            CGPoint(x: 0.476, y: 0.196),
            CGPoint(x: 0.470, y: 0.164),
            CGPoint(x: 0.440, y: 0.152),
            CGPoint(x: 0.394, y: 0.128),
            CGPoint(x: 0.374, y: 0.090),
            CGPoint(x: 0.394, y: 0.052),
            CGPoint(x: 0.440, y: 0.014)
        ]

        /// The trunk: shoulders, ribs, waist, hips. Drawn on its own so the arms can
        /// hang beside it with a gap between them, the way an arm actually does.
        static let torso: [CGPoint] = [
            CGPoint(x: 0.500, y: 0.190),   // where the neck meets the trunk
            CGPoint(x: 0.590, y: 0.210),
            CGPoint(x: 0.660, y: 0.236),   // shoulder
            CGPoint(x: 0.672, y: 0.276),   // deltoid
            CGPoint(x: 0.648, y: 0.350),   // ribs
            CGPoint(x: 0.608, y: 0.430),   // waist
            CGPoint(x: 0.618, y: 0.500),   // hip
            CGPoint(x: 0.500, y: 0.520),   // crotch
            CGPoint(x: 0.382, y: 0.500),
            CGPoint(x: 0.392, y: 0.430),
            CGPoint(x: 0.352, y: 0.350),
            CGPoint(x: 0.328, y: 0.276),
            CGPoint(x: 0.340, y: 0.236),
            CGPoint(x: 0.410, y: 0.210)
        ]

        /// One arm, from the shoulder to the hand. The left arm is the mirror of it.
        static let arm: [CGPoint] = [
            CGPoint(x: 0.660, y: 0.240),
            CGPoint(x: 0.706, y: 0.286),   // upper arm
            CGPoint(x: 0.712, y: 0.360),   // elbow
            CGPoint(x: 0.706, y: 0.440),   // forearm
            CGPoint(x: 0.700, y: 0.492),   // wrist
            CGPoint(x: 0.714, y: 0.526),   // hand
            CGPoint(x: 0.704, y: 0.552),   // fingertips
            CGPoint(x: 0.678, y: 0.542),
            CGPoint(x: 0.674, y: 0.492),
            CGPoint(x: 0.678, y: 0.436),
            CGPoint(x: 0.672, y: 0.356),
            CGPoint(x: 0.650, y: 0.284),
            CGPoint(x: 0.646, y: 0.238)
        ]

        /// One leg, from the hip to the foot. The left leg is the mirror of it.
        ///
        /// The legs are **narrow and parallel**. An earlier version let them splay, and
        /// the splay read as a wide base under the body — a second, lower silhouette
        /// that had nothing to do with the figure.
        static let leg: [CGPoint] = [
            CGPoint(x: 0.506, y: 0.512),
            CGPoint(x: 0.596, y: 0.502),
            CGPoint(x: 0.606, y: 0.610),   // thigh
            CGPoint(x: 0.590, y: 0.720),   // knee
            CGPoint(x: 0.598, y: 0.840),   // calf
            CGPoint(x: 0.590, y: 0.928),   // ankle
            CGPoint(x: 0.612, y: 0.958),   // toe
            CGPoint(x: 0.528, y: 0.962),   // heel
            CGPoint(x: 0.514, y: 0.928),
            CGPoint(x: 0.510, y: 0.840),
            CGPoint(x: 0.504, y: 0.720),
            CGPoint(x: 0.500, y: 0.610)
        ]

        /// The eight marks, crown first, on the spine. The visual order is the reverse
        /// of the sequence's — that one runs earth to crown.
        ///
        /// The heights are the traditional ones: the crown at the top of the head, the
        /// third eye between the brows, the throat at the base of the throat, the heart
        /// in the chest, the solar plexus between the navel and the bottom of the ribs,
        /// the sacral four fingers below the navel, the root at the base of the spine,
        /// and the earth below the feet.
        static let marks: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.030),   // crown
            CGPoint(x: 0.5, y: 0.100),   // third eye
            CGPoint(x: 0.5, y: 0.200),   // throat
            CGPoint(x: 0.5, y: 0.300),   // heart
            CGPoint(x: 0.5, y: 0.420),   // solar plexus
            CGPoint(x: 0.5, y: 0.490),   // sacral
            CGPoint(x: 0.5, y: 0.550),   // root
            CGPoint(x: 0.5, y: 0.948)    // earth, at the feet
        ]
    }

    /// The body's width in points.
    private var bodyWidth: CGFloat { bounds.height * Body.aspect }

    /// Map normalised coordinates onto the view. The body is centred, and its height is
    /// the view's height.
    private func point(_ normalised: CGPoint) -> CGPoint {
        CGPoint(
            x: bounds.midX + (normalised.x - 0.5) * bodyWidth,
            y: normalised.y * bounds.height
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ink = NSColor.secondaryLabelColor
        let line = NSBezierPath()
        line.lineWidth = max(1.0, bounds.height * 0.007)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        line.append(smoothPath(Body.head))
        line.append(smoothPath(Body.torso))
        line.append(smoothPath(Body.arm))
        line.append(smoothPath(Body.arm.map { $0.mirrored() }))
        line.append(smoothPath(Body.leg))
        line.append(smoothPath(Body.leg.map { $0.mirrored() }))

        ink.setStroke()
        line.stroke()

        drawMarks()
    }

    /// A closed path through the given points, smoothed.
    ///
    /// The curve passes **through** the points rather than through the midpoints between
    /// them. Smoothing through the midpoints is the cheaper trick, but it pulls the shape
    /// in towards its own centre and rounds the corners — a body drawn that way loses its
    /// shoulders and its width. A spline through the points keeps the figure's extent and
    /// only softens the corners.
    private func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        let p = points.map { point($0) }
        let n = p.count
        guard n > 2 else { return path }
        // How much of the neighbouring segment the curve borrows. Below 1 it rounds the
        // corners without the overshoot a full Catmull-Rom puts at a sharp turn.
        let tension = 0.8
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n]
            let p1 = p[i]
            let p2 = p[(i + 1) % n]
            let p3 = p[(i + 2) % n]
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
            // The visual order is crown-first; the sequence runs root-first.
            let stepIndex = Body.marks.count - 1 - visualIndex
            let centre = point(normalised)
            let colour = ChakraPalette.color(forStepIndex: stepIndex)
            let isCurrent = currentIndex == stepIndex
            let isReached = stepIndex <= reachedIndex

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
                    colour.withAlphaComponent(halo.alpha).setFill()
                    NSBezierPath(ovalIn: NSRect(
                        x: centre.x - grown, y: centre.y - grown,
                        width: grown * 2, height: grown * 2
                    )).fill()
                }
            }

            colour.withAlphaComponent(isReached ? 1.0 : 0.32).setFill()
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

    /// The user picked a new step duration, in seconds.
    var onStepSecondsChange: ((Double) -> Void)?
    /// The user typed a new beat, in Hz.
    var onBeatChange: ((Double) -> Void)?
    /// The user picked a new length for the whole journey, in minutes.
    var onDurationMinutesChange: ((Int) -> Void)?
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
    private let noteLabel = NSTextField(labelWithString: "")

    private var durationMinutes: Int = ChakraSequence.defaultDurationMinutes
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
        durationPopup.setAccessibilityLabel(L10n.tr("Duration"))

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

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 2
        noteLabel.stringValue = ChakraSequence.defaultBeatNote

        let durationRow = NSStackView(views: [durationCaptionLabel, durationPopup])
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.spacing = 8

        let beatRow = NSStackView(views: [beatCaptionLabel, beatField])
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
            frequencyLabel, nameLabel, descriptionLabel, controls, directionCheckbox, noteLabel
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
            beatField.widthAnchor.constraint(equalToConstant: 76)
        ])

        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildDurationItems()
        setDurationMinutes(durationMinutes)
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
        for choice in ChakraSequence.durationMinutesChoices {
            durationPopup.addItem(withTitle: L10n.tr("%1 min", String(choice)))
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
        frequencyLabel.textColor = ChakraPalette.color(forStepIndex: index)
        nameLabel.stringValue = ChakraSequence.name(of: step)
        descriptionLabel.stringValue = ChakraSequence.description(of: step)
        figure.currentIndex = index
        figure.reachedIndex = reachedIndex
        setAccessibilityValue("\(ChakraSequence.name(of: step)), \(FrequencyGrid.text(step.hz)) Hz")
    }

    /// Select a length without telling anyone — used while restoring.
    func setDurationMinutes(_ value: Int) {
        durationMinutes = value
        let index = ChakraSequence.durationMinutesChoices.firstIndex(of: value)
            ?? Self.closestChoice(to: value)
        isSyncing = true
        durationPopup.selectItem(at: index)
        isSyncing = false
    }

    private static func closestChoice(to value: Int) -> Int {
        var best = 0
        var bestDistance = Int.max
        for (index, choice) in ChakraSequence.durationMinutesChoices.enumerated() {
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
        isSyncing = false
    }

    /// The length of the whole journey, in minutes.
    var selectedDurationMinutes: Int { durationMinutes }

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

    @objc private func durationChanged() {
        guard !isSyncing,
              let raw = durationPopup.selectedItem?.representedObject as? Int,
              raw != durationMinutes
        else { return }
        durationMinutes = raw
        onDurationMinutesChange?(raw)
    }

    @objc private func directionToggled() {
        guard !isSyncing else { return }
        direction = directionCheckbox.state == .on ? .up : .down
        onDirectionChange?(direction)
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
        durationCaptionLabel.stringValue = L10n.tr("Duration")
        durationPopup.setAccessibilityLabel(L10n.tr("Duration"))
        directionCheckbox.title = direction.name(for: L10n.language)
        directionCheckbox.setAccessibilityLabel(L10n.tr("Direction"))
        beatCaptionLabel.stringValue = ChakraSequence.beatCaption
        beatField.setAccessibilityLabel(ChakraSequence.beatCaption)
        noteLabel.stringValue = ChakraSequence.defaultBeatNote
        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildDurationItems()
        setDurationMinutes(durationMinutes)
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
