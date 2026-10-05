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
    private let viewItem = NSMenuItem()
    private let languageItem = NSMenuItem()
    private let languageMenu = NSMenu()

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

    /// The menu bar M2-a needs: the application menu (Quit) and *View → Language*.
    /// M2-b adds the frequency reference and the headphone check to *Help*.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
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

        return main
    }

    private func languageDidChange() {
        retranslateMenus()
    }

    private func retranslateMenus() {
        quitItem.title = L10n.tr("Quit")
        viewItem.title = L10n.tr("&View")
        languageItem.title = L10n.tr("Language")
        languageMenu.title = L10n.tr("Language")
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
}