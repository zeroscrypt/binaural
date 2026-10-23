import AppKit
import BinauralCore

/// The playback timer card of SPEC §5 F5, as the hand-drawn layout puts it: a caption,
/// a large clock, the full list of durations and the few durations a hand reaches for.
///
/// `Session.timerChoices` is the only source of the offered durations, `0` means "off"
/// and 15 minutes is what a fresh session starts on — all three rules are the session's,
/// not the view's, so they cannot drift apart here.
///
/// The countdown is **text**, not a ring or a bar: SPEC §7.2 requires reduced-motion to
/// be respected, and a label is the one representation that needs no animation at all.
/// While the timer runs the clock shows the time that is left; while it is not, it
/// shows the *chosen* duration — a `30:00` that says what a session will last, never a
/// `00:00` that would look like a session that had already ended.
@MainActor
final class TimerControlView: NSView {

    /// The user picked a new duration in minutes. Not sent by ``setMinutes(_:)``.
    var onSelectMinutes: ((Int) -> Void)?

    /// The durations a hand reaches for, of a session duration list (the session still
    /// offers every value it has, through the popup; these are only the shortcuts, and
    /// the session's own list has the last word on what may be clicked).
    private static let quickChoices: [Int] = [5, 10, 15, 30, 60]

    private let captionLabel = NSTextField(labelWithString: "")
    /// The clock: the time left while the timer runs, the chosen duration while it does not.
    private let clockLabel = NSTextField(labelWithString: "")
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quickRow = NSStackView()
    /// Typing a duration straight into the card: the field takes minutes as a whole
    /// number, and the card's own snapping decides which offered duration results.
    private let manualField = NSTextField(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
    private let manualButton = NSButton(title: "", target: nil, action: nil)
    private var quickButtons: [Int: NSButton] = [:]

    private var minutes = Session.defaultTimerMinutes
    /// The remaining time as the controller gave it, or "" while the timer is off.
    private var countdown = ""
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
        captionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        captionLabel.textColor = .secondaryLabelColor

        clockLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        clockLabel.textColor = .labelColor

        popup.controlSize = .regular
        popup.font = .systemFont(ofSize: 13)
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.setAccessibilityLabel(L10n.tr("Timer"))

        quickRow.orientation = .horizontal
        quickRow.alignment = .centerY
        quickRow.spacing = 6
        for choice in Self.quickChoices where Session.timerChoices.contains(choice) {
            let button = NSButton(
                title: String(choice), target: self, action: #selector(quickChoice(_:))
            )
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel(Self.title(forMinutes: choice))
            quickRow.addArrangedSubview(button)
            quickButtons[choice] = button
        }

        // The manual answer, for every duration the quick row does not name: digits in,
        // `Apply` to commit. Any value snaps to the nearest offered duration — the same
        // snapping the stored session goes through — so the popup stays the one place
        // the truth about what can be clicked lives.
        manualField.placeholderString = "15"
        manualField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        manualField.alignment = .right
        manualField.target = self
        manualField.action = #selector(manualEntered)
        manualField.setAccessibilityLabel(L10n.tr("Timer"))
        manualField.setAccessibilityHelp(L10n.tr("How long a new session plays before it stops by itself."))
        manualField.translatesAutoresizingMaskIntoConstraints = false
        manualField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        manualButton.bezelStyle = .rounded
        manualButton.controlSize = .regular
        manualButton.target = self
        manualButton.action = #selector(manualEntered)
        manualButton.setAccessibilityLabel(L10n.tr("Apply"))
        manualField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        manualButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let manualRow = NSStackView(views: [manualField, manualButton])
        manualRow.orientation = .horizontal
        manualRow.alignment = .centerY
        manualRow.spacing = 6

        let stack = NSStackView(views: [captionLabel, clockLabel, popup, quickRow, manualRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // SPEC §7.2: 44 px minimum click target for the full list.
            popup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
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

    /// A duration as a clock reads: `30` minutes is `30:00`, and an hour and a half
    /// stays `90:00` — the number is the popup's own, only written the way a clock does.
    static func clock(forMinutes minutes: Int) -> String {
        String(format: "%02d:00", minutes)
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
        refreshClock()
    }

    private static func closestChoice(to minutes: Int) -> Int {
        Session.timerChoices.min {
            abs($0 - minutes) < abs($1 - minutes)
        } ?? Session.defaultTimerMinutes
    }

    /// The duration currently selected, in minutes.
    var selectedMinutes: Int { minutes }

    /// Type into the manual field and press its own commit — one path for the user and
    /// a test to walk, so the manual answer cannot drift from what it is on screen.
    func typeManualMinutes(_ text: String) {
        manualField.stringValue = text
        manualEntered()
    }

    /// Show the countdown. An empty string means the timer is off and the clock goes
    /// back to the chosen duration.
    func updateCountdown(_ text: String) {
        countdown = text
        refreshClock()
        clockLabel.setAccessibilityLabel(L10n.tr("Timer"))
        clockLabel.setAccessibilityValue(countdown.isEmpty ? clockLabel.stringValue : countdown)
    }

    /// The clock: what is left while counting, the chosen duration the rest of the time.
    private func refreshClock() {
        if countdown.isEmpty {
            clockLabel.stringValue = minutes == Session.timerOff
                ? "\u{2014}"
                : Self.clock(forMinutes: minutes)
            clockLabel.textColor = .secondaryLabelColor
        } else {
            clockLabel.stringValue = countdown
            clockLabel.textColor = .labelColor
        }
    }

    // MARK: - State the tests read

    /// The popup captions, in order: the durations the user can pick.
    var choiceTitles: [String] { popup.itemArray.map(\.title) }

    var countdownText: String { countdown }
    var isShowingCountdown: Bool { !countdown.isEmpty }
    var captionTitle: String { captionLabel.stringValue }
    var clockText: String { clockLabel.stringValue }

    // MARK: - Actions

    @objc private func selectionChanged() {
        guard !isSyncing,
              let raw = popup.selectedItem?.representedObject as? Int,
              raw != minutes
        else { return }
        minutes = raw
        onSelectMinutes?(raw)
    }

    @objc private func manualEntered() {
        guard !isSyncing,
              let parsed = Int(manualField.stringValue.trimmingCharacters(in: .whitespaces)),
              parsed >= 0
        else { manualField.stringValue = "" ; return }
        // The offered durations are data: a typed value lands on the nearest one of
        // them, which is exactly what restoring a session does.
        minutes = parsed == 0 ? Session.timerOff : Self.closestChoice(to: parsed)
        setMinutes(minutes)
        onSelectMinutes?(minutes)
        manualField.stringValue = ""
    }

    @objc private func quickChoice(_ sender: NSButton) {
        guard let raw = quickButtons.first(where: { $0.value === sender })?.key, raw != minutes
        else { return }
        setMinutes(raw)
        onSelectMinutes?(raw)
    }

    // MARK: - Language

    /// Re-read the captions after a language switch (SPEC §7.4), keeping the selection.
    func retranslate() {
        manualButton.title = L10n.tr("Apply")
        captionLabel.stringValue = L10n.tr("Timer")
        popup.setAccessibilityLabel(L10n.tr("Timer"))
        setAccessibilityLabel(L10n.tr("Timer"))
        rebuildItems()
        setMinutes(minutes)
    }
}
