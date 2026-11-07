import Foundation

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unexpectedLayout(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let reason): "The wallpaper settings file could not be read: \(reason)"
        case .unexpectedLayout(let reason): "The wallpaper settings file has an unexpected layout: \(reason)"
        case .writeFailed(let reason): "The wallpaper settings file could not be written: \(reason)"
        }
    }
}

/// What the wallpaper store currently says, for the section that applies to all displays and Spaces.
public struct StoreSnapshot: Equatable, Sendable {
    public let provider: String?
    /// The aerial asset ID, a shuffle sentinel such as `shuffle-all-aerials`, or `nil` for other providers.
    public let assetID: String?
    /// `linked` means the screen saver follows the desktop wallpaper.
    public let layoutType: String?
    /// True when some display or Space has its own wallpaper that overrides the shared one.
    public let hasPerDisplayOverrides: Bool

    public var isAerial: Bool { provider == WallpaperStore.aerialsProvider }
    public var isShuffle: Bool { assetID?.hasPrefix("shuffle") ?? false }
}

/// Reads and edits `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
///
/// The format is undocumented. Editing is deliberately narrow: only the choice of the
/// "all displays and Spaces" section changes; every other key is decoded and written back unchanged.
/// `WallpaperAgent` throws away the whole file if it cannot decode it, so every edit is checked
/// by reading the result back before it is written.
public struct WallpaperStore: Sendable {
    public static let aerialsProvider = "com.apple.wallpaper.choice.aerials"
    static let sharedSection = "AllSpacesAndDisplays"
    static let defaultFrequencyID = "shuffle_every_1_day"

    public let url: URL

    public init(url: URL) { self.url = url }

    public func readData() throws -> Data {
        do { return try Data(contentsOf: url) } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    public func snapshot() throws -> StoreSnapshot { try Self.inspect(readData()) }

    /// Writes atomically: a temporary file in the same folder is renamed over the store.
    public func write(_ data: Data) throws {
        do { try data.write(to: url, options: .atomic) } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Pure functions (tested)

    public static func inspect(_ data: Data) throws -> StoreSnapshot {
        let root = try decodeRoot(data)
        guard let shared = root[sharedSection] as? [String: Any] else {
            throw StoreError.unexpectedLayout("no \(sharedSection) section")
        }
        let type = shared["Type"] as? String
        let choice = (content(of: shared, type: type)?["Choices"] as? [[String: Any]])?.first
        let provider = choice?["Provider"] as? String
        var assetID: String?
        if provider == aerialsProvider, let configuration = choice?["Configuration"] as? Data,
           let decoded = try? PropertyListSerialization.propertyList(from: configuration, format: nil),
           let dict = decoded as? [String: Any] {
            assetID = dict["assetID"] as? String
        }
        let overrides = [(root["Displays"] as? [String: Any]) ?? [:], (root["Spaces"] as? [String: Any]) ?? [:]]
            .contains { !$0.isEmpty }
        return StoreSnapshot(provider: provider, assetID: assetID, layoutType: type, hasPerDisplayOverrides: overrides)
    }

    /// Returns a copy of the store with one aerial video as the shared wallpaper.
    ///
    /// Keeps the layout (linked or separate screen saver), shuffle options and every other section.
    /// When the current wallpaper is not an aerial, its provider options are replaced with the
    /// aerial defaults, because options of another provider cannot be decoded by the aerials extension.
    public static func settingAerial(_ assetID: String, in data: Data, now: Date = Date()) throws -> Data {
        guard !assetID.isEmpty, !assetID.hasPrefix("shuffle") else {
            throw StoreError.unexpectedLayout("refusing to write a shuffle or empty asset ID")
        }
        var root = try decodeRoot(data)
        guard var shared = root[sharedSection] as? [String: Any] else {
            throw StoreError.unexpectedLayout("no \(sharedSection) section")
        }
        let type = shared["Type"] as? String
        guard let key = contentKey(of: shared, type: type), var entry = shared[key] as? [String: Any],
              var content = entry["Content"] as? [String: Any] else {
            throw StoreError.unexpectedLayout("no desktop content in \(sharedSection) (type \(type ?? "nil"))")
        }

        let previousProvider = (content["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0
        )
        content["Choices"] = [["Provider": aerialsProvider, "Configuration": configuration, "Files": [Any]()]]
        if previousProvider != aerialsProvider || content["EncodedOptionValues"] == nil {
            content["EncodedOptionValues"] = try defaultAerialOptions()
        }
        if content["Shuffle"] == nil { content["Shuffle"] = "$null" }
        entry["Content"] = content
        entry["LastSet"] = now
        entry["LastUse"] = now
        shared[key] = entry
        root[sharedSection] = shared

        let result = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        // Read the result back the way the agent will, before anything touches the disk.
        let check = try inspect(result)
        guard check.provider == aerialsProvider, check.assetID == assetID else {
            throw StoreError.unexpectedLayout("edited store does not read back as \(assetID)")
        }
        return result
    }

    /// Every aerial asset ID any part of the store points at: desktop and screen saver,
    /// the shared section, the system default, every display and every Space.
    public static func referencedAssetIDs(_ data: Data) -> Set<String> {
        guard let root = try? decodeRoot(data) else { return [] }
        var result = Set<String>()
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if dict["Provider"] as? String == aerialsProvider, let configuration = dict["Configuration"] as? Data,
                   let decoded = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
                   let id = decoded["assetID"] as? String {
                    result.insert(id)
                }
                dict.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(root)
        return result
    }

    static func defaultAerialOptions() throws -> Data {
        let options: [String: Any] = [
            "values": ["aerialShuffleFrequency": ["picker": ["_0": ["id": defaultFrequencyID]]]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)
    }

    private static func decodeRoot(_ data: Data) throws -> [String: Any] {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let root = plist as? [String: Any] else { throw StoreError.unexpectedLayout("root is not a dictionary") }
            return root
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    private static func contentKey(of section: [String: Any], type: String?) -> String? {
        // "linked": one entry drives desktop and screen saver; otherwise the desktop has its own entry.
        if type == "linked", section["Linked"] != nil { return "Linked" }
        if section["Desktop"] != nil { return "Desktop" }
        if section["Linked"] != nil { return "Linked" }
        return nil
    }

    private static func content(of section: [String: Any], type: String?) -> [String: Any]? {
        guard let key = contentKey(of: section, type: type) else { return nil }
        return (section[key] as? [String: Any])?["Content"] as? [String: Any]
    }
}
