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
            // The user's own videos rotate with Apple's, as they do in All Downloaded.
            wanted = catalog.videoAssets.map(\.id)
        case .category(let id):
            wanted = catalog.videoAssets.filter { $0.categoryIDs.contains(id) }.map(\.id)
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

    /// What actually rotates: the chosen source, or All Aerials while My Aerials has fewer than two videos
    /// (a new install, or every video removed), so macOS Shuffle is still replaced and Next still has somewhere to go.
    /// Only with "Delete shown aerials" on: with it off, every video shown would stay and the disk would fill up.
    public static func effective(
        mode: RotationMode, playlists: [Playlist], catalog: Catalog, local: [String: LocalVideo], deleteShown: Bool = true
    ) -> (pool: [String], showingAllInstead: Bool) {
        let pool = candidates(mode: mode, playlists: playlists, catalog: catalog, local: local, streaming: true)
        if pool.count < 2, deleteShown, mode == RotationState.myAerialsMode {
            return (candidates(mode: .allAerials, playlists: playlists, catalog: catalog, local: local, streaming: true), true)
        }
        return (pool, false)
    }

    /// Without the network (or in Low Data Mode or Low Power Mode) a scheduled change shows a video from the source
    /// that is already on disk: the one shown longest ago (never shown first), not the one on screen.
    /// The round of the online rotation isn't touched.
    public static func onDiskFallback(
        pool: [String], catalog: Catalog, local: [String: LocalVideo], shownLog: [String], current: String?
    ) -> String? {
        let ready = pool.filter { $0 != current && SafetyCheck.verdict(assetID: $0, catalog: catalog, local: local).isSafe }
        func age(_ id: String) -> Int { shownLog.firstIndex(of: id) ?? Int.max }
        return ready.sorted { age($0) != age($1) ? age($0) > age($1) : $0 < $1 }.first
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
