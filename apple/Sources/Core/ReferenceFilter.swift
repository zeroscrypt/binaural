import Foundation

/// The reference dialog's query state (SPEC §6.12).
///
/// A plain value on purpose: "which records are on screen" is a function of the query,
/// the category and the evidence filter, and keeping it out of the view is what lets
/// every filtering rule be tested without AppKit. The sorting rule is already in
/// ``FrequencyCatalogue`` (ranges first, then by beat value — §6.12), so this only adds
/// the evidence filter on top and does not re-sort.
public struct ReferenceFilter: Sendable, Equatable {

    /// Free-text query over name, frequency, effect and tags.
    public var query: String
    /// `nil` means "all categories" — the first row of the sidebar.
    public var categoryID: String?
    /// `nil` hides nothing, which is the SPEC §6.2 default: the badge is a hint for the
    /// reader, never a filter that quietly drops records.
    public var evidence: EvidenceLevel?

    public init(query: String = "", categoryID: String? = nil, evidence: EvidenceLevel? = nil) {
        self.query = query
        self.categoryID = categoryID
        self.evidence = evidence
    }

    /// The records to show, in catalogue order.
    public func apply(to catalogue: FrequencyCatalogue) -> [FrequencyEntry] {
        let found = catalogue.search(query, category: categoryID)
        guard let evidence else { return found }
        return found.filter { $0.evidence == evidence }
    }
}

/// What "Apply" means for a reference record (SPEC §6.12).
///
/// Port of `ui/dialogs/reference.py::frequencies_for`, kept out of the dialog so the
/// rule — a range plays its middle, a *tonal* record becomes the carrier — is testable
/// and cannot drift between platforms.
public enum ReferenceApply {

    /// The beat given to a tonal record. Those store a tone frequency, not a difference,
    /// so without a beat of its own "528 Hz" would be played as a 528 Hz *difference*,
    /// which is not what the record is about.
    public static let tonalBeatHz: Double = 10.0

    /// The pair that realises a record.
    ///
    /// * a range record uses the middle of its band;
    /// * a tonal record uses its own frequency as the carrier and ``tonalBeatHz`` as the
    ///   difference;
    /// * anything else plays its beat around the recommended carrier.
    ///
    /// A record whose pair would leave the audible range falls back to the default
    /// carrier instead of throwing, so a click on "Apply" can never fail.
    public static func frequencies(for entry: FrequencyEntry) -> (left: Double, right: Double) {
        let recommendedCarrier = entry.carrierHz > 0
            ? entry.carrierHz
            : BeatMath.defaultCarrierHz

        var carrier = recommendedCarrier
        let beat: Double
        if entry.isRange {
            beat = ((entry.beatMin ?? 0) + (entry.beatMax ?? 0)) / 2
        } else if entry.isTonal {
            carrier = entry.beatHz ?? recommendedCarrier
            beat = tonalBeatHz
        } else {
            beat = entry.beatHz ?? 0
        }

        guard let pair = try? BeatMath.pair(fromBeat: beat, carrierHz: carrier) else {
            let fallback = (try? BeatMath.pair(
                fromBeat: min(beat, tonalBeatHz),
                carrierHz: BeatMath.defaultCarrierHz
            )) ?? (BeatMath.defaultCarrierHz, BeatMath.defaultCarrierHz)
            return (fallback.0, fallback.1)
        }
        return (pair.left, pair.right)
    }
}
