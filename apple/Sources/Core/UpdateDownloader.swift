import Foundation

/// Downloads a release archive to a temporary file, reporting progress as it arrives.
///
/// The download itself is injected — the same seam ``UpdateChecker`` has for its fetch —
/// so the tests run against a closure that writes a file rather than against the network.
/// The default is a `URLSession` download task with a delegate that reports progress.
///
/// The file the downloader returns is the caller's to remove: the coordinator deletes it
/// after a successful install, and on the way out if the user cancels.
public struct UpdateDownloader: Sendable {

    /// Reports how much of the download has arrived, 0...1.
    ///
    /// Called on the session's delegate queue, never on the main thread; the caller hops.
    public typealias Progress = @Sendable (Double) -> Void

    /// Write `url` to a temporary file and return where it landed.
    public typealias Loader = @Sendable (URL, Progress?) async throws -> URL

    private let load: Loader

    public init(load: @escaping Loader = UpdateDownloader.urlSessionLoad) {
        self.load = load
    }

    /// Download `url` to a temporary file and return where it landed.
    public func download(_ url: URL, progress: Progress? = nil) async throws -> URL {
        try await load(url, progress)
    }

    /// The default loader: a `URLSession` download task with a progress delegate.
    public static func urlSessionLoad(_ url: URL, progress: Progress?) async throws -> URL {
        let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("binaural-update-\(UUID().uuidString)-\(name)")
        let task = DownloadTask(destination: destination, progress: progress)
        return try await task.start(url)
    }

    /// One download in flight: the delegate, the progress reporter and the continuation.
    ///
    /// The session retains the delegate until the download ends, which is what keeps this
    /// object alive for the duration; `finishTasksAndInvalidate` releases it.
    private final class DownloadTask: NSObject, URLSessionDownloadDelegate {
        private let destination: URL
        private let progress: Progress?
        private var continuation: CheckedContinuation<URL, Error>?
        private var failure: Error?

        init(destination: URL, progress: Progress?) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ url: URL) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progress?(min(max(fraction, 0), 1))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // The file at `location` is deleted when this method returns, so it is moved
            // out of the way first — a copy if the move crosses a volume.
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destination)
            do {
                do {
                    try fileManager.moveItem(at: location, to: destination)
                } catch {
                    try fileManager.copyItem(at: location, to: destination)
                }
            } catch {
                failure = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            session.finishTasksAndInvalidate()
            if let error {
                continuation?.resume(throwing: error)
            } else if let failure {
                continuation?.resume(throwing: failure)
            } else if FileManager.default.fileExists(atPath: destination.path) {
                continuation?.resume(returning: destination)
            } else {
                continuation?.resume(throwing: UpdateError.transport("the download produced no file"))
            }
            continuation = nil
        }
    }
}
