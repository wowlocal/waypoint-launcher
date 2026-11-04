import Foundation

/// Delegate-based downloads provide byte callbacks for throttling. The async
/// URLSession download convenience API bypasses these delivery callbacks.
final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limiter: DownloadBandwidthLimiter
    private let progress: @Sendable (Int64, Int64) -> Void
    private let maximumBytes: Int64?
    private let speed = DownloadSpeed.current
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var file: URL?
    private var fileError: Error?
    private var lastProgressTime: TimeInterval = 0

    init(limiter: DownloadBandwidthLimiter, maximumBytes: Int64? = nil,
         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
        self.limiter = limiter
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    func download(session: URLSession, request: URLRequest, resumeData: Data? = nil) async throws -> (URL, URLResponse) {
        let result: (URL, URLResponse) = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = if let resumeData { session.downloadTask(withResumeData: resumeData) }
                           else { session.downloadTask(with: request) }
                task.delegate = self
                let cancelled = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return self.cancelled
                }
                if cancelled { task.cancel() }
                else {
                    limiter.started(task)
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
        do {
            try await limiter.waitUntilReady()
            return result
        } catch {
            try? FileManager.default.removeItem(at: result.0)
            throw error
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        limiter.received(bytesWritten, from: downloadTask)
        speed?.record(bytesWritten)
        if let maximumBytes, totalBytesWritten > maximumBytes {
            lock.withLock { fileError = URLError(.dataLengthExceedsMaximum) }
            downloadTask.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let report = lock.withLock {
            if now - lastProgressTime >= 0.1 || (totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite) {
                lastProgressTime = now
                return true
            }
            return false
        }
        if report { progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-transfer-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            lock.withLock { file = kept }
        } catch {
            lock.withLock { fileError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        limiter.finished(task)
        let result: (CheckedContinuation<(URL, URLResponse), Error>?, URL?, Error?) = lock.withLock {
            defer { continuation = nil; self.task = nil }
            return (continuation, file, fileError ?? error)
        }
        if let error = result.2 {
            if let file = result.1 { try? FileManager.default.removeItem(at: file) }
            result.0?.resume(throwing: error)
        } else if let file = result.1, let response = task.response {
            result.0?.resume(returning: (file, response))
        } else {
            if let file = result.1 { try? FileManager.default.removeItem(at: file) }
            result.0?.resume(throwing: URLError(.badServerResponse))
        }
    }
}
