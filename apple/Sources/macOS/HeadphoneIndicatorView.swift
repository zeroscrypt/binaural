import AppKit
import BinauralCore

/// Headphone / speaker status, always visible (SPEC §7 "Индикатор состояния наушников
/// всегда виден", §7.2 colour is never the only carrier of meaning).
///
/// Port of `ui/widgets/status_indicator.py`: an icon **and** a text, never colour alone.
/// The glyph is a painted typographic character, not an emoji: SPEC §7.3 allows emoji only
/// inside reference data as category markers, never as UI chrome.
///
/// The three states are Python's three (`status_indicator.py`). M2-b feeds them from
/// the CoreAudio heuristic and the perceptual L/R test
/// (`src/binaural/audio/platform/macos.py`, `audio/headphones.py`) through
/// ``apply(report:)``; before anything has looked at the device the window still shows
/// `.unknown`, which is the honest state and the same text the Python window starts
/// with.
@MainActor
final class HeadphoneIndicatorView: NSView {

    /// What the check concluded, as the status line needs it.
    ///
    /// Python has three: headphones / speakers / unknown, and renders `Virtual` under
    /// unknown. The icon and the words carry the meaning, never the colour alone
    /// (SPEC §7.2), which is why `unknown` keeps its own caption rather than borrowing
    /// the speakers one.
    enum State {
        case headphones
        case speakers
        case unknown
    }

    private let glyphLabel = NSTextField(labelWithString: "?")
    private let label = NSTextField(labelWithString: "")
    private var state: State = .unknown
    private var deviceName = ""

    /// The state a ``DeviceClass`` maps to, with the device name for the tooltip.
    static func state(for deviceClass: DeviceClass, deviceName: String?) -> State {
        switch deviceClass {
        case .headphones: return .headphones
        case .speakers: return .speakers
        // A virtual device and an unreadable one are both "cannot tell", which is what
        // Python's status indicator shows for them.
        case .virtual, .unknown: return .unknown
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    private func setUp() {
        // An `NSTextField` for the glyph rather than an `NSImageView`: SF Symbols are
        // tinted and aligned through the same path as text, which avoids an
        // `NSImage` allocation and a layer per state change on the status line.
        glyphLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        glyphLabel.alignment = .center
        glyphLabel.setAccessibilityElement(false)   // the text label carries the meaning

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [glyphLabel, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyphLabel.widthAnchor.constraint(equalToConstant: 20),
            glyphLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
        setAccessibilityLabel(L10n.tr("Audio output status"))
        apply(.unknown)
    }

    /// The visible text, exposed for tests and for the status line.
    var text: String { label.stringValue }

    /// Switch state; `deviceName` is appended to the tooltip when the detector has one.
    func setState(_ state: State, deviceName: String? = nil) {
        self.state = state
        self.deviceName = deviceName ?? ""
        apply(state)
    }

    /// Switch to whatever a report concluded, keeping the device name it carries.
    func apply(report: HeadphoneReport) {
        setState(
            Self.state(for: report.verdict, deviceName: report.deviceName),
            deviceName: report.deviceName
        )
    }

    private func apply(_ state: State) {
        let symbol: Character
        let text: String
        let colour: NSColor
        switch state {
        case .headphones:
            symbol = "\u{2713}"
            text = L10n.tr("Headphones detected")
            colour = .systemGreen
        case .speakers:
            symbol = "!"
            text = L10n.tr("Speakers detected — binaural beats need headphones")
            colour = .systemOrange
        case .unknown:
            symbol = "?"
            text = L10n.tr("Unknown device")
            colour = .secondaryLabelColor
        }
        glyphLabel.stringValue = String(symbol)
        glyphLabel.textColor = colour
        label.stringValue = text
        label.textColor = colour
        toolTip = deviceName.isEmpty ? text : "\(text) — \(deviceName)"
        setAccessibilityLabel(L10n.tr("Audio output status"))
        setAccessibilityValue(text)
    }

    /// Re-read the text after a language switch.
    func retranslate() {
        apply(state)
    }
}
