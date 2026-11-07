import Foundation

public enum RotationInterval: String, CaseIterable, Codable, Sendable {
    case hours3, hours6, hours12, day, days2, week

    public var seconds: TimeInterval {
        switch self {
        case .hours3: 3 * 3600
        case .hours6: 6 * 3600
        case .hours12: 12 * 3600
        case .day: 24 * 3600
        case .days2: 48 * 3600
        case .week: 7 * 24 * 3600
        }
    }
}

public enum RotationMode: Codable, Hashable, Sendable {
    /// Random order over every downloaded video.
    case allDownloaded
    /// Random order over one playlist's downloaded videos.
    case playlist(UUID)
    /// One fixed video, no rotation.
    case single(String)
}

public struct Playlist: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var assetIDs: [String]
    /// The set of the user's own videos this playlist was made from; renaming or deleting one follows the other.
    public var customSetID: UUID?

    public init(id: UUID = UUID(), name: String, assetIDs: [String] = [], customSetID: UUID? = nil) {
        self.id = id
        self.name = name
        self.assetIDs = assetIDs
        self.customSetID = customSetID
    }

    enum CodingKeys: String, CodingKey { case id, name, assetIDs, customSetID }

    /// Tolerant like `RotationState`: a missing or unreadable field takes a default instead of failing the playlist.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Playlist"
        assetIDs = (try? c.decodeIfPresent([String].self, forKey: .assetIDs)) ?? []
        customSetID = try? c.decodeIfPresent(UUID.self, forKey: .customSetID)
    }
}

/// Everything the app remembers between launches.
///
/// Decoding is tolerant: a missing key takes its default, so a file written by an older or newer
/// version never wipes playlists.
public struct RotationState: Codable, Equatable, Sendable {
    public var mode: RotationMode = .allDownloaded
    public var interval: RotationInterval = .day
    public var paused = false
    public var playlists: [Playlist] = []
    /// Videos still to show in the current round, in order. Refilled and reshuffled when empty.
    public var bag: [String] = []
    public var lastChange: Date?
    public var lastAssetID: String?
    /// The interface language the user chose: `system` (the default: the Mac's language when the app has it,
    /// otherwise English), or a language code such as `en` or `ru`.
    public var language = RotationState.systemLanguage
    public static let systemLanguage = "system"
    /// Video files the app knows about, to tell new downloads by macOS from ones the app made.
    public var knownVideoIDs: [String] = []
    /// True once `knownVideoIDs` was filled on the first launch (an empty list is a valid state).
    public var knownVideosSeeded = false
    /// The user agreed to show their own videos in macOS (see `CatalogOverride`).
    public var customVideosEnabled = false
    /// Keys that were in the file but could not be read (not saved). `StateStore` keeps a copy of such a file.
    public var unreadableKeys: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, interval, paused, playlists, bag, lastChange, lastAssetID, knownVideoIDs, knownVideosSeeded
        case customVideosEnabled
        case language = "uiLanguage"
    }

    /// Version 0.1.0 saved the language as `language` and wrote `en` even when nobody chose it.
    private enum LegacyKeys: String, CodingKey { case language }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var unreadable: [String] = []
        /// The value for a key, or nil when it is absent; a present but unreadable value is noted.
        func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            do { return try c.decodeIfPresent(type, forKey: key) } catch {
                unreadable.append(key.stringValue)
                return nil
            }
        }
        let defaults = RotationState()
        mode = read(RotationMode.self, .mode) ?? defaults.mode
        interval = read(RotationInterval.self, .interval) ?? defaults.interval
        paused = read(Bool.self, .paused) ?? defaults.paused
        // Playlists one by one: one damaged entry must not take the others with it.
        if let entries = read([Failable<Playlist>].self, .playlists) {
            playlists = entries.compactMap(\.value)
            if playlists.count < entries.count { unreadable.append(CodingKeys.playlists.stringValue) }
        }
        bag = read([String].self, .bag) ?? defaults.bag
        lastChange = read(Date.self, .lastChange)
        lastAssetID = read(String.self, .lastAssetID)
        if let chosen = read(String.self, .language) {
            language = chosen
        } else {
            // From 0.1.0: only Russian was ever a real choice; `en` was the default, so it becomes `system`.
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .language)
            language = legacy == "ru" ? "ru" : defaults.language
        }
        knownVideoIDs = read([String].self, .knownVideoIDs) ?? defaults.knownVideoIDs
        knownVideosSeeded = read(Bool.self, .knownVideosSeeded) ?? !knownVideoIDs.isEmpty
        customVideosEnabled = read(Bool.self, .customVideosEnabled) ?? false
        unreadableKeys = unreadable
    }

    public func nextChange(after now: Date = Date()) -> Date? {
        if case .single = mode { return nil }
        if paused { return nil }
        // No change made yet: the schedule starts when the app first runs (see `startScheduleIfNeeded`).
        guard let lastChange else { return nil }
        return lastChange.addingTimeInterval(interval.seconds)
    }

    /// Starts counting from now if the app has never changed the wallpaper, so the first run does not switch at once.
    public mutating func startScheduleIfNeeded(now: Date = Date()) {
        if lastChange == nil { lastChange = now }
    }

    public func isDue(now: Date = Date()) -> Bool {
        guard let next = nextChange(after: now) else { return false }
        return next <= now
    }
}

/// Decodes an element if it can, without failing the whole array.
struct Failable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Picks the next video: a shuffled round without repeats, then a new round.
public enum ShuffleBag {
    /// - Parameters:
    ///   - pool: videos allowed right now (downloaded and safe), in any order.
    ///   - bag: remaining videos of the current round; updated in place.
    ///   - current: the video on screen, never picked twice in a row when the pool has more than one.
    /// - Returns: the next video, or `nil` when the pool is empty or holds only the video on screen.
    public static func next<R: RandomNumberGenerator>(
        pool: [String], bag: inout [String], current: String?, using rng: inout R
    ) -> String? {
        let allowed = Set(pool)
        guard !allowed.isEmpty else { bag = []; return nil }
        if allowed.count == 1 {
            bag = []
            let only = allowed.first!
            return only == current ? nil : only
        }
        bag.removeAll { !allowed.contains($0) || $0 == current }
        if bag.isEmpty {
            // A full round of every allowed video in random order. Only if the video on screen came out
            // first is it swapped with a random other one, so it isn't repeated now and no video gets a fixed place.
            var round = Array(allowed).sorted()
            round.shuffle(using: &rng)
            if round.first == current {
                round.swapAt(0, Int.random(in: 1..<round.count, using: &rng))
            }
            bag = round
        }
        return bag.removeFirst()
    }

    public static func next(pool: [String], bag: inout [String], current: String?) -> String? {
        var rng = SystemRandomNumberGenerator()
        return next(pool: pool, bag: &bag, current: current, using: &rng)
    }
}

/// Persists `RotationState` as JSON in the app's support folder.
public struct StateStore: Sendable {
    public let url: URL

    public init(paths: AerialPaths) { self.url = paths.stateFile }

    /// Loads the state. A file that cannot be read at all is moved aside (`state.corrupt-<time>.json`)
    /// instead of being overwritten; a file with some unreadable parts is copied aside (`state.partial-<time>.json`).
    /// `corruptCopy` says where the old file went, `partial` whether the rest of it was still used.
    public func load() -> (state: RotationState, corruptCopy: URL?, partial: Bool) {
        guard let data = try? Data(contentsOf: url) else { return (RotationState(), nil, false) }
        let stamp = Int(Date().timeIntervalSince1970)
        let folder = url.deletingLastPathComponent()
        if let state = try? JSONDecoder.iso.decode(RotationState.self, from: data) {
            guard !state.unreadableKeys.isEmpty else { return (state, nil, false) }
            let copy = folder.appending(path: "state.partial-\(stamp).json")
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return (state, nil, false) }
            return (state, copy, true)
        }
        let aside = folder.appending(path: "state.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return (RotationState(), aside, false)
    }

    /// Reads the state without changing anything on disk; nil when the file is missing or can't be read.
    /// For read-only callers (`aerialctl status`) and for picking up changes made by the other process.
    public func read() -> RotationState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(RotationState.self, from: data)
    }

    /// When the file was last written, by this app or by `aerialctl`.
    public func modificationDate() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    public func save(_ state: RotationState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.iso.encode(state)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
