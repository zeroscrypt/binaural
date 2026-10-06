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
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
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
    private var languageObserver: (any NSObjectProtocol)?

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
        DispatchQueue.main.async {
            _ = check.runAtLaunch(acknowledged: controller.currentSession.headphoneCheckAcknowledged)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveNow()
        // (Nothing to tear down under test: there is no controller.)
        controller?.tearDown()
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
        engine.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

        let viewMenu = NSMenu(title: L10n.tr("&View"))
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

        let helpMenu = NSMenu(title: L10n.tr("&Help"))
        helpMenu.addItem(referenceItem)
        helpMenu.addItem(checkHeadphonesItem)
        helpMenu.addItem(aboutItem)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        return main
    }

    private func languageDidChange() {
        retranslateMenus()
    }

    private func retranslateMenus() {
        quitItem.title = L10n.tr("Quit")
        settingsItem.title = L10n.tr("Settings…")
        viewItem.title = L10n.tr("&View")
        languageItem.title = L10n.tr("Language")
        languageMenu.title = L10n.tr("Language")
        helpItem.title = L10n.tr("&Help")
        referenceItem.title = L10n.tr("Frequency &reference…")
        checkHeadphonesItem.title = L10n.tr("&Check headphones…")
        aboutItem.title = L10n.tr("&About")
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
        dialog.onApply = { [weak self] left, right in
            self?.controller?.setFrequency(left, for: .left)
            self?.controller?.setFrequency(right, for: .right)
        }
        dialog.showWindow(nil)
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// SPEC §6.13: About, with the disclaimer verbatim.
    @objc private func showAbout() {
        let dialog = AboutDialogController()
        dialog.showWindow(nil)
        dialog.window?.center()
        dialog.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}