import Foundation
import XCTest

@testable import BinauralCore

/// The update check: version order, the GitHub payload, and which archive gets installed.
///
/// Every case here runs against a canned document and a stub fetch — the suite must not
/// touch the network, because a test that depends on GitHub is a test that fails when
/// GitHub is down.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version order

    /// The rule the whole feature rests on, and the one a string comparison gets backwards:
    /// `0.10.0` is **newer** than `0.1.0`.
    func testComponentsAreComparedNumerically() {
        XCTAssertNotEqual(AppVersion("0.1.0")!, AppVersion("0.10.0")!)
        XCTAssertTrue(AppVersion("0.10.0")! < AppVersion("0.11.0")!)
        XCTAssertTrue(AppVersion("0.1.9")! < AppVersion("0.1.10")!)
        XCTAssertTrue(AppVersion("0.2")! < AppVersion("0.10")!)
    }

    func testOrderingIsTheSameInBothDirections() {
        let pairs = [("0.1.0", "0.1.1"), ("0.9.9", "0.10.0"), ("1.0.0", "1.0.1"), ("0.1", "0.1.1")]
        for (older, newer) in pairs {
            XCTAssertTrue(AppVersion(older)! < AppVersion(newer)!, "\(older) < \(newer)")
            XCTAssertFalse(AppVersion(newer)! < AppVersion(older)!, "\(newer) >= \(older)")
            XCTAssertEqual(AppVersion(older)!.compare(AppVersion(newer)!), .orderedAscending)
        }
    }

    /// `project.yml` ships `MARKETING_VERSION: "0.1"` and the release is tagged `v0.1.0`.
    /// If those were different versions the shipping build would be told it is out of date
    /// by its own release, on every launch, forever.
    func testAMissingComponentIsZero() {
        XCTAssertEqual(AppVersion("0.1"), AppVersion("0.1.0"))
        XCTAssertEqual(AppVersion("1"), AppVersion("1.0"))
        XCTAssertEqual(AppVersion("1.0.0.0.0"), AppVersion("1"))
        XCTAssertFalse(AppVersion("0.1")! < AppVersion("0.1.0")!)
        XCTAssertFalse(AppVersion("0.1.0")! < AppVersion("0.1")!)
    }

    func testALeadingVIsTheTagSpellingNotAVersion() {
        XCTAssertEqual(AppVersion("v0.1.0"), AppVersion("0.1.0"))
        XCTAssertEqual(AppVersion("V0.10.0"), AppVersion("0.10.0"))
        XCTAssertEqual(AppVersion("  v0.2.0  "), AppVersion("0.2.0"))
        XCTAssertEqual(AppVersion("v0.1.0")!.raw, "0.1.0")
    }

    /// A pre-release is earlier than the release it leads up to, so a beta is never offered
    /// to somebody running the release.
    func testAPreReleaseIsOlderThanItsRelease() {
        XCTAssertTrue(AppVersion("0.2.0-beta.1")! < AppVersion("0.2.0")!)
        XCTAssertTrue(AppVersion("0.2.0")! < AppVersion("0.2.1-beta.1")!)
        XCTAssertFalse(AppVersion("0.2.0")! < AppVersion("0.2.0-beta.1")!)
        XCTAssertTrue(AppVersion("0.2.0-alpha")! < AppVersion("0.2.0-beta")!)
        XCTAssertEqual(AppVersion("0.2.0-beta.1")!.prerelease, "beta.1")
        XCTAssertNil(AppVersion("0.2.0")!.prerelease)
    }

    /// Build metadata is not part of the order, and rubbish after the numbers is ignored
    /// rather than throwing: a tag is text somebody typed.
    func testParsingIsLenientAboutWhatFollowsTheNumbers() {
        XCTAssertEqual(AppVersion("1.2.3+20261006"), AppVersion("1.2.3"))
        XCTAssertEqual(AppVersion("1.2.3 (17)"), AppVersion("1.2.3"))
        XCTAssertEqual(AppVersion("0.10.0abc"), AppVersion("0.10.0"))
        XCTAssertEqual(AppVersion("1.2.x"), AppVersion("1.2"))
        XCTAssertEqual(AppVersion("1.2.3")!.description, "1.2.3")
        XCTAssertEqual(AppVersion("1.2.3-beta.1")!.description, "1.2.3-beta.1")
    }

    /// Text with no version in it is `nil`, never a crash and never a fake `0`.
    func testTextThatIsNotAVersionIsNil() {
        for text in ["", "   ", "v", "release", "beta", "-1", "abc.def"] {
            XCTAssertNil(AppVersion(text), "\(text) parsed as a version")
        }
    }

    // MARK: - The bundle

    /// The running version comes from `CFBundleShortVersionString`, and the build number is
    /// the fallback so a build without a marketing version still compares.
    func testTheRunningVersionComesFromTheBundle() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "0.1",
            "CFBundleVersion": "17",
        ])
        XCTAssertEqual(AppVersion.running(bundle: bundle), AppVersion("0.1"))
    }

    func testTheBuildNumberIsTheFallback() throws {
        let bundle = try makeBundle(info: ["CFBundleVersion": "17"])
        XCTAssertEqual(AppVersion.running(bundle: bundle), AppVersion("17"))
    }

    /// No version in the bundle at all is `nil`, i.e. the check reports "cannot tell"
    /// rather than inventing a version to compare against.
    func testABundleWithoutAVersionIsNil() throws {
        let bundle = try makeBundle(info: ["CFBundleName": "Binaural"])
        XCTAssertNil(AppVersion.running(bundle: bundle))
    }

    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }

    // MARK: - The payload

    /// `static`, not an instance method: the `fetch` closures below are `@Sendable` and
    /// nonisolated, so they cannot reach a `@MainActor` method of the test case.
    /// `nonisolated` for the same reason — the class is `@MainActor`, and a static method of
    /// a `@MainActor` type is main-actor isolated with it.
    private nonisolated static func releaseJSON(
        tag: String = "v0.2.0",
        assets: [(name: String, size: Int64)] = [
            ("binaural-0.2.0-macos-arm64.tar.gz", 2_400_000),
            ("binaural-0.2.0-windows-amd64.zip", 3_000_000),
            ("Source code (zip)", 900_000),
        ]
    ) -> Data {
        let encodedAssets = assets.map { asset in
            """
            {"name": "\(asset.name)", "size": \(asset.size), \
            "browser_download_url": "https://github.com/zeroscrypt/binaural/releases/download/\(tag)/\(asset.name)", \
            "content_type": "application/gzip"}
            """
        }.joined(separator: ", ")
        return Data("""
            {
              "tag_name": "\(tag)",
              "name": "0.2.0",
              "html_url": "https://github.com/zeroscrypt/binaural/releases/tag/\(tag)",
              "draft": false,
              "prerelease": false,
              "published_at": "2026-10-08T12:00:00Z",
              "assets": [\(encodedAssets)]
            }
            """.utf8)
    }

    private static func checker(
        tag: String = "v0.2.0",
        assets: [(name: String, size: Int64)] = [
            ("binaural-0.2.0-macos-arm64.tar.gz", 2_400_000),
            ("binaural-0.2.0-windows-amd64.zip", 3_000_000),
        ]
    ) -> UpdateChecker {
        let document = releaseJSON(tag: tag, assets: assets)
        return UpdateChecker(
            endpoint: UpdateChecker.defaultEndpoint,
            fetch: { _ in document }
        )
    }

    /// A newer tag is an update, and the release carries the archive to install.
    func testANewerTagIsAnUpdate() async throws {
        let availability = try await Self.checker().check(currentVersion: AppVersion("0.1")!)
        guard case .updateAvailable(let current, let release) = availability else {
            return XCTFail("expected an update, got \(availability)")
        }
        XCTAssertEqual(current, AppVersion("0.1"))
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.version, AppVersion("0.2.0"))
        XCTAssertFalse(release.isDraft)
        XCTAssertFalse(release.isPrerelease)
        XCTAssertEqual(
            release.macOSArchive()?.name, "binaural-0.2.0-macos-arm64.tar.gz"
        )
    }

    /// The shipping state: `0.1` against `v0.1.0`. This is the case that makes the feature
    /// quiet on a correctly installed release.
    func testTheRunningReleaseIsNotOfferedToItself() async throws {
        let availability = try await Self.checker(tag: "v0.1.0").check(currentVersion: AppVersion("0.1")!)
        guard case .upToDate(let current) = availability else {
            return XCTFail("expected up to date, got \(availability)")
        }
        XCTAssertEqual(current, AppVersion("0.1"))
        XCTAssertNil(availability.release)
        XCTAssertFalse(availability.isWorthTelling)
    }

    func testAnOlderTagIsNotAnUpdate() async throws {
        let availability = try await Self.checker(tag: "v0.0.9").check(currentVersion: AppVersion("0.1")!)
        XCTAssertEqual(availability, .upToDate(current: AppVersion("0.1")!))
    }

    /// "Skip this version" is its own answer: silent at launch, still reported when the
    /// user asks. A newer release than the skipped one is offered normally.
    func testSkippingSilencesOneVersionOnly() async throws {
        let checker = Self.checker()
        let skipped = try await checker.check(
            currentVersion: AppVersion("0.1")!, skipping: AppVersion("0.2.0")
        )
        guard case .skipped(_, let release) = skipped else {
            return XCTFail("expected a skipped release, got \(skipped)")
        }
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertFalse(skipped.isWorthTelling, "the launch check must stay silent")

        let newer = UpdateChecker(fetch: { _ in
            Self.releaseJSON(tag: "v0.3.0", assets: [
                ("binaural-0.3.0-macos-arm64.tar.gz", 10),
            ])
        })
        let offered = try await newer.check(
            currentVersion: AppVersion("0.1")!, skipping: AppVersion("0.2.0")
        )
        XCTAssertTrue(offered.isWorthTelling)
    }

    // MARK: - Which archive

    /// The exact name wins even when several archives look plausible.
    func testTheExactArchiveIsPreferred() {
        let release = GitHubRelease(
            tagName: "v0.2.0",
            assets: [
                ReleaseAsset(name: "binaural-0.2.0-macos.tar.gz", downloadURL: url("a")),
                ReleaseAsset(name: "binaural-0.2.0-macos-arm64.tar.gz", downloadURL: url("b")),
            ]
        )
        XCTAssertEqual(release.macOSArchive()?.name, "binaural-0.2.0-macos-arm64.tar.gz")
    }

    /// A renamed asset is still installed rather than refused — the archive is verified by
    /// its contents in `UpdateInstaller` before anything is replaced.
    func testARenamedArchiveIsStillFound() {
        let release = GitHubRelease(
            tagName: "v0.2.0",
            assets: [
                ReleaseAsset(name: "Binaural-macOS-arm64.tar.gz", downloadURL: url("a")),
                ReleaseAsset(name: "binaural-0.2.0-windows.zip", downloadURL: url("b")),
            ]
        )
        XCTAssertEqual(release.macOSArchive()?.name, "Binaural-macOS-arm64.tar.gz")
    }

    func testAnArchiveForAnotherPlatformIsNotOffered() {
        let release = GitHubRelease(
            tagName: "v0.2.0",
            assets: [ReleaseAsset(name: "binaural-0.2.0-windows-amd64.zip", downloadURL: url("a"))]
        )
        XCTAssertNil(release.macOSArchive(), "there is no macOS archive in this release")
    }

    // MARK: - Failures

    func testAMalformedDocumentIsAnError() async {
        let checker = UpdateChecker(fetch: { _ in Data("not json at all".utf8) })
        await assertThrows(.unreadablePayload) {
            _ = try await checker.check(currentVersion: AppVersion("0.1")!)
        }
    }

    /// A tag that is not a version is an error, never a crash and never a made-up version.
    func testATagThatIsNotAVersionIsAnError() async {
        let checker = UpdateChecker(fetch: { _ in Self.releaseJSON(tag: "nightly") })
        await assertThrows(.missingVersionTag) {
            _ = try await checker.check(currentVersion: AppVersion("0.1")!)
        }
    }

    func testAFailedRequestIsATransportError() async {
        struct Offline: Error {}
        let checker = UpdateChecker(fetch: { _ in throw Offline() })
        do {
            _ = try await checker.check(currentVersion: AppVersion("0.1")!)
            XCTFail("a failed request must not look like an answer")
        } catch {
            guard case .transport = error as? UpdateError else {
                return XCTFail("expected a transport error, got \(error)")
            }
        }
    }

    func testANonSuccessStatusIsAnError() async {
        // The default fetch maps the status; here the status mapping itself is checked by
        // pointing the checker at a fetch that throws it, so the test does not need a server.
        let checker = UpdateChecker(fetch: { _ in throw UpdateError.httpStatus(403) })
        do {
            _ = try await checker.check(currentVersion: AppVersion("0.1")!)
            XCTFail("403 must not look like an answer")
        } catch {
            XCTAssertEqual(error as? UpdateError, .httpStatus(403))
        }
    }

    /// GitHub's own shape: fields the app does not read are ignored, not fatal.
    func testUnknownFieldsAreIgnored() async throws {
        let document = Data("""
            {"tag_name": "v0.2.0", "node_id": "abc", "author": {"login": "x"}, "assets": []}
            """.utf8)
        let checker = UpdateChecker(fetch: { _ in document })
        let release = try await checker.latestRelease()
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertTrue(release.assets.isEmpty)
    }

    /// The default endpoint is this repository's releases API, spelled out in one place.
    func testTheDefaultEndpointIsThisRepository() {
        XCTAssertEqual(
            UpdateChecker.defaultEndpoint.absoluteString,
            "https://api.github.com/repos/zeroscrypt/binaural/releases/latest"
        )
    }

    /// The check orders versions with `AppVersion` — the injected comparator is a seam for
    /// tests, not a second implementation of "newer".
    func testTheCheckOrdersVersionsWithAppVersion() {
        let checker = UpdateChecker()
        XCTAssertEqual(
            checker.ordering(of: AppVersion("0.1.0")!, AppVersion("0.10.0")!), .orderedAscending
        )
        XCTAssertEqual(
            checker.ordering(of: AppVersion("0.10.0")!, AppVersion("0.1.0")!), .orderedDescending
        )
        XCTAssertEqual(
            checker.ordering(of: AppVersion("0.1")!, AppVersion("0.1.0")!), .orderedSame
        )
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://example.invalid/\(name)")!
    }

    private func assertThrows(
        _ expected: UpdateError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UpdateError, expected, file: file, line: line)
        }
    }
}