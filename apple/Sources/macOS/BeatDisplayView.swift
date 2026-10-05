import AppKit
import BinauralCore

/// The BEAT / CARRIER card (SPEC F1, `ui/widgets/beat_display.py`).
///
/// `beat = |fL - fR|` and `carrier = (fL + fR) / 2`, recomputed from the two controls on
/// every change, plus the §F1 hint while the difference sits outside the 0.5–100 Hz
/// range the ear usually perceives as a beat.
@MainActor
final class BeatDisplayView: NSView {

    private let beatValue = NSTextField(labelWithString: "0.0")
    private let beatCaption = NSTextField(labelWithString: "")
    private let carrierValue = NSTextField(labelWithString: "0.0")
    private let carrierCaption = NSTextField(labelWithString: "")
    private let beatUnit = NSTextField(labelWithString: "")
    private let carrierUnit = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private var beatHz: Double = 0
    private var carrierHz: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        layer?.borderColor = NSColor.separatorColor.cgColor

        for value in [beatValue, carrierValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        }
        beatValue.textColor = .controlAccentColor
        carrierValue.textColor = .secondaryLabelColor
        for caption in [beatCaption, carrierCaption] {
            caption.font = .systemFont(ofSize: 13, weight: .semibold)
            caption.textColor = .secondaryLabelColor
            caption.alignment = .right
            caption.widthAnchor.constraint(equalToConstant: 84).isActive = true
        }

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemOrange
        hintLabel.isHidden = true

        let stack = NSStackView(views: [
            metricRow(caption: beatCaption, value: beatValue, unit: beatUnit),
            metricRow(caption: carrierCaption, value: carrierValue, unit: carrierUnit),
            hintLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
    }

    private func metricRow(caption: NSTextField, value: NSTextField, unit: NSTextField) -> NSStackView {
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [caption, value, unit, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Values

    /// Recompute from the two channel frequencies.
    func update(leftHz: Double, rightHz: Double) {
        beatHz = BeatMath.beatFrequency(leftHz: leftHz, rightHz: rightHz)
        carrierHz = BeatMath.carrierFrequency(leftHz: leftHz, rightHz: rightHz)
        beatValue.stringValue = String(format: "%.1f", beatHz)
        carrierValue.stringValue = String(format: "%.1f", carrierHz)
        applyHint()
    }

    /// The two readouts, exposed for tests and diagnostics.
    var displayedBeatHz: Double { beatHz }
    var displayedCarrierHz: Double { carrierHz }

    /// The visible §F1 hint text; empty while the hint is hidden.
    var hintText: String { hintLabel.stringValue }

    /// True while the §F1 out-of-range hint is showing.
    var isShowingHint: Bool { !hintLabel.isHidden }

    // MARK: - Language

    /// Re-read the captions after a language switch, then re-derive the hint.
    func retranslate() {
        beatCaption.stringValue = L10n.tr("BEAT")
        carrierCaption.stringValue = L10n.tr("CARRIER")
        beatUnit.stringValue = L10n.tr("Hz")
        carrierUnit.stringValue = L10n.tr("Hz")
        setAccessibilityLabel(L10n.tr("Beat and carrier frequencies"))
        applyHint()
    }

    private func applyHint() {
        guard !BeatMath.isRecommendedBeat(beatHz) else {
            hintLabel.isHidden = true
            hintLabel.stringValue = ""
            return
        }
        let range = BeatMath.recommendedBeatRangeHz
        hintLabel.stringValue = L10n.tr(
            "Difference is %1 Hz — outside the %2–%3 Hz range the ear usually perceives as a beat.",
            FrequencyGrid.text(beatHz),
            FrequencyGrid.text(range.lowerBound),
            FrequencyGrid.text(range.upperBound)
        )
        hintLabel.setAccessibilityLabel(L10n.tr("Warning"))
        hintLabel.isHidden = false
    }
}