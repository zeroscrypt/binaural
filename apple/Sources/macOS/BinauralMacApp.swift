import AppKit
import BinauralCore

/// macOS shell for the Swift implementation.
///
/// M2-a scope: a usable app. The window shows the two independent frequencies, the live
/// beat and carrier, the transport and the headphone indicator; playback goes through
/// `AudioEngine` (`AVAudioEngine` + `AVAudioSourceNode` at the device's own sample
/// rate); the interface speaks English and Russian and switches live from
/// *View → Language*. Presets, the reference dialog, the headphone check, the timer,
/// Settings, About and the menu-bar item are M2-b — see `apple/DESIGN.md` §4.
@main
enum BinauralMacApp {

    static func main() {
        // The installer runs `binaural --version` to verify an install. It must answer on
        // stdout and exit: a window here would block that check until its timeout.
        if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-V" }) {
            print("binaural \(bundleVersion() ?? "unknown")")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }

    /// The version of the bundle this executable belongs to. Read through the resolved path:
    /// the `binaural` on the PATH is a symlink, and `Bundle.main` does not follow it.
    static func bundleVersion() -> String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let bundle = executable.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// One engine, one window, for the whole run: the render callback's oscillator
    /// belongs to the engine and must survive every play/stop cycle so the phase stays
    /// continuous.
    private let engine = AudioEngine()
    private var controller: MainWindowController?
    private var coordinator: HeadphoneCheckCoordinator?
    private var updateCoordinator: UpdateCheckCoordinator?
    private var languageObserver: (any NSObjectProtocol)?

    /// True while the status item is installed. Python's rule from `app.py`: with a tray
    /// that can bring the window back, closing the last window must **not** quit; without
    /// one it still has to.
    private var hasStatusItem = false

    /// True when this process is a test host (`BinauralMacTests` runs inside the app).
    ///
    /// The window tests build their own `MainWindowController`, so the delegate's job
    /// under test is nothing at all. Without this the delegate would put a *real* window
    /// on screen while the suite runs — where a stray event reaches a slider and writes
    /// to the user's own session file, and the app icon bounces for no reason.
    private var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // Menu items whose titles are user-visible and therefore follow the language.
    private let quitItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private let viewItem = NSMenuItem()
    private let languageItem = NSMenuItem()
    private let languageMenu = NSMenu()
    private let helpItem = NSMenuItem()
    private let checkHeadphonesItem = NSMenuItem()
    private let referenceItem = NSMenuItem()
    private let aboutItem = NSMenuItem()

    /// Shows a dialog modally — the one place `NSApp.runModal(for:)` is called from the
    /// delegate, so the modality rule has one home.
    private let presenter = ModalPresenter()

    /// The menu-bar item, from launch (SPEC §7: the counterpart of Python's `TrayController`).
    private let statusItem = StatusItemController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Language first: every caption below reads it. Stored choice wins, then the
        // system locale, then English — `i18n.resolve_initial_language`.
        L10n.bootstrap()
        NSApp.mainMenu = makeMainMenu()
        retranslateMenus()

        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue by construction, so the isolation assertion
            // holds; the closure itself must be nonisolated to be `@Sendable`.
            MainActor.assumeIsolated { self?.languageDidChange() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under test: the suite owns the window, and writing to the real Application
        // Support directory from a test run would be a side effect on the user's data.
        guard !isRunningTests else { return }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.binaural.mac"
        // Application Support is the M2 decision for session storage; a fallback keeps
        // the app usable (unwritable) rather than refusing to start.
        let store = (try? SessionStore.applicationSupport(bundleIdentifier: bundleIdentifier))
            ?? SessionStore(
                url: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(SessionStore.fileName)
            )

        let controller = MainWindowController(engine: engine, store: store)
        self.controller = controller

        // The update check: the same coordinator serves the launch check and the About
        // dialog's button, so there is one implementation of the flow. The relaunch is
        // the one step that needs AppKit — it starts the replacement bundle and stops
        // this process.
        let updateCoordinator = UpdateCheckCoordinator(
            installer: UpdateInstaller(relauncher: { newBundle in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: newBundle, configuration: configuration) { _, error in
                    if error == nil {
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }
            }),
            target: controller.makeUpdateTarget()
        )
        self.updateCoordinator = updateCoordinator

        // The window's Space / arrow shortcuts are wired by the controller itself, which
        // owns the actions they invoke; the delegate only puts the window on screen.
        if let window = controller.window {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        // SPEC §4: the check runs *after* the window is on screen, exactly as
        // `app.py` orders it (`window.show()` then `QTimer.singleShot(0, …)`). Deferred to
        // the next turn of the run loop rather than run inline, so the first paint happens
        // before a modal dialog covers it.
        let check = controller.makeHeadphoneCoordinator()
        self.coordinator = check
        // The window's own check button and the *Help* item both go through the
        // coordinator, so "re-check the headphones" is one code path in the whole app.
        controller.setHeadphoneCheckHandler { [weak self] in
            _ = self?.coordinator?.rerunFromUser()
        }

        // The menu-bar item, from launch, and the wiring that makes it the *same* app
        // rather than a second front end: every action asks the window or the coordinator,
        // never the audio engine directly.
        statusItem.onToggleWindow = { [weak controller] in controller?.toggleWindowVisibility() }
        statusItem.onTogglePlayback = { [weak controller] in controller?.togglePlaybackFromKeyboard() }
        statusItem.onCheckHeadphones = { [weak self] in _ = self?.coordinator?.rerunFromUser() }
        statusItem.onOpenReference = { [weak self] in self?.openReference() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        statusItem.install()
        hasStatusItem = statusItem.isInstalled

        controller.setWindowVisibilityHandler { [weak statusItem] visible in
            statusItem?.setWindowVisible(visible)
        }
        controller.setWindowCloseHandler { [weak controller] in controller?.setWindowVisible(false) }
        controller.setStatusItemHandler { [weak statusItem] playing, left, right, beat in
            statusItem?.reportPlayback(
                isPlaying: playing, leftHz: left, rightHz: right, beatHz: beat
            )
        }
        controller.setWindowVisible(true)
        DispatchQueue.main.async {
            _ = check.runAtLaunch(acknowledged: controller.currentSession.headphoneCheckAcknowledged)
            // The update check runs after the headphone check, deferred the same way: a
            // silent background check that only interrupts when there is an update to
            // offer. It does not wait for the headphone dialog — the two are independent.
            Task { await updateCoordinator.runAtLaunch() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem.uninstall()
        controller?.saveNow()
        // (Nothing to tear down under test: there is no controller.)
        controller?.tearDown()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        engine.shutdown()
    }

    /// An explicit *Quit* must always work, tray or no tray.
    ///
    /// The default implementation already answers `terminateNow`, so this is the same
    /// behaviour written down: it is stated next to the rule below, which is the one that
    /// needs care, and having both in one place makes the pair readable — "closing the last
    /// window is not quitting; asking to quit is quitting".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    /// With a status item installed, closing the last window must leave the app running —
    /// that is the whole point of the item. Without one, closing the window quits, as
    /// Python's `setQuitOnLastWindowClosed` decision does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !hasStatusItem
    }

    // MARK: - Menu

    /// The menu bar: the application menu (Quit), *View → Language* and *Help*.
    ///
    /// The three *Help* items are SPEC §7's dialogs list: *Check headphones* (§4, also on
    /// the window), *Frequency reference* (§6) and *About* (§6.13). Key equivalents match
    /// Python's (`Ctrl+O`, `Ctrl+Shift+H`, `Ctrl+Shift+I`) — the same chord does the same
    /// thing in both products, which is what a user of either will expect.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        // SPEC §7 lists a Settings dialog; the application menu is where macOS puts it,
        // and `Cmd-,` is the chord the platform expects.
        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        quitItem.title = L10n.tr("Quit")
        quitItem.action = #selector(NSApplication.terminate(_:))
        quitItem.keyEquivalent = "q"
        appMenu.addItem(quitItem)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        for code in L10n.languages {
            // Native names in both languages: a user must be able to find their own
            // language in the list.
            let item = NSMenuItem(
                title: LanguageCode.name(code),
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = code.rawValue
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu

        let viewMenu = NSMenu(title: Self.menuTitle(L10n.tr("&View")))
        viewMenu.addItem(languageItem)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        checkHeadphonesItem.target = self
        checkHeadphonesItem.action = #selector(checkHeadphones)
        checkHeadphonesItem.keyEquivalent = "h"
        checkHeadphonesItem.keyEquivalentModifierMask = [.control, .shift]

        referenceItem.target = self
        referenceItem.action = #selector(openReference)
        referenceItem.keyEquivalent = "o"
        referenceItem.keyEquivalentModifierMask = .command

        aboutItem.target = self
        aboutItem.action = #selector(showAbout)
        aboutItem.keyEquivalent = "i"
        aboutItem.keyEquivalentModifierMask = [.control, .shift]

        let helpMenu = NSMenu(title: Self.menuTitle(L10n.tr("&Help")))
        helpMenu.addItem(referenceItem)
        helpMenu.addItem(checkHeadphonesItem)
        helpMenu.addItem(aboutItem)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        return main
    }

    /// A translated menu title with its mnemonic marker in **AppKit's** spelling.
    ///
    /// The catalogues are shared with the Qt implementation, where `&` introduces the
    /// mnemonic (`&View`); AppKit has no meaning for `&` at all and draws it literally, so
    /// every title in this menu used to read `&View`, `&About`, `&Help` with a visible
    /// ampersand. Rewriting the marker here, at the one boundary where a translated string
    /// becomes a menu title, fixes it without touching the generated catalogue, which must
    /// stay byte-identical to a run of `Tools/generate_russian_catalogue.py` (CONTRACT rule
    /// 10's spirit: one catalogue, two products, no per-platform copy).
    ///
    /// Every occurrence is rewritten, not just a leading one, so `Frequency &reference…`
    /// becomes `Frequency _reference…`.
    ///
    /// Internal rather than private so `MenuTests` can pin the rule directly; the app's own
    /// titles are asserted through the real `NSApp.mainMenu`.
    static func menuTitle(_ translated: String) -> String {
        translated.replacingOccurrences(of: "&", with: "_")
    }

    private func languageDidChange() {
        retranslateMenus()
        // The status item's captions follow the language too (SPEC §7.4).
        statusItem.retranslate()
    }

    private func retranslateMenus() {
        quitItem.title = Self.menuTitle(L10n.tr("Quit"))
        settingsItem.title = Self.menuTitle(L10n.tr("Settings…"))
        viewItem.title = Self.menuTitle(L10n.tr("&View"))
        languageItem.title = Self.menuTitle(L10n.tr("Language"))
        languageMenu.title = Self.menuTitle(L10n.tr("Language"))
        statusItem.retranslate()
        helpItem.title = Self.menuTitle(L10n.tr("&Help"))
        referenceItem.title = Self.menuTitle(L10n.tr("Frequency &reference…"))
        checkHeadphonesItem.title = Self.menuTitle(L10n.tr("&Check headphones…"))
        aboutItem.title = Self.menuTitle(L10n.tr("&About"))
        for item in languageMenu.items {
            guard let raw = item.representedObject as? String,
                  let code = LanguageCode.parse(raw) else { continue }
            item.state = code == L10n.language ? .on : .off
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        // `L10n` posts the change; the window and this menu both re-read their captions.
        L10n.setLanguage(raw)
    }

    // MARK: - Help menu

    /// SPEC §7's Settings: language, headphone check, timer, volume.
    ///
    /// Every control writes through to the live window — there is no OK button because
    /// there is nothing to apply. The language switch here is the *same* `L10n.setLanguage`
    /// the *View → Language* menu calls, which is what SPEC §7.4 asks for ("наряду с
    /// меню *Вид → Язык*").
    @objc private func openSettings() {
        guard let controller else { return }
        // The window builds its own Settings dialog, already wired to itself; see
        // `MainWindowController.makeSettingsDialog()`.
        let dialog = controller.makeSettingsDialog()
        presenter.present(dialog)
        dialog.tearDown()
    }

    /// SPEC §4: repeat the check whenever the user wants to. Same coordinator, same
    /// dialog as the window's button — there is one implementation of the check.
    @objc private func checkHeadphones() {
        _ = coordinator?.rerunFromUser()
    }

    /// SPEC §6: the full frequency reference. The catalogue comes from the bundle, i.e.
    /// from `src/binaural/data/frequencies.json` — one copy, CONTRACT rule 10.
    @objc private func openReference() {
        guard let catalogue = try? FrequencyCatalogue.load(bundle: .main) else {
            AppAlert.runWarning(parent: controller?.window, message: L10n.tr(
                "The frequency reference is not available in this build."
            ))
            return
        }
        let dialog = ReferenceDialogController(catalogue: catalogue)
        // SPEC §6's *Apply* sets both channels at once. It goes through the pair setter, not
        // two single edits: with the difference locked (SPEC §7), two single edits would be
        // two follower moves and the second would undo the first.
        dialog.onApply = { [weak self] left, right in
            self?.controller?.applyFrequencyPair(leftHz: left, rightHz: right)
        }
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// SPEC §6.13: About, with the disclaimer verbatim.
    @objc private func showAbout() {
        // The dialog gets the app's update coordinator, so its *Check for updates* button
        // and the launch check are one implementation of the flow.
        let dialog = AboutDialogController(coordinator: updateCoordinator)
        dialog.showWindow(nil)
        dialog.window?.center()
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}