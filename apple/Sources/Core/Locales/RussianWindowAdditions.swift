import Foundation

/// Russian strings the Swift app needs that the Python catalogue does not have.
///
/// `RussianCatalogue.swift` is generated from `src/binaural/locales/ru.py` and must stay
/// byte-identical to a fresh run of `apple/Tools/generate_russian_catalogue.py`. When
/// Python gains a key, the entry moves there and this file shrinks — as it did for the
/// mute/timer/settings batch once `ru.py` grew the Settings dialog, the playback timer
/// and the preset registry.
///
/// Every entry here is a key the Swift interface references and `ru.py` has no call site
/// for. `L10nKeysTests` fails if a referenced key is missing from the combined catalogue,
/// so these cannot rot either, and `L10nTests.testEveryAdditionIsShownByTheApp` fails if
/// a key here is one no source shows — so an entry cannot survive by being merely plausible.
///
/// Each group below belongs upstream in `src/binaural/locales/ru.py`: whenever Python
/// grows the matching control, its entry moves into the generated catalogue and this file
/// loses it. Nothing is invented for the sake of having it — every key here is one the
/// Swift interface actually shows.
enum RussianWindowAdditions {

    /// Russian text for the keys in ``messages``, keyed by the same English sources.
    static let messages: [String: String] = [
        // SPEC F2 asks for a mute control and `main_window.py` has no mute button.
        "Mute": "Без звука",
        // The Swift app opens the Settings dialog from the application menu, where macOS
        // titles carry no "&" mnemonic — so `ru.py`'s "&Settings…" (a Qt menu item) is a
        // different key, not a newer version of this one.
        "Settings…": "Настройки…",
        // The Swift build is macOS-only (apple/ is a separate product from the Python
        // PySide6 app, which ships macOS *and* Linux), so the shared "macOS and Linux"
        // tagline would be wrong here.
        "Binaural beats for macOS": "Бинауральные биения для macOS",
        "Version {version} · macOS {system}": "Версия {version} · macOS {system}",
        // SPEC §7's "Lock difference" checkbox. The Python app has no such control, so
        // neither the label nor the two explanations below exist in `ru.py`.
        "Lock difference": "Зафиксировать",
        "Keeps the difference between the two frequencies. Changing one channel moves the other by the same amount, so the beat stays the same.":
            "Держит разность между частотами. Изменение одного канала сдвигает другой на столько же, поэтому биение остаётся прежним.",
        "Difference lock turned off — a preset set its own difference.":
            "Фиксация разности выключена — пресет задал свою разность.",
        // SPEC §7: the existing out-of-range hint slot also carries why a locked channel
        // stopped moving.
        "Stopped at the range limit: the difference is locked, so the other channel cannot follow any further.":
            "Остановлено на границе диапазона: разность зафиксирована, поэтому второй канал не может следовать дальше."
    ]
}

extension RussianCatalogue {

    /// The complete Russian catalogue: the generated port plus the Swift-only keys.
    static var all: [String: String] {
        messages.merging(RussianWindowAdditions.messages) { _, added in added }
    }
}