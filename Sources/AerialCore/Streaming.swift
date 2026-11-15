import Foundation

/// "Keep only the video on screen": the rotation may include Apple videos that aren't downloaded.
/// Right before a change the next one is downloaded, set as the wallpaper, and only then is the one it
/// replaced deleted. Videos the user downloaded and the user's own videos are never deleted this way.
public enum StreamPolicy {
    /// Apple's catalog holds 164 videos, about 80 GB (measured 2026-11-07): 0.5 GB per change on average.
    public static let averageVideoBytes: Int64 = 490_000_000
    public static let largestVideoBytes: Int64 = 1_490_000_000

    /// Whether a video can join a streaming rotation: on disk and safe, or one of Apple's videos that can be
    /// downloaded right before its turn (missing, unfinished, or replaced by Apple with a new file).
    public static func isStreamable(_ id: String, catalog: Catalog, local: [String: LocalVideo]) -> Bool {
        switch SafetyCheck.verdict(assetID: id, catalog: catalog, local: local) {
        case .safe:
            return true
        case .notDownloaded, .incompleteFile, .outdatedFile:
            guard let asset = catalog.asset(id), !asset.isCustom, let url = asset.remoteURL else { return false }
            return AerialDownloader.isAppleURL(url)
        case .notInCatalog, .dynamicWallpaper, .customVideosOff:
            return false
        }
    }

    /// Whether the video has to be downloaded before it can be shown.
    public static func needsDownload(_ id: String, catalog: Catalog, local: [String: LocalVideo]) -> Bool {
        !SafetyCheck.verdict(assetID: id, catalog: catalog, local: local).isSafe
    }

    /// Whether a download made for streaming is a streamed copy (deleted after its turn) rather than a kept one:
    /// a file the user already had stays the user's, even when it is downloaded again because Apple updated it.
    public static func countsAsStreamed(_ id: String, wasOnDisk: Bool, streamed: [String]) -> Bool {
        !wasOnDisk || streamed.contains(id)
    }

    /// Streamed copies that may be deleted now.
    ///
    /// - Parameters:
    ///   - referenced: every video the wallpaper settings point at (any display, Space, screen saver, lock screen);
    ///     nil when they can't be read, and then nothing is deleted: macOS would download a missing video it still uses.
    ///   - protected: videos that must stay whatever the list says: the user's own videos and the one being
    ///     downloaded or switched to right now.
    public static func deletable(
        streamed: [String], current: String?, referenced: Set<String>?, protected: Set<String>, onDisk: Set<String>
    ) -> [String] {
        guard let referenced else { return [] }
        return streamed.filter { id in
            onDisk.contains(id) && id != current && !referenced.contains(id) && !protected.contains(id)
        }
    }

    /// Why an automatic change didn't download its video, so it waits and tries again.
    public enum Wait: Equatable, Sendable {
        /// No connection, or it dropped during the download.
        case network
        /// Low Data Mode is on, or the network is marked as expensive (personal hotspot).
        case lowDataMode
        /// Low Power Mode is on.
        case lowPowerMode
        /// Not enough free space for the next video.
        case diskSpace
        /// Apple's server refused this video; the rotation moves on to another one.
        case server
    }

    /// An automatic change waits in Low Power Mode; one the user asks for (Next Video) doesn't.
    public static func waitsBeforeDownload(automatic: Bool, lowPowerMode: Bool) -> Wait? {
        automatic && lowPowerMode ? .lowPowerMode : nil
    }

    /// What a failed download means for the rotation; nil when the user cancelled it.
    public static func wait(after error: Error) -> Wait? {
        switch error {
        case DownloadError.cancelled: nil
        case DownloadError.constrainedNetwork: .lowDataMode
        case DownloadError.notEnoughSpace: .diskSpace
        case DownloadError.badResponse, DownloadError.noRemoteURL, DownloadError.untrustedURL: .server
        default: .network
        }
    }

    /// How long to wait before the next try: 5, 15, 30, then 60 minutes; Low Power Mode is checked every 15.
    public static func retryDelay(failures: Int, reason: Wait) -> TimeInterval {
        if reason == .lowPowerMode { return 15 * 60 }
        let minutes = [5, 15, 30, 60]
        return TimeInterval(minutes[min(max(failures, 1), minutes.count) - 1] * 60)
    }

    /// Roughly how much a rotation downloads in 30 days at this interval.
    public static func monthlyBytes(interval: RotationInterval) -> Int64 {
        let changes = (30 * 24 * 3600) / interval.seconds
        return Int64(changes * Double(averageVideoBytes))
    }
}

/// Deletes streamed copies that nothing uses any more.
public enum StreamCache {
    public struct Result: Equatable, Sendable {
        /// Deleted files, with their sizes.
        public var deleted: [String: Int64] = [:]
        /// What is left of the streamed list: copies still in use, and none whose file is gone.
        public var remaining: [String] = []
    }

    /// Reads the wallpaper settings itself, right before deleting, while holding the lock the app and `aerialctl`
    /// take to change the wallpaper, so a video can't become the wallpaper while its file is being removed.
    /// Deletes nothing when the settings can't be read or another change is in progress (then `remaining == streamed`).
    /// Files are deleted for good, not moved to the Trash: a streamed copy in the Trash would still take the space.
    public static func prune(
        streamed: [String], protected: Set<String>, paths: AerialPaths, lockTimeout: Duration = .seconds(2)
    ) async -> Result {
        guard !streamed.isEmpty else { return Result() }
        do {
            return try await FileLock(url: paths.switchLock).withLock(timeout: lockTimeout) {
                pruneUnlocked(streamed: streamed, protected: protected, paths: paths)
            }
        } catch {
            return Result(remaining: streamed)
        }
    }

    static func pruneUnlocked(streamed: [String], protected: Set<String>, paths: AerialPaths) -> Result {
        let local = LocalLibrary.scan(paths: paths)
        let data = try? WallpaperStore(url: paths.storeIndex).readData()
        let snapshot = data.flatMap { try? WallpaperStore.inspect($0) }
        // An unreadable store means unknown references: keep everything.
        let referenced = snapshot == nil ? nil : data.map(WallpaperStore.referencedAssetIDs)
        let current = snapshot?.isAerial == true ? snapshot?.assetID : nil
        let deletable = StreamPolicy.deletable(
            streamed: streamed, current: current, referenced: referenced, protected: protected, onDisk: Set(local.keys)
        )
        var result = Result()
        for id in deletable {
            let size = local[id]?.size ?? 0
            if (try? FileManager.default.removeItem(at: paths.videoFile(for: id))) != nil { result.deleted[id] = size }
        }
        // Keep in the list what is still on disk (in use, or failed to delete) and what is being downloaded;
        // forget the rest.
        result.remaining = streamed.filter { result.deleted[$0] == nil && (local[$0] != nil || protected.contains($0)) }
        // Unique, in order.
        var seen = Set<String>()
        result.remaining = result.remaining.filter { seen.insert($0).inserted }
        return result
    }
}
