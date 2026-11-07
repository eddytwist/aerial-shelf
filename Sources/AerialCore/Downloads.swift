import Foundation

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case noRemoteURL
    case untrustedURL(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case badResponse(Int)
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .noRemoteURL: "This video has no download address in Apple's catalog"
        case .untrustedURL(let url): "Refusing to download from \(url): only HTTPS addresses on Apple's servers are allowed"
        case .notEnoughSpace(let needed, let available): "Not enough disk space: \(needed) bytes needed, \(available) available"
        case .badResponse(let code): "Apple's server answered \(code)"
        case .cancelled: "Download cancelled"
        case .failed(let reason): reason
        }
    }
}

/// Downloads aerial videos from Apple's server into the folder macOS uses, only when asked.
///
/// The file gets the same `SourceURL` and `LastETag` attributes macOS writes, so System Settings
/// and the wallpaper service treat it as a normal downloaded aerial. Only HTTPS hosts on Apple's
/// domain are allowed, redirects included, so an edited catalog cannot send the app elsewhere.
public final class AerialDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Called with whole percentages (0...100), at most once per percent.
    public typealias Progress = @Sendable (_ assetID: String, _ percent: Int) -> Void

    private struct Job {
        let assetID: String
        let destination: URL
        let continuation: CheckedContinuation<URL, Error>
        let progress: Progress
        var lastPercent: Int
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var tasksByAsset: [String: URLSessionDownloadTask] = [:]
    private let allowedHostSuffixes: [String]
    private var session: URLSession!

    /// - Parameter allowedHostSuffixes: downloads go only to HTTPS hosts ending with one of these
    ///   (Apple's catalog points at `sylvan.apple.com`).
    public init(configuration: URLSessionConfiguration = .default, allowedHostSuffixes: [String] = ["apple.com"]) {
        self.allowedHostSuffixes = allowedHostSuffixes
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func isTrusted(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func trustedURL(for asset: AerialAsset) throws -> URL {
        guard let url = asset.remoteURL else { throw DownloadError.noRemoteURL }
        guard isTrusted(url) else { throw DownloadError.untrustedURL(url.absoluteString) }
        return url
    }

    /// Size of the file on Apple's server, without downloading it.
    public func remoteSize(of asset: AerialAsset) async throws -> Int64 {
        var request = URLRequest(url: try trustedURL(for: asset))
        request.httpMethod = "HEAD"
        // Asked right before the confirmation; don't keep the user waiting on a slow network.
        request.timeoutInterval = 4
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.failed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.badResponse(http.statusCode) }
        return http.expectedContentLength
    }

    /// Free space on the disk that holds the videos, as macOS reports it for important data.
    public static func availableSpace(paths: AerialPaths) -> Int64? {
        let folder = FileManager.default.fileExists(atPath: paths.videos.path) ? paths.videos : paths.home
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// - Parameter expectedSize: when known, the download is refused unless the disk keeps 500 MB free afterwards.
    public func download(_ asset: AerialAsset, paths: AerialPaths, expectedSize: Int64? = nil,
                         progress: @escaping Progress) async throws -> URL {
        let url = try trustedURL(for: asset)
        if let expectedSize, let available = Self.availableSpace(paths: paths), available < expectedSize + 500_000_000 {
            throw DownloadError.notEnoughSpace(needed: expectedSize, available: available)
        }
        try FileManager.default.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        let destination = paths.videoFile(for: asset.id)
        let assetID = asset.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                lock.withLock {
                    jobs[task.taskIdentifier] = Job(
                        assetID: assetID, destination: destination, continuation: continuation,
                        progress: progress, lastPercent: -1
                    )
                    tasksByAsset[assetID] = task
                }
                task.resume()
            }
        } onCancel: {
            self.cancel(assetID: assetID)
        }
    }

    public func cancel(assetID: String) {
        let task = lock.withLock { tasksByAsset[assetID] }
        task?.cancel()
    }

    public var activeAssetIDs: Set<String> { lock.withLock { Set(tasksByAsset.keys) } }

    /// Removes leftovers of downloads interrupted by a crash or power loss.
    public static func removeLeftovers(paths: AerialPaths) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: paths.videos.path)) ?? []
        for name in files where name.hasPrefix(".") && name.hasSuffix(".mov.partial") {
            try? FileManager.default.removeItem(at: paths.videos.appending(path: name))
        }
    }

    // MARK: URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(isTrusted(request.url) ? request : nil)
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        let job = lock.withLock { () -> Job? in
            guard var job = jobs[downloadTask.taskIdentifier], percent > job.lastPercent else { return nil }
            job.lastPercent = percent
            jobs[downloadTask.taskIdentifier] = job
            return job
        }
        if let job { job.progress(job.assetID, percent) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = lock.withLock({ jobs[downloadTask.taskIdentifier] }) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            finish(downloadTask, with: .failure(DownloadError.badResponse(http?.statusCode ?? 0)))
            return
        }
        do {
            // Move next to the destination first, then rename: macOS never sees a half-written video.
            let partial = job.destination.deletingLastPathComponent()
                .appending(path: ".\(job.assetID).mov.partial")
            let fm = FileManager.default
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: location, to: partial)
            if let source = downloadTask.originalRequest?.url?.absoluteString {
                ExtendedAttributes.set(source, named: "SourceURL", at: partial)
            }
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                ExtendedAttributes.set(etag, named: "LastETag", at: partial)
            }
            if fm.fileExists(atPath: job.destination.path) {
                _ = try fm.replaceItemAt(job.destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: job.destination)
            }
            finish(downloadTask, with: .success(job.destination))
        } catch {
            finish(downloadTask, with: .failure(DownloadError.failed(error.localizedDescription)))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        finish(task, with: .failure(cancelled ? DownloadError.cancelled : DownloadError.failed(error.localizedDescription)))
    }

    private func finish(_ task: URLSessionTask, with result: Result<URL, Error>) {
        let job = lock.withLock { () -> Job? in
            guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return nil }
            tasksByAsset[job.assetID] = nil
            return job
        }
        job?.continuation.resume(with: result)
    }
}

/// Moves a downloaded video to the Trash (never deletes it permanently).
public enum VideoTrash {
    @discardableResult
    public static func moveToTrash(assetID: String, paths: AerialPaths) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: paths.videoFile(for: assetID), resultingItemURL: &trashed)
        return trashed as URL?
    }
}
