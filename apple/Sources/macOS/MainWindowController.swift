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
    private let leftControl = FrequencyControlView(
        ear: .left,
        accent: ChannelPalette.left,
        accentText: ChannelPalette.leftText
    )
    private let rightControl = FrequencyControlView(
        ear: .right,
        accent: ChannelPalette.right,
        accentText: ChannelPalette.rightText
    )
    private let beatView = BeatDisplayView()
    private let playButton = PlayButton()
    /// The speaker next to the volume slider *is* the mute control: clicking it silences
    /// the sound, and the icon says so by being crossed out.
    ///
    /// It was a plain picture next to a second, separate mute control at the far end of
    /// the row — two controls for one thing, and the row longer for it. The state of
    /// the sound belongs on the icon that shows the sound.
    private let volumeIcon = NSButton()
    private let volumeSlider = NSSlider()
    private let volumeLabel = NSTextField(labelWithString: "")
    private var sidebarColumnView: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var rightColumnView: NSView?
    private var rightWidthConstraint: NSLayoutConstraint?
    private var resizeObserver: NSObjectProtocol?
    private let timerView = TimerControlView()
    /// The right-hand column's headphone card: its caption, its own speaker state and
    /// the check button, all fed the same facts the bottom status line gets, so the
    /// two views cannot disagree.
    private let headphoneCardCaption = NSTextField(labelWithString: "")
    private let sessionIndicator = HeadphoneIndicatorView()
    private let checkButton = NSButton(title: "", target: nil, action: nil)
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

    /// The header: the brand on the left, the navigation on the right.
    let headerRow = NSStackView()
    /// The preset block, kept as a property because the chakra mode takes its place: the
    /// two are alternative programs and only one of them is on screen at a time.
    private let presetBlock = NSStackView()

    /// The chakra mode: seven solfeggio steps, root to crown, advanced by a timer.
    ///
    /// Off by default. It is a program of its own — it sets both channels and keeps
    /// setting them — and a user who has not asked for it should get the plain
    /// frequency controls.
    private let chakraView = ChakraView()
    private var isChakraMode = false
    /// The step being played, as an index into `ChakraSequence.steps`.
    private var chakraStepIndex = 0
    /// The highest step the journey has reached. The marks below it stay lit on the way
    /// back down, because the body has been that high.
    private var chakraReachedIndex = 0
    /// The step the journey started from.
    private var chakraStartIndex = 0
    /// The steps the journey visits, in order.
    private var chakraJourney: [Int] = []
    /// When the current step began: the step's wave goes round the ring exactly once
    /// per step, so the picture says how much of the step is left.
    private var chakraStepStartedAt: Date?
    /// Whether the tones of the steps below the one being played keep sounding under
    /// it.
    private var sumsTones = false
    /// The step the session settles on and holds, or nil when it walks as it always did.
    ///
    /// The timer's length decides it when the choice is automatic: the longer the
    /// session, the higher up the body it settles. Without a timer there is no session
    /// to hold, and the journey walks up and back as it always has.
    private var heldStepIndex: Int? {
        if let chosen = chakraView.selectedHoldIndex { return chosen }
        let minutes = timerView.selectedMinutes
        guard minutes > 0 else { return nil }
        let choices = Session.timerChoices.filter { $0 > 0 }
        guard let position = choices.firstIndex(of: minutes) else { return nil }
        let count = ChakraSequence.steps.count
        let step = Int(
            (Double(position) / Double(max(1, choices.count - 1)) * Double(count - 1)).rounded()
        )
        return min(count - 1, max(0, step))
    }

    /// The user turned the accumulating tones on or off.
    private func chakraSumChanged(_ summing: Bool) {
        sumsTones = summing
        applyDrone()
    }

    /// The tones under the current step, when the mode sums them.
    ///
    /// The reference app accumulated the set: every step added its tone to the ones
    /// below it, and by the crown all of them sounded at once. Here the tones of the
    /// steps below the one being played stay under it — centred, so the beat, which is
    /// a difference between the two channels, is untouched by them.
    ///
    /// The amplitudes are scaled by the square root of the count, so the drone does not
    /// get louder as it grows: eight tones at half the amplitude sound like one tone.
    private func applyDrone() {
        guard sumsTones, isChakraMode else {
            engine.drone = []
            return
        }
        let tones = ChakraSequence.steps.prefix(chakraStepIndex).map(\.hz)
        guard !tones.isEmpty else {
            engine.drone = []
            return
        }
        let weight = 1.0 / Double(tones.count).squareRoot()
        engine.drone = tones.map { DroneTone(hz: $0, gain: weight) }
    }

    /// The user chose which step the session holds, or left it to the timer.
    private func chakraHoldChanged() {
        guard isChakraMode else { return }
        startChakraJourney(from: chakraJourneyIndices.first ?? chakraStepIndex)
    }
    /// How far along the journey we are.
    private var chakraJourneyPosition = 0
    /// Advances the sequence. `nil` whenever the mode is off, so an idle window
    /// schedules nothing at all.
    private var chakraTimer: Timer?
    /// The mode's switch, on the status row next to the headphone check.
    /// The mode's trigger: a button that selects the mode.
    ///
    /// It was a checkbox, and a box you untick to leave a mode is not an obvious way
    /// to say "off" — unticking is a gesture to be guessed. So the button is a button:
    /// pressing it turns the mode on and pressing it again turns it off.
    private let chakraButton = NSButton()
    /// The language switch in the header: RU and EN, side by side.
    private let languageControl = NSSegmentedControl()
    /// The brand, in the header's left corner.
    private let brandMark = BrandMark()
    private let brandName = NSTextField(labelWithString: "Binaural")
    private let brandTagline = NSTextField(labelWithString: "")
    /// The navigation, in the header's right corner.
    private let referenceButton = NSButton()
    /// The two frequency cards with the beat between them.
    private let frequencyRow = NSStackView()
    /// The theme switch in the header: the moon.
    private let themeControl = NSSegmentedControl()
    /// The one-line audio-session status, in the header the way the mock-up shows it.
    private let sessionStatusLabel = NSTextField(labelWithString: "")
    /// The quick way to the full preset library.
    private let presetsHeaderButton = NSButton(title: "", target: nil, action: nil)
    /// The catalogue down the left: the preset categories.
    private let categorySidebar = CategorySidebarView()
    /// The sidebar's search: by text among all the presets, in whatever column it shows.
    private let presetSearchField = NSSearchField()
    /// The presets, as cards.
    let presetCards = PresetCardsView()
    /// The full preset library, in a window of its own.
    private lazy var presetLibraryController = PresetLibraryController(owner: self)
    /// The mode's own switch: ticked while the mode is on, and unticking it is the
    /// explicit way out.
    private let chakraModeCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// The overflow menu in the top corner.
    ///
    /// The headphone check, the frequency reference and the language used to be two
    /// buttons and a popup in the top row, which spent the row's width on three things a
    /// user reaches for once and then rarely. One icon in the corner is quieter, and it
    /// leaves the row to say what the app is *doing* rather than what it can be asked to
    /// do. Native names in both languages ("English", "Русский"), so a user can always
    /// find their own language in the list.
    private let menuButton = MenuButton()
    private let overflowMenu = NSMenu()
    private let overflowLanguageItem = NSMenuItem()
    private let overflowLanguageMenu = NSMenu()
    /// The top row, kept so a test can read what is on it.
    private var statusRowView: NSView?

    /// SPEC §7: "кнопка проверки наушников прямо в окне — повторить §4 в любой момент, а
    /// не только при старте". It lives in the overflow menu now, but it is still *in the
    /// window*, which is what the rule asks for.
    private var onHeadphoneCheckRequested: (() -> Void)?
    /// The frequency reference, opened from the same menu.
    private var onReferenceRequested: (() -> Void)?

    private var activeEar: FrequencyControlView.Ear = .left
    /// The preset category currently shown, written back into the session. Not read from
    /// `session` every time: the chips own the selection while the window lives, and the
    /// stored value is only what they started from.
    private var presetCategoryID: String
    /// Id of the preset that produced the frequencies on screen, `nil` when the user has
    /// moved a control since. Python's `apply_preset` also stores this in `last_preset`.
    var lastPresetID: String?
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
        // The release the user skipped, restored like every other setting.
        skippedUpdateVersion = loaded.skippedUpdateVersion

        let window = MainWindow(
            // Tall enough for the preset block F3 adds below the timer: the window is
            // built once here, so the default frame has to cover every row rather than
            // scroll. Python's `setMinimumSize(720, 620)` is the same idea for the same
            // reason.
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The minimum sits below both compactness thresholds — the collapse is
        // something a real window reaches — and its height is the content's own
        // measured least (the session column's cards set it), not an invented round
        // number the layout would have to ignore.
        window.minSize = NSSize(width: 800, height: 600)
        // The title is not shown. macOS 26 draws the window's title as a floating glass
        // plate above the traffic lights, and a plate that only repeats the app's name
        // is a plate that says nothing — the row underneath it says what the app wants
        // the reader to know. The title is still set, because the menu and the About
        // window read it.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
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
            window.onPrepareResize = { [weak self] width in
                let target = MainWindowController.self
                self?.setCompactness(
                    hideSidebar: width < target.sidebarCollapseWidth,
                    hideRight: width < target.rightCollapseWidth
                )
            }
        }
        // The narrow-window answer: the columns leave in the order the mock-up's
        // hierarchy puts them — the catalogue first, then the session column — and the
        // frequencies with their readouts always stay.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyWindowCompactness() }
        }
        applyWindowCompactness()
        // The theme follows the stored three-state choice; `nil` means the system.
        applyThemeStyle()
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
        // The overflow button. An SF Symbol rather than a drawn glyph: it is the same
        // icon the system uses for "more", so it reads without a caption.
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: L10n.tr("More")
        )
        menuButton.bezelStyle = .accessoryBarAction
        menuButton.menu = overflowMenu
        // An image button, so no caption. The default title is "Button", which VoiceOver
        // would read aloud before the accessibility label.
        menuButton.title = ""
        menuButton.setAccessibilityLabel(L10n.tr("More"))

        // The mode's switch. It is a toggle because it is a state, and it sits on the
        // status row next to the overflow menu: both are things a user reaches for when
        // they want to change how the app behaves.
        chakraButton.target = self
        chakraButton.action = #selector(toggleChakraMode)
        chakraButton.bezelStyle = .rounded
        // A trigger, not a latch: the button does not hold a state of its own, and the
        // checkbox beside it is what says which way round the mode is.
        chakraButton.setButtonType(.momentaryPushIn)

        chakraModeCheckbox.target = self
        chakraModeCheckbox.action = #selector(chakraModeSwitched)
        chakraModeCheckbox.font = .systemFont(ofSize: 13)

        // The status line: what the app wants the reader to know right now, in the
        // colour the state deserves.
        //
        // It sits at the **bottom**, in a strip of its own, the way a status bar does —
        // and the way the Qt window already does it, where the indicator is a permanent
        // widget of the `QStatusBar`. The top row is then only the mode's switch and the
        // corner menu: what the app can be *asked* to do, with the top of the window
        // given over to that, and the bottom to what it is *doing*.
        let statusLine = NSStackView(views: [indicator])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 0
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        let statusBarSeparator = NSBox()
        statusBarSeparator.boxType = .separator
        statusBarSeparator.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSStackView(views: [statusBarSeparator, statusLine])
        statusBar.orientation = .vertical
        statusBar.alignment = .leading
        statusBar.spacing = 0
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        // The header: the brand on the left, the navigation on the right. The mock-up
        // puts them in the title bar, and it is right to: a title bar is the one strip
        // of a window that is always about the application rather than about what is
        // in it, and the things worth reaching for — the reference, the settings, the
        // language, the theme — are about the application.
        brandName.font = .systemFont(ofSize: 17, weight: .semibold)
        brandMark.widthAnchor.constraint(equalToConstant: 30).isActive = true
        brandMark.heightAnchor.constraint(equalToConstant: 22).isActive = true
        brandTagline.font = .systemFont(ofSize: 11)
        brandTagline.textColor = .secondaryLabelColor
        brandMark.strokeColor = .controlAccentColor
        let brandText = NSStackView(views: [brandName, brandTagline])
        brandText.orientation = .vertical
        brandText.alignment = .leading
        brandText.spacing = 0
        let brand = NSStackView(views: [brandMark, brandText])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 8
        brand.orientation = .vertical
        brand.alignment = .leading
        brand.spacing = 0

        referenceButton.title = L10n.tr("Reference")
        referenceButton.target = self
        referenceButton.action = #selector(referenceTapped)
        referenceButton.bezelStyle = .inline
        referenceButton.isBordered = false
        referenceButton.font = .systemFont(ofSize: 13)
        referenceButton.contentTintColor = .secondaryLabelColor

        languageControl.segmentStyle = .rounded
        languageControl.trackingMode = .selectOne
        languageControl.target = self
        languageControl.action = #selector(languageSegmentChanged)
        languageControl.font = .systemFont(ofSize: 12)
        languageControl.segmentCount = L10n.languages.count
        for (index, code) in L10n.languages.enumerated() {
            languageControl.setLabel(code.rawValue.uppercased(), forSegment: index)
        }

        // The theme is one control with the three states the shared task names: light,
        // whatever the system says, and dark. The pictures are not self-explanatory in
        // isolation, so every segment also carries an accessibility label.
        themeControl.segmentCount = Self.themeSymbols.count
        themeControl.segmentStyle = .roundRect
        themeControl.controlSize = .regular
        themeControl.target = self
        themeControl.action = #selector(themeChosen(_:))
        themeControl.setAccessibilityLabel(L10n.tr("Theme"))
        themeControl.setAccessibilityHelp(
            L10n.tr("Switches between the light and the dark theme.")
        )
        for (index, symbol) in Self.themeSymbols.enumerated() {
            themeControl.setImage(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                forSegment: index
            )
        }
        themeControl.setSelected(
            true, forSegment: Self.segment(for: themeStyle)
        )

        sessionStatusLabel.font = .systemFont(ofSize: 11)
        sessionStatusLabel.textColor = .secondaryLabelColor

        presetsHeaderButton.bezelStyle = .accessoryBarAction
        presetsHeaderButton.controlSize = .regular
        presetsHeaderButton.target = self
        presetsHeaderButton.action = #selector(showPresetLibrary)
        presetsHeaderButton.title = L10n.tr("All presets")
        presetsHeaderButton.image = NSImage(
            systemSymbolName: "square.on.square.dashed", accessibilityDescription: nil
        )
        presetsHeaderButton.imagePosition = .imageLeading
        presetsHeaderButton.setAccessibilityLabel(L10n.tr("All presets"))
        presetsHeaderButton.setAccessibilityHelp(L10n.tr("All presets"))  // placeholder help until retranslate()

        let header = headerRow
        for view in [
            brand, sessionStatusLabel, NSView(), presetsHeaderButton,
            referenceButton, languageControl, themeControl, menuButton
        ] {
            header.addArrangedSubview(view)
        }
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        // The traffic lights sit on the left of the title bar, and the bar is
        // transparent, so the brand has to leave room for them.
        header.edgeInsets = NSEdgeInsets(top: 8, left: 78, bottom: 8, right: 0)
        header.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [
            chakraButton, chakraModeCheckbox
        ])
        statusRowView = statusRow
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let ears = NSStackView(views: [leftControl, rightControl])
        ears.orientation = .horizontal
        ears.distribution = .fillEqually
        ears.spacing = 16

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        // The button draws the disc itself, so it has no bezel and no image.
        playButton.isBordered = false
        playButton.title = ""
        // The button is a picture, not a word: a play/pause pair is read instantly and
        // takes no room, and a button that says "Stop" while it plays is a sentence to
        // parse. The word is still there for VoiceOver.
        playButton.title = ""
        playButton.setButtonType(.momentaryChange)

        volumeIcon.isBordered = false
        volumeIcon.imagePosition = .imageOnly
        volumeIcon.imageScaling = .scaleProportionallyDown
        volumeIcon.contentTintColor = .secondaryLabelColor
        volumeIcon.target = self
        volumeIcon.action = #selector(muteToggled)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved)

        volumeLabel.font = .systemFont(ofSize: 13)
        volumeLabel.textColor = .secondaryLabelColor
        volumeLabel.alignment = .right

        // The timer has moved to the right-hand column, where the layout shows it as
        // a card of its own; the transport row is the sound itself. `NSView()` at the
        // end is the `addStretch` of the Python transport row: the controls sit at the
        // left and the row's slack goes to the right.
        let transport = NSStackView(views: [
            playButton, volumeIcon, volumeSlider, volumeLabel, NSView()
        ])
        transport.orientation = .horizontal
        transport.alignment = .centerY
        transport.spacing = 12

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        // SPEC §7's layout: presets are the last row of the window, below a stretch —
        // Python's `addStretch(1)` then `_build_presets()`. F3's chips are their own block
        // rather than part of the transport, so they keep the whole width.
        presetStatusLabel.font = .systemFont(ofSize: 11)
        presetStatusLabel.textColor = .secondaryLabelColor
        presetStatusLabel.isHidden = true

        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.isHidden = true

        presetBlock.addArrangedSubview(presetBar)
        // The chips are hidden: the cards say the same thing with a picture, and the
        // two together would say it twice. The bar is still there, because the tests
        // drive it and because it knows how to mark a preset.
        presetBar.isHidden = true
        presetBlock.addArrangedSubview(presetStatusLabel)
        presetBlock.addArrangedSubview(noticeLabel)
        presetBlock.orientation = .vertical
        presetBlock.alignment = .leading
        presetBlock.spacing = 6
        // The chips live in the panel's first tab: they set the frequencies, so they
        // belong with what is playing.
        chakraView.presetSlot.addArrangedSubview(presetBlock)
        // The catalogue down the left: the mode's switch and the preset categories.
        presetSearchField.placeholderString = L10n.tr("Search presets…")
        presetSearchField.font = .systemFont(ofSize: 12)
        presetSearchField.translatesAutoresizingMaskIntoConstraints = false
        presetSearchField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        presetSearchField.delegate = self

        let sidebar = NSStackView(views: [statusRow, presetSearchField, categorySidebar])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 12
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // The middle: the two channels with the beat between them, the transport, and
        // the presets. The beat belongs between the two cards, because the beat *is*
        // the difference between them, and the mock-up is right about that: the
        // number in the middle is the one the two numbers on the sides produce.
        frequencyRow.addArrangedSubview(leftControl)
        frequencyRow.addArrangedSubview(beatView)
        frequencyRow.addArrangedSubview(rightControl)
        frequencyRow.orientation = .horizontal
        frequencyRow.alignment = .top
        frequencyRow.spacing = 16
        frequencyRow.translatesAutoresizingMaskIntoConstraints = false

        // The mode takes the middle: the panel sits where the frequency cards are, so
        // switching to the mode replaces them rather than being added below them.
        // The presets as cards, the way the mock-up shows them: a colour, an icon and
        // the range of beats. The chips they replace are still there, because they are
        // what the tests drive, and they are hidden.
        presetCards.onPick = { [weak self] id in self?.presetPicked(id) }
        presetLibraryController.retranslate()
        let presetsBlock = NSStackView(views: [
            NSTextField(labelWithString: L10n.tr("Presets")), presetCards, presetBlock
        ])
        presetsBlock.orientation = .vertical
        presetsBlock.alignment = .leading
        presetsBlock.spacing = 8
        presetsBlock.translatesAutoresizingMaskIntoConstraints = false

        let centre = NSStackView(views: [
            frequencyRow, chakraView, transport, presetsBlock
        ])
        centre.orientation = .vertical
        centre.alignment = .leading
        centre.spacing = 16
        centre.translatesAutoresizingMaskIntoConstraints = false

        // The right: the session, on cards, the way the hand-drawn layout puts it.
        // The timer says how long it lasts; the headphone card says whether it can be
        // heard at all, with the state the checks have concluded so far on its face.
        headphoneCardCaption.font = .systemFont(ofSize: 12, weight: .semibold)
        headphoneCardCaption.textColor = .secondaryLabelColor
        headphoneCardCaption.alignment = .left
        checkButton.title = L10n.tr("Check headphones…")
        checkButton.target = self
        checkButton.action = #selector(headphoneCheckTapped)
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .regular
        checkButton.translatesAutoresizingMaskIntoConstraints = false

        let headphoneContent = NSStackView(views: [
            headphoneCardCaption, sessionIndicator, checkButton
        ])
        headphoneContent.orientation = .vertical
        headphoneContent.alignment = .leading
        headphoneContent.spacing = 8
        headphoneContent.translatesAutoresizingMaskIntoConstraints = false
        let timerCard = CardBox(content: timerView, padding: 12)
        let headphoneCard = CardBox(content: headphoneContent, padding: 12)
        // A plain view with hand-set anchors rather than a stack: a vertical stack
        // stretches its cards to whatever height the column is given, and a card twice
        // as tall as its content is a lie about what is in it.
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(timerCard)
        right.addSubview(headphoneCard)
        NSLayoutConstraint.activate([
            timerCard.topAnchor.constraint(equalTo: right.topAnchor),
            timerCard.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            timerCard.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            headphoneCard.topAnchor.constraint(equalTo: timerCard.bottomAnchor, constant: 12),
            headphoneCard.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            headphoneCard.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            headphoneCard.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            checkButton.widthAnchor.constraint(equalTo: headphoneContent.widthAnchor)
        ])

        sidebarColumnView = sidebar
        rightColumnView = right
        let body = NSStackView(views: [sidebar, centre, right])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 24
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, body, errorLabel, statusBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)

        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            // Content hugs the top; the window may be taller than it needs to be.
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // The catalogue and the session are fixed columns; the middle takes what is
            // left, which is where the frequencies and the mode live.
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            right.widthAnchor.constraint(equalToConstant: 260),
            timerCard.widthAnchor.constraint(equalTo: right.widthAnchor),
            headphoneCard.widthAnchor.constraint(equalTo: right.widthAnchor),
            frequencyRow.widthAnchor.constraint(lessThanOrEqualTo: centre.widthAnchor),
            // The beat is the difference between the two numbers beside it, so it is a
            // column of its own rather than a panel that takes the room they need. It
            // prefers its full 320 pt and yields down to 240 before anything else in the
            // centre does — the numbers themselves never shrink.
                        withPriority(.init(900), beatView.widthAnchor.constraint(lessThanOrEqualToConstant: 320)),
            beatView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            chakraView.widthAnchor.constraint(equalTo: centre.widthAnchor),
            presetBlock.widthAnchor.constraint(equalTo: centre.widthAnchor),
            presetsBlock.widthAnchor.constraint(equalTo: centre.widthAnchor),
            transport.widthAnchor.constraint(equalTo: centre.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ]
        constraints += [
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            statusBarSeparator.heightAnchor.constraint(equalToConstant: 1),
            statusLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            menuButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            menuButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ears.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            // The button is a picture, so it is as wide as the picture: a fixed 120 pt
            // was a wide empty box around a 17 pt glyph. SPEC §7.2's 44 px target is
            // still met, and the button now fits what it shows.
            // The disc is the size the mock-up shows: big enough to be the thing the
            // eye lands on, and a circle rather than a rectangle.
            playButton.widthAnchor.constraint(equalToConstant: 56),
            playButton.heightAnchor.constraint(equalToConstant: 56),
            volumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            volumeSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // The mute control is a small glyph, but it is a control: the click target
            // is SPEC 7.2's 44 px on both sides.
            volumeIcon.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            volumeIcon.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // SPEC §7.2: the preset chips keep their 44 px targets; the block itself only
            // has to be tall enough to hold both rows.
            presetBlock.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            // The figure is 190 pt tall; the block has to hold it.
            chakraView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            chakraButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            chakraModeCheckbox.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ]
        // The columns' own widths are the constraints that pin the window's least
        // width, so the collapse keeps a hold of them: hiding a view does not
        // deactivate anything, a stopped constraint does.
        sidebarWidthConstraint = constraints.first {
            ($0.firstItem as? NSView) == sidebar && $0.firstAttribute == .width
        }
        rightWidthConstraint = constraints.first {
            ($0.firstItem as? NSView) == right && $0.firstAttribute == .width
        }
        NSLayoutConstraint.activate(constraints)

        window?.contentView = content
        rebuildOverflowMenu()
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
        chakraView.onStepSecondsChange = { [weak self] seconds in
            self?.chakraStepSecondsChanged(seconds)
        }
        chakraView.onDirectionChange = { [weak self] direction in
            self?.chakraDirectionChanged(direction)
        }
        chakraView.onBeatChange = { [weak self] beatHz in self?.chakraBeatChanged(beatHz) }
        chakraView.onChakraPicked = { [weak self] index in self?.chakraPicked(index) }
        chakraView.onHoldChange = { [weak self] _ in self?.chakraHoldChanged() }
        chakraView.onSumChange = { [weak self] summing in self?.chakraSumChanged(summing) }
        // The catalogue on the left drives the same chips as before: choosing a
        // category here is choosing a category there.
        categorySidebar.onSelect = { [weak self] id in
            guard let self else { return }
            self.presetBar.select(categoryID: id ?? "")
            self.categorySidebar.select(categoryID: id)
        }
    }

    // MARK: - The chakra mode

    @objc private func toggleChakraMode() {
        setChakraMode(!isChakraMode)
    }

    /// The user ticked or unticked the mode's switch.
    @objc private func chakraModeSwitched() {
        guard !isSyncingChakraCheckbox else { return }
        setChakraMode(chakraModeCheckbox.state == .on)
    }

    /// Set while the code writes the checkbox, so the write is not read back as the
    /// user's own change and answered with another write.
    private var isSyncingChakraCheckbox = false

    /// The switch's own on-state is not enough on its own: a rounded toggle in the
    /// modern macOS style differs by a hairline, and the mode changes the whole lower
    /// half of the window — the switch has to keep up with that. The fill is drawn here,
    /// the same way the preset chips carry their selection.
    private func updateChakraButtonAppearance() {
        let on = isChakraMode
        chakraButton.wantsLayer = true
        chakraButton.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : nil
        chakraButton.layer?.cornerRadius = 6
        chakraButton.contentTintColor = on ? .white : .labelColor
        chakraButton.needsDisplay = true
    }

    /// Turn the mode on or off.
    ///
    /// The two are alternatives, not additions: the mode sets both channels and keeps
    /// setting them, and a preset click would be overwritten by the next step. So the
    /// preset bar is hidden while the mode is on, and the switch is the way back.
    /// - Parameter startSound: whether turning the mode on also starts the playback.
    ///   It does not, by default. The mode is a *program* the user steps into, and the
    ///   app is a sound app: starting to make noise is the Play button's job, and a
    ///   button that starts playing on its own is a button that can surprise someone.
    ///   Picking a particular chakra on the figure does not start it either — choosing
    ///   where the walk begins is not the same thing as asking for a sound.
    func setChakraMode(_ enabled: Bool, startSound: Bool = false) {
        guard enabled != isChakraMode else { return }
        isChakraMode = enabled
        // The checkbox is the mode's state; the button is only the way in and out.
        isSyncingChakraCheckbox = true
        chakraModeCheckbox.state = enabled ? .on : .off
        isSyncingChakraCheckbox = false
        updateChakraButtonAppearance()
        // The panel is the app's face: the figure and its aura are always there, and
        // the mode only changes what is written beside them. The presets are the one
        // thing the mode takes away — it owns both frequencies while it runs.
        presetBlock.isHidden = enabled
        // The mode takes the middle of the window: the figure, its aura and the tabs
        // are what the mode is about, and the two frequency cards would be saying the
        // same thing twice.
        frequencyRow.isHidden = enabled
        // The panel is the mode's face: outside the mode the middle of the window is
        // the two frequencies, and the figure and the aura come with the mode.
        chakraView.isHidden = !enabled
        applyDrone()
        // The tab follows the mode: the step being played while the journey runs, and
        // the chips that choose a pair when it does not.
        chakraView.selectTab(enabled ? 0 : 3)
        // The cocoon only exists while the mode does, so it is told about the sound
        // again here: turning the mode on while the sound is already running has to
        // bring it to life, and turning it off has to let it go quiet.
        chakraView.setPlaying(isPlaybackRunning)
        if enabled {
            // The mode owns both channels, so a locked difference would fight it.
            if differenceLock.isLocked {
                differenceLock.unlock()
                beatView.setLocked(false)
                beatView.showBoundaryNote(nil)
            }
            startChakraJourney(from: ChakraSequence.defaultStart(for: chakraView.selectedDirection))
            // The mode makes the sound itself. A journey that walked on with the
            // playback stopped was a light show on a timer, and the step on screen had
            // nothing to do with what the ear heard.
            if startSound {
                startChakraPlayback()
            }
        } else {
            stopChakraTimer()
        }
    }

    /// Whether the mode is on. The tests read it; the button's own state is the
    /// on-screen truth.
    var isChakraModeActive: Bool { isChakraMode }

    /// Whether the sound is playing.
    ///
    /// The journey only moves while it is, and the mode starts the sound itself. A unit
    /// test has no audio device to play through, so the answer comes from a seam the
    /// tests can set rather than from the engine.
    var isPlaybackRunning: Bool {
        if let forced = playbackRunningOverride { return forced }
        return engine.isRunning
    }

    /// The tests' answer to "is the sound playing". `nil` means "ask the engine".
    var playbackRunningOverride: Bool?

    /// Choose a step to play from, as a click on the figure or on its button does.
    func pickChakraForTests(_ index: Int) {
        chakraPicked(index)
    }

    /// The step being played, for the tests and the status line.
    var currentChakraStepID: String? {
        isChakraMode ? ChakraSequence.steps[chakraStepIndex].id : nil
    }

    /// The step the journey is on, and how many steps it has visited.
    var currentChakraStepIndex: Int { chakraStepIndex }

    /// The steps a journey visits, in order — the tests read it to check the walk.
    var chakraJourneyIndices: [Int] { chakraJourney }

    /// Begin a journey at `start`.
    ///
    /// The journey goes from one end of the body to the other and back, and the mode
    /// switches itself off when it is over.
    private func startChakraJourney(from start: Int) {
        chakraStartIndex = ChakraSequence.index(of: start)
        chakraJourney = ChakraSequence.journey(
            from: chakraStartIndex,
            direction: chakraView.selectedDirection
        )
        if let held = heldStepIndex,
           let position = chakraJourney.firstIndex(of: held) {
            // The journey stops at the step it holds and stays there: the session's
            // timer decides how long that is.
            chakraJourney = Array(chakraJourney[0...position])
        }
        chakraJourneyPosition = 0
        // The lit marks are the ones the journey has reached: they stay lit on the way
        // back down, because the body has been that high.
        chakraReachedIndex = chakraStartIndex
        applyChakraStep()
        startChakraTimer()
    }

    /// Advance to the next step of the journey.
    ///
    /// The journey only moves while there is sound. It used to walk on a timer whatever
    /// the playback was doing, so the chakras on screen changed in silence — a light
    /// show with no music under it.
    private func advanceChakraStep() {
        guard isPlaybackRunning else { return }
        chakraJourneyPosition += 1
        if chakraJourneyPosition >= chakraJourney.count {
            // The journey is over. The mode switches itself off and the sound stops
            // with it — the journey was the reason for the sound — unless the session
            // is holding a step, in which case it stays there and the session's timer
            // ends it.
            stopChakraTimer()
            if heldStepIndex == nil {
                setChakraMode(false)
                stopPlayback()
                return
            }
            chakraJourneyPosition = chakraJourney.count - 1
            applyChakraStep()
            return
        }
        applyChakraStep()
    }

    /// Put the current step's pair on the two channels and show it.
    ///
    /// `notify: false` on both: the pair is one edit, not two, and the difference lock
    /// is not consulted — the mode has already decided what the difference is.
    private func applyChakraStep() {
        let index = chakraJourney.isEmpty
            ? chakraStartIndex
            : chakraJourney[min(chakraJourneyPosition, chakraJourney.count - 1)]
        chakraStepIndex = index
        chakraReachedIndex = max(chakraReachedIndex, index)

        let step = ChakraSequence.steps[index]
        let (left, right) = ChakraSequence.pair(for: step, beatHz: chakraView.selectedBeatHz)
        chakraStepStartedAt = Date()
        leftControl.setValue(left, notify: false)
        rightControl.setValue(right, notify: false)
        chakraView.show(step: step, index: index, reachedIndex: chakraReachedIndex)
        chakraView.setWaveTint(ChakraPalette.brightColor(forStepIndex: index))
        applyDrone()
        pushWaves()
        frequenciesChanged()
    }

    /// How many times the mode asked for the sound to start. The tests read it: a test
    /// has no audio device, and "the mode asked for a sound" is the thing worth
    /// checking, not "a sound came out".
    private(set) var chakraPlaybackRequests = 0

    /// Start the sound if it is not playing already.
    private func startChakraPlayback() {
        chakraPlaybackRequests += 1
        // The tests answer for themselves; there is no device to open.
        guard playbackRunningOverride == nil else { return }
        guard !engine.isRunning else { return }
        if engine.start() {
            armTimer(at: Date())
        } else {
            showError(engine.error)
        }
    }

    private func startChakraTimer() {
        stopChakraTimer()
        // The step length is the switch timer the user chose; the journey's total
        // follows from it and the number of steps.
        let interval = max(0.5, Double(chakraView.selectedStepSeconds))
        chakraTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceChakraStep() }
        }
    }

    /// Tell the panel what the waves are doing: the beat, the step, and when the step
    /// began. The same three numbers drive the aura on the figure and the scheme of the
    /// waves beside it, so the picture and its explanation cannot disagree.
    private func pushWaves() {
        chakraView.setWaves(
            beatHz: chakraView.selectedBeatHz,
            stepSeconds: chakraView.selectedStepSeconds,
            startedAt: chakraStepStartedAt
        )
    }

    private func stopChakraTimer() {
        chakraTimer?.invalidate()
        chakraTimer = nil
    }

    /// A new length for the journey. The timer is rebuilt, because a `repeats` timer
    /// cannot change its own interval, and the pace follows from the length and the
    /// number of steps.
    private func chakraStepSecondsChanged(_ seconds: Int) {
        guard isChakraMode else { return }
        startChakraTimer()
    }

    /// A new direction. The journey is rebuilt from where it started, because the
    /// direction is which way it walks *first*.
    private func chakraDirectionChanged(_ direction: ChakraSequence.Direction) {
        guard isChakraMode else { return }
        // The direction says which end the walk starts at, so the journey is rebuilt
        // from that end.
        startChakraJourney(from: ChakraSequence.defaultStart(for: direction))
    }

    /// A new beat. The beat is part of the pair, so the current step is replayed with it
    /// rather than waiting for the next one — a change the user just made should be
    /// heard at once.
    private func chakraBeatChanged(_ beatHz: Double) {
        guard isChakraMode else { return }
        applyChakraStep()
    }

    /// The user clicked a chakra on the figure. The journey starts there — and nothing
    /// else changes: the sound is not started, because choosing where the walk begins is
    /// not a request for a sound.
    private func chakraPicked(_ index: Int) {
        if !isChakraMode {
            setChakraMode(true, startSound: false)
        }
        startChakraJourney(from: index)
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
        // The category is what the search was searching in; a new category is a new
        // question, so the field goes empty with it.
        if !presetSearchField.stringValue.isEmpty {
            presetSearchField.stringValue = ""
        }
        refreshPresetCards()
        scheduleSave()
    }

    /// A preset was picked on a card.
    private func presetPicked(_ id: String) {
        guard let preset = PresetCatalogue.presets.first(where: { $0.id == id }) else { return }
        applyPreset(preset)
    }

    /// The cards show the presets of the chosen category.
    private func refreshPresetCards() {
        let shown = PresetCatalogue.presets.filter { $0.categoryID == presetCategoryID }
        presetCards.presets = shown
        presetCards.markedPresetID = lastPresetID
        presetCards.needsDisplay = true
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
        presetCards.markedPresetID = preset.id
        presetLibraryController.refresh()
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
        presetCards.markedPresetID = lastPresetID
        refreshPresetCards()
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
            differenceLocked: differenceLock.isLocked,
            skippedUpdateVersion: skippedUpdateVersion
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
        // The panel is always on screen, so it always has something to say: without the
        // mode running, that is the pair that is on the wire.
        if !isChakraMode {
            let (left, right) = (leftControl.value, rightControl.value)
            chakraView.showCurrentPair(carrierHz: (left + right) / 2)
        }
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
        chakraView.setPlaying(isPlaybackRunning)
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
        chakraView.setPlaying(isPlaybackRunning)
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

    /// The speaker icon was clicked. The mute is a flip, not a checkbox: the icon is
    /// the only place the state is shown, so the control keeps no state of its own.
    @objc private func muteToggled() {
        setMuted(!engine.isMuted)
    }

    /// Mute or unmute, and show it on the icon.
    ///
    /// The volume is left alone: muting is a separate thing from turning the volume
    /// down, and a user who unmutes expects the level they set to still be there.
    func setMuted(_ muted: Bool) {
        engine.isMuted = muted
        updateMuteIcon()
    }

    /// The speaker that doubles as the mute control.
    ///
    /// Muted, it is crossed out — the state is on the icon, not in a word beside it.
    private func updateMuteIcon() {
        let muted = engine.isMuted
        let image = NSImage(
            systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: L10n.tr(muted ? "Unmute" : "Mute")
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        image?.size = NSSize(width: 17, height: 17)
        volumeIcon.image = image
        volumeIcon.setAccessibilityLabel(L10n.tr(muted ? "Unmute" : "Mute"))
        volumeIcon.setAccessibilityHelp(
            L10n.tr("Silences the sound. The volume itself is not changed.")
        )
        volumeIcon.contentTintColor = muted ? .tertiaryLabelColor : .secondaryLabelColor
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

    /// The frequency reference, opened from the window's corner menu.
    func setReferenceHandler(_ handler: @escaping () -> Void) {
        onReferenceRequested = handler
    }

    /// Press the window's own check button, as a click would.
    func tapHeadphoneCheckButton() {
        headphoneCheckTapped()
    }

    /// The button as a view, so a host can place it somewhere other than the status row.

    /// Feed a report straight into the indicators — the coordinator's `Target` path.
    func apply(headphoneReport: HeadphoneReport) {
        showReport(headphoneReport)
    }

    /// One report to every surface that shows the headphone state: the bottom status
    /// line and the right-hand column's card, so the two cannot disagree.
    private func showReport(_ report: HeadphoneReport) {
        indicator.apply(report: report)
        sessionIndicator.apply(report: report)
        noteHeadphoneReport(report)
    }

    /// Remember which report the window is showing, without touching the indicator.
    private func noteHeadphoneReport(_ report: HeadphoneReport) {
        headphoneState = report
    }

    /// The report the indicator is currently showing.
    var currentHeadphoneReport: HeadphoneReport { headphoneState }

    // MARK: - Language (SPEC §7.4)

    /// The overflow menu, rebuilt so its captions and the language's tick follow the
    /// current language.
    ///
    /// A menu is cheap to rebuild and impossible to patch reliably: the titles are
    /// localised, the language submenu's contents change with the interface, and the
    /// tick has to move.
    private func rebuildOverflowMenu() {
        overflowMenu.removeAllItems()

        let check = NSMenuItem(
            title: L10n.tr("Check headphones…"),
            action: #selector(headphoneCheckTapped),
            keyEquivalent: ""
        )
        check.target = self
        check.toolTip = L10n.tr("Re-reads the default audio output device and offers the L/R test.")
        // Naming the current pair is what the model already persists (`last_preset`),
        // so the menu carries the action the data can honestly hold.
        let save = NSMenuItem(
            title: L10n.tr("Save preset"),
            action: #selector(savePresetTapped),
            keyEquivalent: ""
        )
        save.target = self
        overflowMenu.addItem(save)
        overflowMenu.addItem(.separator())
        overflowMenu.addItem(check)

        let reference = NSMenuItem(
            title: L10n.tr("Frequency reference…"),
            action: #selector(referenceTapped),
            keyEquivalent: ""
        )
        reference.target = self
        overflowMenu.addItem(reference)

        overflowMenu.addItem(.separator())

        overflowLanguageMenu.removeAllItems()
        for code in L10n.languages {
            let item = NSMenuItem(
                title: LanguageCode.name(code),
                action: #selector(languageSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = code.rawValue
            item.state = code == L10n.language ? .on : .off
            overflowLanguageMenu.addItem(item)
        }
        overflowLanguageItem.title = L10n.tr("Language")
        overflowLanguageItem.submenu = overflowLanguageMenu
        overflowMenu.addItem(overflowLanguageItem)
    }

    @objc private func referenceTapped() {
        onReferenceRequested?()
    }

    /// Which columns are on screen at this width: the catalogue leaves first, then the
    /// session column. The thresholds are the widths the columns' own required sizes
    /// actually stop fitting at — hiding them is not a choice the window has to survive,
    /// it is what lets it become narrow at all, so both are reachable from `minSize`.
    func applyWindowCompactness() {
        guard let width = window?.contentRect(forFrameRect: window?.frame ?? .zero).width,
              width > 0
        else { return }
        setCompactness(hideSidebar: width < Self.sidebarCollapseWidth,
                       hideRight: width < Self.rightCollapseWidth)
    }

    /// A constraint with an explicit priority: the plain property assignment, one
    /// line instead of a dance.
    private func withPriority(
        _ priority: NSLayoutConstraint.Priority, _ constraint: NSLayoutConstraint
    ) -> NSLayoutConstraint {
        constraint.priority = priority
        return constraint
    }

    private func setCompactness(hideSidebar: Bool, hideRight: Bool) {
        if sidebarColumnView?.isHidden != hideSidebar {
            sidebarColumnView?.isHidden = hideSidebar
            // The column's width is a required constraint: as long as it stays active
            // it pins the window's least size at the column's own width, which is
            // exactly what would keep the window from ever becoming narrow.
            sidebarWidthConstraint?.isActive = !hideSidebar
        }
        if rightColumnView?.isHidden != hideRight {
            rightColumnView?.isHidden = hideRight
            rightWidthConstraint?.isActive = !hideRight
        }
    }

    /// The widths at which the columns leave: the centre's own least size is what
    /// decides the numbers — a threshold above the real minimum would promise a
    /// collapse the window could never reach.
    static let sidebarCollapseWidth: CGFloat = 1280
    static let rightCollapseWidth: CGFloat = 1050

    /// The search text drives the centre's cards: an empty query is the chosen
    /// category the way it always was; typing searches across the registry.
    private func applyPresetFilter(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            refreshPresetCards()
            return
        }
        presetCards.presets = PresetCatalogue.presets.filter {
            PresetCard.matches(preset: $0, query: query)
        }
        presetCards.markedPresetID = lastPresetID
    }

    @objc private func showPresetLibrary() {
        presetLibraryController.present()
    }

    /// Naming the current pair (the model's own `last_preset`, exactly what the Python
    /// window stores) in a small sheet: the name is the only thing asked for.
    @objc private func savePresetTapped() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save preset")
        alert.informativeText = L10n.tr(
            "Current frequencies: left %1, right %2.",
            FrequencyControlView.formatter.string(from: NSNumber(value: leftControl.value)) ?? "",
            FrequencyControlView.formatter.string(from: NSNumber(value: rightControl.value)) ?? ""
        )
        alert.accessoryView = savePresetField
        alert.addButton(withTitle: L10n.tr("Save preset"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.window.initialFirstResponder = savePresetField
        if alert.runModal() == .alertFirstButtonReturn {
            let name = savePresetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // The model holds a name or nothing; an empty answer means a named nothing,
            // which would be a lie in the document, so it stores nil like Python does.
            lastPresetID = name.isEmpty ? nil : name
            if !isRestoring { scheduleSave() }
        }
        savePresetField.stringValue = ""
    }

    /// The field the save dialog asks the name in. The dialog takes it as its
    /// accessory view, so the field's own metrics and behaviour are defined once.
    private let savePresetField: NSTextField = {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.tr("Preset name")
        return field
    }()

    /// The language was picked in the header.
    @objc private func languageSegmentChanged() {
        let index = languageControl.selectedSegment
        let codes = L10n.languages
        guard index >= 0, index < codes.count else { return }
        L10n.setLanguage(codes[index].rawValue)
    }

    /// The theme, as the shared task names it: light, whatever the system says, or dark.
    enum ThemeStyle: String {
        case light
        case system
        case dark
    }

    /// The theme the window shows, from the stored preference.
    ///
    /// The system's own defaults, not the session: the theme is a property of the
    /// machine, not of a listening session, and a session file that carried it would be
    /// copied between machines with it. The old two-state key (`binaural.darkTheme`)
    /// migrates: a preference that said "dark" and never named a style keeps meaning
    /// dark after this control replaces the moon.
    var themeStyle: ThemeStyle {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.themeStyleKey) {
            return ThemeStyle(rawValue: raw) ?? .system
        }
        if defaults.object(forKey: Self.legacyThemeKey) != nil {
            return defaults.bool(forKey: Self.legacyThemeKey) ? .dark : .light
        }
        return .system
    }

    @objc private func themeChosen(_ sender: NSSegmentedControl) {
        let style = Self.style(forSegment: sender.selectedSegment)
        UserDefaults.standard.set(style.rawValue, forKey: Self.themeStyleKey)
        applyThemeStyle()
    }

    /// One place puts the stored choice into effect. `nil` means "follow the system",
    /// which is what an explicit `NSAppearance` would otherwise pin against.
    func applyThemeStyle() {
        let style = themeStyle
        if style == .system {
            NSApp.appearance = nil
        } else {
            NSApp.appearance = NSAppearance(named: style == .dark ? .darkAqua : .aqua)
        }
        themeControl.setSelected(true, forSegment: Self.segment(for: style))
    }

    /// The pictures of the three states: a sun, the half-lit circle of whatever the
    /// system does, and a moon.
    private static let themeSymbols = [
        "sun.max.fill", "circle.lefthalf.filled", "moon.stars.fill"
    ]

    private static func segment(for style: ThemeStyle) -> Int {
        [ThemeStyle.light, .system, .dark].firstIndex(of: style) ?? 1
    }

    private static func style(forSegment segment: Int) -> ThemeStyle {
        [ThemeStyle.light, .system, .dark].first { Self.segment(for: $0) == segment } ?? .system
    }

    /// Where the theme choice is kept.
    ///
    /// The system's own defaults, not the session: the theme is a property of the
    /// machine, not of a listening session, and a session file that carried it would be
    /// copied between machines with it.
    private static let themeStyleKey = "binaural.themeStyle"
    /// The theme's previous two-state key, read only on migration above.
    private static let legacyThemeKey = "binaural.darkTheme"

    @objc private func languageSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        // `L10n` posts the change; the window and the menus all re-read it.
        L10n.setLanguage(raw)
    }

    // MARK: - Language

    /// Re-read every visible string (SPEC §7.4). The window is built once and lives for
    /// the whole session, so captions cannot simply be re-created.
    func retranslate() {
        window?.title = L10n.tr("Binaural")
        brandTagline.stringValue = L10n.tr("Two frequencies. One effect.")
        referenceButton.title = L10n.tr("Reference")
        themeControl.setAccessibilityLabel(L10n.tr("Theme"))
        themeControl.setAccessibilityHelp(
            L10n.tr("Switches between the light and the dark theme.")
        )
        languageControl.selectedSegment = L10n.languages.firstIndex(of: L10n.language) ?? 0
        categorySidebar.retranslate()
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

        volumeSlider.setAccessibilityLabel(L10n.tr("Volume"))
        volumeSlider.setAccessibilityHelp(
            L10n.tr("Output level from 0 to 100 percent. Not medical advice: keep it low.")
        )
        updateMuteIcon()

        timerView.retranslate()
        chakraView.retranslate()
        // The right-hand column's cards, and the preset cards' band names.
        headphoneCardCaption.stringValue = L10n.tr("Headphones")
        checkButton.title = L10n.tr("Check headphones…")
        sessionIndicator.retranslate()
        presetCards.retranslate()
        presetLibraryController.retranslate()
        // The theme's three segments carry their own names, and the header's quick
        // controls read the strings again with the language.
        themeControl.setLabel(L10n.tr("Light"), forSegment: 0)
        themeControl.setLabel(L10n.tr("Follow the system"), forSegment: 1)
        themeControl.setLabel(L10n.tr("Dark"), forSegment: 2)
        presetsHeaderButton.title = L10n.tr("All presets")
        chakraButton.title = L10n.tr("Chakras")
        chakraButton.setAccessibilityLabel(L10n.tr("Chakras"))
        chakraModeCheckbox.title = L10n.tr("On")
        chakraModeCheckbox.setAccessibilityLabel(L10n.tr("Chakras"))
        updateChakraButtonAppearance()
        menuButton.setAccessibilityLabel(L10n.tr("More"))
        rebuildOverflowMenu()
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
        playButton.isPlaying = playing
        // The one-line session status, the way the mock-up carries it in the header.
        sessionStatusLabel.stringValue = L10n.tr(playing ? "Playing" : "Stopped")
        sessionStatusLabel.setAccessibilityValue(sessionStatusLabel.stringValue)
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
    var isMuted: Bool { engine.isMuted }
    var isPlaying: Bool { engine.isRunning }

    /// Whether the difference lock is on.
    var differenceLockIsLocked: Bool { differenceLock.isLocked }

    var leftCaption: String { leftControl.caption }
    var beat: (hz: Double, carrier: Double) {
        (beatView.displayedBeatHz, beatView.displayedCarrierHz)
    }
    var isShowingBeatHint: Bool { beatView.isShowingHint }
    var beatHintText: String { beatView.hintText }
    var rightCaption: String { rightControl.caption }
    var playButtonTitle: String { playButton.accessibilityLabel() ?? "" }
    var volumeCaptionTitle: String { volumeSlider.accessibilityLabel() ?? "" }
    var muteTitle: String { volumeIcon.accessibilityLabel() ?? "" }
    var statusText: String { indicator.text }
    var statusToolTip: String { indicator.toolTip ?? "" }

    // MARK: - Preset state the tests agree on (SPEC §5 F3)

    /// The preset bar as a view, so the tests can press the chips a user presses rather
    /// than reach past them into AppKit.
    var presetBarControl: PresetBarView { presetBar }

    /// The beat card, so a test can ask where the lock checkbox ended up.
    var beatCard: NSView { beatView }

    /// The chakra panel, so a test can read what it shows and press its controls.
    var chakraControl: ChakraView { chakraView }

    /// The preset block, so a test can see whether the chakra mode took its place.
    var presetBlockControl: NSView { presetBlock }

    /// Advance the chakra sequence by one step, as the timer does. The tests drive it
    /// rather than waiting for the clock.
    func advanceChakraStepForTests() {
        advanceChakraStep()
    }

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
        sessionIndicator.setState(state, deviceName: deviceName)
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
            controller.showReport(report)
        }

        func persistHeadphoneState(acknowledged: Bool, report: HeadphoneReport) {
            controller.recordHeadphoneState(acknowledged: acknowledged, report: report)
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
    ///
    /// The swap only changes when the report carries a **decisive** L/R answer. A report
    /// without one — the test never ran, or it ran and could not tell — says nothing
    /// about the channels, and taking its "not swapped" at face value would un-swap a
    /// pair the user had already established. That is not a corner case: the session
    /// remembers the swap as a plain flag, so on the next launch the fresh report has no
    /// L/R answer to repeat, and applying it unconditionally wiped the swap every time
    /// the app was reopened.
    func recordHeadphoneState(acknowledged: Bool, report: HeadphoneReport) {
        headphoneStateAcknowledged = acknowledged
        if report.hasDecisiveLRAnswer {
            channelsSwapped = report.channelsSwapped
        }
        pushFrequencies()
        scheduleSave()
    }

    private var headphoneStateAcknowledged: Bool = false
    /// True when the L/R test proved the channels are swapped (SPEC §4.2).
    private var channelsSwapped = false

    /// The swap flag as the session records it.
    var isChannelsSwapped: Bool { channelsSwapped }

    // MARK: - Update check

    /// The release the user chose not to be asked about, as the session records it.
    ///
    /// Restored from the session on load and written back when the user skips a version,
    /// so the preference survives a restart like every other setting.
    private var skippedUpdateVersion: String?

    /// The session's memory of the skipped release, for the update coordinator's target.
    var currentSkippedUpdateVersion: String? { skippedUpdateVersion }

    /// The update coordinator's window-side target: reads and writes the skipped release
    /// through the session, like ``HeadphoneTarget`` does for the §4 flags.
    ///
    /// Internal, not private like ``HeadphoneTarget``: ``makeUpdateTarget()`` returns it to
    /// the app delegate, which passes it to the coordinator.
    @MainActor
    final class UpdateTarget: UpdateCheckCoordinator.Target {
        private unowned let controller: MainWindowController
        init(controller: MainWindowController) { self.controller = controller }

        func skippedUpdateVersion() -> String? {
            controller.currentSkippedUpdateVersion
        }

        func persistSkippedUpdateVersion(_ version: String?) {
            controller.recordSkippedUpdateVersion(version)
        }
    }

    /// Strong owner of the update coordinator's weak target — see ``makeUpdateTarget()``.
    private var updateTarget: UpdateTarget?

    /// Build the update coordinator's target. The window does not run the coordinator: the
    /// app delegate does, after the window is on screen, so the check never covers an
    /// unpainted UI.
    func makeUpdateTarget() -> UpdateTarget {
        let target = UpdateTarget(controller: self)
        updateTarget = target
        return target
    }

    /// Remember the release to skip, and write the session so the preference survives a
    /// restart. `nil` forgets it.
    func recordSkippedUpdateVersion(_ version: String?) {
        skippedUpdateVersion = version
        scheduleSave()
    }

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

    /// The language control in the window: its list and its caption.
    /// SPEC §7.4 says the choice is switchable from the window as well as from the menu,
    /// which is what the control is.
    var languageTitles: [String] { overflowLanguageMenu.items.map(\.title) }
    /// The accessibility label of the corner menu button: read aloud by VoiceOver, so
    /// unlike a visible caption it does have to follow the language.
    var cornerMenuAccessibilityLabel: String { menuButton.accessibilityLabel() ?? "" }
    /// The overflow menu, so a test can read what it offers and press its items.
    var overflowMenuControl: NSMenu { overflowMenu }
    /// The corner button's frame in the given view, so a test can check where it sits.
    func menuButtonFrame(in view: NSView) -> NSRect {
        menuButton.convert(menuButton.bounds, to: view)
    }
    /// The status row, for tests that need to see what sits on the top row and in which
    /// order.
    var statusRow: NSStackView? { statusRowView as? NSStackView }
    /// The height of the corner menu button, so a test can check that it is a real
    /// click target rather than a glyph.
    var languagePopupHeight: CGFloat { menuButton.frame.height }
    /// The language the app is in. The menu holds the choice rather than *being* the
    /// choice, so this reads the app's own state.
    var selectedLanguage: LanguageCode { L10n.language }

    /// Pick a language as the menu item would, going through the item's own action so
    /// there is one code path for "switch the language" and not two.
    func selectLanguage(_ code: LanguageCode) {
        guard let item = overflowLanguageMenu.items.first(where: {
            ($0.representedObject as? String) == code.rawValue
        }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// The selected duration in minutes, and the only place the window reads it from.
    var selectedTimerMinutes: Int { timerView.selectedMinutes }

    var countdownText: String { timerView.countdownText }
    var isShowingCountdown: Bool { timerView.isShowingCountdown }
    var timerCaptionTitle: String { timerView.captionTitle }

    /// The tones under the current step, for the tests.
    var droneTones: [DroneTone] { engine.drone }

    /// Pick a duration as the popup would, so the rest of the timer reacts.
    func selectTimerMinutes(_ minutes: Int) {
        timerView.setMinutes(minutes)
        timerSelectionChanged(timerView.selectedMinutes)
    }

    // MARK: - The modern interface, for the tests

    /// Pick one of the three theme states the way the segment's click does: through the
    /// same code path that stores and applies the choice.
    func chooseTheme(_ style: ThemeStyle) {
        UserDefaults.standard.set(style.rawValue, forKey: Self.themeStyleKey)
        applyThemeStyle()
    }

    /// The theme control, so a test can read which segment is lit.
    var themeSegments: NSSegmentedControl { themeControl }

    /// The sidebar's search field, read and written like the user types.
    var presetSearchText: String {
        get { presetSearchField.stringValue }
        set { presetSearchField.stringValue = newValue; applyPresetFilter(newValue) }
    }

    /// The channel views, for tests that drive the field's own commit path.
    var leftFrequencyForTest: FrequencyControlView { leftControl }
    var rightFrequencyForTest: FrequencyControlView { rightControl }

    /// Type a duration into the card's own manual field, the way the keyboard would.
    func typeTimerMinutes(_ text: String) {
        timerView.typeManualMinutes(text)
    }

    /// The full preset library, for tests that read what it shows.
    var presetLibraryForTest: PresetLibraryController { presetLibraryController }

    /// The category the centre's cards are drawn from, so a test can compare the
    /// unfiltered count with what the search found.
    var selectedPresetCategoryForTest: String { presetCategoryID }

    /// Which of the two side columns are on screen at the window's current width.
    var isSidebarShown: Bool? { sidebarColumnView.map { !$0.isHidden } }
    var isRightColumnShown: Bool? { rightColumnView.map { !$0.isHidden } }
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

    /// The columns leave *before* the window becomes narrow, not after: their widths
    /// are required constraints, and a window whose minimum size they pin is a window
    /// that could never reach the width at which they would be asked to leave. This
    /// hook is the only place the collapse happens early enough.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let width = sender.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize)
        ).width
        setCompactness(
            hideSidebar: width < Self.sidebarCollapseWidth,
            hideRight: width < Self.rightCollapseWidth
        )
        // `didResize` puts the final state right after; this is only the door opening.
        return frameSize
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
    /// The collapse runs ahead of a programmatic frame change: `windowWillResize`
    /// answers the drag path, and this answers `setContentSize` — the accessibility
    /// highway, a restored frame, a zoom — which bypasses the delegate.
    var onPrepareResize: ((CGFloat) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func setContentSize(_ size: NSSize) {
        onPrepareResize?(size.width)
        super.setContentSize(size)
    }

    /// Every frame change — the accessibility resize, a restored frame — passes here,
    /// so the collapse runs before the constraints see the new width.
    override func setFrame(_ frameRect: NSRect, display: Bool) {
        onPrepareResize?(frameRect.width)
        super.setFrame(frameRect, display: display)
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
extension MainWindowController: NSSearchFieldDelegate {

    /// Every keystroke of the sidebar's search rebuilds the cards, on the main thread
    /// the notification arrives on.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === presetSearchField else { return }
        applyPresetFilter(presetSearchField.stringValue)
    }
}
