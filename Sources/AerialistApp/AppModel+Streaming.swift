import AerialCore
import AppKit

/// Rotation without keeping everything on disk. Any video can rotate: one that isn't on this Mac is downloaded right
/// before its turn, and the video on screen stays until the new one is fully downloaded and set. With
/// "Delete shown aerials" on (`RotationState.deleteShown`), copies the rotation downloaded are deleted once they fall
/// out of the last `keepLast` shown and nothing uses them. Videos kept on this Mac and the user's own are never deleted.
extension AppModel {
    /// After this many failed tries in a row an automatic change gives up until the next interval.
    static let streamTriesPerChange = 4

    /// An automatic change failed and waits before trying again.
    var streamIsWaiting: Bool {
        guard let retry = streamRetryAt else { return false }
        return Date() < retry
    }

    /// Shows the next video of the rotation.
    /// - Parameter automatic: true for the schedule. Then a download skips Low Data Mode, expensive networks and
    ///   Low Power Mode and shows a video that is already on disk instead; Next Video and other changes the user
    ///   asks for download anyway.
    @discardableResult
    func advance(automatic: Bool) async -> Bool {
        guard !isSwitching, streamTarget == nil, !isPruning, let catalog else { return false }
        var bag = state.bag
        // A video the user is downloading right now waits for its download to finish.
        let candidates = pool.filter { downloadProgress[$0] == nil }
        guard let id = ShuffleBag.next(pool: candidates, bag: &bag, current: currentAssetID) else { return false }
        if StreamPolicy.needsDownload(id, catalog: catalog, local: local) {
            return await streamAndShow(id, automatic: automatic, bagAfter: bag)
        }
        let done = await setWallpaper(id)
        if done { state.bag = bag }
        return done
    }

    /// Set as Wallpaper on any tile: downloads the video first when it isn't on this Mac.
    func show(_ id: String) async {
        guard !isSwitching, streamTarget == nil, !isPruning, let catalog else { return }
        guard StreamPolicy.needsDownload(id, catalog: catalog, local: local) else {
            await setWallpaper(id, fromWindow: true)
            return
        }
        var bag = state.bag
        bag.removeAll { $0 == id }
        await streamAndShow(id, automatic: false, bagAfter: bag, fromWindow: true, chosen: true)
    }

    /// Downloads a video, sets it, and leaves the copy it replaced to `pruneStreamed`.
    /// On any failure the video on screen stays; nothing half-downloaded is left behind.
    @discardableResult
    private func streamAndShow(
        _ id: String, automatic: Bool, bagAfter: [String], fromWindow: Bool = false, chosen: Bool = false
    ) async -> Bool {
        guard let asset = catalog?.asset(id), downloadProgress[id] == nil else { return false }
        if let wait = StreamPolicy.waitsBeforeDownload(automatic: automatic, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled) {
            return await showFromDiskOrWait(wait)
        }
        // Protects the video from `pruneStreamed` from the start of the download until it is on screen.
        streamTarget = id
        streamTargetChosen = chosen
        streamCancelled = false
        defer { streamTarget = nil }
        // An unfinished file macOS left behind isn't the user's; one Apple has since replaced still is.
        let wasOnDisk = local[id] != nil && verdict(id) != .incompleteFile
        let streamed = StreamPolicy.countsAsStreamed(id, wasOnDisk: wasOnDisk, streamed: state.streamedIDs)
        // Listed before the download, so a copy left by a crash or a quit is still deleted later.
        if streamed, !state.streamedIDs.contains(id) { state.streamedIDs.append(id) }
        downloadProgress[id] = 0
        failedDownloads.remove(id)
        downloadedByApp.insert(id)
        let expectedSize = try? await downloader.remoteSize(of: asset, allowsConstrainedNetwork: !automatic)
        do {
            // Pause or Cancel pressed while the size was being asked for.
            if streamCancelled || (automatic && state.paused) { throw DownloadError.cancelled }
            _ = try await downloader.download(
                asset, paths: paths, expectedSize: expectedSize, allowsConstrainedNetwork: !automatic
            ) { [weak self] id, percent in
                Task { @MainActor in
                    if self?.downloadProgress[id] != nil { self?.downloadProgress[id] = percent }
                }
            }
        } catch {
            downloadProgress[id] = nil
            downloadedByApp.remove(id)
            refresh()
            if streamed, local[id] == nil { state.streamedIDs.removeAll { $0 == id } }
            guard let wait = StreamPolicy.wait(after: error) else {
                // Cancelled: an automatic change waits a whole interval; a manual one just stops. A new source
                // goes on at once instead.
                if automatic, !streamCancelledForNewSource { state.lastChange = Date() }
                return false
            }
            // Apple's server refused this one: the next try picks another video.
            if wait == .server { state.bag = bagAfter }
            // Short of space: older shown copies make room for the next try.
            if wait == .diskSpace { await pruneStreamed(now: true, keep: max(1, state.keepLast - 1), duringChange: true) }
            if !automatic || wait == .diskSpace {
                report(Self.message(for: error, videoName: name(asset)), fromWindow: fromWindow)
            }
            guard automatic else {
                streamFailures += 1
                return false
            }
            return await showFromDiskOrWait(wait)
        }
        downloadProgress[id] = nil
        state.knownVideoIDs = Array(Set(state.knownVideoIDs).union([id])).sorted()
        refresh()
        // Paused while the last bytes arrived: keep the file (it is deleted later) but don't change the wallpaper.
        if streamCancelled || (automatic && state.paused) { return false }
        // The source changed during the download: the video doesn't belong to the rotation any more.
        if !chosen, !pool.contains(id) { return false }
        let done = await setWallpaper(id, fromWindow: fromWindow)
        if done {
            state.bag = bagAfter
            clearStreamWait()
        }
        return done
    }

    /// A scheduled change that couldn't download: without the network, in Low Data Mode or Low Power Mode it shows
    /// a video from the source that is already on disk right away (the round isn't touched); otherwise, or when
    /// nothing is on disk, the video on screen stays and the change is tried again later.
    private func showFromDiskOrWait(_ wait: StreamPolicy.Wait) async -> Bool {
        if [.network, .lowDataMode, .lowPowerMode].contains(wait), let catalog,
           let id = RotationPool.onDiskFallback(pool: pool, catalog: catalog, local: local,
                                                shownLog: state.shownLog, current: currentAssetID),
           await setWallpaper(id) {
            clearStreamWait()
            return true
        }
        postponeStream(wait)
        return false
    }

    private func clearStreamWait() {
        streamWait = nil
        streamRetryAt = nil
        streamFailures = 0
    }

    /// Waits before the next automatic try: longer after each failure, and after a few failures in a row until the
    /// next interval, so a bad connection doesn't download the same large video again and again.
    private func postponeStream(_ wait: StreamPolicy.Wait) {
        // Low Power Mode isn't a failure: it doesn't make the next network retry wait longer.
        if wait != .lowPowerMode { streamFailures += 1 }
        if streamFailures >= Self.streamTriesPerChange {
            clearStreamWait()
            state.lastChange = Date()
            return
        }
        streamWait = wait
        streamRetryAt = Date().addingTimeInterval(StreamPolicy.retryDelay(failures: max(streamFailures, 1), reason: wait))
    }

    func cancelStreamDownload() {
        guard let target = streamTarget else { return }
        streamCancelled = true
        downloader.cancel(assetID: target)
    }

    // MARK: Storage

    /// Videos kept on this Mac and the user's own: never deleted, and not counted among the last N.
    private var exemptFromDeletion: Set<String> { customIDs.union(state.pinnedIDs) }

    /// What must stay whatever the storage settings say.
    private func protectedFromDeletion(keep: Int) -> Set<String> {
        let lastShown = state.lastShown(keep: keep, exempt: exemptFromDeletion).union(currentAssetID.map { [$0] } ?? [])
        return exemptFromDeletion.union(lastShown).union(downloadProgress.keys)
    }

    /// Deletes rotation copies beyond the last N shown that nothing uses any more. Only with "Delete shown aerials"
    /// on; waits half a minute after a change, so the wallpaper and screen saver have moved to the new file, and
    /// never runs while a change is in progress.
    /// - Parameters:
    ///   - now: skip the half-minute wait (a confirmed lower N, low disk space).
    ///   - keep: how many of the last shown stay (default: the setting).
    ///   - duringChange: called by a change whose download failed (its target isn't on disk, and is protected anyway).
    func pruneStreamed(now: Bool = false, keep: Int? = nil, duringChange: Bool = false) async {
        guard state.storageVersion >= 1, state.deleteShown, !state.streamedIDs.isEmpty, !isSwitching, !isPruning,
              streamTarget == nil || duringChange else { return }
        if !now, let last = state.lastChange, Date().timeIntervalSince(last) < 30 { return }
        let listed = state.streamedIDs
        let protected = protectedFromDeletion(keep: keep ?? state.keepLast)
        // Quick Look's named links are hard links: while one exists, deleting the video frees no space.
        let expected = StreamPolicy.deletable(streamed: listed, current: currentAssetID, referenced: referencedIDs,
                                              protected: protected, onDisk: Set(local.keys))
        if !expected.isEmpty { removePreviewLinks() }
        // While the lock is awaited nothing may become the wallpaper or be kept: it could be what is deleted.
        isPruning = true
        let result = await StreamCache.prune(streamed: listed, protected: protected, paths: paths)
        isPruning = false
        // Only what this pass looked at: entries added or kept meanwhile stay as they are.
        let dropped = Set(listed).subtracting(result.remaining)
        guard !dropped.isEmpty else { return }
        let deleted = Set(result.deleted.keys)
        state.streamedIDs.removeAll { dropped.contains($0) }
        state.knownVideoIDs.removeAll { deleted.contains($0) }
        downloadedByApp.subtract(deleted)
        refresh()
    }

    /// Videos that would go if "Delete shown aerials" were on with `keep` (for the confirmation): Apple videos on
    /// disk that aren't kept on this Mac, among the last `keep` shown, or in use.
    func excess(keep: Int) -> [LocalVideo] {
        guard let catalog else { return [] }
        let inUse = referencedIDs.map { $0.union(currentAssetID.map { [$0] } ?? []).union(downloadProgress.keys) }
        return StreamPolicy.excess(
            onDisk: Array(local.keys), catalog: catalog, pinned: exemptFromDeletion,
            lastShown: state.lastShown(keep: keep, exempt: exemptFromDeletion), inUse: inUse
        ).compactMap { local[$0] }
    }

    /// What lowering N would delete: only rotation copies (the user's earlier downloads aren't deleted automatically).
    func excessOfRotationCopies(keep: Int) -> [LocalVideo] {
        let copies = Set(state.streamedIDs)
        return excess(keep: keep).filter { copies.contains($0.assetID) }
    }

    /// Turns "Delete shown aerials" on or off. When it goes on, the view first asks about what is already on disk
    /// (`excess`): either everything stays (`keepExisting`) or it goes now (`deleteExisting`).
    func setDeleteShown(_ on: Bool) { state.deleteShown = on }

    /// "Keep": what is on disk now stays; rotation copies among it become ordinary downloads.
    func keepExisting(_ videos: [LocalVideo]) {
        let ids = Set(videos.map(\.assetID))
        state.streamedIDs.removeAll { ids.contains($0) }
    }

    /// "Delete": rotation copies are deleted for good (as after their turn); the user's earlier downloads go to the
    /// Trash. Only the videos the user confirmed, and only those that still qualify: holds the lock used for changing
    /// the wallpaper and checks again under it that none is in use.
    func deleteExisting(_ confirmed: [LocalVideo], keep: Int) async {
        guard !isSwitching, streamTarget == nil else {
            windowError = L.t("Another change is still in progress. Try again in a moment.")
            return
        }
        removePreviewLinks()
        var failed = 0
        do {
            try await FileLock(url: paths.switchLock).withLock(timeout: .seconds(5)) {
                refresh()
                guard referencedIDs != nil else {
                    windowError = L.t("Can’t check which videos are in use, so they stay.")
                    return
                }
                let chosen = Set(confirmed.map(\.assetID))
                for video in excess(keep: keep) where chosen.contains(video.assetID) {
                    let id = video.assetID
                    do {
                        if state.streamedIDs.contains(id) {
                            try FileManager.default.removeItem(at: paths.videoFile(for: id))
                        } else {
                            try VideoTrash.moveToTrash(assetID: id, paths: paths)
                        }
                        state.streamedIDs.removeAll { $0 == id }
                        state.knownVideoIDs.removeAll { $0 == id }
                    } catch {
                        failed += 1
                    }
                }
            }
        } catch {
            windowError = L.t("Another change is still in progress. Try again in a moment.")
        }
        if failed > 0 { windowError = L.t("Couldn’t delete %@.", L.videos(failed)) }
        refresh()
        detectUnexpected()
    }

    /// Changes N; when it gets lower, copies beyond it go at once (the view confirms first if more than one would).
    func setKeepLast(_ keep: Int) async {
        let lower = keep < state.keepLast
        state.keepLast = keep
        if lower { await pruneStreamed(now: true) }
    }

    /// Roughly how much a month of rotation downloads at the current interval, if every video has to be downloaded.
    var monthlyTraffic: Int64 { StreamPolicy.monthlyBytes(interval: state.interval) }

    // MARK: Keep on This Mac

    func isPinned(_ id: String) -> Bool { state.pinnedIDs.contains(id) }

    /// Keep on This Mac: never deleted automatically, not counted in N. Downloads the video first if needed.
    func keepOnMac(_ id: String) async {
        guard let asset = catalog?.asset(id), !asset.isCustom else { return }
        // A clean-up holding the lock could be deleting this very file; let it finish first.
        for _ in 0..<30 where isPruning { try? await Task.sleep(for: .milliseconds(100)) }
        if local[id] == nil || verdict(id) == .outdatedFile {
            await download(asset)
            guard local[id] != nil else { return }
        }
        if !state.pinnedIDs.contains(id) { state.pinnedIDs.append(id) }
        if state.streamedIDs.contains(id) {
            state.streamedIDs.removeAll { $0 == id }
            if !state.pinnedCopies.contains(id) { state.pinnedCopies.append(id) }
        }
    }

    /// Don't Keep on This Mac. A rotation copy becomes one again (deleted after it falls out of the last N, not
    /// immediately); a video the user downloaded before 0.5 stays theirs and is never deleted automatically.
    func stopKeepingOnMac(_ id: String) {
        state.pinnedIDs.removeAll { $0 == id }
        let wasCopy = state.pinnedCopies.contains(id)
        state.pinnedCopies.removeAll { $0 == id }
        if wasCopy, local[id] != nil, !state.streamedIDs.contains(id) { state.streamedIDs.append(id) }
    }

    // MARK: My Aerials

    var myAerialsIDs: [String] { state.myAerials?.assetIDs ?? [] }

    func isInMyAerials(_ id: String) -> Bool { myAerialsIDs.contains(id) }

    func toggleMyAerials(_ id: String) {
        if isInMyAerials(id) { remove(id, from: Playlist.myAerialsID) } else { add([id], to: Playlist.myAerialsID) }
    }

    /// A playlist's name in the interface: My Aerials in the app's language, the others as the user named them.
    /// A playlist still called "New Playlist" in any of the app's languages was never renamed: it follows the language.
    func playlistName(_ playlist: Playlist) -> String {
        if playlist.isMyAerials { return L.t("My Aerials") }
        if L.defaultNames(of: "New Playlist").contains(playlist.name) { return L.t("New Playlist") }
        return playlist.name
    }

    /// The user's own playlists (not My Aerials), for the sidebar's Playlists section and Add to Playlist.
    var otherPlaylists: [Playlist] { state.playlists.filter { !$0.isMyAerials } }

    /// The source the rotation picks from, for the toolbar and the menu.
    var sourceTitle: String {
        if showingAllInstead { return L.t("All Aerials") }
        switch state.mode {
        case .allDownloaded: return L.t("All Downloaded", context: "source")
        case .allAerials: return L.t("All Aerials")
        case .category(let id): return catalog?.categories.first { $0.id == id }.map(name) ?? L.t("Category")
        case .playlist(let id): return state.playlists.first { $0.id == id }.map(playlistName) ?? L.t("Playlist", context: "source")
        case .single: return L.t("One Video", context: "source")
        }
    }

    static func waitText(_ wait: StreamPolicy.Wait) -> String {
        switch wait {
        case .network: L.t("Next video waits for the network")
        case .lowDataMode: L.t("Next video waits: Low Data Mode is on")
        case .lowPowerMode: L.t("Next video waits: Low Power Mode is on")
        case .diskSpace: L.t("Next video waits: not enough disk space")
        case .server: L.t("Next video unavailable; trying another soon")
        }
    }
}
