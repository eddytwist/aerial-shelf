import Foundation

/// An exclusive lock shared by the app and `aerialctl`, so only one of them changes the wallpaper at a time.
///
/// Uses `flock(2)` on a file in the app's support folder; the lock goes away by itself if a process dies.
public struct FileLock: Sendable {
    public enum LockError: Error, Sendable {
        case cannotOpen(Int32)
        case timedOut
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// True when someone holds the lock right now. Doesn't wait and doesn't keep the lock.
    public func isHeld() -> Bool {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// Runs `body` while holding the lock, waiting up to `timeout` for another process to finish.
    public func withLock<T>(timeout: Duration = .seconds(15), _ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw LockError.cannotOpen(errno) }
        defer { close(descriptor) }
        let deadline = ContinuousClock.now + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard ContinuousClock.now < deadline else { throw LockError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
