import AppKit
import BinauralCore

/// The menu-bar status item next to the clock — the Swift counterpart of Python's
/// `TrayController` (`src/binaural/ui/tray.py`).
///
/// The role is *remote control*: the window can be closed while the tone keeps playing, so
/// what the window offers has to stay reachable. Python's tray carries more than the two
/// actions M2.md names (it also has Play/Stop and the frequency reference); this carries the
/// same set, and for the same reason — a closed window must not take the app's controls with
/// it.
///
/// Three rules are inherited from Python's docstring because they are what make a tray item
/// safe:
///
/// * **never fatal** — a status bar is not guaranteed (a headless session, a stripped-down
///   environment), so `isAvailable` is false and every method stays a harmless no-op;
/// * **the window stays the single source of truth** — the tray never touches the audio
///   engine, it only reads what the window reports and asks the window to act;
/// * **the icon is an SF Symbol**, not artwork: no asset to ship, no bundle to look for, and
///   it follows the light/dark appearance for free. SPEC §7.3 asks for SVG icons rather than
///   emoji, and a system symbol is the native form of the same idea.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    /// Show the window if it is hidden, hide it if it is visible.
    var onToggleWindow: (() -> Void)?
    /// Play/Stop, when the window reports a transport it can toggle.
    var onTogglePlayback: (() -> Void)?
    /// SPEC §4 — repeat the check, reachable with the window closed.
    var onCheckHeadphones: (() -> Void)?
    /// SPEC §6 — the frequency reference.
    var onOpenReference: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private let toggleItem = NSMenuItem()
    private let playItem = NSMenuItem()
    private let checkItem = NSMenuItem()
    private let referenceItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    /// Where the status item is in the menu bar. `NSStatusBar` has no documented index for
    /// a programmatic item, so this is only for the tests.
    private(set) var isInstalled = false

    // MARK: - Life cycle

    /// Build the menu and its captions. Split out of ``install()`` because a status bar
    /// needs a real login session: the menu is the part that can be wrong, and it is the
    /// part the tests drive.
    func buildMenu() {
        guard toggleItem.menu == nil else { return }

        toggleItem.target = self
        toggleItem.action = #selector(toggleWindow)
        toggleItem.keyEquivalent = "w"

        playItem.target = self
        playItem.action = #selector(togglePlayback)

        checkItem.target = self
        checkItem.action = #selector(checkHeadphones)
        referenceItem.target = self
        referenceItem.action = #selector(openReference)

        quitItem.target = self
        quitItem.action = #selector(quit)

        menu.delegate = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(playItem)
        menu.addItem(.separator())
        menu.addItem(checkItem)
        menu.addItem(referenceItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        retranslate()
    }

    /// Install the item. Called once, from the app delegate, **after** the window exists so
    /// the very first menu the user opens already says the right thing.
    func install() {
        guard statusItem == nil else { return }
        buildMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A system symbol, so nothing has to be shipped and nothing has to be tinted by hand.
        if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Binaural") {
            symbol.isTemplate = true
            item.button?.image = symbol
        } else {
            // No symbol on this OS: the menu still works, which is what matters.
            item.button?.title = "Binaural"
        }
        item.menu = menu
        statusItem = item
        isInstalled = true
    }

    /// Remove the item. Safe to call more than once; the app calls it on quit.
    func uninstall() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        isInstalled = false
    }

    // MARK: - State

    /// Is the window on screen? Drives the Show/Hide caption and the Window-menu item.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        retranslate()
    }

    /// Python's tray tooltip: the frequencies, and the beat while playing.
    ///
    /// Both captions already exist in `ru.py`, so the Russian comes from the shared
    /// catalogue rather than from a private string here.
    func updatePlayback(isPlaying: Bool, leftHz: Double, rightHz: Double, beatHz: Double) {
        let left = FrequencyGrid.text(leftHz)
        let right = FrequencyGrid.text(rightHz)
        statusItem?.button?.toolTip = isPlaying
            ? L10n.tr("▶ %1 / %2 Hz — beat %3 Hz", left, right, FrequencyGrid.text(beatHz))
            : L10n.tr("⏹ %1 / %2 Hz", left, right)
        retranslate()
    }

    // MARK: - Actions

    @objc private func toggleWindow() {
        onToggleWindow?()
    }

    @objc private func togglePlayback() {
        onTogglePlayback?()
    }

    @objc private func checkHeadphones() {
        onCheckHeadphones?()
    }

    @objc private func openReference() {
        onOpenReference?()
    }

    @objc private func quit() {
        onQuit?()
    }

    // MARK: - Language

    func retranslate() {
        toggleItem.title = L10n.tr(windowVisible ? "Hide Binaural" : "Show Binaural")
        toggleItem.setAccessibilityLabel(toggleItem.title)
        playItem.title = L10n.tr(isPlaying ? "Stop" : "Play")
        checkItem.title = L10n.tr("Check headphones…")
        referenceItem.title = L10n.tr("Frequency reference…")
        quitItem.title = L10n.tr("Quit")
        quitItem.keyEquivalent = "q"
        menu.title = L10n.tr("Binaural")
    }

    // MARK: - State the tests read

    private var windowVisible = true
    private(set) var isPlaying = false

    /// The menu, top to bottom, as captions — what the user will see.
    func menuTitles() -> [String] {
        menu.items.filter { $0.title != "" }.map(\.title)
    }

    var toggleTitle: String { toggleItem.title }
    var playTitle: String { playItem.title }
    var checkTitle: String { checkItem.title }
    var referenceTitle: String { referenceItem.title }
    var quitTitle: String { quitItem.title }
    var tooltip: String { statusItem?.button?.toolTip ?? "" }

    /// Press a menu item as a click would.
    func press(toggle: Bool = false, play: Bool = false, check: Bool = false,
               reference: Bool = false, quit: Bool = false) {
        if toggle { onToggleWindow?() }
        if play { onTogglePlayback?() }
        if check { onCheckHeadphones?() }
        if reference { onOpenReference?() }
        if quit { onQuit?() }
    }

    /// Report the transport, so the caption and the tooltip follow it.
    func reportPlayback(isPlaying playing: Bool, leftHz: Double, rightHz: Double, beatHz: Double) {
        isPlaying = playing
        updatePlayback(isPlaying: playing, leftHz: leftHz, rightHz: rightHz, beatHz: beatHz)
    }
}