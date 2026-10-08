import Foundation

// Self-update is a macOS-only feature: iOS builds reach users through the App Store, which
// updates them, and iOS has no `Process` to run `tar` or `open` with.
#if os(macOS)

/// Extracts a release archive, verifies it, and replaces the running `.app` with it.
///
/// The dangerous half of the update flow, written so that a failure at any step leaves the
/// installed app exactly as it was:
///
/// * the archive is extracted into a throwaway directory and verified **before** anything
///   installed is touched — an incomplete download is a clean error, not a half-written
///   bundle;
/// * the running bundle is renamed aside, not deleted, and that rename is the undo: if the
///   copy into place fails, the old bundle is moved back and the app is untouched;
/// * the new bundle is checked for the version that was downloaded, so a stale or wrong
///   archive cannot be installed over a good one.
///
/// The replace and relaunch steps are injected — they are the two that need the real
/// filesystem and a running process, which is exactly what the tests must not have.
public struct UpdateInstaller: Sendable {

    /// Why an install could not be completed. Every case leaves the app as it was.
    public enum UpdateInstallError: Error, Equatable, Sendable {
        /// The archive is not a readable `.tar.gz`.
        case unreadableArchive
        /// The archive holds no `.app` bundle.
        case archiveHasNoApp
        /// The bundle inside is not a complete app (no `Contents/MacOS/<name>`).
        case incompleteBundle(String)
        /// The bundle's version is not the one that was downloaded.
        case versionMismatch(expected: AppVersion, found: String?)
        /// The bundle could not be put in place; the previous one was restored.
        case replaceFailed(String)
    }

    /// Put `newBundle` where `currentBundle` is, leaving the app able to run either way.
    public typealias Replacement = @Sendable (_ newBundle: URL, _ currentBundle: URL) throws -> Void

    /// Start the replacement bundle and stop this process.
    public typealias Relauncher = @Sendable (_ newBundle: URL) -> Void

    private let replace: Replacement
    private let relaunch: Relauncher

    public init(
        replace: @escaping Replacement = UpdateInstaller.defaultReplace,
        relauncher: @escaping Relauncher = UpdateInstaller.defaultRelaunch
    ) {
        self.replace = replace
        self.relaunch = relauncher
    }

    // MARK: - Extract

    /// Extract `archive` and return the `.app` inside it. Touches nothing installed.
    ///
    /// The extraction directory is removed on failure; on success it is the caller's (the
    /// one-shot ``install(archive:expectedVersion:)`` removes it after the replace).
    public func extract(_ archive: URL, expectedVersion: AppVersion? = nil) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try extractWithTar(archive, into: directory)
            let bundle = try findAppBundle(in: directory)
            try verify(bundle, expectedVersion: expectedVersion)
            return bundle
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Replace the running bundle with an already-extracted `newBundle` and relaunch it.
    public func install(newBundle: URL, expectedVersion: AppVersion? = nil) throws {
        try verify(newBundle, expectedVersion: expectedVersion)
        let current = Bundle.main.bundleURL
        try replace(newBundle, current)
        relaunch(current)
    }

    /// Extract, verify, replace and relaunch — the whole install, cleaning up after itself.
    public func install(archive: URL, expectedVersion: AppVersion? = nil) throws {
        let bundle = try extract(archive, expectedVersion: expectedVersion)
        try install(newBundle: bundle, expectedVersion: expectedVersion)
        // The bundle is copied into place; the extraction directory is no longer needed.
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    // MARK: - The real replace and relaunch

    /// The real replacement: rename the running bundle aside, copy the new one in, and put
    /// the old one back if the copy fails.
    ///
    /// Rename-aside rather than delete-first is the whole safety of the operation: the old
    /// bundle stays on disk under a generated name until the new one is in place, so a failed
    /// copy is undone by moving it back and the app is never without a bundle.
    public static func defaultReplace(_ newBundle: URL, _ currentBundle: URL) throws {
        let fileManager = FileManager.default
        let backup = currentBundle.deletingLastPathComponent()
            .appendingPathComponent("\(currentBundle.lastPathComponent).old-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: currentBundle, to: backup)
        } catch {
            throw UpdateInstallError.replaceFailed(
                "could not move the current bundle aside: \(error.localizedDescription)"
            )
        }
        do {
            try fileManager.copyItem(at: newBundle, to: currentBundle)
        } catch {
            // The copy failed and the old bundle is still on disk under the backup name.
            // Moving it back is what leaves the app exactly as it was.
            try? fileManager.moveItem(at: backup, to: currentBundle)
            throw UpdateInstallError.replaceFailed(
                "could not copy the new bundle into place: \(error.localizedDescription)"
            )
        }
        // The new bundle is in place and verified; the old one has served its purpose.
        try? fileManager.removeItem(at: backup)
    }

    /// The real relaunch: start the replacement bundle and stop this process.
    ///
    /// `open` starts the new bundle without waiting for it to be ready; the delay before
    /// leaving is the window in which the new process takes over the dock and the menu bar.
    public static func defaultRelaunch(_ newBundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [newBundle.path]
        try? process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            exit(0)
        }
    }

    // MARK: - Extraction

    /// `tar -xzf`, the tool every macOS ships with and the one that reads the release
    /// archive's own format.
    private func extractWithTar(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.unreadableArchive
        }
    }

    /// The `.app` inside the extraction directory, wherever in it the archive put it.
    ///
    /// The archive normally holds `Binaural.app` at its root; a top-level folder around it
    /// is found just as readily. The one preference is for the app this release ships, so
    /// an archive with a stray bundle inside installs the real one.
    private func findAppBundle(in directory: URL) throws -> URL {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { throw UpdateInstallError.archiveHasNoApp }
        var apps: [URL] = []
        for case let url as URL in walker where url.pathExtension == "app" {
            apps.append(url)
        }
        guard !apps.isEmpty else { throw UpdateInstallError.archiveHasNoApp }
        return apps.first { $0.lastPathComponent == "Binaural.app" } ?? apps[0]
    }

    // MARK: - Verification

    /// Check that `bundle` is a complete `.app` and, when a version is expected, that it is
    /// the version that was downloaded.
    ///
    /// The version check is the guard against installing an incomplete download: the
    /// archive that arrives is verified against the release that was offered, and a mismatch
    /// refuses to touch the running bundle.
    func verify(_ bundle: URL, expectedVersion: AppVersion?) throws {
        let name = bundle.deletingPathExtension().lastPathComponent
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(name)")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw UpdateInstallError.incompleteBundle(bundle.path)
        }
        guard let expectedVersion else { return }
        let info = Bundle(url: bundle)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version = info.flatMap(AppVersion.init), version == expectedVersion else {
            throw UpdateInstallError.versionMismatch(expected: expectedVersion, found: info)
        }
    }
}

#endif
