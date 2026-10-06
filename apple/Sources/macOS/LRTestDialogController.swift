import AppKit
import BinauralCore

/// The perceptual left/right channel test of SPEC §4.2.
///
/// Port of `ui/dialogs/lr_test.py`. The split is the same as Python's and it is the point
/// of the whole thing: **the dialog owns the question, `LrTestSequence` owns the timing,
/// the engine owns the sound.** The dialog never schedules anything itself and never
/// touches the oscillator.
///
/// `Left → Right` and `Right → Left` are both headphones; the difference is the important
/// part — `Right → Left` means the channels are **swapped** and the generator must swap
/// them, which is exactly what ``HeadphoneReport/channelsSwapped`` and
/// `Session.channelsSwapped` carry.
///
/// Nothing here animates: the status is static words with an icon, which is SPEC §7.2's
/// reduced-motion rule satisfied by there being no motion to reduce. A broken engine
/// produces a written message and a still-usable answer — never a crash (Python's rule).
@MainActor
final class LRTestDialogController: NSWindowController {

    /// The user's answer. Called once, whatever closes the dialog.
    var onAnswer: ((LRTestResult) -> Void)?

    private let sequence: LrTestSequence
    private let player: LRTonePlayer

    private let instructionLabel = NSTextField(wrappingLabelWithString: "")
    private let stepLabel = NSTextField(wrappingLabelWithString: "")
    private let stepGlyph = NSTextField(labelWithString: "○")
    private let toneLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let confirmationLabel = NSTextField(wrappingLabelWithString: "")
    private let answerPanel = NSStackView()
    private let playButton = NSButton()
    private let closeButton = NSButton()

    private var answerButtons: [LRTestResult: NSButton] = [:]
    private var isFinished = false
    /// The answer, once given. Python exposes `lr_result` for the same reason: the caller
    /// needs it *after* the dialog closed, and `NSWindowController` has no return value.
    private(set) var answer: LRTestResult?
    /// True while the question and its three answers are on screen — Python's `asking`.
    private(set) var asked = false

    /// `toneSeconds` and `gapSeconds` are parameters so a test can run the whole sequence
    /// in milliseconds instead of 3.3 seconds.
    init(
        player: LRTonePlayer,
        timing: LRTestTiming = .standard,
        toneSeconds: TimeInterval? = nil,
        gapSeconds: TimeInterval? = nil
    ) {
        self.player = player
        let timing = LRTestTiming(
            frequencyHz: timing.frequencyHz,
            toneSeconds: toneSeconds ?? timing.toneSeconds,
            gapSeconds: gapSeconds ?? timing.gapSeconds
        )
        sequence = LrTestSequence(player: player, timing: timing, schedule: { delay, work in
            MainQueueSchedule.after(delay, work)
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        sequence.onStepChanged = { [weak self] step in self?.apply(step: step) }
        sequence.onFinished = { [weak self] result in self?.finish(result) }
        buildContent()
        retranslate()
        apply(step: .idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the dialog is built in code")
    }

    // MARK: - Building

    private func buildContent() {
        instructionLabel.font = .systemFont(ofSize: 13)
        instructionLabel.setAccessibilityLabel(L10n.tr("Left / right channel test"))

        let stepBox = NSBox()
        stepBox.titlePosition = .noTitle
        stepBox.boxType = .custom
        stepBox.borderWidth = 1
        stepBox.borderColor = .separatorColor
        let stepStack = NSStackView(views: [stepGlyph, stepLabel])
        stepStack.orientation = .horizontal
        stepStack.alignment = .firstBaseline
        stepStack.spacing = 8
        stepStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stepBox.contentView = stepStack

        stepLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        stepGlyph.font = .systemFont(ofSize: 16)
        stepGlyph.setAccessibilityElement(false)   // the words carry the meaning (§7.2)
        toneLabel.font = .systemFont(ofSize: 11)
        toneLabel.textColor = .secondaryLabelColor

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        confirmationLabel.font = .systemFont(ofSize: 13)
        confirmationLabel.isHidden = true

        answerPanel.orientation = .vertical
        answerPanel.alignment = .leading
        answerPanel.spacing = 8
        answerPanel.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        answerPanel.isHidden = true
        answerPanel.setAccessibilityLabel(L10n.tr("What did you hear?"))

        for result in LRTestResult.allCases {
            let button = AnswerButton()
            button.target = self
            button.action = #selector(answerPressed(_:))
            button.answer = result
            button.bezelStyle = .rounded
            button.alignment = .left
            button.isHidden = true
            answerButtons[result] = button
            answerPanel.addArrangedSubview(button)
        }

        playButton.target = self
        playButton.action = #selector(startTest)
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"
        playButton.setAccessibilityLabel(L10n.tr("Play the left/right test sequence"))
        playButton.setAccessibilityHelp(
            L10n.tr("A short tone in the left ear, a pause, then the right ear.")
        )

        closeButton.target = self
        closeButton.action = #selector(cancel)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityLabel(L10n.tr("Close the test without answering"))

        let row = NSStackView(views: [playButton, NSView(), closeButton])
        row.orientation = .horizontal
        row.spacing = 12

        let stack = NSStackView(views: [
            instructionLabel, stepBox, NSBox(), errorLabel, confirmationLabel, answerPanel, row,
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
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stepBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            answerPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for button in answerButtons.values {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        window?.contentView = content
        playButton.setAccessibilityLabel(L10n.tr("Play the left/right test sequence"))
    }

    /// An answer button that remembers *which* answer it stands for.
    ///
    /// `NSView.tag` is read-only and a target/action pair has nowhere else to put the
    /// identity of the button that fired, so the answer lives in a one-line subclass
    /// instead of being encoded into an integer and decoded again.
    final class AnswerButton: NSButton {
        var answer: LRTestResult?
    }

    // MARK: - Flow

    @objc private func startTest() {
        clearError()
        sequence.begin()
        // The engine took the call but produced no sound — say so in words rather than
        // letting the user wonder why nothing happened (Python's `_ENGINE_IDLE_WARNING`).
        if player.error != nil { showError(player.error) }
    }

    /// Answer as if the corresponding button had been pressed.
    @discardableResult
    func submit(_ result: LRTestResult) -> LRTestResult {
        sequence.answer(result)
        return result
    }

    /// Abort the sequence and close. Safe to call repeatedly, and always safe: no tone can
    /// outlive the dialog, whichever way it was dismissed.
    @objc func cancel() {
        sequence.stop()
        endModalSessionAndClose(code: .cancel)
    }

    private func finish(_ result: LRTestResult) {
        guard !isFinished else { return }
        isFinished = true
        answer = result
        sequence.stop()

        for button in answerButtons.values { button.isHidden = true }
        answerPanel.isHidden = true

        stepGlyph.stringValue = "\u{2713}"
        stepLabel.stringValue = L10n.tr("Answer recorded.")
        stepLabel.textColor = Self.color(for: result)
        confirmationLabel.stringValue = Self.confirmation(for: result)
        confirmationLabel.textColor = Self.color(for: result)
        confirmationLabel.isHidden = false
        playButton.title = L10n.tr("Play test again")

        onAnswer?(result)
        endModalSessionAndClose()
    }

    private func apply(step: LRTestStep) {
        let glyph: String
        let text: String
        switch step {
        case .idle: glyph = "○"; text = L10n.tr("Ready. Press \"Play test\" and listen.")
        case .left: glyph = "◀"; text = L10n.tr("Playing in LEFT ear…")
        case .pause: glyph = "—"; text = L10n.tr("Pause…")
        case .right: glyph = "▶"; text = L10n.tr("Playing in RIGHT ear…")
        case .answer: glyph = "?"; text = L10n.tr("What did you hear?")
        }
        stepGlyph.stringValue = glyph
        stepLabel.stringValue = text
        stepLabel.textColor = step == .answer ? .labelColor : .labelColor

        asked = step == .answer
        answerPanel.isHidden = !asked
        for button in answerButtons.values { button.isHidden = !asked }
        playButton.title = asked ? L10n.tr("Play test again") : L10n.tr("Play test")

        if asked, let first = answerButtons[.leftThenRight] {
            window?.makeFirstResponder(first)
        }
    }

    private func showError(_ message: String?) {
        guard let message, !message.isEmpty else { return clearError() }
        errorLabel.stringValue = L10n.tr(message)
        errorLabel.isHidden = false
        errorLabel.setAccessibilityLabel(L10n.tr("Error"))
    }

    private func clearError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    // MARK: - Language

    func retranslate() {
        window?.title = L10n.tr("Left / right channel test")
        window?.setAccessibilityTitle(L10n.tr("Left / right channel test"))

        instructionLabel.stringValue = L10n.tr(
            "You will hear a tone in one ear, then a pause, then a tone in the other ear."
                + " Tell us what you heard."
        )
        instructionLabel.setAccessibilityLabel(L10n.tr("Left / right channel test"))

        for (result, button) in answerButtons {
            let (title, hint) = Self.answerText(for: result)
            button.title = title
            button.toolTip = hint
            button.setAccessibilityLabel(L10n.tr("{answer}. {hint}", named: ["answer": title, "hint": hint]))
        }
        answerPanel.setAccessibilityLabel(L10n.tr("What did you hear?"))

        playButton.title = asked ? L10n.tr("Play test again") : L10n.tr("Play test")
        playButton.setAccessibilityLabel(L10n.tr("Play the left/right test sequence"))
        playButton.setAccessibilityHelp(
            L10n.tr("A short tone in the left ear, a pause, then the right ear.")
        )
        closeButton.title = L10n.tr("Close")
        closeButton.setAccessibilityLabel(L10n.tr("Close the test without answering"))

        toneLabel.stringValue = L10n.tr(
            "Tone: {freq} Hz — one channel at a time, no beat",
            named: ["freq": String(format: "%g", sequence.timing.frequencyHz)]
        )
        apply(step: sequence.step)
    }

    // MARK: - The wording, ported

    /// The three answers of SPEC §4.2 and their one-line explanations.
    static func answerText(for result: LRTestResult) -> (title: String, hint: String) {
        switch result {
        case .leftThenRight:
            return (
                L10n.tr("Left → Right"),
                L10n.tr("The first tone came from the left ear: the channels are correct.")
            )
        case .rightThenLeft:
            return (
                L10n.tr("Right → Left"),
                L10n.tr("The channels are swapped. The application will swap them for you.")
            )
        case .indeterminate:
            return (
                L10n.tr("Both at once / Can't tell"),
                L10n.tr("Sounds like speakers or a mono mixer, where no beat can be perceived.")
            )
        }
    }

    /// What the dialog says after an answer. `Right → Left` gets its own sentence because
    /// the swap is a real consequence the user should know about.
    static func confirmation(for result: LRTestResult) -> String {
        switch result {
        case .leftThenRight:
            return L10n.tr("Headphones confirmed, the channels are correct.")
        case .rightThenLeft:
            return L10n.tr(
                "Headphones confirmed, but the channels are swapped. Binaural will swap them "
                    + "so the beat stays on the side you expect."
            )
        case .indeterminate:
            return L10n.tr("No clear answer. This usually means speakers or a mono mixer.")
        }
    }

    /// Icon **and** words always (SPEC §7.2: colour is never the only carrier of meaning).
    private static func color(for result: LRTestResult) -> NSColor {
        switch result {
        case .leftThenRight: return .systemGreen
        case .rightThenLeft: return .systemOrange
        case .indeterminate: return .systemRed
        }
    }

    // MARK: - State the tests read

    var stepText: String { stepLabel.stringValue }
    var isAsking: Bool { !answerPanel.isHidden }
    var errorText: String { errorLabel.stringValue }
    var hasError: Bool { !errorLabel.isHidden }
    var confirmationText: String { confirmationLabel.stringValue }
    var answerTitles: [String] { LRTestResult.allCases.map { Self.answerText(for: $0).title } }
    var currentStep: LRTestStep { sequence.step }

    @objc private func answerPressed(_ sender: AnswerButton) {
        guard let result = sender.answer else { return }
        submit(result)
    }
}