import Foundation

// MARK: - Evidence

/// Evidence level of a record — SPEC §6.2. The badge is a hint for the reader, never a
/// filter: nothing is hidden and nothing is ranked.
///
/// Ported from `binaural.data.frequencies.EVIDENCE_BADGES` / `EVIDENCE_LEVELS`.
public enum EvidenceLevel: String, CaseIterable, Codable, Sendable {
    /// 🟢 Peer-reviewed studies exist.
    case wellStudied = "well-studied"
    /// 🔵 Studies exist, fewer of them.
    case studied
    /// 🟡 Claimed; little research.
    case reported
    /// 🟣 From traditions and esoteric practice.
    case traditional
    /// Not one of the four levels of SPEC §6.2.
    ///
    /// Python keeps such a value as a raw string and badges it ⚪, so leniency is kept
    /// here too — only the unknown spelling itself is dropped.
    case unknown

    /// The badge shown next to a record. ⚪ for an unknown level.
    public var badge: String {
        switch self {
        case .wellStudied: return "\u{1F7E2}"   // green circle
        case .studied:      return "\u{1F535}"   // blue circle
        case .reported:     return "\u{1F7E1}"   // yellow circle
        case .traditional:  return "\u{1F7E3}"   // purple circle
        case .unknown:      return "\u{26AA}"    // white circle
        }
    }

    /// The four levels SPEC §6.2 defines, in registry order (Python's `EVIDENCE_LEVELS`).
    public static var defined: [EvidenceLevel] {
        [.wellStudied, .studied, .reported, .traditional]
    }

    /// Lenient decoding: anything outside the four known levels becomes ``unknown``,
    /// exactly like `str(data.get("evidence", ""))` in Python.
    public init(lenient rawValue: String) {
        self = EvidenceLevel(rawValue: rawValue) ?? .unknown
    }
}

// MARK: - Models

/// A reference category. `icon`/`color` come only from this registry (SPEC §6.1) —
/// never from the records themselves.
public struct FrequencyCategory: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    public let order: Int
    public let icon: String
    public let color: String
    public let labelEn: String
    public let labelRu: String
    public let descriptionEn: String
    public let descriptionRu: String

    enum CodingKeys: String, CodingKey {
        case id, order, icon, color, labelEn = "label_en", labelRu = "label_ru"
        case descriptionEn = "description_en", descriptionRu = "description_ru"
    }

    public init(
        id: String,
        order: Int,
        icon: String,
        color: String,
        labelEn: String,
        labelRu: String,
        descriptionEn: String,
        descriptionRu: String
    ) {
        self.id = id
        self.order = order
        self.icon = icon
        self.color = color
        self.labelEn = labelEn
        self.labelRu = labelRu
        self.descriptionEn = descriptionEn
        self.descriptionRu = descriptionRu
    }
}

/// One reference record.
///
/// Either `beatHz` or the `beatMin`/`beatMax` pair is set, never both. Records tagged
/// `tonal` carry a tone frequency in `beatHz` rather than a difference — SPEC §6.5.
public struct FrequencyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let category: String
    public let label: String

    /// The difference to feed the beat, when the record is a single value.
    public let beatHz: Double?
    /// Lower bound of a band record (SPEC §6.3).
    public let beatMin: Double?
    /// Upper bound of a band record.
    public let beatMax: Double?
    /// Recommended carrier. The beat is what the record is *about*.
    public let carrierHz: Double

    public let effectEn: String
    public let effectRu: String
    public let evidence: EvidenceLevel
    public let source: String
    public let tags: [String]

    public init(
        id: String,
        category: String,
        label: String,
        beatHz: Double?,
        beatMin: Double?,
        beatMax: Double?,
        carrierHz: Double,
        effectEn: String,
        effectRu: String,
        evidence: EvidenceLevel,
        source: String,
        tags: [String]
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.beatHz = beatHz
        self.beatMin = beatMin
        self.beatMax = beatMax
        self.carrierHz = carrierHz
        self.effectEn = effectEn
        self.effectRu = effectRu
        self.evidence = evidence
        self.source = source
        self.tags = tags
    }

    /// True for band records spanning `beatMin...beatMax`.
    public var isRange: Bool {
        beatHz == nil && beatMin != nil && beatMax != nil
    }

    /// True when `beatHz` holds a tone frequency rather than a beat difference.
    public var isTonal: Bool {
        tags.contains("tonal")
    }

    /// Evidence badge for this record.
    public var badge: String { evidence.badge }

    /// Sort order used inside a category: ranges first, then ascending beat value
    /// (SPEC §6.12).
    var sortKey: (group: Int, value: Double, id: String) {
        if isRange {
            return (0, beatMin ?? 0.0, id)
        }
        return (1, beatHz ?? 0.0, id)
    }

    /// Human-readable frequency: `10 Hz` or `0.5–4 Hz`.
    public var frequencyText: String {
        if isRange {
            return "\(Self.format(beatMin))\u{2013}\(Self.format(beatMax)) Hz"
        }
        return "\(Self.format(beatHz)) Hz"
    }

    /// Format without a trailing `.0`, like Python's `%g`-based `_fmt`.
    ///
    /// `public` because the macOS window formats the same numbers into its tooltips and
    /// hints, and the app target is a separate module from `BinauralCore`.
    public static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(value)
        if text.hasSuffix(".0") {
            text.removeLast(2)
        }
        return text
    }
}

/// A category together with how many records it holds (SPEC §6.12 shows the count in
/// the sidebar).
public struct CategoryCount: Sendable, Equatable {
    public let category: FrequencyCategory
    public let count: Int
}

// MARK: - Validation

/// One problem found in the catalogue. Python asserts the same conditions in
/// `tests/test_frequencies.py`; here they are available at runtime, so a broken data
/// file can be reported instead of silently mis-rendered.
public enum CatalogueIssue: Sendable, Equatable, CustomStringConvertible {
    case duplicateID(String)
    case unknownCategory(id: String, category: String)
    case invalidEvidence(id: String, evidence: EvidenceLevel)
    case badBeatValue(id: String)
    case badRange(id: String)
    case mixedBeatForms(id: String)
    case badCarrier(id: String)
    case emptyField(id: String, field: String)
    case badColor(id: String, color: String)

    public var description: String {
        switch self {
        case let .duplicateID(id):
            return "\(id): duplicate id"
        case let .unknownCategory(id, category):
            return "\(id): unknown category '\(category)'"
        case let .invalidEvidence(id, evidence):
            return "\(id): evidence '\(evidence.rawValue)' is not one of the four levels of SPEC §6.2"
        case let .badBeatValue(id):
            return "\(id): beat_hz must be > 0"
        case let .badRange(id):
            return "\(id): beat_min must be > 0 and beat_max must exceed beat_min"
        case let .mixedBeatForms(id):
            return "\(id): either beat_hz or beat_min/beat_max, never both and never neither"
        case let .badCarrier(id):
            return "\(id): carrier_hz must be > 0"
        case let .emptyField(id, field):
            return "\(id).\(field) is empty"
        case let .badColor(id, color):
            return "\(id): color '\(color)' must be #RRGGBB"
        }
    }
}

/// Why a catalogue could not be read at all.
public enum CatalogueError: Error, CustomStringConvertible, Sendable {
    case missingResource(name: String)
    case unreadable(url: URL, underlying: String)
    case malformed(underlying: String)

    public var description: String {
        switch self {
        case let .missingResource(name):
            return "Frequency reference not found in bundle: \(name)"
        case let .unreadable(url, underlying):
            return "Frequency reference could not be read at \(url.path): \(underlying)"
        case let .malformed(underlying):
            return "Frequency reference is malformed: \(underlying)"
        }
    }
}

// MARK: - Catalogue

/// The whole frequency reference: decoded, indexed and validated on demand.
///
/// Port of `binaural.data.frequencies` (CONTRACT §5). An immutable value — load it
/// once, hand it around freely across threads.
///
/// Unlike Python, there is no `lru_cache`: an immutable value needs no cache, and the
/// apps load the catalogue once at start-up.
public struct FrequencyCatalogue: Sendable, Equatable {

    /// File name inside the app bundle, set by the Copy Files phase in `project.yml`.
    public static let resourceName = "frequencies"
    public static let resourceExtension = "json"

    /// Version of the document schema; 1 as of SPEC §6.2.
    public let version: Int

    /// Categories sorted by `order`.
    public let categories: [FrequencyCategory]

    /// Records sorted ranges-first, then by beat value, then by id (SPEC §6.12).
    public let entries: [FrequencyEntry]

    private let indexByID: [String: Int]
    private let indexByCategory: [String: [Int]]
    private let categoryIndexByID: [String: Int]

    // MARK: Loading

    /// Read and index the reference from disk.
    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CatalogueError.unreadable(url: url, underlying: String(describing: error))
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw CatalogueError.malformed(underlying: String(describing: error))
        }

        version = document.version
        categories = document.categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        entries = document.frequencies
            .map(\.entry)
            .sorted { lhs, rhs in
                let (left, right) = (lhs.sortKey, rhs.sortKey)
                if left.group != right.group { return left.group < right.group }
                if left.value != right.value { return left.value < right.value }
                return left.id < right.id
            }

        indexByID = Dictionary(
            entries.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        categoryIndexByID = Dictionary(
            categories.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        var grouped: [String: [Int]] = [:]
        for (offset, entry) in entries.enumerated() {
            grouped[entry.category, default: []].append(offset)
        }
        indexByCategory = grouped
    }

    /// Read the reference out of a bundle — the Copy Files phase puts it there.
    public static func load(bundle: Bundle = .main) throws -> FrequencyCatalogue {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw CatalogueError.missingResource(name: "\(resourceName).\(resourceExtension)")
        }
        return try FrequencyCatalogue(contentsOf: url)
    }

    // MARK: Lookups

    /// The record with this id, or `nil`.
    public func entry(id: String) -> FrequencyEntry? {
        indexByID[id].map { entries[$0] }
    }

    /// The category with this id, or `nil`.
    public func category(id: String) -> FrequencyCategory? {
        categoryIndexByID[id].map { categories[$0] }
    }

    /// Every record of one category, in catalogue order.
    public func entries(inCategory id: String) -> [FrequencyEntry] {
        (indexByCategory[id] ?? []).map { entries[$0] }
    }

    /// How many records each category holds, in category `order` order. The count is
    /// computed here, never stored in the file (SPEC §6.1).
    public func categoriesWithCounts() -> [CategoryCount] {
        categories.map { category in
            CategoryCount(category: category, count: indexByCategory[category.id]?.count ?? 0)
        }
    }

    /// Records per evidence level. Levels with no records are present with `0`.
    public func totalsByEvidence() -> [EvidenceLevel: Int] {
        var totals: [EvidenceLevel: Int] = [:]
        for level in EvidenceLevel.defined {
            totals[level] = 0
        }
        for entry in entries {
            totals[entry.evidence, default: 0] += 1
        }
        return totals
    }

    // MARK: Search

    /// Find records by label, id, tag or effect text, optionally inside one category.
    ///
    /// An empty query returns everything (optionally restricted to `category`). A
    /// numeric query also matches `beat_hz`/`beat_min`/`beat_max` numerically, so
    /// `7.83` finds the Schumann record. The carrier is deliberately not matched: it is
    /// a default, so `200` would otherwise match almost every record.
    public func search(_ query: String, category: String? = nil) -> [FrequencyEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = Self.parseNumber(needle)

        return entries.filter { entry in
            if let category, entry.category != category { return false }
            if needle.isEmpty { return true }
            if let number, Self.hits(entry: entry, number: number) { return true }
            return Self.matches(entry: entry, needle: needle)
        }
    }

    private static func matches(entry: FrequencyEntry, needle: String) -> Bool {
        let haystack = [
            entry.label,
            entry.id,
            entry.effectEn,
            entry.effectRu,
            entry.category,
            entry.tags.joined(separator: " "),
        ]
        return haystack.contains { field in
            !field.isEmpty && field.lowercased().contains(needle)
        }
    }

    private static func hits(entry: FrequencyEntry, number: Double) -> Bool {
        for value in [entry.beatHz, entry.beatMin, entry.beatMax] {
            guard let value else { continue }
            if abs(value - number) <= 0.01 { return true }
        }
        return false
    }

    /// Parse a frequency query; `nil` when it is not a number. A comma is accepted as
    /// the decimal separator, like the Python helper.
    private static func parseNumber(_ text: String) -> Double? {
        let normalised = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalised)
    }

    // MARK: Validation

    /// Everything wrong with this catalogue. Empty means the data honours SPEC §6 and
    /// CONTRACT §5.
    public func validate() -> [CatalogueIssue] {
        var issues: [CatalogueIssue] = []
        let knownCategories = Set(categories.map(\.id))

        for category in categories {
            if category.color.isEmpty || !category.color.hasPrefix("#") || category.color.count != 7 {
                issues.append(.badColor(id: category.id, color: category.color))
            }
            for (field, value) in [
                ("icon", category.icon),
                ("label_en", category.labelEn),
                ("label_ru", category.labelRu),
                ("description_en", category.descriptionEn),
                ("description_ru", category.descriptionRu),
            ] where value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.emptyField(id: category.id, field: field))
            }
        }

        var seen = Set<String>()
        for entry in entries {
            if !seen.insert(entry.id).inserted {
                issues.append(.duplicateID(entry.id))
            }
            if !knownCategories.contains(entry.category) {
                issues.append(.unknownCategory(id: entry.id, category: entry.category))
            }
            if entry.evidence == .unknown {
                issues.append(.invalidEvidence(id: entry.id, evidence: .unknown))
            }
            switch (entry.beatHz, entry.beatMin, entry.beatMax) {
            case (.some, .some, .some):
                // Both forms at once — neither is authoritative.
                issues.append(.mixedBeatForms(id: entry.id))
            case let (hz?, nil, nil):
                if hz <= 0 { issues.append(.badBeatValue(id: entry.id)) }
            case let (nil, min?, max?):
                if min <= 0 || max <= min { issues.append(.badRange(id: entry.id)) }
            default:
                issues.append(.mixedBeatForms(id: entry.id))
            }
            if entry.carrierHz <= 0 {
                issues.append(.badCarrier(id: entry.id))
            }
            for (field, value) in [
                ("label", entry.label),
                ("effect_en", entry.effectEn),
                ("effect_ru", entry.effectRu),
                ("source", entry.source),
            ] where value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.emptyField(id: entry.id, field: field))
            }
        }

        return issues
    }
}

// MARK: - Decoding

/// Raw document shape (SPEC §6.2). Optional keys mirror the Python `_make_entry`
/// defaults; missing required keys throw, as the Python `KeyError` would.
private struct Document: Decodable {
    let version: Int
    let categories: [FrequencyCategory]
    let frequencies: [EntryDocument]

    enum CodingKeys: String, CodingKey {
        case version, categories, frequencies
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        categories = try container.decodeIfPresent([FrequencyCategory].self, forKey: .categories) ?? []
        frequencies = try container.decodeIfPresent([EntryDocument].self, forKey: .frequencies) ?? []
    }
}

private struct EntryDocument: Decodable {
    let entry: FrequencyEntry

    enum CodingKeys: String, CodingKey {
        case id, category, label, beatHz = "beat_hz", beatMin = "beat_min", beatMax = "beat_max"
        case carrierHz = "carrier_hz", effectEn = "effect_en", effectRu = "effect_ru"
        case evidence, source, tags
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entry = FrequencyEntry(
            id: try container.decode(String.self, forKey: .id),
            category: try container.decode(String.self, forKey: .category),
            label: try container.decode(String.self, forKey: .label),
            beatHz: try container.decodeIfPresent(Double.self, forKey: .beatHz),
            beatMin: try container.decodeIfPresent(Double.self, forKey: .beatMin),
            beatMax: try container.decodeIfPresent(Double.self, forKey: .beatMax),
            carrierHz: try container.decode(Double.self, forKey: .carrierHz),
            effectEn: try container.decodeIfPresent(String.self, forKey: .effectEn) ?? "",
            effectRu: try container.decodeIfPresent(String.self, forKey: .effectRu) ?? "",
            evidence: EvidenceLevel(lenient: try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""),
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? "",
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        )
    }
}