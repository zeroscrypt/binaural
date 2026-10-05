import BinauralCore
import SwiftUI

/// iOS shell for the Swift implementation.
///
/// M1 scope, same as the macOS shell: prove the app builds, links `BinauralCore` and
/// reads `frequencies.json` out of its own bundle (Copy Files phase in `project.yml`),
/// then show what the catalogue holds and what the default session would play. The real
/// interface is M2 — see `apple/DESIGN.md` §4.
@main
struct BinauraliOSApp: App {
    var body: some Scene {
        WindowGroup {
            CatalogueScreen()
        }
    }
}

/// One screen, one job: report what the shared data layer actually loaded.
struct CatalogueScreen: View {
    private let report = CatalogueReport.load()

    var body: some View {
        List {
            Section("Binaural — Swift foundation (M1)") {
                Text(report.headline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Frequency reference") {
                ForEach(report.categoryLines, id: \.self) { line in
                    Text(line)
                }
            }

            Section("Evidence levels") {
                Text(report.evidenceLine)
                Text(report.validationLine)
                    .foregroundStyle(report.isValid ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }

            Section("Default session") {
                Text(report.sessionLine)
                Text("Timer: \(report.timerMinutes) min")
                Text("Preset category: \(report.presetCategory)")
                Text(report.pairLine)
            }
        }
        .navigationTitle("Binaural")
    }
}

/// Everything the screen shows, assembled once from the catalogue.
///
/// A plain `Sendable` value rather than `@Observable` state: M1 renders facts about the
/// data layer, and nothing here is edited yet.
struct CatalogueReport: Sendable {
    let headline: String
    let categoryLines: [String]
    let evidenceLine: String
    let validationLine: String
    let isValid: Bool
    let sessionLine: String
    let timerMinutes: Int
    let presetCategory: String
    let pairLine: String

    static func load() -> CatalogueReport {
        let session = Session.standard
        let pair = try? BeatMath.pair(fromBeat: 10, carrierHz: 200)

        do {
            let catalogue = try FrequencyCatalogue.load(bundle: .main)
            let totals = catalogue.totalsByEvidence()
            let evidence = EvidenceLevel.defined
                .map { "\($0.badge) \($0.rawValue): \(totals[$0] ?? 0)" }
                .joined(separator: "  ")
            let issues = catalogue.validate()
            return CatalogueReport(
                headline: "Loaded from frequencies.json in the app bundle "
                    + "(src/binaural/data/frequencies.json), document version \(catalogue.version).",
                categoryLines: catalogue.categoriesWithCounts().map {
                    "\($0.category.icon) \($0.category.labelEn): \($0.count)"
                },
                evidenceLine: evidence,
                validationLine: issues.isEmpty
                    ? "Validation: no issues"
                    : "Validation: \(issues.count) issue(s) — \(issues[0])",
                isValid: issues.isEmpty,
                sessionLine: String(
                    format: "Left %.1f Hz · Right %.1f Hz → beat %.1f Hz, carrier %.1f Hz",
                    session.leftHz, session.rightHz, session.beatHz, session.carrierHz
                ),
                timerMinutes: session.timerMinutes,
                presetCategory: session.presetCategory,
                pairLine: pair.map { "pair(beat: 10, carrier: 200) = \(format($0.left)) / \(format($0.right)) Hz" }
                    ?? "pair(beat: 10, carrier: 200) is impossible"
            )
        } catch {
            return CatalogueReport(
                headline: "frequencies.json is missing from the bundle: \(error)",
                categoryLines: ["No records."],
                evidenceLine: "—",
                validationLine: "Validation: not run",
                isValid: false,
                sessionLine: "—",
                timerMinutes: session.timerMinutes,
                presetCategory: session.presetCategory,
                pairLine: "—"
            )
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}