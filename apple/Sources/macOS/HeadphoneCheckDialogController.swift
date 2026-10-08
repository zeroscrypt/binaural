import AppKit
import BinauralCore

/// The headphone check of SPEC §4 — a **dialog, never a wall**.
///
/// Port of `ui/dialogs/headphone_check.py`, with the two levels SPEC §4 defines: the
/// heuristic is silent and automatic, the perceptual L/R test asks the user, and when
/// headphones are not confirmed the app **explains and allows continuing** (§4.3). The
/// "Continue anyway" button is created enabled and is never disabled anywhere in this file
/// — that is the whole guarantee of §4.3, and a missing or broken detector must not be able
/// to trap a user in a startup dialog.
///
/// The dialog owns the wording and the verdict table; it never runs detection itself
/// except through ``HeadphoneDetector`` when the user presses *Retry check*, and it never
/// plays a tone itself — ``LRTestDialogController`` does, over the same engine.
@MainActor
final class HeadphoneCheckDialogController: NSWindowController, NSWindowDelegate {

    /// True once the user chose to continue (SPEC §4.3). The caller stores this as
    /// `Session.headphoneCheckAcknowledged` so the check is not repeated every start.
    private(set) var acknowledged = false

    /// The verdict including any perceptual answer, ready for the window and the session.
    private(set) var report: HeadphoneReport

    private let player: LRTonePlayer

    private let headlineLabel = NSTextField(wrappingLabelWithString: "")
    private let statusGlyph = NSTextField(labelWithString: "?")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsStack = NSStackView()
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let lrLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let lrButton = NSButton()
    private let retryButton = NSButton()
    private let continueButton = NSButton()
    private let checkButton = NSButton()

    /// Injected so the tests can run the whole check against a stub. The app passes
    /// nothing and gets the CoreAudio backend.
    private let detect: () -> HeadphoneReport

    /// The window's own re-check button calls back into here (SPEC §7: "кнопка проверки
    /// наушников прямо в окне"), so the window's button and the Help menu item end up in
    /// exactly the same dialog.
    var onRequestRecheck: ((HeadphoneReport) -> Void)?

    init(player: LRTonePlayer, report: HeadphoneReport? = nil, detect: (() -> HeadphoneReport)? = nil) {
        self.player = player
        self.report = report ?? HeadphoneDetector.detect()
        self.detect = detect ?? { HeadphoneDetector.detect() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        // A modal session ends only through `endModalSessionAndClose`, so the red close
        // button and Cmd+W need a route to `continueAnyway()`. Plain `close()` would hide
        // the dialog while `NSApp.runModal(for:)` kept spinning, leaving the app blocked.
        window.delegate = self
        buildContent()
        retranslate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the dialog is built in code")
    }

    // MARK: - Building

    private func buildContent() {
        headlineLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let statusBox = NSBox()
        statusBox.titlePosition = .noTitle
        statusBox.boxType = .custom
        statusBox.borderWidth = 1
        statusBox.borderColor = .separatorColor
        statusGlyph.font = .systemFont(ofSize: 16)
        statusGlyph.setAccessibilityElement(false)
        statusLabel.font = .systemFont(ofSize: 13)
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 4
        let statusStack = NSStackView(views: [statusGlyph, statusLabel, detailsStack])
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 8
        statusStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        statusBox.contentView = statusStack

        explanationLabel.font = .systemFont(ofSize: 13)
        lrLabel.font = .systemFont(ofSize: 13)
        lrLabel.isHidden = true

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        lrButton.target = self
        lrButton.action = #selector(runLRTestTapped)
        lrButton.bezelStyle = .rounded
        lrButton.alignment = .left
        lrButton.setAccessibilityLabel(L10n.tr("Run the perceptual left/right channel test"))
        lrButton.setAccessibilityHelp(
            L10n.tr("Plays a tone in the left ear, then the right ear, and asks what you heard.")
        )

        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.bezelStyle = .rounded
        retryButton.setAccessibilityLabel(L10n.tr("Run the device check again"))
        retryButton.setAccessibilityHelp(L10n.tr("Re-reads the default audio output device."))

        // §4.3: this button is created enabled and nothing in this file ever disables it.
        continueButton.target = self
        continueButton.action = #selector(onContinue)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.setAccessibilityLabel(
            L10n.tr("Continue anyway, even without confirmed headphones")
        )
        continueButton.setAccessibilityHelp(
            L10n.tr(
                "Nothing is blocked; the app will keep the speakers warning in the status bar."
            )
        )

        // The window's own check button (SPEC §7) — it must not close this dialog, or the
        // Help menu item and the window button would behave differently.
        checkButton.target = self
        checkButton.action = #selector(retryFromWindowButton)
        checkButton.bezelStyle = .rounded
        checkButton.setAccessibilityLabel(L10n.tr("Run the device check again"))
        checkButton.setAccessibilityHelp(L10n.tr("Re-reads the default audio output device."))

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.tag = 3
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let row = NSStackView(views: [retryButton, NSView(), continueButton])
        row.orientation = .horizontal
        row.spacing = 12

        let stack = NSStackView(views: [
            headlineLabel, statusBox, explanationLabel, errorLabel, lrLabel, lrButton, hint, row,
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
            // SPEC §7.2: 44 px minimum click target, every button.
            lrButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            checkButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            statusBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lrButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        window?.contentView = content
        window?.setAccessibilityLabel(L10n.tr("Headphones recommended"))
    }

    // MARK: - Actions

    /// *Retry check* — re-read the device and refresh in place.
    @discardableResult
    func retry() -> HeadphoneReport {
        report = detect()
        if let lrTest = report.lrTest {
            report = HeadphoneDetector.withLRResult(lrTest, in: report)
        }
        refresh()
        return report
    }

    /// `@objc` shims: the actions above return values a selector cannot carry, so AppKit
    /// reaches the Swift methods through these void wrappers.
    @objc private func retryTapped() {
        retry()
    }

    @objc private func runLRTestTapped() {
        runLRTest()
    }

    @objc private func retryFromWindowButton() {
        let fresh = retry()
        onRequestRecheck?(fresh)
    }

    /// Run the perceptual test (SPEC §4.2) and fold the answer in.
    @discardableResult
    func runLRTest() -> LRTestResult? {
        let dialog = LRTestDialogController(player: player)
        dialog.onAnswer = { [weak self] result in
            guard let self else { return }
            self.report = HeadphoneDetector.withLRResult(result, in: self.report)
            self.refresh()
        }
        dialog.showWindow(nil)
        dialog.window?.center()
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return dialog.answer ?? report.lrTest
    }

    /// Feed an answer in without showing the dialog — for a test, or a caller that
    /// collected the answer elsewhere. Public in Python for exactly this reason.
    @discardableResult
    func setLRResult(_ result: LRTestResult) -> HeadphoneReport {
        report = HeadphoneDetector.withLRResult(result, in: report)
        refresh()
        return report
    }

    /// SPEC §4.3's way out. Also what closing the window means.
    func continueAnyway() {
        acknowledged = true
        endModalSessionAndClose()
    }

    /// The red close button and Cmd+W *are* the §4.3 way out — this dialog has no Cancel
    /// button, so a dismissal must count as "continue anyway" rather than leave the
    /// modal session spinning and the app blocked. See
    /// ``SettingsDialogController/windowShouldClose(_:)`` for the mechanism.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        continueAnyway()
        return true
    }

    @objc private func onContinue() {
        continueAnyway()
    }

    // MARK: - Refresh

    private func refresh() {
        let (glyph, status, tone) = Self.verdictText(for: report.verdict)
        statusGlyph.stringValue = glyph
        statusLabel.stringValue = status
        statusLabel.textColor = tone

        headlineLabel.stringValue = report.isHeadphones
            ? L10n.tr("Headphones detected")
            : L10n.tr("Headphones recommended")
        window?.title = headlineLabel.stringValue
        window?.setAccessibilityLabel(headlineLabel.stringValue)

        clearDetails()
        addDetail(key: L10n.tr("Device"), value: report.deviceName.isEmpty
            ? L10n.tr("Unknown output device")
            : report.deviceName)
        addDetail(key: L10n.tr("Verdict"), value: L10n.tr(Self.verdictLabel(for: report.verdict)))
        addDetail(key: L10n.tr("Confidence"), value: L10n.tr(Self.confidenceLabel(for: report.confidence)))

        if let lrTest = report.lrTest {
            lrLabel.stringValue = L10n.tr(Self.lrResultText(for: lrTest))
            lrLabel.textColor = tone
            lrLabel.isHidden = false
        } else {
            lrLabel.isHidden = true
        }

        // Never gate the user: this is re-asserted on every refresh, so no code path can
        // leave the button disabled (SPEC §4.3).
        continueButton.isEnabled = true
        clearError()
    }

    private func clearDetails() {
        for view in detailsStack.arrangedSubviews {
            detailsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func addDetail(key: String, value: String) {
        let label = NSTextField(labelWithString: "\(key): \(value)")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        detailsStack.addArrangedSubview(label)
    }

    private func showError(_ message: String?) {
        guard let message, !message.isEmpty else { return clearError() }
        errorLabel.stringValue = L10n.tr(message)
        errorLabel.isHidden = false
    }

    private func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    // MARK: - The wording, ported from `headphone_check.py`

    /// `DeviceClass` -> (icon, status text, colour). Icon **and** words always: SPEC §7.2
    /// forbids colour being the only carrier of meaning.
    static func verdictText(for verdict: DeviceClass) -> (glyph: String, status: String, tone: NSColor) {
        switch verdict {
        case .headphones:
            return ("\u{2713}", L10n.tr("Headphones detected"), .systemGreen)
        case .speakers:
            return ("\u{26a0}", L10n.tr("Speakers detected"), .systemOrange)
        case .virtual:
            return (
                "\u{25d0}",
                L10n.tr("Virtual audio device — cannot tell what is playing"),
                .systemOrange
            )
        case .unknown:
            return (
                "?",
                L10n.tr("Output device not recognised — run the L/R test"),
                .systemOrange
            )
        }
    }

    static func verdictLabel(for verdict: DeviceClass) -> String {
        switch verdict {
        case .headphones: return L10n.tr("Headphones")
        case .speakers: return L10n.tr("Speakers")
        case .virtual: return L10n.tr("Virtual device")
        case .unknown: return L10n.tr("Unknown")
        }
    }

    static func confidenceLabel(for confidence: DetectionConfidence) -> String {
        switch confidence {
        case .high: return L10n.tr("High")
        case .medium: return L10n.tr("Medium")
        case .low: return L10n.tr("Low")
        }
    }

    static func lrResultText(for result: LRTestResult) -> String {
        switch result {
        case .leftThenRight:
            return L10n.tr("L/R test: Left → Right — headphones confirmed, channels correct.")
        case .rightThenLeft:
            return L10n.tr(
                "L/R test: Right → Left — headphones confirmed, channels are swapped. "
                    + "Binaural will swap them when generating."
            )
        case .indeterminate:
            return L10n.tr(
                "L/R test: both at once or unclear — this sounds like speakers or a mono mixer."
            )
        }
    }

    // MARK: - Language

    func retranslate() {
        window?.title = report.isHeadphones
            ? L10n.tr("Headphones detected")
            : L10n.tr("Headphones recommended")

        explanationLabel.stringValue = L10n.tr(
            "Binaural beats only work when each ear receives its own tone. On speakers the "
                + "two frequencies mix in the air before reaching your ears, and the effect "
                + "disappears. You can continue anyway — the app will keep showing a "
                + "\u{201C}Speakers detected\u{201D} indicator in the status bar."
        )
        lrButton.title = L10n.tr("Run L/R test")
        retryButton.title = L10n.tr("Retry check")
        checkButton.title = L10n.tr("Retry check")
        continueButton.title = L10n.tr("Continue anyway")
        continueButton.setAccessibilityLabel(
            L10n.tr("Continue anyway, even without confirmed headphones")
        )
        retryButton.setAccessibilityLabel(L10n.tr("Run the device check again"))
        if let hint = hintLabel() {
            hint.stringValue = L10n.tr("This check can be repeated at any time from the Help menu.")
        }
        refresh()
    }

    private func hintLabel() -> NSTextField? {
        window?.contentView?.subviews.first?.subviews.first { ($0 as? NSTextField)?.tag == 3 } as? NSTextField
    }

    // MARK: - State the tests read

    var statusText: String { statusLabel.stringValue }
    var headlineText: String { headlineLabel.stringValue }
    var detailTexts: [String] { detailsStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var lrResultText: String { lrLabel.stringValue }
    var isShowingLRResult: Bool { !lrLabel.isHidden }
    var continueButtonTitle: String { continueButton.title }
    /// SPEC §4.3's accessibility guarantee, exposed the way Python exposes it.
    var isContinueEnabled: Bool { continueButton.isEnabled }
    var lrButtonTitle: String { lrButton.title }
    var retryButtonTitle: String { retryButton.title }
    var checkButtonTitle: String { checkButton.title }
    var isHeadphones: Bool { report.isHeadphones }
    var channelsSwapped: Bool { report.channelsSwapped }
    var lrResult: LRTestResult? { report.lrTest }
    var deviceName: String { report.deviceName }
    var confidence: DetectionConfidence { report.confidence }
    var verdict: DeviceClass { report.verdict }

    /// The window button, so the controller can put it on a status row.
    var headphoneCheckButton: NSButton { checkButton }
}