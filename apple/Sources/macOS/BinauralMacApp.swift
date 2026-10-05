import AppKit
import BinauralCore

/// macOS shell for the Swift implementation.
///
/// M1 scope: prove the app launches, links `BinauralCore`, finds `frequencies.json`
/// inside its own bundle (the Copy Files phase in `project.yml` put it there) and shows
/// what the catalogue contains plus the beat/carrier of the default session. The real
/// interface is M2 — see `apple/DESIGN.md` §4.
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

    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Binaural"
        window.center()
        window.contentView = makeContentView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Content

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(heading("Binaural — Swift foundation (M1)"))
        stack.addArrangedSubview(caption(
            "Data source: src/binaural/data/frequencies.json, copied into this bundle by the Xcode build phase."
        ))

        let result: Result<FrequencyCatalogue, Error>
        do {
            result = .success(try FrequencyCatalogue.load(bundle: .main))
        } catch {
            result = .failure(error)
        }

        switch result {
        case let .success(catalogue):
            stack.addArrangedSubview(heading("Frequency reference"))
            stack.addArrangedSubview(body(
                "\(catalogue.entries.count) records in \(catalogue.categories.count) categories · document version \(catalogue.version)"
            ))
            for count in catalogue.categoriesWithCounts() {
                stack.addArrangedSubview(row(
                    "\(count.category.icon) \(count.category.labelEn)",
                    detail: "\(count.count)"
                ))
            }

            let totals = catalogue.totalsByEvidence()
            let summary = EvidenceLevel.defined
                .map { "\($0.badge) \($0.rawValue) \(totals[$0] ?? 0)" }
                .joined(separator: "   ")
            stack.addArrangedSubview(caption(summary))

            let issues = catalogue.validate()
            stack.addArrangedSubview(caption(
                issues.isEmpty ? "Validation: no issues" : "Validation: \(issues.count) issue(s)"
            ))

            stack.addArrangedSubview(heading("Default session"))
            let session = Session.standard
            stack.addArrangedSubview(body(
                "Left \(fmt(session.leftHz)) Hz · Right \(fmt(session.rightHz)) Hz → beat \(fmt(session.beatHz)) Hz, carrier \(fmt(session.carrierHz)) Hz"
            ))
            stack.addArrangedSubview(row("Timer", detail: "\(session.timerMinutes) min"))
            stack.addArrangedSubview(row("Preset category", detail: session.presetCategory))
            if let pair = try? BeatMath.pair(fromBeat: 10, carrierHz: 200) {
                stack.addArrangedSubview(row(
                    "pair(beat: 10, carrier: 200)",
                    detail: "\(fmt(pair.left)) / \(fmt(pair.right)) Hz"
                ))
            }
        case let .failure(error):
            stack.addArrangedSubview(heading("Frequency reference"))
            stack.addArrangedSubview(body("Could not load frequencies.json:"))
            stack.addArrangedSubview(caption(String(describing: error)))
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    // MARK: - Small view helpers (no M2 design system yet)

    private func heading(_ text: String) -> NSTextField {
        label(text, size: 17, weight: .semibold, color: .labelColor)
    }

    private func body(_ text: String) -> NSTextField {
        label(text, size: 13, weight: .regular, color: .labelColor)
    }

    private func caption(_ text: String) -> NSTextField {
        label(text, size: 11, weight: .regular, color: .secondaryLabelColor)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func row(_ title: String, detail: String) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.addArrangedSubview(label(title, size: 13, weight: .regular, color: .labelColor))
        stack.addArrangedSubview(label(detail, size: 13, weight: .medium, color: .secondaryLabelColor))
        return stack
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}