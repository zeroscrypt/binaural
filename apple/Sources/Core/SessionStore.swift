import Foundation

/// Where the session document lives.
///
/// M1 left this open (`apple/DESIGN.md` §5, deviation 1: "`Session` is `Codable` and
/// round-trips JSON at an explicit URL … Which file the app opens is an M2
/// decision"). The decision, and why:
///
/// * **Application Support**, not `UserDefaults`. The session is a document with a
///   schema that `docs/CONTRACT.md` §7 pins down field by field — it is going to grow
///   (presets, timer), it is the thing an export/import would move, and it must stay
///   readable by both implementations. `UserDefaults` is for small preferences whose
///   storage format the app should not depend on; a plist of nested keys would also
///   force a second, different on-disk shape next to the documented JSON one.
/// * **One file, `session.json`**, written atomically. `Session.save(to:)` already
///   writes through `.atomic`, so a crash mid-write cannot leave a half session —
///   which matters more here than in Python, where `QSettings` is an ini.
/// * **Per-bundle directory**, `~/Library/Application Support/app.binaural.mac/`, the
///   documented macOS location for exactly this: backed up, not synced, not shown in
///   Finder.
public struct SessionStore: Sendable, Equatable {

    /// The file name inside the store directory.
    public static let fileName = "session.json"

    /// The session document.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/<bundle identifier>/session.json`.
    ///
    /// - Throws: when the application-support directory cannot be located or created
    ///   — a real failure the caller should report, unlike a missing file.
    public static func applicationSupport(bundleIdentifier: String) throws -> SessionStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SessionStore(
            url: base
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent(fileName)
        )
    }

    /// Read the session, or the standard one when there is nothing to read.
    ///
    /// Never throws: the whole point of the lenient `Session.load(from:)` rules is that
    /// a missing or damaged file must not stop the app from starting.
    public func load() -> Session {
        (try? Session.load(from: url)) ?? Session.standard
    }

    /// Write the session. Returns `false` when the write failed — persistence is a
    /// convenience, never a blocker, so the caller does not have to handle it.
    @discardableResult
    public func save(_ session: Session) -> Bool {
        (try? session.save(to: url)) != nil
    }
}