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

        /// The head, the torso and the two arms, as one closed outline. The points run
        /// clockwise from the crown of the head, down the right side to the hip, across
        /// the crotch and back up the left. The x values are fractions of the body's own
        /// width, with 0.5 on the centre line.
        static let torso: [CGPoint] = [
            CGPoint(x: 0.500, y: 0.000),   // crown
            CGPoint(x: 0.545, y: 0.008),   // right crown
            CGPoint(x: 0.602, y: 0.030),   // right upper head
            CGPoint(x: 0.650, y: 0.066),   // right temple
            CGPoint(x: 0.672, y: 0.104),   // right ear
            CGPoint(x: 0.638, y: 0.144),   // right jaw
            CGPoint(x: 0.578, y: 0.171),   // right jaw corner
            CGPoint(x: 0.560, y: 0.198),   // right neck
            CGPoint(x: 0.760, y: 0.248),   // right shoulder
            CGPoint(x: 0.800, y: 0.320),   // right upper arm
            CGPoint(x: 0.812, y: 0.392),   // right elbow
            CGPoint(x: 0.806, y: 0.452),   // right forearm
            CGPoint(x: 0.792, y: 0.486),   // right wrist
            CGPoint(x: 0.812, y: 0.522),   // right hand
            CGPoint(x: 0.778, y: 0.548),   // right fingertips
            CGPoint(x: 0.744, y: 0.522),   // right palm
            CGPoint(x: 0.640, y: 0.560),   // right hip
            CGPoint(x: 0.500, y: 0.572),   // crotch
            CGPoint(x: 0.360, y: 0.560),   // left hip
            CGPoint(x: 0.256, y: 0.522),   // left palm
            CGPoint(x: 0.222, y: 0.548),   // left fingertips
            CGPoint(x: 0.188, y: 0.522),   // left hand
            CGPoint(x: 0.208, y: 0.486),   // left wrist
            CGPoint(x: 0.194, y: 0.452),   // left forearm
            CGPoint(x: 0.188, y: 0.392),   // left elbow
            CGPoint(x: 0.200, y: 0.320),   // left upper arm
            CGPoint(x: 0.240, y: 0.248),   // left shoulder
            CGPoint(x: 0.440, y: 0.198),   // left neck
            CGPoint(x: 0.422, y: 0.171),   // left jaw corner
            CGPoint(x: 0.362, y: 0.144),   // left jaw
            CGPoint(x: 0.328, y: 0.104),   // left ear
            CGPoint(x: 0.350, y: 0.066),   // left temple
            CGPoint(x: 0.398, y: 0.030),   // left upper head
            CGPoint(x: 0.455, y: 0.008)    // left crown
        ]

        /// One leg, from the hip to the foot. The left leg is the mirror of it.
        ///
        /// The legs are **narrow and parallel**. An earlier version let them splay, and
        /// the splay read as a wide base under the body — a second, lower silhouette
        /// that had nothing to do with the figure. A standing person's legs do not
        /// spread out into a plinth.
        static let leg: [CGPoint] = [
            CGPoint(x: 0.498, y: 0.566),
            CGPoint(x: 0.600, y: 0.560),
            CGPoint(x: 0.606, y: 0.660),
            CGPoint(x: 0.598, y: 0.770),
            CGPoint(x: 0.606, y: 0.870),
            CGPoint(x: 0.598, y: 0.938),
            CGPoint(x: 0.618, y: 0.966),   // toe
            CGPoint(x: 0.532, y: 0.970),   // heel
            CGPoint(x: 0.518, y: 0.938),
            CGPoint(x: 0.512, y: 0.870),
            CGPoint(x: 0.506, y: 0.770),
            CGPoint(x: 0.502, y: 0.660)
        ]

        /// The eight marks, crown first, on the spine. The visual order is the reverse
        /// of the sequence's — that one runs earth to crown.
        static let marks: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.040),   // crown
            CGPoint(x: 0.5, y: 0.112),   // third eye
            CGPoint(x: 0.5, y: 0.198),   // throat
            CGPoint(x: 0.5, y: 0.307),   // heart
            CGPoint(x: 0.5, y: 0.426),   // solar plexus
            CGPoint(x: 0.5, y: 0.491),   // sacral
            CGPoint(x: 0.5, y: 0.552),   // root
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
        let ink = NSColor.separatorColor
        let line = NSBezierPath()
        line.lineWidth = max(1.0, bounds.height * 0.008)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round

        line.append(closedPath(Body.torso))
        line.append(closedPath(Body.leg))
        line.append(closedPath(Body.leg.map { $0.mirrored() }))

        ink.setStroke()
        line.stroke()

        drawMarks()
    }

    /// A closed path through a list of points.
    private func closedPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: point(first))
        for next in points.dropFirst() {
            path.line(to: point(next))
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
                    (1.9, 0.14), (1.4, 0.24)
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

    private let figure = ChakraFigureView()
    private let frequencyLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let stepCaptionLabel = NSTextField(labelWithString: "")
    private let stepPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let beatCaptionLabel = NSTextField(labelWithString: "")
    private let beatField = TallTargetTextField()
    private let noteLabel = NSTextField(labelWithString: "")

    private var stepSeconds: Double = ChakraSequence.defaultStepSeconds
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

        stepCaptionLabel.font = .systemFont(ofSize: 13)
        stepCaptionLabel.textColor = .secondaryLabelColor

        stepPopup.controlSize = .regular
        stepPopup.font = .systemFont(ofSize: 13)
        stepPopup.target = self
        stepPopup.action = #selector(stepChanged)
        stepPopup.setAccessibilityLabel(ChakraSequence.stepCaption)

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

        let stepRow = NSStackView(views: [stepCaptionLabel, stepPopup])
        stepRow.orientation = .horizontal
        stepRow.alignment = .centerY
        stepRow.spacing = 8

        let beatRow = NSStackView(views: [beatCaptionLabel, beatField])
        beatRow.orientation = .horizontal
        beatRow.alignment = .centerY
        beatRow.spacing = 8

        // Both controls share one row. The panel has to fit between the timer and the
        // bottom of the window, and two rows of controls was what pushed the note off
        // the screen.
        //
        // The trailing view is a spacer: a stack with `.fill` gives the slack to its
        // lowest-priority child, and a plain view has a far lower content-hugging
        // priority than a row of controls. Without it the slack went to the beat row
        // and pushed the caption to the far edge of the window.
        let controls = NSStackView(views: [stepRow, beatRow, NSView()])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 16

        let text = NSStackView(views: [
            frequencyLabel, nameLabel, descriptionLabel, controls, noteLabel
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
            stepPopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            beatField.widthAnchor.constraint(equalToConstant: 76)
        ])

        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildStepItems()
        setStepSeconds(stepSeconds)
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

    /// The offered step durations are data, and translating them changes every caption,
    /// so the list is rebuilt rather than patched.
    private func rebuildStepItems() {
        stepPopup.removeAllItems()
        for choice in ChakraSequence.stepSecondsChoices {
            stepPopup.addItem(withTitle: ChakraSequence.stepSecondsText(choice))
            stepPopup.lastItem?.representedObject = choice
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

    /// Select a step duration without telling anyone — used while restoring.
    func setStepSeconds(_ value: Double) {
        stepSeconds = value
        let index = ChakraSequence.stepSecondsChoices.firstIndex(of: value)
            ?? Self.closestChoice(to: value)
        isSyncing = true
        stepPopup.selectItem(at: index)
        isSyncing = false
    }

    private static func closestChoice(to value: Double) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, choice) in ChakraSequence.stepSecondsChoices.enumerated() {
            let distance = abs(choice - value)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Show a beat without telling anyone.
    func setBeatHz(_ value: Double) {
        beatHz = value
        isSyncing = true
        beatField.doubleValue = value
        isSyncing = false
    }

    /// The step duration currently selected, in seconds.
    var selectedStepSeconds: Double { stepSeconds }

    /// The beat currently shown, in Hz.
    var selectedBeatHz: Double { beatHz }

    // MARK: - State the tests read

    var stepChoiceTitles: [String] { stepPopup.itemArray.map(\.title) }
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

    @objc private func stepChanged() {
        guard !isSyncing,
              let raw = stepPopup.selectedItem?.representedObject as? Double,
              raw != stepSeconds
        else { return }
        stepSeconds = raw
        onStepSecondsChange?(raw)
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
        stepCaptionLabel.stringValue = ChakraSequence.stepCaption
        stepPopup.setAccessibilityLabel(ChakraSequence.stepCaption)
        beatCaptionLabel.stringValue = ChakraSequence.beatCaption
        beatField.setAccessibilityLabel(ChakraSequence.beatCaption)
        noteLabel.stringValue = ChakraSequence.defaultBeatNote
        setAccessibilityLabel(ChakraSequence.modeName)
        rebuildStepItems()
        setStepSeconds(stepSeconds)
    }
}

extension ChakraView: NSTextFieldDelegate {

    /// Commit on focus loss as well as on Return — a half-typed beat must not stay in
    /// the field while the mode is using another one.
    func controlTextDidEndEditing(_ obj: Notification) {
        beatCommitted()
    }
}
