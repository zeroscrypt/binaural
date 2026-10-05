import AppKit
import BinauralCore

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
    private let captionLabel = NSTextField(labelWithString: "")
    private let rangeHintLabel = NSTextField(labelWithString: "")
    private let displayLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let slider = NSSlider()
    private var isSyncing = false

    init(ear: Ear, accent: NSColor) {
        self.ear = ear
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setUp(accent: accent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Building

    private func setUp(accent: NSColor) {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        captionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        captionLabel.textColor = .secondaryLabelColor

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

        let stack = NSStackView(views: [header, displayLabel, field, slider])
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
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
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
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = active ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
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
        slider.doubleValue = FrequencyGrid.sliderPosition(for: value) * FrequencyGrid.sliderSteps
    }

    @objc private func commitField() {
        guard !isSyncing else { return }
        setValue(field.doubleValue, notify: true)
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