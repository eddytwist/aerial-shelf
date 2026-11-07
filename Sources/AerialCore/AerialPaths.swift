import Foundation

/// File locations used by macOS for aerial wallpapers and by this app for its own data.
///
/// macOS 26+ keeps aerial wallpapers under `~/Library/Application Support/com.apple.wallpaper`.
/// Tests point `home` at a temporary folder with fixtures instead of the real home folder.
public struct AerialPaths: Sendable, Equatable {
    public let home: URL
    public let appSupport: URL

    public init(home: URL, appFolderName: String = "AerialShelf") {
        self.home = home
        self.appSupport = home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: appFolderName, directoryHint: .isDirectory)
    }

    public static var live: AerialPaths {
        AerialPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var wallpaperRoot: URL {
        home.appending(path: "Library/Application Support/com.apple.wallpaper", directoryHint: .isDirectory)
    }

    /// The wallpaper store that `WallpaperAgent` reads at launch.
    public var storeIndex: URL { wallpaperRoot.appending(path: "Store/Index.plist") }

    public var aerialsRoot: URL { wallpaperRoot.appending(path: "aerials", directoryHint: .isDirectory) }

    /// Apple's catalog of aerial videos.
    public var manifest: URL { aerialsRoot.appending(path: "manifest/entries.json") }

    /// Localized names of videos and categories (binary plist: language → key → string).
    public var localizedStrings: URL {
        aerialsRoot.appending(
            path: "manifest/TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable"
        )
    }

    /// Downloaded videos, named `<assetID>.mov`.
    public var videos: URL { aerialsRoot.appending(path: "videos", directoryHint: .isDirectory) }

    /// Small preview images for every catalog entry, named `<assetID>.png`.
    public var thumbnails: URL { aerialsRoot.appending(path: "thumbnails", directoryHint: .isDirectory) }

    /// The catalog with the user's videos added, which macOS reads while they are on. It sits next to
    /// macOS's own aerial data because the wallpaper extension can't read files elsewhere.
    public var customCatalogFolder: URL { aerialsRoot.appending(path: "aerial-shelf", directoryHint: .isDirectory) }
    public var customCatalog: URL { customCatalogFolder.appending(path: "entries.json") }

    public func videoFile(for assetID: String) -> URL { videos.appending(path: "\(assetID).mov") }
    public func thumbnailFile(for assetID: String) -> URL { thumbnails.appending(path: "\(assetID).png") }

    // MARK: App data

    public var backups: URL { appSupport.appending(path: "Backups", directoryHint: .isDirectory) }
    public var originalStoreBackup: URL { backups.appending(path: "Index.original.plist") }
    public var stateFile: URL { appSupport.appending(path: "state.json") }
    /// Live status written by the running app (read by `aerialctl status`).
    public var statusFile: URL { appSupport.appending(path: "status.json") }
    /// Held while the wallpaper is being changed, by the app or by `aerialctl`.
    public var switchLock: URL { appSupport.appending(path: "switch.lock") }
    public var frameCache: URL { appSupport.appending(path: "Frames", directoryHint: .isDirectory) }
    /// The user's own videos and sets (`CustomLibrary`).
    public var customLibraryFile: URL { appSupport.appending(path: "custom.json") }
}
