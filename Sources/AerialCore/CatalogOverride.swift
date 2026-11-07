import Foundation

/// Reads and writes another app's preferences. A protocol so tests don't touch the real ones.
public protocol PreferencesAccessing: Sendable {
    func value(_ key: String, domain: String) -> Any?
    func set(_ value: Any?, _ key: String, domain: String)
}

/// The user's real preferences, through CFPreferences (works for other domains in an app without a sandbox).
public struct SystemPreferences: PreferencesAccessing {
    public init() {}

    public func value(_ key: String, domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    public func set(_ value: Any?, _ key: String, domain: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// Points macOS's aerial extension at the catalog with the user's videos, and back.
///
/// Uses two keys the extension reads but Apple doesn't document:
/// `AerialManifestLocalPathOverride` (path of the catalog to load) and `AerialManifestForceLocal`.
/// With both removed macOS uses Apple's catalog again, exactly as before.
public struct CatalogOverride: Sendable {
    public static let domain = "com.apple.wallpaper.aerial"
    public static let pathKey = "AerialManifestLocalPathOverride"
    public static let forceKey = "AerialManifestForceLocal"

    public let paths: AerialPaths
    public let preferences: PreferencesAccessing

    public init(paths: AerialPaths, preferences: PreferencesAccessing = SystemPreferences()) {
        self.paths = paths
        self.preferences = preferences
    }

    /// True when macOS is set to read Aerial Shelf's catalog.
    public var isActive: Bool {
        (preferences.value(Self.pathKey, domain: Self.domain) as? String) == paths.customCatalog.path
            && (preferences.value(Self.forceKey, domain: Self.domain) as? Bool) == true
    }

    /// True when the keys point somewhere else (another tool or an old experiment); then the app leaves them alone.
    public var isUsedByOthers: Bool {
        guard let path = preferences.value(Self.pathKey, domain: Self.domain) as? String else { return false }
        return path != paths.customCatalog.path
    }

    /// Writes the merged catalog. Returns true when the file changed (macOS then needs to reload it).
    @discardableResult
    public func writeCatalog(library: CustomLibrary, categoryName: String, looseSetName: String) throws -> Bool {
        let apple = try Data(contentsOf: paths.manifest)
        let merged = try CustomCatalog.merge(appleCatalog: apple, library: library, categoryName: categoryName, looseSetName: looseSetName)
        if let current = try? Data(contentsOf: paths.customCatalog), current == merged { return false }
        try FileManager.default.createDirectory(at: paths.customCatalogFolder, withIntermediateDirectories: true)
        try merged.write(to: paths.customCatalog, options: .atomic)
        return true
    }

    /// Whether the merged catalog on disk differs from what it should be now (new videos, names, language,
    /// or a newer Apple catalog). Cheap enough to check every minute.
    public func catalogIsOutdated(library: CustomLibrary, categoryName: String, looseSetName: String) -> Bool {
        guard let apple = try? Data(contentsOf: paths.manifest),
              let merged = try? CustomCatalog.merge(appleCatalog: apple, library: library, categoryName: categoryName, looseSetName: looseSetName)
        else { return false }
        return (try? Data(contentsOf: paths.customCatalog)) != merged
    }

    /// Whether Apple's catalog changed after the merged one was written (macOS updates it now and then).
    public var appleCatalogIsNewer: Bool {
        func date(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        guard let apple = date(paths.manifest) else { return false }
        guard let merged = date(paths.customCatalog) else { return true }
        return apple > merged
    }

    public func activate() {
        preferences.set(paths.customCatalog.path, Self.pathKey, domain: Self.domain)
        preferences.set(true, Self.forceKey, domain: Self.domain)
    }

    /// Removes both keys, but only when they are Aerial Shelf's own.
    public func deactivate() {
        guard !isUsedByOthers else { return }
        preferences.set(nil, Self.pathKey, domain: Self.domain)
        preferences.set(nil, Self.forceKey, domain: Self.domain)
    }
}

/// Makes the aerial extension load the catalog again: it reads it only at launch and macOS relaunches it at once.
public struct AerialExtensionReloader: WallpaperAgentControlling {
    public init() {}

    /// Restarts the extension while holding the switch lock, so it never happens in the middle of a wallpaper change.
    public func restart(lockingWith paths: AerialPaths) async throws {
        try await FileLock(url: paths.switchLock).withLock { try await restart() }
    }

    public func restart() async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["WallpaperAerialsExtension"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        // 1 means no such process: nothing was running, so nothing has an old catalog loaded.
        guard status == 0 || status == 1 else { throw AgentError.notRestarted(status) }
    }
}
