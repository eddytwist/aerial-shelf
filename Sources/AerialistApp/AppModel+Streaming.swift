import AerialCore
import AppKit

/// "Keep Only the Video on Screen" (`RotationState.streaming`): the rotation may include videos that aren't
/// downloaded. Each one is downloaded right before its turn; the video on screen stays until the new one is
/// fully downloaded and set, and the streamed copy it replaced is deleted afterwards.
extension AppModel {
    /// After this many failed tries in a row an automatic change gives up until the next interval.
    static let streamTriesPerChange = 4

    /// A streaming change failed and waits before trying again (only automatic changes wait).
    var streamIsWaiting: Bool {
        guard state.streaming, let retry = streamRetryAt else { return false }
        return Date() < retry
    }

    /// Shows the next video of the rotation.
    /// - Parameter automatic: true for the schedule. Then a download skips Low Data Mode, expensive networks and
    ///   Low Power Mode, and waits instead; Next Video and other changes the user asks for don't.
    @discardableResult
    func advance(automatic: Bool) async -> Bool {
        guard !isSwitching, streamTarget == nil, let catalog else { return false }
        var bag = state.bag
        // A video the user is downloading right now waits for its download to finish.
        let candidates = pool.filter { downloadProgress[$0] == nil }
        guard let id = ShuffleBag.next(pool: candidates, bag: &bag, current: currentAssetID) else { return false }
        if state.streaming, StreamPolicy.needsDownload(id, catalog: catalog, local: local) {
            return await streamAndShow(id, automatic: automatic, bagAfter: bag)
        }
        let done = await setWallpaper(id)
        if done { state.bag = bag }
        return done
    }

    /// Show Now on a video that isn't downloaded: downloads it as a streamed copy and sets it.
    func showStreamed(_ id: String) async {
        guard state.streaming, !isSwitching, streamTarget == nil else { return }
        var bag = state.bag
        bag.removeAll { $0 == id }
        await streamAndShow(id, automatic: false, bagAfter: bag, fromWindow: true, chosen: true)
    }

    /// Downloads a video, sets it, and leaves the streamed copy it replaced to `pruneStreamed`.
    /// On any failure the video on screen stays; nothing half-downloaded is left behind.
    @discardableResult
    private func streamAndShow(
        _ id: String, automatic: Bool, bagAfter: [String], fromWindow: Bool = false, chosen: Bool = false
    ) async -> Bool {
        guard let asset = catalog?.asset(id), downloadProgress[id] == nil else { return false }
        if let wait = StreamPolicy.waitsBeforeDownload(automatic: automatic, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled) {
            postponeStream(wait, automatic: automatic)
            return false
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
                // Cancelled: an automatic change waits a whole interval; a manual one just stops.
                if automatic { state.lastChange = Date() }
                return false
            }
            // Apple's server refused this one: the next try picks another video.
            if wait == .server { state.bag = bagAfter }
            postponeStream(wait, automatic: automatic)
            if !automatic || wait == .diskSpace {
                report(Self.message(for: error, videoName: name(asset)), fromWindow: fromWindow)
            }
            return false
        }
        downloadProgress[id] = nil
        state.knownVideoIDs = Array(Set(state.knownVideoIDs).union([id])).sorted()
        refresh()
        if streamed, let file = local[id] { state.streamedSizes[id] = file.size }
        // Paused while the last bytes arrived: keep the file (it is deleted later) but don't change the wallpaper.
        if streamCancelled || (automatic && state.paused) { return false }
        let done = await setWallpaper(id, fromWindow: fromWindow)
        if done {
            state.bag = bagAfter
            streamWait = nil
            streamRetryAt = nil
            streamFailures = 0
        }
        return done
    }

    /// Waits before the next automatic try: longer after each failure, and after a few failures in a row until the
    /// next interval, so a bad connection doesn't download the same large video again and again.
    private func postponeStream(_ wait: StreamPolicy.Wait, automatic: Bool) {
        // Low Power Mode isn't a failure: it doesn't make the next network retry wait longer.
        if wait != .lowPowerMode { streamFailures += 1 }
        guard automatic else { return }
        if streamFailures >= Self.streamTriesPerChange {
            streamFailures = 0
            streamWait = nil
            streamRetryAt = nil
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

    /// Deletes streamed copies nothing uses any more. Waits half a minute after a change, so the wallpaper
    /// and screen saver have moved to the new file, and never runs while a change is in progress.
    /// - Parameter now: skip the half-minute wait (turning streaming off).
    func pruneStreamed(now: Bool = false) async {
        guard !state.streamedIDs.isEmpty, !isSwitching, streamTarget == nil else { return }
        if !now, let last = state.lastChange, Date().timeIntervalSince(last) < 30 { return }
        let listed = state.streamedIDs
        let protected = customIDs.union(downloadProgress.keys)
        // Quick Look's named links are hard links: while one exists, deleting the video frees no space.
        let expected = StreamPolicy.deletable(streamed: listed, current: currentAssetID, referenced: referencedIDs,
                                              protected: protected, onDisk: Set(local.keys))
        if !expected.isEmpty { removePreviewLinks() }
        let result = await StreamCache.prune(streamed: listed, protected: protected, paths: paths)
        // Only what this pass looked at: entries added or kept meanwhile stay as they are.
        let dropped = Set(listed).subtracting(result.remaining)
        guard !dropped.isEmpty else { return }
        let deleted = Set(result.deleted.keys)
        state.streamedIDs.removeAll { dropped.contains($0) }
        state.knownVideoIDs.removeAll { deleted.contains($0) }
        downloadedByApp.subtract(deleted)
        refresh()
    }

    /// Turns streaming on or off. Nothing is deleted when it goes on. When it goes off, streamed copies nothing
    /// uses are deleted at once; the ones still in use (the video on screen) become ordinary downloads, and any
    /// that couldn't be checked now stay listed and are deleted by a later pass. All Aerials falls back to
    /// All Downloaded.
    func setStreaming(_ on: Bool) async {
        state.streaming = on
        streamWait = nil
        streamRetryAt = nil
        streamFailures = 0
        guard !on else {
            // The video on screen stays; the next change already picks from the whole catalog.
            state.normalizeSource()
            return
        }
        cancelStreamDownload()
        // Let a cancelled download finish unwinding before the last clean-up.
        for _ in 0..<20 where streamTarget != nil { try? await Task.sleep(for: .milliseconds(100)) }
        await pruneStreamed(now: true)
        // Turned on again while this was waiting: leave the new choice alone.
        guard !state.streaming else { return }
        refresh()
        if referencedIDs != nil { state.streamedIDs.removeAll { isInUse($0) } }
        let source = RotationPolicy.source(state.mode, streaming: false)
        if source != state.mode { await setMode(source) }
    }

    /// The source the rotation picks from, for the toolbar and the menu.
    var sourceTitle: String {
        switch state.mode {
        case .allDownloaded: L.t("All Downloaded", context: "source")
        case .allAerials: L.t("All Aerials")
        case .playlist(let id): state.playlists.first { $0.id == id }?.name ?? L.t("Playlist", context: "source")
        case .single: L.t("One Video", context: "source")
        }
    }

    /// "Rotate All Aerials…" when only downloaded videos rotate: explains the traffic, then turns on
    /// Keep Only the Video on Screen, which makes All Aerials the source.
    func offerStreaming() async {
        let alert = NSAlert()
        alert.messageText = L.t("Rotate all aerials without storing them?")
        let month = Self.size(StreamPolicy.monthlyBytes(interval: state.interval), language: language)
        alert.informativeText = L.t("Each video is downloaded right before its turn, and the one it replaces is deleted. At your interval that’s about %@ a month; automatic changes wait while Low Data Mode or Low Power Mode is on. Videos you downloaded yourself stay. To stop, turn off Keep Only the Video on Screen in Settings → Storage.", month)
        alert.addButton(withTitle: L.t("Turn On"))
        alert.addButton(withTitle: L.t("Cancel"))
        // A menu bar app isn't in front when its menu is used, and macOS may not let it activate:
        // a floating alert still shows above other apps' windows.
        NSApp.activate()
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await setStreaming(true)
        // The button promised All Aerials, also from a playlist or a single video: a new round from it.
        if state.mode != .allAerials {
            state.bag = []
            await setMode(.allAerials)
        }
    }

    func isStreamed(_ id: String) -> Bool { state.streamedIDs.contains(id) }

    /// Keep Downloaded: a streamed copy becomes the user's, so it isn't deleted after its turn.
    func keepStreamed(_ id: String) { state.streamedIDs.removeAll { $0 == id } }

    /// Space streaming saves: videos it has shown that aren't on disk now.
    var streamSavings: (count: Int, bytes: Int64) {
        let gone = state.streamedSizes.filter { local[$0.key] == nil }
        return (gone.count, gone.values.reduce(0, +))
    }

    /// Apple videos the user downloaded (not streamed copies, not their own videos) that aren't in use:
    /// with streaming on they can go to the Trash; playlists download them again for their turn.
    var keptVideosToTrash: [LocalVideo] {
        guard let catalog else { return [] }
        let streamed = Set(state.streamedIDs)
        return local.values.filter { video in
            guard let asset = catalog.asset(video.assetID), !asset.isCustom else { return false }
            return !streamed.contains(video.assetID) && !customIDs.contains(video.assetID)
                && !isInUse(video.assetID) && downloadProgress[video.assetID] == nil
        }
    }

    /// Moves every video in `keptVideosToTrash` to the Trash. Holds the lock used for changing the wallpaper and
    /// reads the settings again under it, so none of them can become the wallpaper meanwhile.
    func trashKeptVideos() async {
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
                for video in keptVideosToTrash {
                    do {
                        try VideoTrash.moveToTrash(assetID: video.assetID, paths: paths)
                        state.knownVideoIDs.removeAll { $0 == video.assetID }
                    } catch {
                        failed += 1
                    }
                }
            }
        } catch {
            windowError = L.t("Another change is still in progress. Try again in a moment.")
        }
        if failed > 0 { windowError = L.t("Couldn’t move %@ to the Trash.", L.videos(failed)) }
        refresh()
        detectUnexpected()
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
