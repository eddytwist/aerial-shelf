import Foundation

/// What the running app currently shows as warnings, so the command-line tool can report it.
public struct AppStatus: Codable, Equatable, Sendable {
    public var updated: Date
    public var paused: Bool
    public var changedOutside: Bool
    public var appleShuffleOn: Bool
    public var unexpectedDownloads: [String]
    public var lastError: String?

    public init(updated: Date = Date(), paused: Bool, changedOutside: Bool, appleShuffleOn: Bool,
                unexpectedDownloads: [String], lastError: String?) {
        self.updated = updated
        self.paused = paused
        self.changedOutside = changedOutside
        self.appleShuffleOn = appleShuffleOn
        self.unexpectedDownloads = unexpectedDownloads
        self.lastError = lastError
    }

    public static func load(paths: AerialPaths) -> AppStatus? {
        guard let data = try? Data(contentsOf: paths.statusFile) else { return nil }
        return try? JSONDecoder.iso.decode(AppStatus.self, from: data)
    }

    public func save(paths: AerialPaths) {
        try? FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(self) { try? data.write(to: paths.statusFile, options: .atomic) }
    }
}
