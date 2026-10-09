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
    /// The boundary note replaces the ordinary §F1 out-of-range hint while it is up: the two
    /// never need to be on screen at once, because a locked difference cannot be both at
    /// the limit and out of range at the same moment without saying the same thing twice.
    private var boundaryNote: String?

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

        // SPEC §7 puts the lock next to the difference it protects, and "next to" is on the
        // BEAT row itself — to its right, not on a row of its own underneath. The beat
        // stays a read-out: there is no field for typing a difference, only a way to hold
        // the current one.
        lockCheckbox.target = self
        lockCheckbox.action = #selector(lockToggled)
        lockCheckbox.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [
            metricRow(caption: beatCaption, value: beatValue, unit: beatUnit, trailing: lockCheckbox),
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
            // The beat row carries the lock checkbox, so it — and not the card — is what
            // has to clear SPEC §7.2's 44 px minimum target.
            lockCheckbox.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    /// One row of the card: caption, value, unit, then whatever follows to the right.
    ///
    /// `trailing` is pushed to the far end by a stretch, which is what puts the lock box
    /// at the right edge of the BEAT row rather than hugging the number it protects.
    private func metricRow(
        caption: NSTextField,
        value: NSTextField,
        unit: NSTextField,
        trailing: NSView? = nil
    ) -> NSStackView {
        unit.font = .systemFont(ofSize: 13)
        unit.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [caption, value, unit, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        if let trailing { row.addArrangedSubview(trailing) }
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

    // MARK: - Lock difference (SPEC §7)

    /// The user ticked or cleared the box. Not sent by ``setLocked(_:)``, so restoring a
    /// session stays silent — the same rule the frequency controls follow.
    var onLockToggled: ((Bool) -> Void)?

    private let lockCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var isSyncingLock = false

    /// Tick or clear the box without telling anyone — used while restoring the session.
    func setLocked(_ locked: Bool) {
        isSyncingLock = true
        defer { isSyncingLock = false }
        lockCheckbox.state = locked ? .on : .off
    }

    /// True while the box is ticked, as the user sees it.
    var isLocked: Bool { lockCheckbox.state == .on }

    /// The checkbox as a view, for accessibility and for tests that want to place it.
    var lockControl: NSButton { lockCheckbox }

    @objc private func lockToggled() {
        guard !isSyncingLock else { return }
        onLockToggled?(lockCheckbox.state == .on)
    }

    /// The visible §F1 hint text; empty while the hint is hidden.
    var hintText: String { hintLabel.stringValue }

    /// True while the §F1 out-of-range hint is showing.
    var isShowingHint: Bool { !hintLabel.isHidden }

    /// True while the hint slot carries the boundary note rather than the §F1 text.
    var isShowingBoundaryNote: Bool { boundaryNote != nil }

    /// Say, in the existing hint slot, that the lock stopped a channel at the range limit.
    ///
    /// The same orange hint the §F1 out-of-range message uses — a user who cannot drag the
    /// slider further deserves the same kind of "here is why" as one whose beat is inaudible,
    /// and inventing a second warning style for it would be worse. Pass `nil` to go back to
    /// the ordinary §F1 rule.
    func showBoundaryNote(_ note: String?) {
        boundaryNote = note
        applyHint()
    }

    // MARK: - Language

    /// Re-read the captions after a language switch, then re-derive the hint.
    func retranslate() {
        beatCaption.stringValue = L10n.tr("BEAT")
        carrierCaption.stringValue = L10n.tr("CARRIER")
        beatUnit.stringValue = L10n.tr("Hz")
        carrierUnit.stringValue = L10n.tr("Hz")
        lockCheckbox.title = L10n.tr("Lock difference")
        lockCheckbox.setAccessibilityLabel(L10n.tr("Lock difference"))
        lockCheckbox.setAccessibilityHelp(
            L10n.tr(
                "Keeps the difference between the two frequencies. Changing one channel moves the other by the same amount, so the beat stays the same."
            )
        )
        setAccessibilityLabel(L10n.tr("Beat and carrier frequencies"))
        applyHint()
    }

    private func applyHint() {
        // A boundary stop is news from this very edit, so it wins over the standing §F1
        // hint: the user is dragging *right now* and needs to know why the slider stopped.
        // Both are the same kind of message, so both use the same slot.
        if let boundaryNote {
            hintLabel.stringValue = boundaryNote
            hintLabel.setAccessibilityLabel(L10n.tr("Warning"))
            hintLabel.isHidden = false
            return
        }
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