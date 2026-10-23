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
        DynamicColor.make(light: light, dark: dark)
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
    private let field = TallTargetTextField()
    /// The explicit mouse steps beside the number: the minus and the plus do what the
    /// stepper did, and read as directions rather than as a hidden widget.
    private let lowerButton = NSButton(title: "", target: nil, action: nil)
    private let raiseButton = NSButton(title: "", target: nil, action: nil)
    /// The unit, spoken once beside the number rather than guessed from the field.
    private let unitLabel = NSTextField(labelWithString: "")
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

        field.delegate = self
        // The field **is** the readout. It used to have a big number above it and a
        // small field below, and both showed the same value — the panel said the same
        // thing twice and the eye had to work out which one was the real one.
        field.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        field.textColor = accent
        field.alignment = .left
        // The number is read at a fixed place — the left edge — and sits in the middle
        // of the field's height rather than at the top of it. A single-line bezeled cell
        // centres itself, but only if the cell knows the field's height.
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byClipping
        field.cell?.wraps = false
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
        for (button, symbol, selector) in [
            (lowerButton, "minus", #selector(lowerTapped)),
            (raiseButton, "plus", #selector(raiseTapped))
        ] {
            button.bezelStyle = .recessed
            button.controlSize = .regular
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.contentTintColor = accent
            button.target = self
            button.action = selector
            button.setButtonType(.momentaryChange)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        // The unit sits right of the number: `Hz` in English, `Гц` in Russian — the same
        // word the beat card speaks — and its own spot between the digits and the steps.
        unitLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor

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

        // The field and its steps share one row: the minus sits to the left of the
        // field, the plus keeps its place on the right — a stepper the number sits
        // between, not a pair of arrows parked beside the readout.
        let entryRow = NSStackView(views: [lowerButton, field, unitLabel, NSView(), raiseButton])
        entryRow.orientation = .horizontal
        entryRow.alignment = .centerY
        entryRow.spacing = 6

        let stack = NSStackView(views: [header, entryRow, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // The digits take the room there is; the unit and the two step buttons keep
        // their own, so the numbers never squeeze out their neighbours.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            // SPEC §7.2: 44 px minimum click target, and the header must not squash.
            // The field itself is the height of its own text — AppKit pins a bezeled
            // field's text to the top, so a taller field would show the number floating
            // at the top of an empty box. `TallTargetTextField` adds the missing band
            // back as hit slop, and the row keeps the 44 px.
            entryRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            // The exact-entry field is as wide as the widest value it can hold —
            // `20000.0` — and no wider. It was stretched across the whole panel, which
            // made a four-digit number look like it was floating in an empty room; the
            // slider below is the thing that wants the width.
            field.widthAnchor.constraint(
                equalToConstant: FieldMetrics.width(
                    for: "20000.0",
                    font: field.font ?? NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
                )
            ),
            rangeHintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            rangeHintLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: rangeHintLabel.leadingAnchor, constant: -8)
        ])

        setValue(FrequencyGrid.minHz, notify: false)
    }

    /// Frequencies are always written with a dot, whatever the OS locale is — the
    /// `QLocale.c()` decision of `freq_control.py`.
    static let formatter: NumberFormatter = {
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
        setAccessibilityLabel(caption)
        setAccessibilityHelp(
            L10n.tr(
                "Frequency for %1, from 1 to 20000 hertz. Use the arrow keys for 0.1 hertz steps.",
                caption
            )
        )
        field.setAccessibilityLabel(L10n.tr("%1 frequency in hertz", caption))
        field.setAccessibilityHelp(L10n.tr("Type an exact value between 1 and 20000, in steps of 0.1 hertz."))
        unitLabel.stringValue = L10n.tr("Hz")
        lowerButton.setAccessibilityLabel(L10n.tr("Lower the frequency"))
        lowerButton.setAccessibilityHelp(
            L10n.tr("Raises or lowers the frequency by 0.1 hertz. Keep it held down to repeat.")
        )
        raiseButton.setAccessibilityLabel(L10n.tr("Raise the frequency"))
        raiseButton.setAccessibilityHelp(
            L10n.tr("Raises or lowers the frequency by 0.1 hertz. Keep it held down to repeat.")
        )
        slider.setAccessibilityLabel(L10n.tr("%1 frequency slider", caption))
        slider.setAccessibilityHelp(L10n.tr("Sweeps the frequency from 1 to 20000 hertz."))
    }

    // MARK: - Widgets

    private func syncWidgets() {
        isSyncing = true
        defer { isSyncing = false }
        if let editor = field.currentEditor() {
            // Do not fight the user while they are typing: only refresh the buffer
            // when the field is not being edited.
            editor.string = String(format: "%.1f", value)
        } else {
            field.stringValue = String(format: "%.1f", value)
        }
        slider.doubleValue = FrequencyGrid.sliderPosition(for: value) * FrequencyGrid.sliderSteps
    }

    /// Escape's own answer, factored out of the delegate so a test can walk the same
    /// code: the readout goes back to the sound's value, nothing is committed.
    func cancelEditing() {
        field.stringValue = String(format: "%.1f", value)
        window?.makeFirstResponder(nil)
    }

    /// Type into the field without going through the formatter, the way a keyboard does.
    var fieldText: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// The field's own commit, for a test that leaves the half-typed state to it.
    func commitFieldForTest() {
        commitField()
    }

    @objc private func commitField() {
        guard !isSyncing else { return }
        // The dot and the comma are one decimal point here: a Russian keyboard typing
        // `,` is not an error, it is the same number. Anything unparseable — an empty
        // half-typed value, `inf`, garbage — keeps the field as it is and the sound as
        // it is: a bad edit is refused, not half-applied into the engine.
        let raw = field.stringValue.replacingOccurrences(of: ",", with: ".")
        // The field is the readout: `setValue` writes the quantised value back into it,
        // so a nudge while editing cannot surprise the user with a stale buffer.
        guard let parsed = Double(raw), parsed.isFinite else { return }
        setValue(parsed, notify: true)
    }

    /// The arrows. `NSStepper` auto-repeats while the mouse is held on it, so this only has
    /// to turn "the user moved it" into a value change and let `setValue` push the result
    /// back into the field, the readout and the slider.
    /// The minus and the plus: one step of the grid each, the direction the glyph says.
    /// `0.1` is the step the window's keyboard shortcuts move by — F1's grid — so the
    /// mouse, the keys and the buttons all agree on what one step is.
    @objc private func lowerTapped() {
        nudge(-0.1)
    }

    @objc private func raiseTapped() {
        nudge(0.1)
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

    /// `Escape` cancels the edit: the field returns to the sound's own value and
    /// nothing is committed that the user typed halfway. The engine is never touched.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        cancelEditing()
        return true
    }
}