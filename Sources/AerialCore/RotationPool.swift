import Foundation

/// Which videos the current mode may show — only downloaded, safe ones.
public enum RotationPool {
    public static func candidates(
        mode: RotationMode, playlists: [Playlist], catalog: Catalog, local: [String: LocalVideo]
    ) -> [String] {
        let wanted: [String]
        switch mode {
        case .allDownloaded:
            wanted = Array(local.keys)
        case .playlist(let id):
            wanted = playlists.first { $0.id == id }?.assetIDs ?? []
        case .single(let id):
            wanted = [id]
        }
        return wanted
            .filter { SafetyCheck.verdict(assetID: $0, catalog: catalog, local: local).isSafe }
            .sorted()
    }

    /// Video files that appeared since the last check and were not downloaded by the app.
    public static func unexpectedDownloads(
        known: Set<String>, local: [String: LocalVideo], downloadedByApp: Set<String>
    ) -> [LocalVideo] {
        local.values
            .filter { !known.contains($0.assetID) && !downloadedByApp.contains($0.assetID) }
            .sorted { $0.modified < $1.modified }
    }
}
