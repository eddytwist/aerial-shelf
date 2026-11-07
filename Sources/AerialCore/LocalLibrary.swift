import Foundation

/// A video file that macOS (or this app) has downloaded.
public struct LocalVideo: Hashable, Sendable {
    public let assetID: String
    public let url: URL
    public let size: Int64
    /// The `SourceURL` extended attribute macOS writes on downloaded videos.
    public let sourceURL: String?
    public let modified: Date
}

/// Reads the list of downloaded videos from disk.
public enum LocalLibrary {
    /// Files smaller than this are treated as unfinished downloads.
    public static let minimumVideoSize: Int64 = 1_000_000

    public static func scan(paths: AerialPaths) -> [String: LocalVideo] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(
            at: paths.videos, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [String: LocalVideo] = [:]
        for file in files where file.pathExtension.lowercased() == "mov" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            let id = file.deletingPathExtension().lastPathComponent
            result[id] = LocalVideo(
                assetID: id,
                url: file,
                size: Int64(values.fileSize ?? 0),
                sourceURL: ExtendedAttributes.string(named: "SourceURL", at: file),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        return result
    }
}

/// Why a video can or cannot become the wallpaper without macOS downloading anything.
public enum SafetyVerdict: Equatable, Sendable {
    case safe
    case notInCatalog
    case dynamicWallpaper
    case notDownloaded
    case incompleteFile
    /// Apple changed the video's address; macOS would download the new file once it is in use.
    case outdatedFile
    /// One of the user's own videos while they are turned off: macOS doesn't know it.
    case customVideosOff

    public var isSafe: Bool { self == .safe }
}

public enum SafetyCheck {
    public static func verdict(assetID: String, catalog: Catalog, local: [String: LocalVideo]) -> SafetyVerdict {
        guard let asset = catalog.asset(assetID) else { return .notInCatalog }
        if asset.isDynamic { return .dynamicWallpaper }
        if asset.isCustom, !catalog.customEnabled { return .customVideosOff }
        guard let file = local[assetID] else { return .notDownloaded }
        // The app writes the user's videos in one step, so even a short clip under 1 MB is complete.
        if !asset.isCustom, file.size < LocalLibrary.minimumVideoSize { return .incompleteFile }
        if let source = file.sourceURL, let remote = asset.remoteURL?.absoluteString, source != remote {
            return .outdatedFile
        }
        return .safe
    }
}

enum ExtendedAttributes {
    static func string(named name: String, at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, name, &buffer, length, 0, 0)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    @discardableResult
    static func set(_ value: String, named name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let bytes = Array(value.utf8)
            return setxattr(path, name, bytes, bytes.count, 0, 0) == 0
        }
    }
}
