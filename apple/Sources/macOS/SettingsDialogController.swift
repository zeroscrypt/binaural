import AppKit
import BinauralCore

/// The Settings dialog of SPEC §7 — *language, headphone check, timer, volume*.
///
/// Python has no settings layer at all, so this is not a port: the four things SPEC §7
/// names are the four controls here, and each one writes through to the **live** window
/// rather than to a private copy. There is no OK button and no Apply, because there is
/// nothing to apply: language switches as you pick it (SPEC §7.4 — *переключается на лету*),
/// volume moves the gain as you drag, the timer re-arms a running session, and the headphone
/// check opens the same dialog the Help menu opens. Close just closes.
///
/// Every control goes through the window's own entry points — `setVolume`,
/// `selectTimerMinutes`, `setHeadphoneCheckHandler` — so a value changed here and a value
/// changed in the window go through identical code and identical saving.
@MainActor
final class SettingsDialogController: NSWindowController, NSWindowDelegate {

    /// The language as it was when the dialog opened, restored if the user cancels out of
    /// a switch. `nil` means "leave it alone".
    private var initialLanguage: LanguageCode
    private var languageObserver: (any NSObjectProtocol)?

    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider = NSSlider()
    private let volumeLabel = NSTextField(labelWithString: "")
    private let headphoneLabel = NSTextField(wrappingLabelWithString: "")
    private let headphoneDetailLabel = NSTextField(labelWithString: "")
    private let headphoneButton = NSButton()
    private let closeButton = NSButton()

    /// The values the dialog edits. Every entry point already exists on the window, so
    /// there is no "settings model" that could drift from what the app actually does.
    struct Values {
        var language: LanguageCode
        var timerMinutes: Int
        var volume: Double
        /// The current verdict, for the status line — `nil` when nothing has been detected.
        var headphoneReport: HeadphoneReport?
    }

    /// Called for each change, with what changed. Main actor by construction.
    var onLanguageChange: ((LanguageCode) -> Void)?
    var onTimerChange: ((Int) -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    /// *Check headphones…* — the same coordinator the Help menu item uses.
    var onCheckHeadphones: (() -> Void)?

    init(values: Values) {
        initialLanguage = values.language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        // The dialog runs a modal session, and a modal session only ends through
        // `endModalSessionAndClose`. Without the delegate, the red close button and
        // Cmd+W would close the window while `NSApp.runModal(for:)` kept spinning:
        // the dialog would vanish and the whole app — window, menus and all — would
        // stay blocked with nothing on screen to explain why.
        window.delegate = self
        buildContent()
        apply(values)
        retranslate()

        // SPEC §7.4: the dialog reads the language itself. Observing the change is what
        // lets the *other* controls of this dialog follow a switch made in the View menu
        // while it is open.
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retranslate() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the dialog is built in code")
    }

    /// Stop observing. Called by the app when the dialog is dismissed, and by the tests —
    /// `deinit` cannot, because a `deinit` is nonisolated and the token is not `Sendable`.
    /// The observation holds the dialog weakly, so a forgotten call leaks nothing that
    /// matters; this exists to keep the notification centre's table tidy.
    func tearDown() {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
    }

    // MARK: - Building

    private func buildContent() {
        for popup in [languagePopup, timerPopup] {
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: 13)
            popup.target = self
        }
        languagePopup.action = #selector(languageChanged)
        timerPopup.action = #selector(timerChanged)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved)
        volumeLabel.font = .systemFont(ofSize: 13)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right

        headphoneLabel.font = .systemFont(ofSize: 13)
        headphoneDetailLabel.font = .systemFont(ofSize: 11)
        headphoneDetailLabel.textColor = .secondaryLabelColor

        headphoneButton.target = self
        headphoneButton.action = #selector(checkHeadphones)
        headphoneButton.bezelStyle = .rounded
        headphoneButton.setAccessibilityLabel(L10n.tr("Check headphones…"))
        headphoneButton.setAccessibilityHelp(
            L10n.tr("Re-reads the default audio output device and offers the L/R test.")
        )

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel(L10n.tr("Close"))

        let stack = NSStackView(views: [
            languageRow(),
            timerRow(),
            volumeRow(),
            headphoneBox(),
            footer(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40),
            // SPEC §7.2: 44 px minimum click target.
            languagePopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            timerPopup.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            headphoneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        window?.contentView = content
        rebuildLanguages()
        rebuildTimers()
    }

    /// One row: caption on the left, control on the right, as Python's settings rows are.
    private func row(caption: NSTextField, control: NSView) -> NSStackView {
        let stack = NSStackView(views: [caption, NSView(), control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    private func languageRow() -> NSStackView {
        let caption = NSTextField(labelWithString: "")
        caption.tag = 1
        caption.font = .systemFont(ofSize: 13)
        return row(caption: caption, control: languagePopup)
    }

    private func timerRow() -> NSStackView {
        let caption = NSTextField(labelWithString: "")
        caption.tag = 2
        caption.font = .systemFont(ofSize: 13)
        return row(caption: caption, control: timerPopup)
    }

    private func volumeRow() -> NSStackView {
        let caption = NSTextField(labelWithString: "")
        caption.tag = 3
        caption.font = .systemFont(ofSize: 13)
        let control = NSStackView(views: [volumeSlider, volumeLabel])
        control.orientation = .horizontal
        control.spacing = 8
        volumeSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        volumeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return row(caption: caption, control: control)
    }

    private func headphoneBox() -> NSBox {
        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        let caption = NSTextField(labelWithString: "")
        caption.tag = 4
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [caption, headphoneLabel, headphoneDetailLabel, headphoneButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        box.contentView = stack
        stack.widthAnchor.constraint(equalTo: stack.superview!.widthAnchor, constant: -24).isActive = true
        return box
    }

    private func footer() -> NSStackView {
        let stack = NSStackView(views: [NSView(), closeButton])
        stack.orientation = .horizontal
        stack.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return stack
    }

    /// Native language names ("English", "Русский") in both languages, exactly as the
    /// View menu does it — a user must be able to find their own language in the list.
    private func rebuildLanguages() {
        languagePopup.removeAllItems()
        for code in L10n.languages {
            // `addItem(withTitle:)` returns the menu, not the item; see below.
            languagePopup.menu?.addItem(
                withTitle: LanguageCode.name(code),
                action: nil,
                keyEquivalent: ""
            ).representedObject = code.rawValue
        }
    }

    /// `Session.timerChoices`, the same data the main window offers — a settings dialog that
    /// offered a different set of durations would be a second source of truth.
    private func rebuildTimers() {
        timerPopup.removeAllItems()
        for choice in Session.timerChoices {
            // `addItem(withTitle:)` returns the *menu*, not the item — which is the only way
            // to reach the item and set its payload.
            timerPopup.menu?.addItem(
                withTitle: TimerControlView.title(forMinutes: choice),
                action: nil,
                keyEquivalent: ""
            ).representedObject = choice
        }
    }

    // MARK: - Values

    private func apply(_ values: Values) {
        let languageIndex = L10n.languages.firstIndex(of: values.language) ?? 0
        languagePopup.selectItem(at: languageIndex)

        let minutes = Session.timerChoices.contains(values.timerMinutes)
            ? values.timerMinutes
            : (Session.timerChoices.min { abs($0 - values.timerMinutes) < abs($1 - values.timerMinutes) }
                ?? Session.defaultTimerMinutes)
        timerPopup.selectItem(at: Session.timerChoices.firstIndex(of: minutes) ?? 0)

        volumeSlider.doubleValue = min(1, max(0, values.volume))
        updateVolumeLabel()
        apply(headphoneReport: values.headphoneReport)
    }

    /// Show the verdict the app is currently acting on, so the dialog states the truth
    /// rather than implying the check has never run.
    func apply(headphoneReport report: HeadphoneReport?) {
        let (glyph, status, colour) = report.map {
            HeadphoneCheckDialogController.verdictText(for: $0.verdict)
        } ?? ("?", L10n.tr("Unknown device"), .secondaryLabelColor)
        headphoneLabel.stringValue = "\(glyph)  \(status)"
        headphoneLabel.textColor = colour

        guard let report else {
            headphoneDetailLabel.stringValue = ""
            return
        }
        let device = report.deviceName.isEmpty ? L10n.tr("Unknown output device") : report.deviceName
        headphoneDetailLabel.stringValue = "\(L10n.tr("Device")): \(device)   ·   "
            + "\(L10n.tr("Verdict")): \(L10n.tr(HeadphoneCheckDialogController.verdictLabel(for: report.verdict)))"
            + "   ·   \(L10n.tr("Confidence")): "
            + L10n.tr(HeadphoneCheckDialogController.confidenceLabel(for: report.confidence))
    }

    /// The red close button and Cmd+W mean the same as the *Close* button: end the modal
    /// session, close, nothing else.
    ///
    /// The subtle half is ending the **modal session** rather than the window. A dialog
    /// closed by plain `close()` disappears but leaves `NSApp.runModal(for:)` spinning,
    /// and the app behind it stays disabled — the window cannot be touched and no menu
    /// item responds, with no dialog left to close. That is what the red button did here
    /// until it was wired to this method. (`NSWindowDelegate` has it as an optional
    /// method, so it is not an `override`.)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endModalSessionAndClose(code: .cancel)
        return true
    }

    // MARK: - Actions

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let code = LanguageCode.parse(raw)
        else { return }
        // `L10n` posts the change; the window, the menu and this dialog all re-read.
        L10n.setLanguage(raw)
        onLanguageChange?(code)
    }

    @objc private func timerChanged() {
        guard let minutes = timerPopup.selectedItem?.representedObject as? Int else { return }
        onTimerChange?(minutes)
    }

    @objc private func volumeMoved() {
        updateVolumeLabel()
        onVolumeChange?(volumeSlider.doubleValue)
    }

    private func updateVolumeLabel() {
        volumeLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
    }

    @objc private func checkHeadphones() {
        onCheckHeadphones?()
    }

    @objc private func closeTapped() {
        endModalSessionAndClose()
    }

    /// Close, restoring the language the dialog opened with if it was changed and nothing
    /// else adopted it. There is no OK button, so a language switched and then dismissed
    /// would otherwise be a silent, permanent change.
    func cancel() {
        if L10n.language != initialLanguage {
            L10n.setLanguage(initialLanguage)
            onLanguageChange?(initialLanguage)
        }
        endModalSessionAndClose(code: .cancel)
    }

    // MARK: - Language

    func retranslate() {
        window?.title = L10n.tr("Settings")
        window?.setAccessibilityLabel(L10n.tr("Settings"))
        for label in captionLabels() {
            switch label.tag {
            case 1: label.stringValue = L10n.tr("Language")
            case 2: label.stringValue = L10n.tr("Timer")
            case 3: label.stringValue = L10n.tr("Volume")
            case 4: label.stringValue = L10n.tr("Headphones")
            default: break
            }
        }
        // Both popups are rebuilt: the captions are translated, and the selection has to be
        // kept — the same rule `TimerControlView` follows.
        let languageIndex = L10n.languages.firstIndex(of: L10n.language) ?? 0
        rebuildLanguages()
        languagePopup.selectItem(at: languageIndex)

        let selected = timerPopup.selectedItem?.representedObject as? Int ?? Session.defaultTimerMinutes
        rebuildTimers()
        timerPopup.selectItem(at: Session.timerChoices.firstIndex(of: selected) ?? 0)

        closeButton.title = L10n.tr("Close")
        headphoneButton.title = L10n.tr("Check headphones…")
        volumeSlider.setAccessibilityLabel(L10n.tr("Volume"))
        volumeSlider.setAccessibilityHelp(
            L10n.tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )
        languagePopup.setAccessibilityLabel(L10n.tr("Language"))
        timerPopup.setAccessibilityLabel(L10n.tr("Timer"))
    }

    /// The caption labels of the four rows, found by tag rather than by walking a fragile
    /// subview path — a query the tests can check too.
    private func captionLabels() -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let label = view as? NSTextField, label.tag >= 1, label.tag <= 4 {
                found.append(label)
            }
            for sub in view.subviews { walk(sub) }
        }
        if let content = window?.contentView { walk(content) }
        return found
    }

    // MARK: - State the tests read

    var languageTitles: [String] { languagePopup.itemArray.map(\.title) }
    var timerTitles: [String] { timerPopup.itemArray.map(\.title) }
    var selectedLanguage: LanguageCode {
        guard let raw = languagePopup.selectedItem?.representedObject as? String else { return L10n.language }
        return LanguageCode.parse(raw) ?? L10n.language
    }
    var selectedTimerMinutes: Int {
        timerPopup.selectedItem?.representedObject as? Int ?? Session.timerOff
    }
    var volumeValue: Double { volumeSlider.doubleValue }
    var volumeTitle: String { volumeLabel.stringValue }
    var headphoneStatusText: String { headphoneLabel.stringValue }
    var headphoneDetailText: String { headphoneDetailLabel.stringValue }
    var checkButtonTitle: String { headphoneButton.title }
    var closeButtonTitle: String { closeButton.title }

    /// Caption labels, in the order the rows appear — what a user reads.
    var captionTitles: [String] { captionLabels().map(\.stringValue) }

    // MARK: - Test entry points

    /// Pick a language as the popup would, going through `L10n.setLanguage` exactly as the
    /// View menu does.
    func selectLanguage(_ code: LanguageCode) {
        let index = L10n.languages.firstIndex(of: code) ?? 0
        languagePopup.selectItem(at: index)
        languageChanged()
    }

    /// Pick a duration as the popup would.
    func selectTimerMinutes(_ minutes: Int) {
        timerPopup.selectItem(at: Session.timerChoices.firstIndex(of: minutes) ?? 0)
        timerChanged()
    }

    func setVolume(_ level: Double) {
        volumeSlider.doubleValue = min(1, max(0, level))
        volumeMoved()
    }

    func tapCheckHeadphones() {
        checkHeadphones()
    }
}