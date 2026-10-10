import AppKit
import BinauralCore

/// The two channel colours, kept identical to the Qt tokens in `ui/theme.py`.
///
/// Left is blue and right is purple, so which ear a panel is can be told without
/// reading the caption — and, more to the point, without comparing the two panels
/// against each other first.
enum ChannelPalette {
    /// The panel edge and the large display number. 5.2:1 on white, 6.6:1 on the dark
    /// surface.
    static let left = dynamic(light: 0x2563EB, dark: 0x60A5FA)
    /// The caption, at 13px, so it takes the darker shade: 6.7:1 and 9.4:1.
    static let leftText = dynamic(light: 0x1D4ED8, dark: 0x93C5FD)
    static let right = dynamic(light: 0x8B5CF6, dark: 0xC4B5FD)
    static let rightText = dynamic(light: 0x6D3FD4, dark: 0xC4B5FD)

    /// An `NSColor` that follows the window's appearance.
    ///
    /// `.systemBlue` and friends would resolve this for free, but they are system
    /// colours: they move when macOS updates and they are not the values the theme
    /// pins. These hexes are the same numbers `TOKENS` carries on the Qt side, so the
    /// two implementations cannot drift apart by accident.
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func resolve(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? resolve(dark)
                : resolve(light)
        }
    }
}

/// One ear's frequency control (SPEC F1, `ui/widgets/freq_control.py`).
///
/// Caption, the large display number, an exact-entry field and a logarithmic slider.
/// The two instances in the window share nothing: changing one never writes the other,
/// which is the "independence" F1 insists on.
///
/// Every rule about the value itself — clamping, the 0.1 Hz grid, the slider mapping —
/// lives in ``FrequencyGrid``; this view only moves the number around.
@MainActor
final class FrequencyControlView: NSView {

    /// Called after the user changed the frequency. Not called by ``setValue(_:)``
    /// unless `notify` is asked for, so restoring a session stays silent.
    var onChange: ((Double) -> Void)?

    /// The current frequency in Hz.
    private(set) var value: Double = FrequencyGrid.minHz

    /// The channel caption, as currently shown.
    var caption: String { captionLabel.stringValue }

    /// Which ear this is — only used for accessibility and the focus ring.
    enum Ear {
        case left
        case right
    }

    private let ear: Ear
    /// The channel colour. Drives the panel edge and the display number, and is never
    /// given up for a state colour: which ear this is must not depend on focus.
    private let accent: NSColor
    /// The channel colour at a shade that clears 4.5:1 at caption size.
    private let accentText: NSColor
    private let captionLabel = NSTextField(labelWithString: "")
    private let rangeHintLabel = NSTextField(labelWithString: "")
    private let displayLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let slider = NSSlider()
    private var isSyncing = false

    init(ear: Ear, accent: NSColor, accentText: NSColor) {
        self.ear = ear
        self.accent = accent
        self.accentText = accentText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Building

    private func setUp() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = accent.cgColor

        captionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        captionLabel.textColor = accentText

        rangeHintLabel.font = .systemFont(ofSize: 11)
        rangeHintLabel.textColor = .tertiaryLabelColor
        rangeHintLabel.alignment = .right

        displayLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        displayLabel.textColor = accent

        field.delegate = self
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        field.alignment = .left
        field.formatter = Self.formatter
        field.target = self
        field.action = #selector(commitField)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = "0.0"

        // The step matches the `↑`/`↓` keys and the 0.1 Hz grid the field sits on, so the mouse
        // and the keyboard move the number by the same amount. `NSStepper` accelerates
        // while it is held, which is what makes covering a wide sweep bearable at this
        // resolution — and 0.1 Hz is the only step worth having here, since a tenth of a
        // hertz off the carrier is invisible but a tenth of a hertz off the *difference*
        // is right at the edge of what a listener can tell apart at low beat rates.
        stepper.minValue = FrequencyGrid.minHz
        stepper.maxValue = FrequencyGrid.maxHz
        stepper.increment = 0.1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperMoved)

        slider.minValue = 0
        slider.maxValue = FrequencyGrid.sliderSteps
        slider.doubleValue = 0
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [captionLabel, rangeHintLabel])
        header.orientation = .horizontal
        header.spacing = 8
        header.distribution = .fill

        // The field and its arrows share one row. The arrows belong to the number, and putting
        // them beside it is what turns "nudge by a step" into a mouse action instead of
        // an `↑`/`↓` shortcut only.
        let entryRow = NSStackView(views: [field, stepper])
        entryRow.orientation = .horizontal
        entryRow.alignment = .centerY
        entryRow.spacing = 6

        let stack = NSStackView(views: [header, displayLabel, entryRow, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // SPEC §7.2: 44 px minimum click target, and the header must not squash.
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            entryRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            rangeHintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            rangeHintLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: rangeHintLabel.leadingAnchor, constant: -8)
        ])

        setValue(FrequencyGrid.minHz, notify: false)
    }

    /// Frequencies are always written with a dot, whatever the OS locale is — the
    /// `QLocale.c()` decision of `freq_control.py`.
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.minimum = NSNumber(value: FrequencyGrid.minHz)
        formatter.maximum = NSNumber(value: FrequencyGrid.maxHz)
        return formatter
    }()

    // MARK: - Value

    /// Show `hz`. Pass `notify: true` to treat it as a user edit.
    func setValue(_ hz: Double, notify: Bool = false) {
        let quantized = FrequencyGrid.quantized(hz)
        value = quantized
        syncWidgets()
        if notify { onChange?(quantized) }
    }

    /// Move by `delta` Hz (SPEC `↑`/`↓`).
    func nudge(_ delta: Double) {
        setValue(FrequencyGrid.nudged(value, by: delta), notify: true)
    }

    /// Move keyboard focus into the exact-entry field (SPEC `←`/`→`).
    func focusField() {
        window?.makeFirstResponder(field)
    }

    /// Highlight the channel the `↑`/`↓` keys act on.
    func setActive(_ active: Bool) {
        // Focus is carried by the width, never by the colour. The edge used to switch
        // between the system accent and `separatorColor`, which meant the two panels
        // were blue and grey at the same time — the right one grey because nothing ever
        // tinted it — and the channel colours were only ever visible on the number.
        layer?.borderWidth = active ? 2 : 1
    }

    // MARK: - Appearance

    /// `NSView` declares this as a property rather than a method; overriding it is what
    /// makes the `updateLayer()` below run at all.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A dynamic `NSColor` resolves to a `CGColor` once, at the moment it is asked for,
        // so an edge painted from one keeps its light-mode value after the window goes
        // dark. On a saturated channel colour that is a contrast failure rather than a
        // cosmetic one, so the edge is re-resolved whenever the layer redraws.
        layer?.borderColor = accent.cgColor
    }

    // MARK: - Language

    /// Re-read the caption after a language switch (SPEC §7.4).
    func retranslate(caption: String, rangeHint: String) {
        captionLabel.stringValue = caption
        rangeHintLabel.stringValue = rangeHint
        field.placeholderString = rangeHint
        setAccessibilityLabel(caption)
        setAccessibilityHelp(
            L10n.tr(
                "Frequency for %1, from 1 to 20000 hertz. Use the arrow keys for 0.1 hertz steps.",
                caption
            )
        )
        field.setAccessibilityLabel(L10n.tr("%1 frequency in hertz", caption))
        field.setAccessibilityHelp(L10n.tr("Type an exact value between 1 and 20000, in steps of 0.1 hertz."))
        stepper.setAccessibilityLabel(L10n.tr("%1 frequency in hertz", caption))
        stepper.setAccessibilityHelp(
            L10n.tr("Raises or lowers the frequency by 0.1 hertz. Keep it held down to repeat.")
        )
        slider.setAccessibilityLabel(L10n.tr("%1 frequency slider", caption))
        slider.setAccessibilityHelp(L10n.tr("Sweeps the frequency from 1 to 20000 hertz."))
    }

    // MARK: - Widgets

    private func syncWidgets() {
        isSyncing = true
        defer { isSyncing = false }
        displayLabel.stringValue = String(format: "%.1f", value)
        if let editor = field.currentEditor() {
            // Do not fight the user while they are typing: only refresh the buffer
            // when the field is not being edited.
            editor.string = String(format: "%.1f", value)
        } else if let parsed = Self.formatter.number(from: String(format: "%.1f", value)) {
            field.doubleValue = parsed.doubleValue
        }
        stepper.doubleValue = value
        slider.doubleValue = FrequencyGrid.sliderPosition(for: value) * FrequencyGrid.sliderSteps
    }

    @objc private func commitField() {
        guard !isSyncing else { return }
        setValue(field.doubleValue, notify: true)
    }

    /// The arrows. `NSStepper` auto-repeats while the mouse is held on it, so this only has
    /// to turn "the user moved it" into a value change and let `setValue` push the result
    /// back into the field, the readout and the slider.
    @objc private func stepperMoved() {
        guard !isSyncing else { return }
        setValue(stepper.doubleValue, notify: true)
    }

    @objc private func sliderMoved() {
        guard !isSyncing else { return }
        let position = slider.doubleValue / FrequencyGrid.sliderSteps
        setValue(FrequencyGrid.frequency(atSliderPosition: position), notify: true)
    }
}

extension FrequencyControlView: NSTextFieldDelegate {

    /// Commit on focus loss as well as on Return — a half-typed frequency must never
    /// stay in the field while the readout says something else.
    func controlTextDidEndEditing(_ obj: Notification) {
        commitField()
    }
}