import Foundation

/// Russian strings the Swift window needs that the Python catalogue does not have.
///
/// `RussianCatalogue.swift` is generated from `src/binaural/locales/ru.py` and must stay
/// byte-identical to a fresh run of `apple/Tools/generate_russian_catalogue.py`. When
/// Python gains a key, the entry moves there and this file shrinks — possibly to
/// nothing.
///
/// Today there is exactly one: SPEC F2 asks for a mute control and
/// `src/binaural/ui/main_window.py` has no mute button, so no Python call site ever
/// needed the word.
enum RussianWindowAdditions {

    /// Russian text for the keys in ``messages``, keyed by the same English sources.
    static let messages: [String: String] = [
        "Mute": "Без звука"
    ]
}

extension RussianCatalogue {

    /// The complete Russian catalogue: the generated port plus the Swift-only keys.
    static var all: [String: String] {
        messages.merging(RussianWindowAdditions.messages) { _, added in added }
    }
}