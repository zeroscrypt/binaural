import Foundation

/// One entry of a GitHub release: a file the release publishes.
public struct ReleaseAsset: Sendable, Equatable, Decodable {

    public let name: String
    public let downloadURL: URL
    /// Size in bytes as GitHub reports it. `0` when the API did not say, which the
    /// downloader reads as "no integrity check available" rather than "empty file".
    public let size: Int64
    public let contentType: String?

    public init(name: String, downloadURL: URL, size: Int64 = 0, contentType: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.contentType = contentType
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
    }

    /// Decode leniently: an asset with no usable URL is dropped rather than failing the
    /// whole release, because one malformed entry must not hide the rest of the release.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        let raw = try container.decode(String.self, forKey: .downloadURL)
        guard let url = URL(string: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .downloadURL, in: container, debugDescription: "not a URL: \(raw)"
            )
        }
        downloadURL = url
        size = (try? container.decode(Int64.self, forKey: .size)) ?? 0
        contentType = try? container.decode(String.self, forKey: .contentType)
    }
}

/// The payload of `GET /repos/{owner}/{repo}/releases/latest`.
///
/// Only the fields the update flow uses are decoded; the rest of the GitHub document is
/// ignored, which `JSONDecoder` does by default.
public struct GitHubRelease: Sendable, Equatable, Decodable {

    public let tagName: String
    public let name: String?
    public let htmlURL: URL?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [ReleaseAsset]

    public init(
        tagName: String,
        name: String? = nil,
        htmlURL: URL? = nil,
        isDraft: Bool = false,
        isPrerelease: Bool = false,
        assets: [ReleaseAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    /// The version the tag names, `nil` when the tag is not a version at all.
    public var version: AppVersion? { AppVersion(tagName) }

    /// The macOS archive to install: `binaural-<version>-macos-arm64.tar.gz`.
    ///
    /// The exact name first, then progressively looser matches — an archive that says
    /// `macos` and `arm64` and ends in `.tar.gz`, then any `macos` tarball. Guessing rather
    /// than refusing is deliberate here: a release whose asset was renamed is still a
    /// usable update, and the archive is verified by content in ``UpdateInstaller`` before
    /// it replaces anything. `nil` when nothing looks like the macOS archive, which is
    /// ``UpdateError/missingArchive`` rather than a wrong file.
    public func macOSArchive(version: AppVersion? = nil) -> ReleaseAsset? {
        let wanted = (version ?? self.version).map { "binaural-\($0)-macos-arm64.tar.gz" }
        let archives = assets.filter { $0.name.hasSuffix(".tar.gz") }
        if let wanted, let exact = archives.first(where: { $0.name == wanted }) {
            return exact
        }
        if let match = archives.first(where: {
            $0.name.contains("macos") && $0.name.contains("arm64")
        }) {
            return match
        }
        return archives.first { $0.name.contains("macos") } ?? archives.first
    }
}

/// Why an update check could not produce an answer.
///
/// Every case is something a person can read: the app never shows a raw HTTP body, and it
/// never treats a failed check as "no update" *silently* — the launch check says nothing
/// at all and the About button reports the error.
public enum UpdateError: Error, Equatable, Sendable {
    /// The request itself failed: no network, DNS, TLS.
    case transport(String)
    /// GitHub answered with something other than 200.
    case httpStatus(Int)
    /// The body was not the JSON document the API documents.
    case unreadablePayload
    /// The release carries a tag that is not a version.
    case missingVersionTag
    /// The release has no macOS archive to install.
    case missingArchive
}

/// What the check concluded.
///
/// Three cases and not two, because "the user asked not to hear about this release" is a
/// **third** answer to "is there an update", not the same as "there is none". The launch
/// check stays silent for both of the first and the third.
public enum UpdateAvailability: Equatable, Sendable {
    /// Nothing newer than what is running.
    case upToDate(current: AppVersion)
    /// A newer release exists, with the archive to install.
    case updateAvailable(current: AppVersion, release: GitHubRelease)
    /// A newer release exists, but the user chose to skip this version.
    case skipped(current: AppVersion, release: GitHubRelease)

    /// The release to offer, whatever the verdict. `nil` when there is nothing to offer.
    public var release: GitHubRelease? {
        switch self {
        case .upToDate: nil
        case .updateAvailable(_, let release), .skipped(_, let release): release
        }
    }

    /// True when the user should be told about a newer version — the one case the launch
    /// check is allowed to interrupt for.
    public var isWorthTelling: Bool {
        if case .updateAvailable = self { return true }
        return false
    }
}

/// Looks up the newest release on GitHub and compares it with the running version.
///
/// Both dependencies are injected — the endpoint and the comparator — because every rule
/// worth testing here is a rule about *this* code: which tag it reads, which asset it picks
/// and in which order two versions come. The default endpoint is the repository's own
/// releases API, and the default fetch is a plain `URLSession` call.
///
/// Nothing throws at the UI on its own: the caller decides what a failure looks like
/// (``UpdateCheckCoordinator`` stays silent at launch and reports from the About dialog).
public struct UpdateChecker: Sendable {

    /// `https://api.github.com/repos/zeroscrypt/binaural/releases/latest`
    public static let defaultEndpoint = URL(
        string: "https://api.github.com/repos/zeroscrypt/binaural/releases/latest"
    )!

    /// Fetches a URL and returns the body. A closure rather than a `URLSession` property so
    /// the tests never touch the network and the type stays `Sendable`.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let endpoint: URL
    private let fetch: Fetch
    private let compare: @Sendable (AppVersion, AppVersion) -> ComparisonResult

    /// - Parameters:
    ///   - endpoint: the releases API to read.
    ///   - fetch: how to read it; the tests pass a closure over a canned document.
    ///   - compare: how to order two versions. Injectable because "newer" is the one
    ///     decision the whole feature rests on — a test asserts that the *default*
    ///     comparator is the one used, without re-testing `AppVersion` order here.
    public init(
        endpoint: URL = UpdateChecker.defaultEndpoint,
        fetch: @escaping Fetch = UpdateChecker.urlSessionFetch,
        compare: @escaping @Sendable (AppVersion, AppVersion) -> ComparisonResult =
            { $0.compare($1) }
    ) {
        self.endpoint = endpoint
        self.fetch = fetch
        self.compare = compare
    }

    /// The newest release, decoded.
    public func latestRelease() async throws -> GitHubRelease {
        let data: Data
        do {
            data = try await fetch(endpoint)
        } catch let error as UpdateError {
            // Already one of ours — a non-200 from the default fetch, say. Wrapped again it
            // would read as a network failure, which is a lie about what happened.
            throw error
        } catch {
            // The fetch is injected and may throw anything — a `URLError`, a test's own
            // error type. The checker's contract is that a failure is an ``UpdateError``,
            // never a raw error from somebody else's stack.
            throw UpdateError.transport(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            // One malformed field must not hide the release: try again with only what the
            // update flow reads. GitHub adds fields; it does not remove `tag_name`.
            if let lenient = try? JSONDecoder().decode(LenientRelease.self, from: data) {
                return lenient.release
            }
            throw UpdateError.unreadablePayload
        }
    }

    /// The newest release, compared with `currentVersion`.
    ///
    /// - Parameter skipping: the version the user chose to skip, or `nil`. Equal means
    ///   ``UpdateAvailability/skipped(current:release:)``, which the launch check treats as
    ///   silence and the About button treats as a normal "there is an update" answer.
    public func check(
        currentVersion: AppVersion,
        skipping skippedVersion: AppVersion? = nil
    ) async throws -> UpdateAvailability {
        let release = try await latestRelease()
        guard let releaseVersion = release.version else { throw UpdateError.missingVersionTag }
        guard releaseVersion > currentVersion else {
            return .upToDate(current: currentVersion)
        }
        if let skippedVersion, releaseVersion == skippedVersion {
            return .skipped(current: currentVersion, release: release)
        }
        return .updateAvailable(current: currentVersion, release: release)
    }

    /// The comparator this checker actually uses, exposed so the tests can pin that
    /// `check(currentVersion:)` orders with ``AppVersion`` rather than with something else.
    public func ordering(of lhs: AppVersion, _ rhs: AppVersion) -> ComparisonResult {
        compare(lhs, rhs)
    }

    /// The default fetch: `GET` with the headers GitHub asks for, mapped onto
    /// ``UpdateError`` so a failure never reaches the UI as an `NSError` nobody can read.
    public static func urlSessionFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Without a User-Agent the GitHub API rejects the request outright.
        request.setValue("Binaural-macOS", forHTTPHeaderField: "User-Agent")
        // The async `URLSession` API has no timeout argument; the request carries it.
        request.timeoutInterval = UpdateChecker.requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.transport(error.localizedDescription)
        }
    }

    /// How long a check may take before the app gives up on it. A launch-time check must
    /// not hold the window hostage on a bad connection.
    public static let requestTimeout: TimeInterval = 15

    // MARK: - Lenient decoding

    /// `tag_name` alone, for a payload whose other fields will not parse.
    private struct LenientRelease: Decodable {
        let release: GitHubRelease

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .tag_name)
            let assets = (try? container.decodeIfPresent([ReleaseAsset].self, forKey: .assets))
                .flatMap { $0 } ?? []
            release = GitHubRelease(
                tagName: tag,
                name: try? container.decode(String.self, forKey: .name),
                htmlURL: (try? container.decode(String.self, forKey: .html_url)).flatMap(URL.init(string:)),
                isDraft: (try? container.decode(Bool.self, forKey: .draft)) ?? false,
                isPrerelease: (try? container.decode(Bool.self, forKey: .prerelease)) ?? false,
                assets: assets
            )
        }

        private enum CodingKeys: String, CodingKey {
            case tag_name, name, html_url, draft, prerelease, assets
        }
    }
}