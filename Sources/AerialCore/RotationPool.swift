import Foundation

/// Which videos the current mode may show: downloaded, safe ones, and with streaming on also Apple videos
/// that can be downloaded right before their turn.
public enum RotationPool {
    public static func candidates(
        mode: RotationMode, playlists: [Playlist], catalog: Catalog, local: [String: LocalVideo], streaming: Bool = false
    ) -> [String] {
        let wanted: [String]
        switch mode {
        case .allDownloaded:
            wanted = Array(local.keys)
        case .allAerials:
            wanted = catalog.videoAssets.filter { !$0.isCustom }.map(\.id)
        case .playlist(let id):
            wanted = playlists.first { $0.id == id }?.assetIDs ?? []
        case .single(let id):
            wanted = [id]
        }
        let allowed: (String) -> Bool = streaming
            ? { StreamPolicy.isStreamable($0, catalog: catalog, local: local) }
            : { SafetyCheck.verdict(assetID: $0, catalog: catalog, local: local).isSafe }
        return Array(Set(wanted.filter(allowed))).sorted()
    }

    /// Video files that appeared since the last check and were not downloaded by the app.
    /// Streamed copies count as the app's own, also after a restart (they are deleted once not in use).
    public static func unexpectedDownloads(
        known: Set<String>, local: [String: LocalVideo], downloadedByApp: Set<String>, streamed: Set<String> = []
    ) -> [LocalVideo] {
        local.values
            .filter { !known.contains($0.assetID) && !downloadedByApp.contains($0.assetID) && !streamed.contains($0.assetID) }
            .sorted { $0.modified < $1.modified }
    }
}
