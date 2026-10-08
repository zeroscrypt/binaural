import Foundation
import XCTest

@testable import BinauralCore

/// The downloader: where the file lands, what progress reports, and what a failure means.
///
/// The loader is injected, so nothing here touches the network — the same rule as
/// `UpdateCheckerTests`.
@MainActor
final class UpdateDownloaderTests: XCTestCase {

    private let archiveURL = URL(
        string: "https://github.com/zeroscrypt/binaural/releases/download/v0.2.0/binaural-0.2.0-macos-arm64.tar.gz"
    )!

    /// The download writes a real file, named after the URL, and reports the whole range.
    func testDownloadWritesAFileAndReportsProgress() async throws {
        let reported = Recorder<Double>()
        let downloader = UpdateDownloader(load: { url, progress in
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("binaural-download-test-\(UUID().uuidString)-\(url.lastPathComponent)")
            for step in 1...4 {
                progress?(Double(step) / 4)
            }
            try Data(repeating: 0xAB, count: 1024).write(to: file)
            return file
        })
        let file = try await downloader.download(archiveURL) { reported.append($0) }
        XCTAssertEqual(reported.snapshot, [0.25, 0.5, 0.75, 1.0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, 1024)
        try? FileManager.default.removeItem(at: file)
    }

    /// A loader that fails is a failed download — the error reaches the caller, which is
    /// the coordinator's to turn into a sentence the user can read.
    func testADownloadFailurePropagates() async {
        struct Offline: Error {}
        let downloader = UpdateDownloader(load: { _, _ in throw Offline() })
        do {
            _ = try await downloader.download(archiveURL)
            XCTFail("a failed download must throw")
        } catch {
            // Any error is fine: the downloader does not wrap, the coordinator decides.
        }
    }
}
