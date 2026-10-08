import Foundation

/// A dotted version number, compared **numerically** component by component.
///
/// The update check compares the running app's `CFBundleShortVersionString` with the tag of
/// the newest GitHub release, and the only thing that must be right here is the order:
/// `0.10.0` is newer than `0.1.0`, and a string comparison gets that exactly backwards.
/// So the components are parsed into `Int`s and compared pairwise, never as text.
///
/// Three tolerances, each of which the app actually depends on:
///
/// * a leading `v` is stripped — a GitHub tag is normally `v0.1.0` while the bundle says
///   `0.1`;
/// * missing components count as zero, so `0.1` and `0.1.0` are the **same** version.
///   `project.yml` carries `MARKETING_VERSION: "0.1"` and the first release is tagged
///   `v0.1.0`, so without this the shipping build would be told it is out of date by its
///   own release;
/// * a pre-release suffix (`0.2.0-beta.1`) is **older** than `0.2.0`, so a beta is never
///   offered as an update to a release build.
public struct AppVersion: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// The numeric components, most significant first: `0.1.10` is `[0, 1, 10]`.
    public let components: [Int]

    /// Everything after the first `-` or `+`, verbatim; `nil` for a plain release.
    public let prerelease: String?

    /// The text this version was parsed from, minus a leading `v`.
    public let raw: String

    /// `nil` when the text holds no leading number at all — `"unknown"`, `""`, `"v"`.
    ///
    /// Deliberately not a failable *init* with a throwing parser: a version that cannot be
    /// read must not throw, because a tag the app cannot parse has to mean "no update
    /// offered" rather than an error dialog about an update.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `v0.1.0` and `V 0.1.0` are both tags people write; both mean `0.1.0`.
        var body = trimmed
        if body.first == "v" || body.first == "V" {
            body.removeFirst()
            body = body.trimmingCharacters(in: .whitespaces)
        }
        // A `-` starts a pre-release, a `+` starts build metadata; both end the numeric
        // part. Which one it is decides the suffix, below.
        let releasePart = body.prefix { $0 != "-" && $0 != "+" }

        var parsed: [Int] = []
        for chunk in releasePart.split(separator: ".") {
            // Leading digits only: `1.2.3abc` is `1.2.3` as far as ordering goes, and a
            // chunk with no digits at all ends the version rather than failing it.
            let digits = chunk.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        // A `-` starts a pre-release suffix; a `+` starts build metadata, which is not
        // part of the version at all and is dropped with everything after it.
        var prerelease: String? = nil
        if body.count > releasePart.count {
            let separator = body[body.index(body.startIndex, offsetBy: releasePart.count)]
            if separator == "-" {
                var tail = String(body.dropFirst(releasePart.count + 1))
                if let plus = tail.firstIndex(of: "+") { tail = String(tail[..<plus]) }
                prerelease = tail.isEmpty ? nil : tail
            }
        }
        self.components = parsed
        self.prerelease = prerelease
        self.raw = String(body)
    }

    /// The version of the running application, from the bundle.
    ///
    /// `CFBundleShortVersionString` first, `CFBundleVersion` as the fallback: a debug build
    /// with no marketing version still has a build number, and refusing to compare would
    /// silently turn the feature off.
    @MainActor
    public static func running(bundle: Bundle = .main) -> AppVersion? {
        let keys = ["CFBundleShortVersionString", "CFBundleVersion"]
        for key in keys {
            if let text = bundle.object(forInfoDictionaryKey: key) as? String,
               let version = AppVersion(text) {
                return version
            }
        }
        return nil
    }

    /// Numeric order, then the pre-release rule.
    ///
    /// The two are compared over the same number of components by padding the shorter one
    /// with zeros, which is what makes `0.1` and `0.1.0` equal rather than "the shorter one
    /// is older" — the latter would nag the shipping build about its own release.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // Equal numbers: `1.0.0-beta.1` is earlier than `1.0.0`.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false   // a release is newer than any pre-release
        case (_, nil): return true
        case (let left?, let right?): return left < right
        }
    }

    /// Numeric order as a `ComparisonResult`.
    ///
    /// The one place the three-way answer is built, so ``<`` and the checker cannot
    /// disagree about what "newer" means.
    public func compare(_ other: AppVersion) -> ComparisonResult {
        if self < other { return .orderedAscending }
        if other < self { return .orderedDescending }
        return .orderedSame
    }

    /// Equality by the same order, not by the stored text.
    ///
    /// `0.1` and `0.1.0` are the same version — that is the rule the padding in ``<``
    /// exists for — so two versions are equal exactly when neither is newer. The stored
    /// `raw` text and the number of parsed components are deliberately **not** compared:
    /// `1.2.3 (17)` and `1.2.3+build` are the same version as `1.2.3`, and a structural
    /// comparison would call them different versions on the strength of a suffix the order
    /// ignores.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.compare(rhs) == .orderedSame
    }

    /// Hash the *significant* components, so equal versions hash equally.
    ///
    /// Trailing zeros carry no order (`0.1` and `0.1.0` are the same version), so they are
    /// dropped before hashing — at least one component is kept, because `0.0.0` and `0`
    /// are the same version too and an empty array would collide with a parse failure.
    public func hash(into hasher: inout Hasher) {
        var significant = components
        while significant.count > 1, significant.last == 0 { significant.removeLast() }
        hasher.combine(significant)
        hasher.combine(prerelease)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }
}