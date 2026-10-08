import Foundation
import XCTest

@testable import BinauralCore

/// The installer: what it extracts, what it refuses, and the order of the dangerous part.
///
/// The extract and verify steps run against real archives in temporary directories. The
/// replace and relaunch steps are injected everywhere they would touch the real bundle —
/// the two real ones are tested as `static` methods against fake bundles in a temporary
/// directory, which is the only safe way to exercise them.
@MainActor
final class UpdateInstallerTests: XCTestCase {

    // MARK: - Fixtures

    /// A fake `.app` bundle: `Contents/MacOS/<name>` plus an Info.plist with a version.
    private func makeAppBundle(
        name: String = "Binaural.app",
        version: String = "0.2.0"
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)")
        let bundle = directory.appendingPathComponent(name)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
        try Data("binary".utf8).write(to: executable)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>\(version)</string>
        </dict>
        </plist>
        """
        try Data(plist.utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return bundle
    }

    /// Tar a directory into a `.tar.gz` beside it, the way the release archive is built.
    private func makeArchive(of directory: URL, named name: String) throws -> URL {
        let archive = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)-\(name)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-czf", archive.path,
            "-C", directory.deletingLastPathComponent().path,
            directory.lastPathComponent,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "tar failed")
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// An installer whose dangerous steps are recorded rather than performed.
    private func makeStubInstaller(
        events: Recorder<String>
    ) -> UpdateInstaller {
        UpdateInstaller(
            replace: { _, _ in events.append("replace") },
            relauncher: { _ in events.append("relaunch") }
        )
    }

    // MARK: - Extract

    /// The archive's `.app` is found and returned, with its version verified.
    func testExtractFindsTheAppInsideTheArchive() throws {
        let app = try makeAppBundle(version: "0.2.0")
        let archive = try makeArchive(of: app, named: "binaural-0.2.0-macos-arm64.tar.gz")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        let extracted = try installer.extract(archive, expectedVersion: AppVersion("0.2.0")!)
        XCTAssertEqual(extracted.lastPathComponent, "Binaural.app")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: extracted.appendingPathComponent("Contents/Info.plist").path
        ))
        XCTAssertTrue(events.snapshot.isEmpty, "extracting touches nothing installed")
    }

    /// An archive with no `.app` in it is refused, and the extraction directory is cleaned up.
    func testExtractRefusesAnArchiveWithNoApp() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: directory.appendingPathComponent("README.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let archive = try makeArchive(of: directory, named: "no-app.tar.gz")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        XCTAssertThrowsError(try installer.extract(archive)) { error in
            XCTAssertEqual(error as? UpdateInstaller.UpdateInstallError, .archiveHasNoApp)
        }
    }

    /// A file that is not a tarball at all is refused.
    func testExtractRefusesAnUnreadableArchive() throws {
        let archive = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)-not-a-tarball.tar.gz")
        try Data("garbage".utf8).write(to: archive)
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        XCTAssertThrowsError(try installer.extract(archive)) { error in
            XCTAssertEqual(error as? UpdateInstaller.UpdateInstallError, .unreadableArchive)
        }
    }

    /// A bundle without `Contents/MacOS/<name>` is not an app and is refused.
    func testExtractRefusesAnIncompleteBundle() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("Binaural.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let archive = try makeArchive(of: app, named: "incomplete.tar.gz")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        XCTAssertThrowsError(try installer.extract(archive)) { error in
            guard case .incompleteBundle = error as? UpdateInstaller.UpdateInstallError else {
                return XCTFail("expected an incomplete-bundle error, got \(error)")
            }
        }
    }

    /// The version inside the archive must be the one that was offered: a stale or wrong
    /// download is refused before anything installed is touched.
    func testExtractChecksTheVersionAgainstTheRelease() throws {
        let app = try makeAppBundle(version: "0.2.0")
        let archive = try makeArchive(of: app, named: "binaural-0.2.0-macos-arm64.tar.gz")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        XCTAssertThrowsError(try installer.extract(archive, expectedVersion: AppVersion("0.3.0")!)) { error in
            XCTAssertEqual(
                error as? UpdateInstaller.UpdateInstallError,
                .versionMismatch(expected: AppVersion("0.3.0")!, found: "0.2.0")
            )
        }
        // The right version passes.
        _ = try installer.extract(archive, expectedVersion: AppVersion("0.2.0")!)
    }

    // MARK: - Install

    /// A verified bundle is replaced and then relaunched, in that order.
    func testInstallReplacesThenRelaunches() throws {
        let app = try makeAppBundle(version: "0.2.0")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        try installer.install(newBundle: app, expectedVersion: AppVersion("0.2.0")!)
        XCTAssertEqual(events.snapshot, ["replace", "relaunch"])
    }

    /// A version mismatch means the replace never happens — the running bundle is safe.
    func testInstallRefusesToReplaceAVersionThatDoesNotMatch() throws {
        let app = try makeAppBundle(version: "0.2.0")
        let events = Recorder<String>()
        let installer = makeStubInstaller(events: events)
        XCTAssertThrowsError(try installer.install(newBundle: app, expectedVersion: AppVersion("9.9.9")!)) { error in
            guard case .versionMismatch = error as? UpdateInstaller.UpdateInstallError else {
                return XCTFail("expected a version mismatch, got \(error)")
            }
        }
        XCTAssertTrue(events.snapshot.isEmpty, "nothing is replaced when the version is wrong")
    }

    /// The one-shot install extracts, replaces, relaunches and cleans up after itself.
    func testTheOneShotInstallRunsTheWholeSequence() throws {
        let app = try makeAppBundle(version: "0.2.0")
        let archive = try makeArchive(of: app, named: "binaural-0.2.0-macos-arm64.tar.gz")
        let events = Recorder<String>()
        let relaunched = Recorder<URL>()
        let installer = UpdateInstaller(
            replace: { _, _ in events.append("replace") },
            relauncher: { relaunched.append($0); events.append("relaunch") }
        )
        try installer.install(archive: archive, expectedVersion: AppVersion("0.2.0")!)
        XCTAssertEqual(events.snapshot, ["replace", "relaunch"])
        XCTAssertEqual(relaunched.snapshot.count, 1)
    }

    // MARK: - The real replace, against fake bundles in a temporary directory

    /// The new bundle ends up where the old one was, with its version in place.
    func testTheDefaultReplacePutsTheNewBundleInPlace() throws {
        let current = try makeAppBundle(version: "0.1.0")
        let new = try makeAppBundle(version: "0.2.0")
        try UpdateInstaller.defaultReplace(new, current)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Contents/Info.plist").path
        ))
        let info = try? Bundle(url: current)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(info, "0.2.0", "the new bundle's version is the one in place")
        // No backup is left behind. `contentsOfDirectory` returns directories with a
        // trailing slash, so the comparison is on the last path component.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: current.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            leftovers.map(\.lastPathComponent),
            [current.lastPathComponent],
            "only the installed bundle remains: \(leftovers)"
        )
    }

    /// When the copy fails, the old bundle is back where it was and the app is untouched.
    func testTheDefaultReplaceRestoresTheOldBundleWhenTheCopyFails() throws {
        let current = try makeAppBundle(version: "0.1.0")
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-installer-test-\(UUID().uuidString)-missing.app")
        XCTAssertThrowsError(try UpdateInstaller.defaultReplace(missing, current)) { error in
            guard case .replaceFailed = error as? UpdateInstaller.UpdateInstallError else {
                return XCTFail("expected a replace failure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Contents/Info.plist").path
        ), "the current bundle is still in place")
        let info = try? Bundle(url: current)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertEqual(info, "0.1.0", "the old bundle was restored, not the missing one")
    }
}
