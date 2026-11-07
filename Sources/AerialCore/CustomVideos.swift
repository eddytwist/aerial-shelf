import Foundation

/// A video the user added, shown by macOS as an aerial in its own "My Videos" category.
public struct CustomVideo: Codable, Identifiable, Hashable, Sendable {
    /// A UUID, also the file name in macOS's video folder (`<id>.mov`).
    public let id: String
    public var name: String
    /// The set (folder) the video came from, if any.
    public var setID: UUID?
    public let added: Date

    public init(id: String = UUID().uuidString, name: String, setID: UUID? = nil, added: Date = Date()) {
        self.id = id
        self.name = name
        self.setID = setID
        self.added = added
    }

    enum CodingKeys: String, CodingKey { case id, name, setID, added }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        setID = try? c.decodeIfPresent(UUID.self, forKey: .setID)
        added = (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? .distantPast
    }
}

/// A group of the user's videos, made from a folder. In macOS it is a subcategory of "My Videos";
/// in Aerial Shelf it also gets a playlist, so the set can rotate on its own.
public struct CustomSet: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything the app knows about the user's own videos.
public struct CustomLibrary: Codable, Equatable, Sendable {
    public var videos: [CustomVideo] = []
    public var sets: [CustomSet] = []
    /// Videos moved to the Trash recently, so one put back from the Trash returns with its name.
    public var trashed: [CustomVideo] = []

    public init(videos: [CustomVideo] = [], sets: [CustomSet] = [], trashed: [CustomVideo] = []) {
        self.videos = videos
        self.sets = sets
        self.trashed = trashed
    }

    enum CodingKeys: String, CodingKey { case videos, sets, trashed }

    /// Tolerant like the rotation state: one damaged entry doesn't take the others with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = ((try? c.decodeIfPresent([Failable<CustomVideo>].self, forKey: .videos)) ?? []).compactMap(\.value)
        // One entry per ID, whatever the file says.
        var seen: Set<String> = []
        videos = decoded.filter { seen.insert($0.id).inserted }
        sets = ((try? c.decodeIfPresent([Failable<CustomSet>].self, forKey: .sets)) ?? []).compactMap(\.value)
        trashed = ((try? c.decodeIfPresent([Failable<CustomVideo>].self, forKey: .trashed)) ?? []).compactMap(\.value)
    }

    /// Adds a video, or updates it if one with the same ID is already listed.
    public mutating func add(_ video: CustomVideo) {
        if let index = videos.firstIndex(where: { $0.id == video.id }) { videos[index] = video } else { videos.append(video) }
        trashed.removeAll { $0.id == video.id }
    }

    /// Removes a video and remembers it (the last 100), dropping sets that became empty.
    public mutating func remove(_ id: String) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let video = videos.remove(at: index)
        trashed.removeAll { $0.id == id }
        trashed.append(video)
        if trashed.count > 100 { trashed.removeFirst(trashed.count - 100) }
        sets.removeAll { set in !videos.contains { $0.setID == set.id } }
    }

    /// Takes back files of the user's videos that are on disk but not in the list (for example put back from
    /// the Trash), recognised by their `SourceURL`. Returns the IDs taken back.
    public mutating func adoptReturnedFiles(_ local: [String: LocalVideo], defaultName: String) -> [String] {
        var adopted: [String] = []
        for (id, file) in local where video(id) == nil && Catalog.isAssetID(id) {
            guard let source = file.sourceURL, source == Self.sourceURL(for: id).absoluteString else { continue }
            var returned = trashed.first { $0.id == id } ?? CustomVideo(id: id, name: defaultName)
            if let setID = returned.setID, !sets.contains(where: { $0.id == setID }) { returned.setID = nil }
            add(returned)
            adopted.append(id)
        }
        return adopted.sorted()
    }

    public var isEmpty: Bool { videos.isEmpty }

    public func video(_ id: String) -> CustomVideo? { videos.first { $0.id == id } }

    /// Address written in the catalog and on the file. It can never be downloaded (`.invalid` is reserved),
    /// so macOS has nothing to fetch even if a file goes missing.
    public static func sourceURL(for id: String) -> URL {
        URL(string: "https://aerial-shelf.invalid/videos/\(id).mov")!
    }

    /// Stable IDs of the "My Videos" category and of its subcategory for videos that aren't in a set.
    public static let categoryID = "6F2D1A7C-3B5E-4E8A-9C1D-AE51F0000001"
    public static let looseSubcategoryID = "6F2D1A7C-3B5E-4E8A-9C1D-AE51F0000002"
}

/// Reads and writes `custom.json` in the app's support folder.
public struct CustomLibraryStore: Sendable {
    public let url: URL

    public init(paths: AerialPaths) { url = paths.customLibraryFile }

    /// Reads the list without changing anything on disk (an unreadable file reads as empty).
    public func read() -> CustomLibrary {
        guard let data = try? Data(contentsOf: url) else { return CustomLibrary() }
        return (try? JSONDecoder.iso.decode(CustomLibrary.self, from: data)) ?? CustomLibrary()
    }

    /// Loads the list. A file that can't be read is moved aside (`custom.corrupt-<time>.json`) instead of being
    /// overwritten by the next save; the videos themselves are found again by their `SourceURL`.
    public func load() -> (library: CustomLibrary, corruptCopy: URL?) {
        guard let data = try? Data(contentsOf: url) else { return (CustomLibrary(), nil) }
        if let library = try? JSONDecoder.iso.decode(CustomLibrary.self, from: data) { return (library, nil) }
        let aside = url.deletingLastPathComponent().appending(path: "custom.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return (CustomLibrary(), aside)
    }

    public func save(_ library: CustomLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(library).write(to: url, options: .atomic)
    }
}

/// Builds the catalog macOS reads while the user's videos are on: Apple's catalog, unchanged,
/// plus a "My Videos" category with one subcategory per set.
public enum CustomCatalog {
    public enum MergeError: Error, Equatable {
        case unreadableAppleCatalog
    }

    /// - Parameters:
    ///   - categoryName: shown by System Settings as the section title (it isn't in Apple's string table,
    ///     so macOS shows the key itself); pass it in the system language.
    ///   - looseSetName: subcategory name for videos that aren't in a set.
    public static func merge(appleCatalog: Data, library: CustomLibrary, categoryName: String, looseSetName: String) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: appleCatalog) as? [String: Any],
              var assets = root["assets"] as? [[String: Any]],
              var categories = root["categories"] as? [[String: Any]] else {
            throw MergeError.unreadableAppleCatalog
        }
        let videos = library.videos.filter { Catalog.isAssetID($0.id) }
        guard let first = videos.first else { return appleCatalog }

        var subcategories: [[String: Any]] = []
        func subcategory(id: String, name: String, order: Int, representative: String) -> [String: Any] {
            ["id": id, "localizedNameKey": name, "localizedDescriptionKey": name, "preferredOrder": order,
             "previewImage": preview(representative), "representativeAssetID": representative, "combineVariants": false]
        }
        if let loose = videos.first(where: { $0.setID == nil }) {
            subcategories.append(subcategory(id: CustomLibrary.looseSubcategoryID, name: looseSetName, order: 0, representative: loose.id))
        }
        for (index, set) in library.sets.enumerated() {
            guard let representative = videos.first(where: { $0.setID == set.id }) else { continue }
            subcategories.append(subcategory(id: set.id.uuidString, name: set.name, order: index + 1, representative: representative.id))
        }

        categories.append([
            "id": CustomLibrary.categoryID, "localizedNameKey": categoryName, "localizedDescriptionKey": categoryName,
            // After all of Apple's categories.
            "preferredOrder": (categories.compactMap { $0["preferredOrder"] as? Int }.max() ?? 0) + 100,
            "previewImage": preview(first.id), "representativeAssetID": first.id, "subcategories": subcategories,
        ])
        for (index, video) in videos.enumerated() {
            let set = video.setID.flatMap { id in library.sets.first { $0.id == id } }
            assets.append([
                "id": video.id, "localizedNameKey": video.name, "accessibilityLabel": video.name,
                "categories": [CustomLibrary.categoryID],
                "subcategories": [set?.id.uuidString ?? CustomLibrary.looseSubcategoryID],
                // Never part of Apple's Shuffle: it is only ever chosen by Aerial Shelf.
                "includeInShuffle": false, "showInTopLevel": true, "preferredOrder": index,
                "pointsOfInterest": [String: Any](), "shotID": "AERIAL_SHELF_\(video.id)",
                "previewImage": preview(video.id),
                "url-4K-SDR-240FPS": CustomLibrary.sourceURL(for: video.id).absoluteString,
            ])
        }
        root["assets"] = assets
        root["categories"] = categories
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func preview(_ id: String) -> String { "https://aerial-shelf.invalid/thumbnails/\(id).png" }
}

extension Catalog {
    /// This catalog plus the user's videos, as Aerial Shelf shows and checks them.
    /// - Parameter enabled: whether macOS currently knows the videos (the catalog override is on).
    public func adding(_ library: CustomLibrary, enabled: Bool) -> Catalog {
        let custom = library.videos.filter { Catalog.isAssetID($0.id) }.map { video in
            AerialAsset(
                id: video.id, nameKey: video.name, fallbackName: video.name,
                categoryIDs: [CustomLibrary.categoryID],
                subcategoryIDs: [video.setID?.uuidString ?? CustomLibrary.looseSubcategoryID],
                preferredOrder: 0, includeInShuffle: false,
                remoteURL: CustomLibrary.sourceURL(for: video.id), isDynamic: false, isCustom: true
            )
        }
        return Catalog(
            assets: assets.filter { !$0.isCustom } + custom, categories: categories,
            stringsFrom: self, customEnabled: enabled
        )
    }
}

extension Catalog {
    /// Apple's catalog plus the user's videos, as the app and `aerialctl` use it.
    /// The videos count as usable only while the user has them on and macOS points at Aerial Shelf's catalog.
    public static func loadWithCustom(
        paths: AerialPaths, customVideosEnabled: Bool, preferences: PreferencesAccessing = SystemPreferences()
    ) throws -> Catalog {
        let library = CustomLibraryStore(paths: paths).read()
        let active = customVideosEnabled && CatalogOverride(paths: paths, preferences: preferences).isActive
        return try load(paths: paths).adding(library, enabled: active)
    }
}

/// Names macOS shows for the "My Videos" category. System Settings uses the system language,
/// not the app's, so this follows the user's first system language.
public enum CustomCategoryNames {
    public static func names(systemLanguage: String?) -> (category: String, loose: String) {
        (systemLanguage ?? "en").hasPrefix("ru") ? ("Мои видео", "Мои видео") : ("My Videos", "My Videos")
    }

    /// The first language in the user's system settings (the app itself may run in another one).
    public static var systemLanguage: String? { systemLanguages.first }

    /// The user's system languages in order (read from the global domain, not the app's own).
    public static var systemLanguages: [String] {
        (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? []
    }
}

/// Decisions about the user's own videos, kept free of UI so they can be tested.
public enum CustomPolicy {
    /// Whether macOS can go back to Apple's catalog without losing a wallpaper: none of the user's videos may be
    /// in use anywhere (desktop, screen saver, any display or Space), and the settings must have been readable.
    public static func canTurnOff(referenced: Set<String>?, customIDs: Set<String>) -> Bool {
        guard let referenced else { return false }
        return referenced.isDisjoint(with: customIDs)
    }

    /// The user's videos still in use, for the message when turning off has to wait.
    public static func inUse(referenced: Set<String>?, customIDs: Set<String>) -> Set<String> {
        referenced?.intersection(customIDs) ?? customIDs
    }

    /// After a failed attempt (keys used by another app, catalog not writable), wait before trying again,
    /// so a notice the user dismissed doesn't come back every minute.
    public static func shouldRetry(lastFailure: Date?, now: Date = Date(), interval: TimeInterval = 3600) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= interval
    }
}

extension CustomLibrary {
    /// IDs of the user's videos on disk, known or not: files whose `SourceURL` is an Aerial Shelf address.
    /// Lets checks work even when the list itself couldn't be read.
    public static func filesOnDisk(_ local: [String: LocalVideo]) -> Set<String> {
        Set(local.filter { $0.value.sourceURL == sourceURL(for: $0.key).absoluteString }.keys)
    }
}
