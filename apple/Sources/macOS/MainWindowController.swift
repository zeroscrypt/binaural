import AppKit
import BinauralCore

/// The main window: status, two independent frequency controls, the beat card and the
/// transport row (SPEC §7 "Главное окно").
///
/// The window owns no audio logic. It pushes frequencies and the play state into
/// ``AudioEngine`` — where they cross to the audio thread as plain values through
/// ``ParameterMailbox`` — and it re-reads its own captions when ``L10n`` reports a
/// language change. What M2-b adds (presets, timer, headphone check, reference) hangs
/// off the same seams.
@MainActor
final class MainWindowController: NSWindowController {

    private let engine: AudioEngine
    private let store: SessionStore
    private let session: Session

    private let indicator = HeadphoneIndicatorView()
    private let leftControl = FrequencyControlView(ear: .left, accent: .controlAccentColor)
    private let rightControl = FrequencyControlView(ear: .right, accent: .systemPurple)
    private let beatView = BeatDisplayView()
    private let playButton = NSButton()
    private let volumeCaptionLabel = NSTextField(labelWithString: "")
    private let volumeSlider = NSSlider()
    private let volumeLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let timerView = TimerControlView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    private var activeEar: FrequencyControlView.Ear = .left
    /// Written once, after the first successful `start()`, and on every change after.
    /// Never on the audio thread.
    private(set) var saves = 0
    private var saveTimer: Timer?
    private var languageObserver: (any NSObjectProtocol)?
    private var isRestoring = false

    // MARK: Playback timer (SPEC §5 F5)

    /// The timer as it stands: which durations were offered, and when playback ends.
    /// A value, not a run loop — `PlaybackTimer` is a pure function of "now", so the
    /// countdown is testable to the second without waiting for one.
    private var playbackTimer: PlaybackTimer = .off
    /// Ticks once a second while a timer is armed. `nil` whenever the timer is off or
    /// playback has stopped, so an idle window schedules nothing at all.
    private var countdownTicker: Timer?

    init(engine: AudioEngine, store: SessionStore) {
        self.engine = engine
        self.store = store
        session = store.load()

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 540)
        super.init(window: window)

        buildContent()
        connect()
        // The window's shortcuts call the same methods the buttons and fields do, so
        // there is one code path per action rather than two that can drift. Wiring them
        // here rather than in the app delegate keeps the pair together and testable.
        if let window = window as? MainWindow {
            window.onTogglePlayback = { [weak self] in self?.togglePlayback() }
            window.onNudge = { [weak self] delta in self?.nudge(delta) }
            window.onSwitchChannel = { [weak self] in self?.toggleActiveChannel() }
        }
        restoreSession()
        retranslate()

        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue by construction, so the isolation assertion
            // holds; the closure itself has to be nonisolated to be `@Sendable`.
            MainActor.assumeIsolated { self?.retranslate() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used: the window is built in code")
    }

    // MARK: - Building

    private func buildContent() {
        let statusRow = NSStackView(views: [indicator, NSView()])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let ears = NSStackView(views: [leftControl, rightControl])
        ears.orientation = .horizontal
        ears.distribution = .fillEqually
        ears.spacing = 16

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.bezelStyle = .rounded
        playButton.controlSize = .large

        volumeCaptionLabel.font = .systemFont(ofSize: 13)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved)

        volumeLabel.font = .systemFont(ofSize: 13)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right

        muteButton.target = self
        muteButton.action = #selector(muteToggled)

        // `NSView()` between the volume and the mute control is the `addStretch` of the
        // Python transport row: the mute sits at the far end, not next to the slider.
        let transport = NSStackView(views: [
            playButton, volumeCaptionLabel, volumeSlider, volumeLabel, NSView(), muteButton
        ])
        transport.orientation = .horizontal
        transport.alignment = .centerY
        transport.spacing = 12

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        // The timer sits under the transport rather than inside it: it has its own
        // caption, a popup and a countdown, and SPEC §7 gives the transport row Play,
        // volume and mute.
        let timerRow = NSStackView(views: [timerView, NSView()])
        timerRow.orientation = .horizontal
        timerRow.alignment = .centerY
        timerRow.spacing = 12

        let stack = NSStackView(views: [statusRow, ears, beatView, transport, timerRow, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)

        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            // Content hugs the top; the window may be taller than it needs to be.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ]
        // `.leading` alignment keeps each row at its natural width, so the rows that
        // should span the window are pinned to the stack's width by hand.
        for row in [statusRow as NSView, ears, beatView, transport, timerRow, errorLabel] {
            row.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        constraints += [
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            ears.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            volumeSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            muteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            timerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ]
        NSLayoutConstraint.activate(constraints)

        window?.contentView = content
    }

    private func connect() {
        leftControl.onChange = { [weak self] _ in self?.frequenciesChanged() }
        rightControl.onChange = { [weak self] _ in self?.frequenciesChanged() }
        timerView.onSelectMinutes = { [weak self] minutes in self?.timerSelectionChanged(minutes) }
    }

    // MARK: - Session

    private func restoreSession() {
        isRestoring = true
        defer { isRestoring = false }
        leftControl.setValue(session.leftHz)
        rightControl.setValue(session.rightHz)
        volumeSlider.doubleValue = session.volume
        // `Session.timerMinutes` is clamped to 0…1440 on load, so the only thing left to
        // reconcile is a value that is in range but not one of the offered durations;
        // `TimerControlView.setMinutes` picks the nearest one it can show.
        timerView.setMinutes(session.timerMinutes)
        engine.volume = session.volume
        engine.isMuted = false
        setActive(.left)
        frequenciesChanged(save: false)
        updateVolumeLabel()
        showCountdown(at: Date())
    }

    /// The session as it stands now.
    var currentSession: Session {
        Session(
            leftHz: leftControl.value,
            rightHz: rightControl.value,
            volume: volumeSlider.doubleValue,
            channelsSwapped: session.channelsSwapped,
            headphoneCheckAcknowledged: session.headphoneCheckAcknowledged,
            lastPreset: session.lastPreset,
            timerMinutes: timerView.selectedMinutes,
            presetCategory: session.presetCategory
        )
    }

    /// Write the session now. Called on quit and by the coalescing timer.
    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        if store.save(currentSession) { saves += 1 }
    }

    /// Coalesce the writes a slider drag or a typed digit would otherwise produce.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    // MARK: - Frequencies

    private func frequenciesChanged(save: Bool = true) {
        let left = leftControl.value
        let right = rightControl.value
        beatView.update(leftHz: left, rightHz: right)
        // The controls clamp to 1–20000 Hz, so this cannot fail; `try?` keeps the
        // window from handling a validation error it cannot produce.
        try? engine.setFrequencies(leftHz: left, rightHz: right)
        if save, !isRestoring { scheduleSave() }
    }

    // MARK: - Transport

    @objc func togglePlayback() {
        if engine.isRunning {
            stopPlayback()
        } else if engine.start() {
            hideError()
            armTimer(at: Date())
        } else {
            showError(engine.error)
        }
        retranslate()
    }

    /// Stop, through the fade.
    ///
    /// One place for every stop — the button, the keyboard and the timer expiry all come
    /// through here, so none of them can grow its own cut-off. `AudioEngine.stop()`
    /// publishes a gain of zero **with** the ramp, which is SPEC §5 F5's "плавное
    /// затухание, чтобы остановка не была щелчком" and SPEC §2.1's smooth end of
    /// session: the amplitude slides to silence over `BeatMath.defaultRampSeconds`
    /// (30 ms, inside F2's 20–50 ms band) instead of being switched off, and the engine
    /// keeps running so the phase stays continuous for the next play.
    private func stopPlayback() {
        engine.stop()
        disarmTimer()
        hideError()
    }

    // MARK: - Timer (SPEC §5 F5)

    /// The user picked a duration in the popup.
    private func timerSelectionChanged(_ minutes: Int) {
        // Re-arming matters: a session that is already playing gets the new duration
        // from now, rather than keeping the countdown of the old one.
        if engine.isRunning {
            armTimer(at: Date())
        } else {
            showCountdown(at: Date())
        }
        if !isRestoring { scheduleSave() }
    }

    /// Arm the timer for the currently selected duration.
    ///
    /// `0` minutes is "off" (`Session.timerOff`): the countdown is hidden and nothing is
    /// scheduled, so "play until stopped" costs nothing.
    func armTimer(at now: Date) {
        playbackTimer = PlaybackTimer(minutes: timerView.selectedMinutes, startedAt: now)
        startTicking()
        showCountdown(at: now)
    }

    /// Stop counting. The selected duration stays as it is — only the countdown goes.
    func disarmTimer() {
        playbackTimer = .off
        countdownTicker?.invalidate()
        countdownTicker = nil
        timerView.updateCountdown("")
    }

    private func startTicking() {
        guard playbackTimer.isEnabled, countdownTicker == nil else { return }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTimer(at: Date()) }
        }
        // `.common` rather than `.default`: a menu being tracked runs the run loop in
        // `NSEventTrackingRunLoopMode`, and a timer registered only in the default mode
        // would freeze the countdown exactly while the user opens a menu to change it.
        RunLoop.main.add(ticker, forMode: .common)
        countdownTicker = ticker
    }

    /// One tick of the countdown.
    ///
    /// Split out with the time injected rather than reading the clock inline, so the
    /// expiry path is testable to the second instead of having to wait a minute for it.
    func tickTimer(at now: Date = Date()) {
        guard playbackTimer.isEnabled else { return }
        if playbackTimer.hasExpired(at: now) {
            stopPlayback()
            retranslate()
        } else {
            showCountdown(at: now)
        }
    }

    private func showCountdown(at now: Date) {
        timerView.updateCountdown(playbackTimer.countdownText(at: now))
    }

    @objc private func volumeMoved() {
        engine.volume = volumeSlider.doubleValue
        updateVolumeLabel()
        scheduleSave()
    }

    @objc private func muteToggled() {
        engine.isMuted = muteButton.state == .on
    }

    private func updateVolumeLabel() {
        volumeLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
    }

    // MARK: - Errors

    /// Show an engine failure, translated now rather than when it happened — the rule
    /// from `engine.py`'s `_ERROR_SOURCES`.
    private func showError(_ message: String?) {
        guard let message, !message.isEmpty else {
            hideError()
            return
        }
        errorLabel.stringValue = L10n.tr(message)
        errorLabel.isHidden = false
        errorLabel.setAccessibilityLabel(L10n.tr("Error"))
    }

    private func hideError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }

    // MARK: - Keyboard

    private func setActive(_ ear: FrequencyControlView.Ear) {
        activeEar = ear
        leftControl.setActive(ear == .left)
        rightControl.setActive(ear == .right)
    }

    private func toggleActiveChannel() {
        setActive(activeEar == .left ? .right : .left)
        switch activeEar {
        case .left: leftControl.focusField()
        case .right: rightControl.focusField()
        }
    }

    private func nudge(_ delta: Double) {
        switch activeEar {
        case .left: leftControl.nudge(delta)
        case .right: rightControl.nudge(delta)
        }
    }

    // MARK: - Language

    /// Re-read every visible string (SPEC §7.4). The window is built once and lives for
    /// the whole session, so captions cannot simply be re-created.
    func retranslate() {
        window?.title = L10n.tr("Binaural")
        leftControl.retranslate(caption: L10n.tr("LEFT EAR"), rangeHint: L10n.tr("1 – 20000 Hz"))
        rightControl.retranslate(caption: L10n.tr("RIGHT EAR"), rangeHint: L10n.tr("1 – 20000 Hz"))
        beatView.retranslate()
        indicator.retranslate()

        volumeCaptionLabel.stringValue = L10n.tr("Volume")
        volumeSlider.setAccessibilityLabel(L10n.tr("Volume"))
        volumeSlider.setAccessibilityHelp(
            L10n.tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )
        muteButton.title = L10n.tr("Mute")

        timerView.retranslate()
        // The popup captions are rebuilt by `retranslate()`, so the countdown has to be
        // re-pushed or a Russian switch would leave the label blank until the next tick.
        showCountdown(at: Date())

        let playing = engine.isRunning
        playButton.title = L10n.tr(playing ? "Stop" : "Play")
        playButton.setAccessibilityLabel(
            L10n.tr(playing ? "Stop the binaural tone" : "Play the binaural tone")
        )
        playButton.setAccessibilityHelp(
            L10n.tr("Starts or stops playback. The keyboard shortcut is Space.")
        )

        // Re-run the visible message through `tr`: it is still a catalogue key, and a
        // translated string simply comes back unchanged.
        showError(errorLabel.stringValue)
    }

    /// Stop observing the language and release the coalescing timer.
    func tearDown() {
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        saveTimer?.invalidate()
        saveTimer = nil
        disarmTimer()
    }

    // MARK: - Keyboard entry points

    // Called from `MainWindow`'s closures (SPEC §7: Space, ↑/↓, ←/→) and from the
    // menu items. They are the same operations the buttons and fields drive, so there is
    // one code path per action rather than two that can drift.

    func togglePlaybackFromKeyboard() { togglePlayback() }
    func nudgeFromKeyboard(_ delta: Double) { nudge(delta) }
    func switchChannelFromKeyboard() { toggleActiveChannel() }

    // MARK: - State the tests and the window agree on

    /// The window's own numbers, so an assertion does not have to reach into AppKit.
    ///
    /// Read-only on purpose: a test observes the window through the same values a user
    /// sees, and changes it through ``setFrequency(_:for:)`` and friends, which are the
    /// paths the controls themselves take.
    var displayedFrequencies: (left: Double, right: Double) {
        (leftControl.value, rightControl.value)
    }

    var displayedVolume: Double { volumeSlider.doubleValue }
    var isMuted: Bool { muteButton.state == .on }
    var isPlaying: Bool { engine.isRunning }

    var leftCaption: String { leftControl.caption }
    var beat: (hz: Double, carrier: Double) {
        (beatView.displayedBeatHz, beatView.displayedCarrierHz)
    }
    var isShowingBeatHint: Bool { beatView.isShowingHint }
    var beatHintText: String { beatView.hintText }
    var rightCaption: String { rightControl.caption }
    var playButtonTitle: String { playButton.title }
    var volumeCaptionTitle: String { volumeCaptionLabel.stringValue }
    var muteTitle: String { muteButton.title }
    var statusText: String { indicator.text }
    var statusToolTip: String { indicator.toolTip ?? "" }

    /// Drive the headphone indicator (SPEC §7). M2-b wires the CoreAudio heuristic and
    /// the perceptual L/R test to it.
    func setHeadphoneState(_ state: HeadphoneIndicatorView.State, deviceName: String? = nil) {
        indicator.setState(state, deviceName: deviceName)
    }

    /// Move one channel and notify the engine, as the text field and the slider do.
    func setFrequency(_ hz: Double, for ear: FrequencyControlView.Ear) {
        switch ear {
        case .left: leftControl.setValue(hz, notify: true)
        case .right: rightControl.setValue(hz, notify: true)
        }
    }

    func setVolume(_ level: Double) {
        volumeSlider.doubleValue = min(1, max(0, level))
        volumeMoved()
    }

    func setMuted(_ muted: Bool) {
        muteButton.state = muted ? .on : .off
        muteToggled()
    }

    // MARK: - Timer state the tests agree on

    /// The durations on offer, as captions — `Session.timerChoices` and nothing else,
    /// so "the timer offers the session's durations" is checkable rather than asserted
    /// in a comment.
    var timerChoiceTitles: [String] { timerView.choiceTitles }

    /// The selected duration in minutes, and the only place the window reads it from.
    var selectedTimerMinutes: Int { timerView.selectedMinutes }

    var countdownText: String { timerView.countdownText }
    var isShowingCountdown: Bool { timerView.isShowingCountdown }
    var timerCaptionTitle: String { timerView.captionTitle }

    /// Pick a duration as the popup would, so the rest of the timer reacts.
    func selectTimerMinutes(_ minutes: Int) {
        timerView.setMinutes(minutes)
        timerSelectionChanged(timerView.selectedMinutes)
    }
}

/// The window, with the shortcuts SPEC §7 puts on it.
///
/// Space toggles playback, `↑`/`↓` nudge the active channel by 0.1 Hz and `←`/`→` switch
/// channel. The window answers these itself instead of a menu item, because a menu key
/// equivalent cannot promise that a field the user is typing into keeps the same keys —
/// which is exactly what SPEC §7.2 ("полная клавиатурная навигация") and Python's
/// `_TEXT_INPUTS` check are about.
@MainActor
final class MainWindow: NSWindow {

    var onTogglePlayback: (() -> Void)?
    var onNudge: ((Double) -> Void)?
    var onSwitchChannel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty else { return false }

        // Space is a printable character, not a special key, so it is matched on the
        // character itself; the arrows come through `specialKey`.
        if event.charactersIgnoringModifiers == " " {
            // A focused text field keeps its space; anything else toggles.
            guard !(firstResponder is NSTextInput) else { return false }
            onTogglePlayback?()
            return true
        }

        switch event.specialKey {
        case .upArrow:
            onNudge?(FrequencyGrid.stepHz)
            return true
        case .downArrow:
            onNudge?(-FrequencyGrid.stepHz)
            return true
        case .leftArrow, .rightArrow:
            // A focused slider keeps its own arrows, the way the Python window lets a
            // focused spin box keep the identical 0.1 Hz step.
            guard !(firstResponder is NSSlider) else { return false }
            onSwitchChannel?()
            return true
        default:
            return false
        }
    }
}