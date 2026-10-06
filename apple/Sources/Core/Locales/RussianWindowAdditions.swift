import Foundation

/// Russian strings the Swift app needs that the Python catalogue does not have.
///
/// `RussianCatalogue.swift` is generated from `src/binaural/locales/ru.py` and must stay
/// byte-identical to a fresh run of `apple/Tools/generate_russian_catalogue.py`. When
/// Python gains a key, the entry moves there and this file shrinks — possibly to
/// nothing.
///
/// Every entry here is a key the Swift interface references and `ru.py` has no call site
/// for. `L10nKeysTests` fails if a referenced key is missing from the combined catalogue,
/// so these cannot rot either.
///
/// Each group below belongs upstream in `src/binaural/locales/ru.py`: whenever Python
/// grows the matching control, its entry moves into the generated catalogue and this
/// file loses it. Nothing is invented for the sake of having it — every key here is one
/// the Swift interface actually shows.
enum RussianWindowAdditions {

    /// Russian text for the keys in ``messages``, keyed by the same English sources.
    static let messages: [String: String] = [
        // SPEC F2 asks for a mute control and `main_window.py` has no mute button.
        "Mute": "Без звука",
        // SPEC §5 F5 asks for a playback timer; `main_window.py` has no timer row either.
        "Timer": "Таймер",
        "Off": "Выкл.",
        "%1 min": "%1 мин",
        // SPEC §7 lists a Settings dialog; Python has no settings layer at all.
        "Settings": "Настройки",
        // SPEC §7 asks for a headphone-check button in the window itself, not only at
        // start-up. `ru.py` already has "Check headphones…" for the tray item, so only the
        // button's help text is new.
        "Re-reads the default audio output device and offers the L/R test.":
            "Перечитывает устройство аудиовыхода по умолчанию и предлагает тест L/R.",
        // The Swift build is macOS-only (apple/ is a separate product from the Python
        // PySide6 app, which ships macOS *and* Linux), so the shared "macOS and Linux"
        // tagline would be wrong here.
        "Binaural beats for macOS": "Бинауральные биения для macOS",
        "Version {version} · macOS {system}": "Версия {version} · macOS {system}",
        // The menu-bar status item (SPEC §7) is the Swift counterpart of TrayController.
        "Show or hide the main window": "Показать или скрыть главное окно",
        // SPEC §7 lists a Settings dialog with a volume control; the Python window has the
        // slider only and no settings layer, so these section titles have no call site.
        "Audio": "Звук",
        "Playback": "Воспроизведение"
    ]
}

extension RussianCatalogue {

    /// The complete Russian catalogue: the generated port plus the Swift-only keys.
    static var all: [String: String] {
        messages.merging(RussianWindowAdditions.messages) { _, added in added }
    }
}