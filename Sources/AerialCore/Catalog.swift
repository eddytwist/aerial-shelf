import Foundation

/// One aerial video from Apple's catalog.
public struct AerialAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let nameKey: String
    /// English name shipped in the catalog itself; used when no translation is available.
    public let fallbackName: String
    public let categoryIDs: [String]
    public let subcategoryIDs: [String]
    public let preferredOrder: Int
    public let includeInShuffle: Bool
    public let remoteURL: URL?
    /// Dynamic wallpapers (light/dark variants) are not plain videos; the app leaves them alone.
    public let isDynamic: Bool
    /// A video the user added (see `CustomLibrary`), not one of Apple's.
    public var isCustom: Bool = false
}

public struct AerialCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let nameKey: String
    public let preferredOrder: Int
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case missingManifest(String)
    case unreadableManifest(String)

    public var description: String {
        switch self {
        case .missingManifest(let path): "Apple's aerial catalog is missing at \(path)"
        case .unreadableManifest(let reason): "Apple's aerial catalog could not be read: \(reason)"
        }
    }
}

/// Apple's aerial catalog (`entries.json`) plus localized names.
public struct Catalog: Sendable {
    public static let dynamicCategoryID = "dynamic-aerials"

    public let assets: [AerialAsset]
    public let categories: [AerialCategory]
    /// Whether macOS knows the user's videos right now (see `Catalog.adding(_:enabled:)`).
    public let customEnabled: Bool
    private let strings: [String: [String: String]]
    private let byID: [String: AerialAsset]

    public init(assets: [AerialAsset], categories: [AerialCategory], strings: [String: [String: String]], customEnabled: Bool = false) {
        self.assets = assets
        self.categories = categories
        self.strings = strings
        self.customEnabled = customEnabled
        self.byID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    init(assets: [AerialAsset], categories: [AerialCategory], stringsFrom other: Catalog, customEnabled: Bool) {
        self.init(assets: assets, categories: categories, strings: other.strings, customEnabled: customEnabled)
    }

    /// The user's own videos in this catalog.
    public var customAssets: [AerialAsset] { assets.filter(\.isCustom) }

    public func asset(_ id: String) -> AerialAsset? { byID[id] }

    /// Videos that can be wallpapers through this app (everything except dynamic wallpapers).
    public var videoAssets: [AerialAsset] { assets.filter { !$0.isDynamic } }

    /// Categories shown in the library, without the dynamic one.
    public var videoCategories: [AerialCategory] {
        categories.filter { $0.id != Self.dynamicCategoryID }.sorted { $0.preferredOrder < $1.preferredOrder }
    }

    public func name(of asset: AerialAsset, language: String) -> String {
        localized(asset.nameKey, language: language) ?? asset.fallbackName
    }

    public func name(of category: AerialCategory, language: String) -> String {
        localized(category.nameKey, language: language) ?? category.nameKey
    }

    private func localized(_ key: String, language: String) -> String? {
        for lang in [language, String(language.prefix(2)), "en"] {
            if let value = strings[lang]?[key], !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Loading

    public static func load(paths: AerialPaths) throws -> Catalog {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.manifest.path) else {
            throw CatalogError.missingManifest(paths.manifest.path)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: paths.manifest))
        } catch {
            throw CatalogError.unreadableManifest(String(describing: error))
        }
        let strings = (try? loadStrings(at: paths.localizedStrings)) ?? [:]
        let categories = manifest.categories.map {
            AerialCategory(id: $0.id, nameKey: $0.localizedNameKey, preferredOrder: $0.preferredOrder ?? 0)
        }
        // IDs become file names, so only well-formed UUIDs are accepted.
        let assets = manifest.assets.filter { isAssetID($0.id) }.map { entry in
            AerialAsset(
                id: entry.id,
                nameKey: entry.localizedNameKey,
                fallbackName: entry.accessibilityLabel ?? entry.id,
                categoryIDs: entry.categories,
                subcategoryIDs: entry.subcategories ?? [],
                preferredOrder: entry.preferredOrder ?? 0,
                includeInShuffle: entry.includeInShuffle ?? true,
                remoteURL: entry.url4K.flatMap(URL.init(string:)),
                isDynamic: entry.categories.contains(dynamicCategoryID) || entry.variant != nil
            )
        }
        return Catalog(assets: assets, categories: categories, strings: strings)
    }

    static func isAssetID(_ id: String) -> Bool {
        id.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil
    }

    static func loadStrings(at url: URL) throws -> [String: [String: String]] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let root = plist as? [String: Any] else { return [:] }
        var result: [String: [String: String]] = [:]
        for (language, table) in root {
            if let table = table as? [String: String] { result[language] = table }
        }
        return result
    }

    private struct Manifest: Decodable {
        let assets: [Entry]
        let categories: [CategoryEntry]
    }

    private struct Entry: Decodable {
        let id: String
        let localizedNameKey: String
        let accessibilityLabel: String?
        let categories: [String]
        let subcategories: [String]?
        let preferredOrder: Int?
        let includeInShuffle: Bool?
        let url4K: String?
        let variant: Variant?

        struct Variant: Decodable {}

        enum CodingKeys: String, CodingKey {
            case id, localizedNameKey, accessibilityLabel, categories, subcategories
            case preferredOrder, includeInShuffle, variant
            case url4K = "url-4K-SDR-240FPS"
        }
    }

    private struct CategoryEntry: Decodable {
        let id: String
        let localizedNameKey: String
        let preferredOrder: Int?
    }
}
