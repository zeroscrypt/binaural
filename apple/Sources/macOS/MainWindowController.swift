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
    /// Transient note under the preset bar — Python's `statusBar().showMessage`, reused for
    /// the difference lock because the same "we just changed your state, here is why" message
    /// needs saying in both places.
    private let noticeLabel = NSTextField(labelWithString: "")
    private var noticeTimer: Timer?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// SPEC §5 F3: the two-level preset control, chips along the bottom of the window.
    private let presetBar = PresetBarView()
    /// Transient confirmation after a preset click — Python's
    /// `statusBar().showMessage(tr("Preset applied: difference %1 Hz", …), 3000)`.
    /// F3 asks the control to show "what came out"; the beat card already shows the
    /// numbers, so this says which preset was applied and then gets out of the way.
    private let presetStatusLabel = NSTextField(labelWithString: "")
    private var presetStatusTimer: Timer?

    /// SPEC §7: "кнопка проверки наушников прямо в окне — повторить §4 в любой момент, а
    /// не только при старте". It sits on the status row next to the always-visible
    /// indicator, so the warning and the way to re-check are in one place.
    private let headphoneCheckButton = NSButton()
    private var onHeadphoneCheckRequested: (() -> Void)?

    private var activeEar: FrequencyControlView.Ear = .left
    /// The preset category currently shown, written back into the session. Not read from
    /// `session` every time: the chips own the selection while the window lives, and the
    /// stored value is only what they started from.
    private var presetCategoryID: String
    /// Id of the preset that produced the frequencies on screen, `nil` when the user has
    /// moved a control since. Python's `apply_preset` also stores this in `last_preset`.
    private var lastPresetID: String?
    /// Written once, after the first successful `start()`, and on every change after.
    /// Never on the audio thread.
    private(set) var saves = 0
    private var saveTimer: Timer?
    private var languageObserver: (any NSObjectProtocol)?
    private var isRestoring = false

    /// SPEC §7's "Lock difference", off by default. The signed difference itself is
    /// **not** restored from the session: it is captured again from the pair the session
    /// restored, which is the same number by construction and cannot contradict it.
    private var differenceLock = DifferenceLock.unlocked

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
        let loaded = store.load()
        session = loaded
        // F3: an unknown or missing `preset_category` falls back to `relaxation` for the
        // chips, and the document keeps whatever it said (CONTRACT §7 allows any string).
        presetCategoryID = PresetCatalogue.resolvedCategoryID(loaded.presetCategory)
        lastPresetID = loaded.lastPreset
        // F5's "remember the state": the lock is restored, and the difference it holds is
        // captured again from the pair that was restored — which is the same number, and
        // cannot disagree with the two frequencies stored beside it.
        differenceLock = DifferenceLock(isLocked: loaded.differenceLocked)

        let window = MainWindow(
            // Tall enough for the preset block F3 adds below the timer: the window is
            // built once here, so the default frame has to cover every row rather than
            // scroll. Python's `setMinimumSize(720, 620)` is the same idea for the same
            // reason.
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 700)
        // The tray can hide and show this window, so closing it must not destroy it.
        // Without this, `close()` releases the controller and the status item's Show
        // command would have nothing to show.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

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
        headphoneCheckButton.target = self
        headphoneCheckButton.action = #selector(headphoneCheckTapped)
        headphoneCheckButton.bezelStyle = .rounded

        let statusRow = NSStackView(views: [indicator, NSView(), headphoneCheckButton])
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

        // SPEC §7's layout: presets are the last row of the window, below a stretch —
        // Python's `addStretch(1)` then `_build_presets()`. F3's chips are their own block
        // rather than part of the transport, so they keep the whole width.
        presetStatusLabel.font = .systemFont(ofSize: 11)
        presetStatusLabel.textColor = .secondaryLabelColor
        presetStatusLabel.isHidden = true

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.isHidden = true

        let presetBlock = NSStackView(views: [presetBar, presetStatusLabel, noticeLabel])
        presetBlock.orientation = .vertical
        presetBlock.alignment = .leading
        presetBlock.spacing = 6

        let stack = NSStackView(views: [
            statusRow, ears, beatView, transport, timerRow, presetBlock, errorLabel
        ])
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
        for row in [statusRow as NSView, ears, beatView, transport, timerRow,
                    presetBlock, errorLabel] {
            row.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        constraints += [
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            headphoneCheckButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ears.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            volumeSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            muteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            timerRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // SPEC §7.2: the preset chips keep their 44 px targets; the block itself only
            // has to be tall enough to hold both rows.
            presetBlock.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ]
        NSLayoutConstraint.activate(constraints)

        window?.contentView = content
    }

    private func connect() {
        // The lock is resolved in `frequencyEdited(_:)`, which has to know *which* control
        // moved: the difference is signed, so "the other channel" is not a fixed one.
        leftControl.onChange = { [weak self] _ in self?.frequencyEdited(.left) }
        rightControl.onChange = { [weak self] _ in self?.frequencyEdited(.right) }
        timerView.onSelectMinutes = { [weak self] minutes in self?.timerSelectionChanged(minutes) }
        // SPEC §5 F3: the category is *state* (it is persisted), so it is written back
        // like any other session field; the preset click is a pair of frequencies.
        presetBar.onCategorySelected = { [weak self] id in self?.presetCategoryChanged(id) }
        presetBar.onPresetSelected = { [weak self] preset in self?.applyPreset(preset) }
        beatView.onLockToggled = { [weak self] locked in self?.setDifferenceLocked(locked) }
    }

    // MARK: - Lock difference (SPEC §7)

    /// One control moved. This is the single seam every frequency path goes through — the
    /// slider, the exact-entry field, the `↑`/`↓` nudge and ``setFrequency(_:for:)`` all
    /// end up in `FrequencyControlView.setValue(_:notify: true)`, so the lock cannot be
    /// honoured by one route and quietly skipped by another.
    private func frequencyEdited(_ ear: FrequencyControlView.Ear) {
        guard !isRestoring else { return }
        let channel: DifferenceLock.Channel = ear == .left ? .left : .right
        let requested = ear == .left ? leftControl.value : rightControl.value

        guard let resolution = differenceLock.resolve(edited: channel, to: requested) else {
            // No lock, or no legal pair: the controls keep the value they already took.
            beatView.showBoundaryNote(nil)
            frequenciesChanged()
            return
        }
        // `notify: false` on both: the pair is one edit, not two. A follower pushed through
        // `onChange` would read the lock again and move the channel back.
        leftControl.setValue(resolution.leftHz, notify: false)
        rightControl.setValue(resolution.rightHz, notify: false)
        // The §F1 hint slot reports a refusal, so a slider that will not move further says
        // why instead of simply not moving. Cleared on the next accepted edit.
        beatView.showBoundaryNote(
            resolution.isAtBoundary
                ? L10n.tr(
                    "Stopped at the range limit: the difference is locked, so the other channel cannot follow any further."
                )
                : nil
        )
        frequenciesChanged()
    }

    /// Tick or clear the box, as a click does.
    func setDifferenceLocked(_ locked: Bool) {
        guard locked != differenceLock.isLocked else { return }
        if locked {
            // Capture, do not edit: whatever the difference is *now*, signed.
            differenceLock.capture(leftHz: leftControl.value, rightHz: rightControl.value)
        } else {
            // Unchecking only stops the following — the frequencies stay where they are.
            differenceLock.unlock()
            beatView.showBoundaryNote(nil)
        }
        beatView.setLocked(differenceLock.isLocked)
        scheduleSave()
    }

    /// Presets win (SPEC §5 F3: one click sets *both* frequencies to the preset's beat),
    /// so applying one turns the lock off rather than fighting it — and says so, because a
    /// checkbox that clears itself with no explanation looks like a bug.
    private func unlockDifferenceForPreset() {
        guard differenceLock.isLocked else { return }
        differenceLock.unlock()
        beatView.setLocked(false)
        beatView.showBoundaryNote(nil)
        showNotice(L10n.tr("Difference lock turned off — a preset set its own difference."))
    }

    /// Show a short note under the preset bar for three seconds, then get out of the way —
    /// Python's `statusBar().showMessage(…, 3000)`, which is where the preset message and the
    /// Python equivalent of the lock notice would both live.
    private var showingNotice: String?

    /// The English key behind the note on screen, kept so a language switch can translate it
    /// again — the window lives for the whole session, so its captions are re-read, not
    /// rebuilt (SPEC §7.4).
    var noticeKey: String? { showingNotice }

    private func showNotice(_ key: String) {
        showingNotice = key
        showNoticeNow(key)
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideNotice() }
        }
    }

    private func showNoticeNow(_ key: String) {
        noticeLabel.stringValue = L10n.tr(key)
        noticeLabel.isHidden = false
    }

    private func hideNotice() {
        noticeTimer?.invalidate()
        noticeTimer = nil
        showingNotice = nil
        noticeLabel.isHidden = true
    }

    // MARK: - Presets (SPEC §5 F3)

    /// The user picked another category. Nothing on screen moves — only which presets are
    /// offered — so this is a session write and nothing else.
    private func presetCategoryChanged(_ id: String) {
        // An unknown id from a hand-edited file degrades to the default (F3), so the
        // document and the chips cannot drift apart.
        presetCategoryID = PresetCatalogue.resolvedCategoryID(id)
        scheduleSave()
    }

    /// One click sets **both** channels so their difference is the preset's beat —
    /// `BeatMath.pair(fromBeat:carrier:)` around the default carrier, exactly as SPEC F3
    /// describes (`fL = 205, fR = 215 → 10 Hz`).
    private func applyPreset(_ preset: Preset) {
        guard let pair = try? PresetCatalogue.frequencies(for: preset) else {
            // `pair` rejects only what `FrequencyControlView` clamps away anyway; a
            // silent no-op would be dishonest, so it goes through the error path.
            showError(L10n.tr("Could not open the audio output device."))
            return
        }
        // `notify: false` on both: the pair is one edit, not two. The controls would
        // otherwise push an intermediate state in which the beat is half the preset's.
        // F3 wins: the preset owns the difference, so the lock lets go of it.
        unlockDifferenceForPreset()
        leftControl.setValue(pair.left, notify: false)
        rightControl.setValue(pair.right, notify: false)
        frequenciesChanged()

        // F3: "Показывает, что получилось" — the beat card carries the numbers, and this
        // names the preset that produced them, the way Python's status bar does.
        presetBar.markPreset(preset.id)
        // Stored the way Python stores it (`last_preset`), so the chip is highlighted
        // again on the next launch.
        lastPresetID = preset.id
        showPresetStatus(beatHz: preset.beatHz)
    }

    private func showPresetStatus(beatHz: Double) {
        presetStatusTimer?.invalidate()
        presetStatusLabel.stringValue = L10n.tr(
            "Preset applied: difference %1 Hz",
            FrequencyGrid.text(beatHz)
        )
        presetStatusLabel.isHidden = false
        // Three seconds, then out of the way — Python's `showMessage(…, 3000)`.
        presetStatusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePresetStatus() }
        }
    }

    private func hidePresetStatus() {
        presetStatusTimer?.invalidate()
        presetStatusTimer = nil
        presetStatusLabel.isHidden = true
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
        // The chips start on the stored category, and the stored preset is highlighted
        // when it belongs to that category — Python's `_restore_session` re-checks the
        // chip whose label the session remembers.
        presetBar.select(categoryID: presetCategoryID)
        presetBar.markPreset(lastPresetID)
        // SPEC §7's lock comes back ticked, and its difference is captured from the pair just
        // restored — the stored flag alone would say "locked" without saying *what* is locked.
        beatView.setLocked(differenceLock.isLocked)
        if differenceLock.isLocked {
            differenceLock.capture(leftHz: leftControl.value, rightHz: rightControl.value)
        }
        engine.volume = session.volume
        engine.isMuted = false
        // A stored swap is honoured on the very first push: §4.2 says the generator swaps
        // when generating, and "on the first push" includes the one made while restoring.
        channelsSwapped = session.channelsSwapped
        headphoneStateAcknowledged = session.headphoneCheckAcknowledged
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
            channelsSwapped: channelsSwapped,
            headphoneCheckAcknowledged: headphoneStateAcknowledged,
            lastPreset: lastPresetID,
            timerMinutes: timerView.selectedMinutes,
            presetCategory: presetCategoryID,
            differenceLocked: differenceLock.isLocked
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
        beatView.update(leftHz: leftControl.value, rightHz: rightControl.value)
        pushFrequencies()
        if save, !isRestoring { scheduleSave() }
    }

    /// Send the displayed pair to the engine, swapping the channels when the L/R test
    /// proved they are swapped (SPEC §4.2).
    ///
    /// Only the **generator** swaps. The window keeps showing the frequencies the user
    /// typed and the session keeps the unswapped pair, so the stored document means the
    /// same thing on any machine and the swap is applied here rather than being baked
    /// into the numbers — which is `HeadphoneDetector.swapChannels`'s whole reason for
    /// existing as a function.
    private func pushFrequencies() {
        publishPlaybackState()
        let pair = HeadphoneDetector.swapChannels(
            leftHz: leftControl.value,
            rightHz: rightControl.value,
            swapped: channelsSwapped
        )
        // The controls clamp to 1–20000 Hz, so this cannot fail; `try?` keeps the
        // window from handling a validation error it cannot produce.
        try? engine.setFrequencies(leftHz: pair.left, rightHz: pair.right)
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
        publishPlaybackState()
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

    // MARK: - Headphone check (SPEC §4, §7)

    @objc private func headphoneCheckTapped() {
        onHeadphoneCheckRequested?()
    }

    /// Who runs the check when the window's button is pressed. The app delegate installs
    /// this (it owns the coordinator); without it the button is inert, which is the state
    /// the window tests run in.
    func setHeadphoneCheckHandler(_ handler: @escaping () -> Void) {
        onHeadphoneCheckRequested = handler
    }

    /// Press the window's own check button, as a click would.
    func tapHeadphoneCheckButton() {
        headphoneCheckTapped()
    }

    /// The button as a view, so a host can place it somewhere other than the status row.
    var headphoneCheckControl: NSButton { headphoneCheckButton }

    /// Feed a report straight into the indicator — the coordinator's `Target` path.
    func apply(headphoneReport: HeadphoneReport) {
        indicator.apply(report: headphoneReport)
        noteHeadphoneReport(headphoneReport)
    }

    /// Remember which report the window is showing, without touching the indicator.
    private func noteHeadphoneReport(_ report: HeadphoneReport) {
        headphoneState = report
    }

    /// The report the indicator is currently showing.
    var currentHeadphoneReport: HeadphoneReport { headphoneState }

    // MARK: - Settings (SPEC §7)

    /// Build the Settings dialog wired to this window.
    ///
    /// A factory rather than four loose closures handed over by the app delegate: this is
    /// the **only** place where "Settings writes into the window" is decided, so the menu
    /// item and a test cannot end up with a dialog whose sliders move nothing.
    func makeSettingsDialog() -> SettingsDialogController {
        let dialog = SettingsDialogController(
            values: SettingsDialogController.Values(
                language: L10n.language,
                timerMinutes: timerView.selectedMinutes,
                volume: volumeSlider.doubleValue,
                headphoneReport: headphoneState
            )
        )
        dialog.onTimerChange = { [weak self] minutes in self?.selectTimerMinutes(minutes) }
        dialog.onVolumeChange = { [weak self] level in self?.setVolume(level) }
        dialog.onLanguageChange = { [weak self] _ in self?.saveNow() }
        dialog.onCheckHeadphones = { [weak self] in
            guard let self else { return }
            // The §4.3 dialog, not a second check: Settings offers the entry point.
            coordinator?.rerunFromUser()
            dialog.apply(headphoneReport: coordinator?.report ?? headphoneState)
        }
        settingsDialog = dialog
        return dialog
    }

    /// Kept so the Settings dialog cannot outlive the window it edits.
    private weak var settingsDialog: SettingsDialogController?

    // MARK: - Language

    /// Re-read every visible string (SPEC §7.4). The window is built once and lives for
    /// the whole session, so captions cannot simply be re-created.
    func retranslate() {
        window?.title = L10n.tr("Binaural")
        leftControl.retranslate(caption: L10n.tr("LEFT EAR"), rangeHint: L10n.tr("1 – 20000 Hz"))
        rightControl.retranslate(caption: L10n.tr("RIGHT EAR"), rangeHint: L10n.tr("1 – 20000 Hz"))
        beatView.retranslate()
        indicator.retranslate()
        // Both transient notes are catalogue keys, so a language switch must re-read the one
        // that is currently on screen rather than leaving it in the previous language.
        if let key = showingNotice { showNoticeNow(key) }
        if beatView.isShowingBoundaryNote {
            beatView.showBoundaryNote(L10n.tr(
                "Stopped at the range limit: the difference is locked, so the other channel cannot follow any further."
            ))
        }

        volumeCaptionLabel.stringValue = L10n.tr("Volume")
        volumeSlider.setAccessibilityLabel(L10n.tr("Volume"))
        volumeSlider.setAccessibilityHelp(
            L10n.tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )
        muteButton.title = L10n.tr("Mute")
        headphoneCheckButton.title = L10n.tr("Check headphones…")
        headphoneCheckButton.setAccessibilityLabel(L10n.tr("Check headphones…"))
        headphoneCheckButton.setAccessibilityHelp(
            L10n.tr("Re-reads the default audio output device and offers the L/R test.")
        )

        timerView.retranslate()
        // SPEC §7.4: the preset chips are data (F3's own EN/RU names), but the caption
        // and the chip help go through `tr`, so the whole bar is re-read here.
        presetBar.retranslate()
        if !presetStatusLabel.isHidden {
            let beat = presetBar.selectedPresetID
                .flatMap { id in PresetCatalogue.presets.first { $0.id == id }?.beatHz }
            if let beat { showPresetStatus(beatHz: beat) }
        }
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
        hidePresetStatus()
        hideNotice()
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

    // MARK: - Preset state the tests agree on (SPEC §5 F3)

    /// The preset bar as a view, so the tests can press the chips a user presses rather
    /// than reach past them into AppKit.
    var presetBarControl: PresetBarView { presetBar }

    /// The beat card, so a test can ask where the lock checkbox ended up.
    var beatCard: NSView { beatView }

    /// The category chips, as captions.
    var presetCategoryTitles: [String] { presetBar.categoryTitles }

    /// The preset chips of the selected category, as captions.
    var visiblePresetTitles: [String] { presetBar.visiblePresetTitles }

    /// The id of the highlighted preset chip, if any.
    var highlightedPresetID: String? { presetBar.selectedPresetID }

    /// The category currently shown.
    var selectedPresetCategory: String { presetCategoryID }

    // MARK: - Difference-lock state the tests agree on (SPEC §7)

    /// The lock as the checkbox shows it.
    var isDifferenceLocked: Bool { differenceLock.isLocked }

    /// The captured signed difference, `fR - fL`. Zero while the lock is off, because there
    /// is nothing captured to report then.
    var lockedDifferenceHz: Double { differenceLock.isLocked ? differenceLock.signedDifferenceHz : 0 }

    /// The checkbox itself, so a test presses the control a user presses.
    var differenceLockControl: NSButton { beatView.lockControl }

    /// The lock caption in the current language.
    var differenceLockTitle: String { beatView.lockControl.title }

    /// Tick or clear the box through its own action, as a click does.
    func tapDifferenceLock(_ locked: Bool) {
        beatView.lockControl.state = locked ? .on : .off
        setDifferenceLocked(locked)
    }

    /// True while the hint slot explains a boundary stop.
    var isShowingDifferenceBoundaryNote: Bool { beatView.isShowingBoundaryNote }

    /// The transient unlock note's English key, while it is on screen.
    var differenceNoticeKey: String? { noticeKey }

    /// The transient confirmation after a preset click, and whether it is showing.
    var presetStatusText: String { presetStatusLabel.stringValue }
    var isShowingPresetStatus: Bool { !presetStatusLabel.isHidden }

    /// Press the preset chip standing for `presetID`, optionally after switching to
    /// `categoryID` first.
    func tapPreset(_ presetID: String, inCategory categoryID: String? = nil) {
        if let categoryID { presetBar.select(categoryID: categoryID) }
        presetBar.tapPreset(id: presetID)
    }

    /// Press the category chip, so the write-back path runs the way a click runs it.
    func tapPresetCategory(_ categoryID: String) {
        presetBar.tapCategory(id: categoryID)
    }

    /// Pick a preset without going through the chips, for restoring state only.
    func selectPresetCategory(_ categoryID: String) {
        presetBar.select(categoryID: categoryID)
        presetCategoryChanged(categoryID)
    }

    /// Drive the headphone indicator (SPEC §7). M2-b wires the CoreAudio heuristic and
    /// the perceptual L/R test to it.
    func setHeadphoneState(_ state: HeadphoneIndicatorView.State, deviceName: String? = nil) {
        indicator.setState(state, deviceName: deviceName)
    }

    // MARK: - Headphone check (SPEC §4)

    /// The indicator and the session state the check talks to.
    ///
    /// A nested type rather than a class so it can hold the controller strongly while the
    /// coordinator holds it weakly, with no retain cycle through the window: the window
    /// owns the coordinator's target, and the coordinator owns nothing back. The `Target`
    /// protocol is main-actor isolated, so this one is too — no `assumeIsolated` hop.
    @MainActor
    private final class HeadphoneTarget: HeadphoneCheckCoordinator.Target {
        private unowned let controller: MainWindowController
        init(controller: MainWindowController) { self.controller = controller }

        func apply(headphoneReport report: HeadphoneReport) {
            controller.indicator.apply(report: report)
            controller.noteHeadphoneReport(report)
        }

        func persistHeadphoneState(acknowledged: Bool, channelsSwapped: Bool) {
            controller.recordHeadphoneState(
                acknowledged: acknowledged,
                channelsSwapped: channelsSwapped
            )
        }
    }

    private var headphoneState = HeadphoneReport.unknown

    /// Build the §4 coordinator. The window does not run it: the app delegate does, after
    /// the window is on screen (Python's order), so the check never covers an unpainted UI.
    func makeHeadphoneCoordinator() -> HeadphoneCheckCoordinator {
        // The coordinator holds its target **weakly**, so that a coordinator kept alive by
        // a menu item cannot keep a closed window alive. That only works if somebody else
        // owns the target: this is that somebody. Built inline it would be released
        // immediately and the check would silently do nothing at all.
        let target = HeadphoneTarget(controller: self)
        headphoneTarget = target
        let coordinator = HeadphoneCheckCoordinator(
            player: LRTonePlayer(engine: engine),
            target: target
        )
        self.coordinator = coordinator
        return coordinator
    }

    private var coordinator: HeadphoneCheckCoordinator?
    /// Strong owner of the coordinator's weak target — see ``makeHeadphoneCoordinator()``.
    private var headphoneTarget: HeadphoneTarget?

    /// Store the two session flags §4 decides, and re-push the frequencies so a swap takes
    /// effect immediately rather than at the next edit.
    ///
    /// `channelsSwapped` is a *generator* decision: the window keeps showing what the user
    /// asked for and the session keeps the unswapped numbers, so the stored document is
    /// readable without knowing the hardware (`HeadphoneDetector.swapChannels`'s rule).
    func recordHeadphoneState(acknowledged: Bool, channelsSwapped swapped: Bool) {
        headphoneStateAcknowledged = acknowledged
        channelsSwapped = swapped
        pushFrequencies()
        scheduleSave()
    }

    private var headphoneStateAcknowledged: Bool = false
    /// True when the L/R test proved the channels are swapped (SPEC §4.2).
    private var channelsSwapped = false

    /// The swap flag as the session records it.
    var isChannelsSwapped: Bool { channelsSwapped }

    /// Set **both** channels at once, the way a preset and the frequency reference do.
    ///
    /// Not `setFrequency(_:for:)` twice: with the difference locked, two single edits would
    /// be two follower moves and the second would undo the first. A named pair from outside
    /// the window (SPEC §6's *Apply*) is the same kind of instruction a preset is — "use
    /// these two frequencies" — so it wins and unlocks, with the same notice.
    func applyFrequencyPair(leftHz: Double, rightHz: Double) {
        unlockDifferenceForPreset()
        leftControl.setValue(leftHz, notify: false)
        rightControl.setValue(rightHz, notify: false)
        frequenciesChanged()
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

    // MARK: - Window visibility (the status item's job)

    /// Put the window on screen without going through the status item — the seam the tray
    /// tests need, since they are about the window's behaviour, not about AppKit activation.
    func showAndActivateForTests() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// Ask the window delegate's question the way AppKit would.
    func windowShouldCloseForTests(_ window: NSWindow) -> Bool {
        windowShouldClose(window)
    }

    /// Set by the app delegate: a status item exists, so closing must only hide.
    private var onWindowCloseRequested: (() -> Void)?
    func setWindowCloseHandler(_ handler: @escaping () -> Void) {
        onWindowCloseRequested = handler
    }

    /// Show the window, or hide it if it is already on screen.
    ///
    /// The status item's Show/Hide, and what the *Window* menu would do if it existed. The
    /// window is **ordered out**, never closed: it holds the session state, the running
    /// countdown and the audio engine's view of the world, and all three must survive the
    /// window being out of sight.
    func toggleWindowVisibility() {
        setWindowVisible(!isWindowOnScreen)
    }

    func setWindowVisible(_ visible: Bool) {
        if visible {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderOut(nil)
        }
        onVisibilityChanged?(visible)
    }

    var isWindowOnScreen: Bool { window?.isVisible ?? false }

    /// The status item and the *Window* menu follow the window.
    private var onVisibilityChanged: ((Bool) -> Void)?
    func setWindowVisibilityHandler(_ handler: @escaping (Bool) -> Void) {
        onVisibilityChanged = handler
    }

    /// Tell the status item what the transport and the frequencies are — Python's tray
    /// tooltip, from the window's own numbers.
    func setStatusItemHandler(_ handler: @escaping (Bool, Double, Double, Double) -> Void) {
        onPlaybackChanged = handler
    }

    private var onPlaybackChanged: ((Bool, Double, Double, Double) -> Void)?

    /// Push the current transport and frequencies to whoever is listening (the status item).
    private func publishPlaybackState() {
        guard let onPlaybackChanged else { return }
        let left = leftControl.value
        let right = rightControl.value
        onPlaybackChanged(
            engine.isRunning,
            left,
            right,
            BeatMath.beatFrequency(leftHz: left, rightHz: right)
        )
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

extension MainWindowController: NSWindowDelegate {

    /// Closing the window **hides** it.
    ///
    /// This is what makes the status item meaningful: with a tray item present the app keeps
    /// running (Python does `setQuitOnLastWindowClosed(False)` for exactly this reason), and
    /// a window that merely went away would leave no way back except the tray.
    /// `performClose` is `orderOut` plus `isReleasedWhenClosed = false`, so this hook is
    /// belt and braces — and it is also what keeps a stray close from tearing down the
    /// session state the tray is still reporting.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onWindowCloseRequested?()
        return false
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