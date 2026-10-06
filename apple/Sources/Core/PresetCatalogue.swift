import Foundation

/// The brainwave bands of SPEC §6.1 / F3.
///
/// The raw values are the **English** names, because they are also the identifier a
/// catalogue record carries (`"Alpha 10 Hz"` in `frequencies.json`), and the Russian
/// names come from the F3 localisation list.
///
/// **The boundaries are half-open, deliberately.** F3 tabulates them as
/// `[0.5,4)`, `[4,8)`, `[8,13)`, `[13,30)`, `[30,100]` because they are read out of
/// `frequencies.json`, where a band record is *one* record and the next one starts at
/// the same number. With closed intervals 4, 8, 13 and 30 would each belong to two
/// bands and "falls in exactly one band" would be false for four of the twenty
/// presets. `Gamma` is the only one closed at the top, because the table says
/// `[30, 100]` — there is no 100.1 Hz record to overlap with.
public enum BrainwaveBand: String, CaseIterable, Sendable, Identifiable {

    /// `Delta 0.5–4 Hz`
    case delta = "Delta"
    /// `Theta 4–8 Hz`
    case theta = "Theta"
    /// `Alpha 8–13 Hz`
    case alpha = "Alpha"
    /// `Beta 13–30 Hz`
    case beta = "Beta"
    /// `Gamma 30–100 Hz`
    case gamma = "Gamma"

    public var id: String { rawValue }

    /// Lower bound, inclusive.
    public var lowerBoundHz: Double {
        switch self {
        case .delta: return 0.5
        case .theta: return 4
        case .alpha: return 8
        case .beta: return 13
        case .gamma: return 30
        }
    }

    /// Upper bound, **exclusive** — except for ``gamma``, which F3 tabulates closed.
    public var upperBoundHz: Double {
        switch self {
        case .delta: return 4
        case .theta: return 8
        case .alpha: return 13
        case .beta: return 30
        case .gamma: return 100
        }
    }

    /// The matching record in `frequencies.json` (`"Delta 0.5–4 Hz"`), which is where
    /// the bounds above are read from.
    public var jsonRangeLabel: String {
        switch self {
        case .delta: return "Delta 0.5–4 Hz"
        case .theta: return "Theta 4–8 Hz"
        case .alpha: return "Alpha 8–13 Hz"
        case .beta: return "Beta 13–30 Hz"
        case .gamma: return "Gamma 30–100 Hz"
        }
    }

    /// English name, the source language of the interface.
    public var nameEn: String { rawValue }

    /// Russian name from the F3 list (`Delta/Дельта`, `Theta/Тета`, `Alpha/Альфа`,
    /// `Beta/Бета`).
    ///
    /// `Gamma` is the one name F3 does not tabulate, because Gamma is excluded from the
    /// presets; `Гамма` is the transliteration every Russian EEG text uses. It cannot
    /// reach a preset label either way — see ``PresetCatalogue/presets``.
    public var nameRu: String {
        switch self {
        case .delta: return "Дельта"
        case .theta: return "Тета"
        case .alpha: return "Альфа"
        case .beta: return "Бета"
        case .gamma: return "Гамма"
        }
    }

    /// The name in the given language. A plain switch on the language rather than a
    /// catalogue lookup: these names are **data of the preset registry** (SPEC F3),
    /// exactly like `FrequencyCategory.labelEn/labelRu`, so they travel with the
    /// registry instead of with the translation tables.
    public func name(for language: LanguageCode) -> String {
        language == .ru ? nameRu : nameEn
    }

    /// Does `beatHz` fall inside this band, under the half-open reading of F3?
    public func contains(_ beatHz: Double) -> Bool {
        guard beatHz.isFinite else { return false }
        guard beatHz >= lowerBoundHz else { return false }
        return self == .gamma ? beatHz <= upperBoundHz : beatHz < upperBoundHz
    }

    /// The single band `beatHz` falls into, or `nil` when it falls into none.
    ///
    /// Because the bounds are half-open this is total: a value can never match twice,
    /// which is what F3's "exactly one band" rule asks for. The catalogue order is used
    /// rather than a numeric search, so adding a band cannot silently change the answer
    /// for an existing one.
    public static func band(forBeatHz beatHz: Double) -> BrainwaveBand? {
        allCases.first { $0.contains(beatHz) }
    }
}

/// One preset: a beat difference inside a category (SPEC F3).
///
/// A preset carries **no frequencies of its own**. One click sets both channels so that
/// their difference is `beatHz` around the default carrier — the same
/// `BeatMath.pair(fromBeat:carrier:)` the reference dialog and `Synthesizer` use.
public struct Preset: Sendable, Equatable, Identifiable {

    /// Category this preset is listed under; one of ``PresetCatalogue/categories``.
    public let categoryID: String

    /// The difference between the two channels, in Hz.
    public let beatHz: Double

    public init(categoryID: String, beatHz: Double) {
        self.categoryID = categoryID
        self.beatHz = beatHz
    }

    /// Stable identifier, `sleep-2`. Built from the beat rather than an index so it
    /// survives the registry being reordered.
    public var id: String { "\(categoryID)-\(beatText)" }

    /// The beat as text: `2`, not `2.0` — the same "no pointless .0" rule the rest of
    /// the interface uses.
    public var beatText: String { FrequencyGrid.text(beatHz) }

    /// The band this preset belongs to. Non-`nil` for every registry entry; a preset
    /// outside all bands would be a registry bug, and ``PresetCatalogueTests`` fails on
    /// it rather than letting the UI invent a label.
    public var band: BrainwaveBand? { BrainwaveBand.band(forBeatHz: beatHz) }

    /// The `<band> <beat>` label of SPEC F3, in the given language.
    public func title(for language: LanguageCode) -> String {
        guard let band else { return beatText }
        return "\(band.name(for: language)) \(beatText)"
    }
}

/// One level of the two-level preset control: a category and its presets (SPEC F3).
public struct PresetCategory: Sendable, Equatable, Identifiable {

    public let id: String
    /// Category name in English — SPEC F3's own table.
    public let nameEn: String
    /// Category name in Russian — SPEC F3's own table.
    public let nameRu: String
    /// The presets inside this category, ascending.
    public let presets: [Preset]

    public init(id: String, nameEn: String, nameRu: String, presets: [Preset]) {
        self.id = id
        self.nameEn = nameEn
        self.nameRu = nameRu
        self.presets = presets
    }

    /// The chip caption, in the given language.
    public func name(for language: LanguageCode) -> String {
        language == .ru ? nameRu : nameEn
    }
}

/// The preset registry of SPEC §5 F3 — **the** list both implementations share.
///
/// Seven categories, twenty presets, every one of them inside the 1–30 Hz range §2.1
/// calls the limit of perceivable beats, and every one of them inside exactly one
/// half-open brainwave band. `Session.presetCategory` holds an id from ``categories``.
///
/// F3 replaced the old `main_window.PRESETS = (Delta 2, Theta 6, Alpha 10, Beta 20,
/// Gamma 40)` band chips: all five sat in the right band, but `Gamma 40` is outside the
/// 30 Hz cap the same rule imposes on presets. Gamma therefore does not appear here at
/// all — which is a rule about *presets*, not about the reference, where `Gamma 40 Hz`
/// and `Gamma 30–100 Hz` stay untouched (F3 says so explicitly).
public enum PresetCatalogue {

    /// Presets stay inside this value (SPEC §2.1).
    public static let maxPresetHz: Double = 30.0

    /// …and not below this one.
    public static let minPresetHz: Double = 1.0

    /// The category a fresh session starts on (SPEC F3, `Session.preset_category`).
    public static let defaultCategoryID: String = Session.defaultPresetCategory

    /// The registry, in the order F3's table lists it — that order is the chip order.
    public static let categories: [PresetCategory] = [
        PresetCategory(id: "sleep", nameEn: "Sleep", nameRu: "Сон", presets: [
            Preset(categoryID: "sleep", beatHz: 1),
            Preset(categoryID: "sleep", beatHz: 2),
            Preset(categoryID: "sleep", beatHz: 3)
        ]),
        PresetCategory(id: "meditation", nameEn: "Meditation", nameRu: "Медитация", presets: [
            Preset(categoryID: "meditation", beatHz: 4),
            Preset(categoryID: "meditation", beatHz: 5),
            Preset(categoryID: "meditation", beatHz: 6)
        ]),
        PresetCategory(id: "relaxation", nameEn: "Relaxation", nameRu: "Расслабление", presets: [
            Preset(categoryID: "relaxation", beatHz: 8),
            Preset(categoryID: "relaxation", beatHz: 9),
            Preset(categoryID: "relaxation", beatHz: 10)
        ]),
        PresetCategory(id: "awareness", nameEn: "Awareness", nameRu: "Ясность", presets: [
            Preset(categoryID: "awareness", beatHz: 11),
            Preset(categoryID: "awareness", beatHz: 12)
        ]),
        PresetCategory(id: "concentration", nameEn: "Concentration", nameRu: "Сосредоточенность", presets: [
            Preset(categoryID: "concentration", beatHz: 13),
            Preset(categoryID: "concentration", beatHz: 14),
            Preset(categoryID: "concentration", beatHz: 15)
        ]),
        PresetCategory(id: "work", nameEn: "Work", nameRu: "Работа", presets: [
            Preset(categoryID: "work", beatHz: 16),
            Preset(categoryID: "work", beatHz: 18),
            Preset(categoryID: "work", beatHz: 20)
        ]),
        PresetCategory(id: "sport", nameEn: "Sport", nameRu: "Спорт", presets: [
            Preset(categoryID: "sport", beatHz: 22),
            Preset(categoryID: "sport", beatHz: 25),
            Preset(categoryID: "sport", beatHz: 28)
        ])
    ]

    /// Every preset, in registry order.
    public static let presets: [Preset] = categories.flatMap(\.presets)

    /// The category with this id, or `nil`.
    public static func category(id: String) -> PresetCategory? {
        categories.first { $0.id == id }
    }

    /// The presets of one category; empty for an unknown id rather than a crash, so a
    /// hand-edited `preset_category` degrades to an empty chip row instead of taking
    /// the window down.
    public static func presets(inCategory id: String) -> [Preset] {
        category(id: id)?.presets ?? []
    }

    /// A stored category id, or ``defaultCategoryID`` when it is missing or unknown.
    ///
    /// CONTRACT §7 allows `preset_category` to be a free string on the way *in* — the
    /// value is never discarded — so this only decides what the **chips** select. The
    /// document itself keeps whatever it said.
    public static func resolvedCategoryID(_ raw: String?) -> String {
        guard let raw, category(id: raw) != nil else { return defaultCategoryID }
        return raw
    }

    /// Index of a category in chip order, or `nil` when the id is unknown.
    public static func index(ofCategory id: String) -> Int? {
        categories.firstIndex { $0.id == id }
    }

    /// The pair a preset sets: both channels around `carrierHz` so that the difference is
    /// the preset's beat (SPEC F3).
    ///
    /// - Throws: ``FrequencyError`` when the pair would leave the audible range — the
    ///   same validation `BeatMath.pair(fromBeat:carrier:)` does everywhere else.
    public static func frequencies(
        for preset: Preset,
        carrierHz: Double = BeatMath.defaultCarrierHz
    ) throws -> (left: Double, right: Double) {
        try BeatMath.pair(fromBeat: preset.beatHz, carrierHz: carrierHz)
    }
}
