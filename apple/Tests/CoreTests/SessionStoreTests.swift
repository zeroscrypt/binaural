import Foundation
import XCTest

@testable import BinauralCore

/// Where the session document lives — the M2 decision recorded in `apple/DESIGN.md` §7.
///
/// `Session`'s own round-trip is covered by `SessionTests` (M1). What is new here is the
/// store: the path, the leniency, and the promise that a failed write is reported rather
/// than thrown at the window.
final class SessionStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("binaural-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultPathIsApplicationSupport() throws {
        let store = try SessionStore.applicationSupport(bundleIdentifier: "app.binaural.test")
        let expected = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("app.binaural.test", isDirectory: true)
        .appendingPathComponent(SessionStore.fileName)

        XCTAssertEqual(store.url, expected)
        XCTAssertEqual(store.url.lastPathComponent, "session.json")
        // Nothing is created until something is written: reading a store must not litter
        // Application Support.
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
    }

    func testMissingFileYieldsTheStandardSession() {
        let store = SessionStore(url: directory.appendingPathComponent("nothing-here.json"))
        XCTAssertEqual(store.load(), Session.standard)
    }

    func testSaveThenLoadRoundTrips() {
        let store = SessionStore(url: directory.appendingPathComponent(SessionStore.fileName))
        let session = Session(leftHz: 231.5, rightHz: 240.5, volume: 0.42, timerMinutes: 30)
        XCTAssertTrue(store.save(session))
        XCTAssertEqual(store.load(), session)
    }

    /// The leniency rules of CONTRACT §7 survive the store: a damaged document is the
    /// default session, never a failed launch.
    func testDamagedFileYieldsTheStandardSession() throws {
        let url = directory.appendingPathComponent(SessionStore.fileName)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(SessionStore(url: url).load(), Session.standard)
    }

    func testPartialFileKeepsDefaultsForMissingKeys() throws {
        let url = directory.appendingPathComponent(SessionStore.fileName)
        try Data(#"{"left_hz": 180.0}"#.utf8).write(to: url)
        let loaded = SessionStore(url: url).load()
        XCTAssertEqual(loaded.leftHz, 180.0)
        XCTAssertEqual(loaded.rightHz, Session.standard.rightHz)
        XCTAssertEqual(loaded.volume, Session.standard.volume)
    }

    func testSaveCreatesTheContainingDirectory() {
        let url = directory
            .appendingPathComponent("deep", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent(SessionStore.fileName)
        XCTAssertTrue(SessionStore(url: url).save(Session.standard))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Persistence is a convenience, never a blocker: an unwritable path reports `false`
    /// and does not throw at the caller.
    func testUnwritablePathReportsFailureInsteadOfThrowing() {
        // A path whose parent is a *file* cannot be created as a directory.
        let file = directory.appendingPathComponent("not-a-directory")
        try? Data("x".utf8).write(to: file)
        let store = SessionStore(url: file.appendingPathComponent("session.json"))
        XCTAssertFalse(store.save(Session.standard))
        // And reading it is still safe.
        XCTAssertEqual(store.load(), Session.standard)
    }

    func testStoreEqualityIsByURL() {
        let url = directory.appendingPathComponent("session.json")
        XCTAssertEqual(SessionStore(url: url), SessionStore(url: url))
        XCTAssertNotEqual(SessionStore(url: url), SessionStore(url: directory))
    }
}