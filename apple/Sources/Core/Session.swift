import Foundation

/// Persisted user state — the Swift half of `docs/CONTRACT.md` §7.
///
/// Port of `binaural.core.session.Session` field for field. Storage differs: Python
/// writes through `QSettings` under `session/<key>`, Swift uses `Codable` JSON at an
/// explicit URL, because Core must stay platform-independent (see `apple/DESIGN.md` §5).
/// The *field names*, the *defaults* and the *load-time clamps* are identical, and the
/// JSON keys are the Python field names verbatim, so one document shape is readable by
/// both implementations.
///
/// Which file the app actually opens is an M2 decision (UserDefaults vs Application
/// Support); M1 hands the caller a URL.
public struct Session: Sendable, Equatable {

    // MARK: - Defaults read out of the Python source

    public static let defaultLeftHz: Double = 205.0
    public static let defaultRightHz: Double = 215.0
    public static let defaultVolume: Double = 0.7

    /// Playback timer in minutes; `0` means "no timer — play until stopped".
    public static let timerOff: Int = 0

    /// SPEC §2.1: studies stimulate for 5–15 minutes, so 15 is the default session.
    public static let defaultTimerMinutes: Int = 15

    /// Durations offered by the timer control (minutes; `0` = off).
    public static let timerChoices: [Int] = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    /// A timer longer than a day is a typo in the settings file, not a wish.
    public static let maxTimerMinutes: Int = 1440

    public static let defaultPresetCategory: String = "relaxation"

    /// The defaults, ready to compare against. Equivalent to Python's `Session()`.
    public static let standard = Session()

    // MARK: - Fields

    public var leftHz: Double
    public var rightHz: Double
    public var volume: Double
    /// True when the perceptual test proved the channels are swapped; the generator
    /// then swaps them (SPEC §4.2).
    public var channelsSwapped: Bool
    /// True once the user has seen the headphone dialog at start-up.
    public var headphoneCheckAcknowledged: Bool
    public var lastPreset: String?
    /// Minutes before playback stops by itself; `0` = play indefinitely.
    public var timerMinutes: Int
    /// Selected preset category. A free string in the Python reference too — see
    /// `apple/DESIGN.md` §5, item 4.
    public var presetCategory: String

    public init(
        leftHz: Double = Session.defaultLeftHz,
        rightHz: Double = Session.defaultRightHz,
        volume: Double = Session.defaultVolume,
        channelsSwapped: Bool = false,
        headphoneCheckAcknowledged: Bool = false,
        lastPreset: String? = nil,
        timerMinutes: Int = Session.defaultTimerMinutes,
        presetCategory: String = Session.defaultPresetCategory
    ) {
        self.leftHz = leftHz
        self.rightHz = rightHz
        self.volume = volume
        self.channelsSwapped = channelsSwapped
        self.headphoneCheckAcknowledged = headphoneCheckAcknowledged
        self.lastPreset = lastPreset
        self.timerMinutes = timerMinutes
        self.presetCategory = presetCategory
    }

    // MARK: - Derived values

    /// `|fL - fR|` — the tone the listener perceives.
    public var beatHz: Double {
        BeatMath.beatFrequency(leftHz: leftHz, rightHz: rightHz)
    }

    /// `(fL + fR) / 2` — the tone each ear hears.
    public var carrierHz: Double {
        BeatMath.carrierFrequency(leftHz: leftHz, rightHz: rightHz)
    }

    // MARK: - Persistence

    fileprivate enum CodingKeys: String, CodingKey {
        case leftHz = "left_hz"
        case rightHz = "right_hz"
        case volume
        case channelsSwapped = "channels_swapped"
        case headphoneCheckAcknowledged = "headphone_check_acknowledged"
        case lastPreset = "last_preset"
        case timerMinutes = "timer_minutes"
        case presetCategory = "preset_category"
    }

    /// The session as JSON. A `nil` preset is omitted rather than written as `null`,
    /// which is how it reads back as `nil`.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Write the session, creating the containing directory when needed.
    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    /// Read the session back, falling back to the default for every missing or
    /// unreadable key — the leniency of the Python `load()`.
    ///
    /// - Throws: only when the file is missing or is not JSON at all. A valid JSON
    ///   document always yields a session.
    public static func load(from url: URL) throws -> Session {
        let data = try Data(contentsOf: url)
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
            return Session()
        }
        return session
    }
}

// MARK: - Lenient decoding

extension Session: Codable {

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Session.standard
        self.init(
            leftHz: container.clampedDouble(forKey: .leftHz) ?? defaults.leftHz,
            rightHz: container.clampedDouble(forKey: .rightHz) ?? defaults.rightHz,
            volume: min(1.0, max(0.0, container.clampedDouble(forKey: .volume) ?? defaults.volume)),
            channelsSwapped: container.clampedBool(forKey: .channelsSwapped) ?? defaults.channelsSwapped,
            headphoneCheckAcknowledged: container.clampedBool(forKey: .headphoneCheckAcknowledged)
                ?? defaults.headphoneCheckAcknowledged,
            lastPreset: container.clampedString(forKey: .lastPreset),
            timerMinutes: min(
                Session.maxTimerMinutes,
                max(0, container.clampedInt(forKey: .timerMinutes) ?? defaults.timerMinutes)
            ),
            presetCategory: container.clampedString(forKey: .presetCategory).flatMap { $0.isEmpty ? nil : $0 }
                ?? defaults.presetCategory
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leftHz, forKey: .leftHz)
        try container.encode(rightHz, forKey: .rightHz)
        try container.encode(volume, forKey: .volume)
        try container.encode(channelsSwapped, forKey: .channelsSwapped)
        try container.encode(headphoneCheckAcknowledged, forKey: .headphoneCheckAcknowledged)
        try container.encodeIfPresent(lastPreset, forKey: .lastPreset)
        try container.encode(timerMinutes, forKey: .timerMinutes)
        try container.encode(presetCategory, forKey: .presetCategory)
    }
}

fileprivate extension KeyedDecodingContainer where Key == Session.CodingKeys {
    /// A number, whatever it is typed as in the file, or `nil`.
    ///
    /// Python's `_float` runs the raw value through `float(...)`, which also accepts a
    /// numeric string; this matches that.
    func clampedDouble(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value.isFinite ? value : nil }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let text = try? decode(String.self, forKey: key),
           let value = Double(text.trimmingCharacters(in: .whitespaces)) {
            return value.isFinite ? value : nil
        }
        return nil
    }

    /// An integer, accepting the "15.0" a settings writer may leave behind.
    func clampedInt(forKey key: Key) -> Int? {
        clampedDouble(forKey: key).map { Int($0.rounded()) }
    }

    /// Python accepts `true/1/yes/on` and `false/0/no/off` for booleans; a settings file
    /// written by an older build can hold any of those.
    func clampedBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        guard let text = try? decode(String.self, forKey: key) else { return nil }
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// A non-empty string, or `nil` — `JSONDecoder` hands back `nil` for `null`.
    func clampedString(forKey key: Key) -> String? {
        guard let value = try? decode(String.self, forKey: key) else { return nil }
        return value.isEmpty ? nil : value
    }
}