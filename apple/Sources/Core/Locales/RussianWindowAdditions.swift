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
        // SPEC F2 asks for a mute control and `main_window.py` has no mute button. The
        // speaker by the volume slider *is* that control, so the icon has to say both
        // ways round: silence it, and stop silencing it.
        "Mute": "Без звука",
        "Unmute": "Включить звук",
        // The mode's own switch, beside the button that selects it.
        "On": "Вкл.",
        // The header: the brand's line, the navigation, the catalogue and the theme.
        "Two frequencies. One effect.": "Две частоты. Один эффект.",
        "All presets": "Все пресеты",
        "Reference": "Справочник",
        "Theme": "Тема",
        "Switches between the light and the dark theme.": "Переключает светлую и тёмную темы.",
        // The step the session settles on and holds, and the choice of leaving it to
        // the timer.
        "Hold": "Держать",
        "Auto": "Авто",
        // The picture of the waves, as against the beat that makes them.
        "Pulse": "Пульс",
        // The tones of the steps below the one being played keep sounding under it.
        "Sum": "Суммировать",
        // The chakra mode, which only the macOS build has.
        "The chakra mode walks the spine: the earth and the seven solfeggio tones, up and back, with the figure and its aura beside it. The tones of the steps below the one being played can be summed under it, the way the reference app accumulated them.": (
            "Режим чакр идёт по позвоночнику: земля и семь соль-факторийных тонов, вверх и обратно, рядом фигура и её аура. Тона ступеней ниже играющей можно суммировать под ней, как накапливались они в том приложении."
        ),
        "Silences the sound. The volume itself is not changed.": (
            "Выключает звук. Сама громкость не меняется."
        ),
        // The Settings dialog is retired: the language it held moved into the main window,
        // so nothing here shows `Settings…` any more. `ru.py`'s "&Settings…" is still the Qt
        // app's own menu item and stays in the generated catalogue, untouched.
        // The Swift build is macOS-only (apple/ is a separate product from the Python
        // PySide6 app, which ships macOS *and* Linux), so the shared "macOS and Linux"
        // tagline would be wrong here.
        "Binaural beats for macOS": "Бинауральные биения для macOS",
        "Version {version} · macOS {system}": "Версия {version} · macOS {system}",
        // SPEC §7 item 6's four About sections. Every other line of them lives in
        // `ru.py` — these two are macOS-specific for the same reason the tagline
        // above is, so they cannot use the shared wording.
        "Platform: macOS. Licence: MIT — use it, change it, ship it.": (
            "Платформа: macOS. Лицензия: MIT — используйте, изменяйте, распространяйте."
        ),
        "Built with Swift and AVAudioEngine. Two applications are built from this repository; they share their frequency arithmetic, not their code.": (
            "Сделано на Swift и AVAudioEngine. Из этого репозитория собираются два приложения: у них общая арифметика частот, а не общий код."
        )
    ]
}

extension RussianCatalogue {

    /// The complete Russian catalogue: the generated port plus the Swift-only keys.
    static var all: [String: String] {
        messages.merging(RussianWindowAdditions.messages) { _, added in added }
    }
}