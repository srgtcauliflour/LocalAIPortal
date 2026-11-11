import Foundation

/// Downloads single files to disk with byte-level progress and cancellation.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private struct Pending {
        let destination: URL
        let onBytes: (Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        var failure: Error?
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Downloads `request` to `destination`, replacing any existing file.
    /// `onBytes` reports the bytes received so far for this file.
    func download(
        _ request: URLRequest, to destination: URL, onBytes: @escaping (Int64) -> Void
    ) async throws {
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                pending[task.taskIdentifier] = Pending(
                    destination: destination, onBytes: onBytes, continuation: continuation,
                    failure: nil)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let entry = pending[downloadTask.taskIdentifier]
        lock.unlock()
        entry?.onBytes(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = pending[downloadTask.taskIdentifier] else { return }
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
                !(200 ..< 300).contains(http.statusCode)
            {
                throw HFError.badResponse(http.statusCode)
            }
            let manager = FileManager.default
            try manager.createDirectory(
                at: entry.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if manager.fileExists(atPath: entry.destination.path) {
                try manager.removeItem(at: entry.destination)
            }
            // The temporary file is deleted when this method returns, so move it now.
            try manager.moveItem(at: location, to: entry.destination)
        } catch {
            entry.failure = error
            pending[downloadTask.taskIdentifier] = entry
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let failure = error ?? entry.failure {
            entry.continuation.resume(throwing: failure)
        } else {
            entry.continuation.resume()
        }
    }
}
