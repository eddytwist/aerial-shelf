import Foundation

/// Copies of the wallpaper store taken before every change.
///
/// The first copy ever taken is kept as `Index.original.plist` and never overwritten,
/// so "Restore Original Wallpaper" always returns to what the user had before the app.
/// Rolling copies are skipped when the store has not changed since the last one, so repeated
/// attempts cannot push older history out.
public struct BackupStore: Sendable {
    public let paths: AerialPaths
    public let keep: Int

    public init(paths: AerialPaths, keep: Int = 20) {
        self.paths = paths
        self.keep = keep
    }

    public var hasOriginal: Bool { FileManager.default.fileExists(atPath: paths.originalStoreBackup.path) }

    /// Saves the current store. Returns the newest rolling copy (an existing one when nothing changed).
    @discardableResult
    public func backUp(_ data: Data, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        if !hasOriginal {
            try data.write(to: paths.originalStoreBackup, options: .atomic)
        }
        if let latest = rolling().last, (try? Data(contentsOf: latest)) == data {
            return latest
        }
        let file = paths.backups.appending(path: "Index.\(Self.stamp(now)).plist")
        try data.write(to: file, options: .atomic)
        prune()
        return file
    }

    public func original() throws -> Data { try Data(contentsOf: paths.originalStoreBackup) }

    /// Rolling copies, oldest first (names sort by UTC time).
    public func rolling() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: paths.backups, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Index.") && $0.lastPathComponent != "Index.original.plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune() {
        let files = rolling()
        guard files.count > keep else { return }
        for file in files.prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS'Z'"
        return formatter.string(from: date)
    }
}
