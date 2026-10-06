import AppKit
import BinauralCore

/// The playback timer control of SPEC §5 F5: a duration popup and a visible countdown.
///
/// `Session.timerChoices` is the only source of the offered durations, `0` means "off"
/// and 15 minutes is what a fresh session starts on — all three rules are the session's,
/// not the view's, so they cannot drift apart here.
///
/// The countdown is **text**, not a ring or a bar: SPEC §7.2 requires reduced-motion to
/// be respected, and a label is the one representation that needs no animation at all.
/// While the timer is off the label is empty and hidden rather than reading `00:00`,
/// which would look like a session that had already ended.
@MainActor
final class TimerControlView: NSView {

    /// The user picked a new duration in minutes. Not sent by ``setMinutes(_:)``.
    var onSelectMinutes: ((Int) -> Void)?

    private let captionLabel = NSTextField(labelWithString: "")
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countdownLabel = NSTextField(labelWithString: "")

    private var minutes = Session.defaultTimerMinutes
    private var isSyncing = false

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
        captionLabel.font = .systemFont(ofSize: 13)
        captionLabel.textColor = .secondaryLabelColor

        popup.controlSize = .regular
        popup.font = .systemFont(ofSize: 13)
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.setAccessibilityLabel(L10n.tr("Timer"))

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .right

        let stack = NSStackView(views: [captionLabel, popup, countdownLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // SPEC §7.2: 44 px minimum click target.
            popup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            countdownLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])

        setAccessibilityLabel(L10n.tr("Timer"))
        rebuildItems()
        setMinutes(minutes)
    }

    /// Rebuild the popup from `Session.timerChoices` — the offered durations are data,
    /// and translating them changes every caption, so the list is rebuilt rather than
    /// patched.
    private func rebuildItems() {
        popup.removeAllItems()
        for choice in Session.timerChoices {
            popup.addItem(withTitle: Self.title(forMinutes: choice))
            popup.lastItem?.representedObject = choice
        }
    }

    /// The caption of one choice: `Off`, or `15 min` in the current language.
    static func title(forMinutes minutes: Int) -> String {
        minutes == Session.timerOff
            ? L10n.tr("Off")
            : L10n.tr("%1 min", String(minutes))
    }

    // MARK: - Value

    /// Select a duration without telling anyone — used while restoring the session.
    ///
    /// A stored value outside `timerChoices` still selects the nearest offered one: the
    /// session clamps the *number*, the control shows what can be clicked.
    func setMinutes(_ value: Int) {
        minutes = Session.timerChoices.contains(value)
            ? value
            : Self.closestChoice(to: value)
        let index = Session.timerChoices.firstIndex(of: minutes) ?? 0
        isSyncing = true
        popup.selectItem(at: index)
        isSyncing = false
    }

    private static func closestChoice(to minutes: Int) -> Int {
        Session.timerChoices.min {
            abs($0 - minutes) < abs($1 - minutes)
        } ?? Session.defaultTimerMinutes
    }

    /// The duration currently selected, in minutes.
    var selectedMinutes: Int { minutes }

    /// Show the countdown. An empty string hides the label — the timer is off.
    func updateCountdown(_ text: String) {
        countdownLabel.stringValue = text
        countdownLabel.isHidden = text.isEmpty
        countdownLabel.setAccessibilityLabel(L10n.tr("Timer"))
        countdownLabel.setAccessibilityValue(text)
    }

    // MARK: - State the tests read

    /// The popup captions, in order: the durations the user can pick.
    var choiceTitles: [String] { popup.itemArray.map(\.title) }

    var countdownText: String { countdownLabel.stringValue }
    var isShowingCountdown: Bool { !countdownLabel.isHidden }
    var captionTitle: String { captionLabel.stringValue }

    // MARK: - Actions

    @objc private func selectionChanged() {
        guard !isSyncing,
              let raw = popup.selectedItem?.representedObject as? Int,
              raw != minutes
        else { return }
        minutes = raw
        onSelectMinutes?(raw)
    }

    // MARK: - Language

    /// Re-read the captions after a language switch (SPEC §7.4), keeping the selection.
    func retranslate() {
        captionLabel.stringValue = L10n.tr("Timer")
        popup.setAccessibilityLabel(L10n.tr("Timer"))
        setAccessibilityLabel(L10n.tr("Timer"))
        rebuildItems()
        setMinutes(minutes)
    }
}
