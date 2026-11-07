import AerialCore
import AppKit

/// Progress of adding the user's videos.
struct ImportStatus: Equatable {
    var total: Int
    var done = 0
    /// Progress of the current file, 0...1.
    var fraction = 0.0

    /// Overall progress, 0...1.
    var overall: Double { (Double(done) + fraction) / Double(max(1, total)) }
}

/// The user's own videos ("My Videos"): adding, renaming, removing, and keeping macOS's catalog in step.
extension AppModel {
    var customOverride: CatalogOverride { CatalogOverride(paths: paths) }

    /// Usable as wallpapers right now: switched on, and macOS points at Aerial Shelf's catalog.
    var customVideosActive: Bool { catalog?.customEnabled ?? false }

    var customIDs: Set<String> { Set(custom.videos.map(\.id)) }

    var customAssets: [AerialAsset] {
        (catalog?.customAssets ?? []).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    private var categoryNames: (category: String, loose: String) {
        CustomCategoryNames.names(systemLanguage: CustomCategoryNames.systemLanguage)
    }

    /// Something to bring in step: the keys, the catalog content (videos, names, system language, Apple's update).
    /// After a failure it waits an hour, so a dismissed notice doesn't come back every minute.
    var customCatalogNeedsUpdate: Bool {
        guard CustomPolicy.shouldRetry(lastFailure: customSyncFailure) else { return false }
        let override = customOverride
        let wanted = state.customVideosEnabled && !custom.isEmpty
        guard wanted else { return override.isActive }
        let names = categoryNames
        return !override.isActive || override.catalogIsOutdated(library: custom, categoryName: names.category, looseSetName: names.loose)
    }

    // MARK: Adding

    /// Adds files and folders. Each folder also becomes a playlist (a set: a group in System Settings too).
    /// While one batch runs, the next waits in line.
    func importVideos(_ urls: [URL]) {
        importQueue += urls
        guard importTask == nil else { return }
        importTask = Task { [weak self] in
            while let self, !self.importQueue.isEmpty, !Task.isCancelled {
                let batch = self.importQueue
                self.importQueue = []
                await self.runImport(batch)
            }
            self?.importTask = nil
            self?.importQueue = []
        }
    }

    func cancelImport() {
        importQueue = []
        importTask?.cancel()
    }

    private func runImport(_ urls: [URL]) async {
        guard !customOverride.isUsedByOthers else {
            windowError = L.t("Another app already points macOS at its own aerial catalog, so My Videos stay off.")
            return
        }
        var jobs: [(url: URL, set: CustomSet?)] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = VideoImporter.videos(inFolder: url)
                guard !files.isEmpty else { continue }
                let set = CustomSet(name: url.lastPathComponent)
                jobs += files.map { ($0, set) }
            } else if VideoImporter.videoExtensions.contains(url.pathExtension.lowercased()) {
                jobs.append((url, nil))
            }
        }
        guard !jobs.isEmpty else {
            windowError = L.t("No videos found. Aerial Shelf adds .mov, .mp4 and .m4v files and folders with them.")
            return
        }
        state.customVideosEnabled = true
        importStatus = ImportStatus(total: jobs.count)
        defer { importStatus = nil }
        var problems: [String] = []
        var playlists: [UUID: (name: String, ids: [String])] = [:]
        let importer = VideoImporter(paths: paths)
        for job in jobs {
            if Task.isCancelled { break }
            importStatus?.fraction = 0
            // Known before the file lands, so the minute check never takes it for a macOS download.
            let id = UUID().uuidString
            downloadedByApp.insert(id)
            do {
                let video = try await importer.importVideo(from: job.url, id: id, setID: job.set?.id) { [weak self] fraction in
                    Task { @MainActor in self?.importStatus?.fraction = fraction }
                }
                // Saved after every video, so an interrupted batch leaves nothing unaccounted for.
                if let set = job.set, !custom.sets.contains(set) { custom.sets.append(set) }
                custom.add(video)
                state.knownVideoIDs = Array(Set(state.knownVideoIDs).union([video.id])).sorted()
                saveCustom()
                if let set = job.set { playlists[set.id, default: (set.name, [])].ids.append(video.id) }
            } catch ImportError.cancelled {
                downloadedByApp.remove(id)
                break
            } catch {
                downloadedByApp.remove(id)
                problems.append(Self.message(for: error, videoName: job.url.lastPathComponent))
            }
            importStatus?.done += 1
        }
        for (setID, playlist) in playlists {
            createPlaylist(named: playlist.name, with: playlist.ids, customSetID: setID)
        }
        await syncCustomCatalog()
        if !problems.isEmpty { windowError = problems.joined(separator: "\n") }
    }

    // MARK: Changing and removing

    func renameCustomVideo(_ id: String, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = custom.videos.firstIndex(where: { $0.id == id }) else { return }
        custom.videos[index].name = name
        saveCustom()
        await syncCustomCatalog()
    }

    /// Called after the file went to the Trash, or for an entry whose file is gone: drops the entry
    /// (remembering its name in case the file comes back), its preview, empty sets and playlist entries.
    func forgetCustomVideo(_ id: String) {
        let setsBefore = Set(custom.sets.map(\.id))
        custom.remove(id)
        try? FileManager.default.trashItem(at: paths.thumbnailFile(for: id), resultingItemURL: nil)
        for index in state.playlists.indices { state.playlists[index].assetIDs.removeAll { $0 == id } }
        // A set that lost its last video takes its playlist with it.
        let goneSets = setsBefore.subtracting(custom.sets.map(\.id))
        let gonePlaylists = state.playlists.filter { $0.customSetID.map(goneSets.contains) ?? false }.map(\.id)
        state.playlists.removeAll { gonePlaylists.contains($0.id) }
        if case .playlist(let id) = state.mode, gonePlaylists.contains(id) { state.mode = .allDownloaded }
        saveCustom()
        Task { await syncCustomCatalog() }
    }

    /// For an entry whose file was deleted outside the app.
    func removeMissingCustomVideo(_ id: String) {
        guard custom.video(id) != nil, !isDownloaded(id) else { return }
        forgetCustomVideo(id)
    }

    /// Keeps a set and its playlist in step when the playlist is renamed or deleted.
    func customSetChanged(playlistID: UUID, newName: String?) {
        guard let playlist = state.playlists.first(where: { $0.id == playlistID }), let setID = playlist.customSetID,
              let index = custom.sets.firstIndex(where: { $0.id == setID }) else { return }
        if let newName {
            custom.sets[index].name = newName
        } else {
            custom.sets.remove(at: index)
            for video in custom.videos.indices where custom.videos[video].setID == setID { custom.videos[video].setID = nil }
        }
        saveCustom()
        Task { await syncCustomCatalog() }
    }

    /// Takes back the user's video files that are on disk but not listed (put back from the Trash, or left by an
    /// interrupted import), recognised by their `SourceURL`.
    func adoptReturnedCustomFiles() {
        // Not while adding: a file that just landed isn't listed yet, but it isn't a stray either.
        guard importTask == nil else { return }
        let adopted = custom.adoptReturnedFiles(local.filter { !downloadedByApp.contains($0.key) || custom.video($0.key) != nil },
                                                defaultName: L.t("Restored Video"))
        guard !adopted.isEmpty else { return }
        for id in adopted {
            downloadedByApp.insert(id)
            // Back into its set's playlist, if both are still there.
            if let setID = custom.video(id)?.setID,
               let index = state.playlists.firstIndex(where: { $0.customSetID == setID }),
               !state.playlists[index].assetIDs.contains(id) {
                state.playlists[index].assetIDs.append(id)
            }
        }
        state.knownVideoIDs = Array(Set(state.knownVideoIDs).union(adopted)).sorted()
        saveCustom()
        let importer = VideoImporter(paths: paths)
        Task {
            for id in adopted where !FileManager.default.fileExists(atPath: paths.thumbnailFile(for: id).path) {
                await importer.writePreview(of: paths.videoFile(for: id), id: id)
            }
            await syncCustomCatalog()
        }
    }

    // MARK: On and off

    func setCustomVideosEnabled(_ enabled: Bool) async {
        if enabled, customOverride.isUsedByOthers {
            windowError = L.t("Another app already points macOS at its own aerial catalog, so My Videos stay off.")
            return
        }
        state.customVideosEnabled = enabled
        customSyncFailure = nil
        await syncCustomCatalog()
    }

    /// Brings macOS in step: writes the merged catalog and points macOS at it while My Videos are on, or puts
    /// Apple's catalog back. The aerial extension is restarted only when something changed.
    func syncCustomCatalog() async {
        let override = customOverride
        let wanted = state.customVideosEnabled && !custom.isEmpty
        if wanted {
            guard !override.isUsedByOthers else {
                customSyncFailure = Date()
                notice = L.t("Another app already points macOS at its own aerial catalog, so My Videos stay off.")
                refresh()
                return
            }
            do {
                let names = categoryNames
                let changed = try override.writeCatalog(library: custom, categoryName: names.category, looseSetName: names.loose)
                let wasActive = override.isActive
                if !wasActive { override.activate() }
                if changed || !wasActive { await reloadAerialExtension() }
                customSyncFailure = nil
            } catch {
                customSyncFailure = Date()
                notice = L.t("Couldn’t prepare My Videos for macOS. Apple’s videos work as before.")
            }
        } else if override.isActive {
            guard await moveAwayFromCustomVideos() else {
                // Keep them on: macOS would reset any wallpaper that points at a video it no longer knows.
                state.customVideosEnabled = true
                refresh()
                return
            }
            override.deactivate()
            await reloadAerialExtension()
        }
        refresh()
    }

    /// Before macOS goes back to Apple's catalog: an Apple video replaces the user's video on the desktop.
    /// Returns false (with a message) when one of the user's videos is still in use somewhere.
    private func moveAwayFromCustomVideos() async -> Bool {
        refresh()
        let ids = customIDs
        if CustomPolicy.canTurnOff(referenced: referencedIDs, customIDs: ids) { return true }
        if let current = currentAssetID, ids.contains(current) {
            let apple = downloadedAssets.filter { !$0.isCustom && verdict($0.id) == .safe }.map(\.id)
            let preferred = pool.filter { !ids.contains($0) }
            if let id = (preferred.isEmpty ? apple : preferred).randomElement() { await setWallpaper(id) }
            refresh()
        }
        guard CustomPolicy.canTurnOff(referenced: referencedIDs, customIDs: ids) else {
            let names = CustomPolicy.inUse(referenced: referencedIDs, customIDs: ids).compactMap { name(of: $0) }.sorted()
            windowError = names.isEmpty
                ? L.t("My Videos stay on: the wallpaper settings can’t be checked right now.")
                : L.t("My Videos stay on: “%@” is still a wallpaper or screen saver. Choose one of Apple’s videos in System Settings first.",
                      names.joined(separator: L.language == "ru" ? "», «" : "”, “"))
            return false
        }
        return true
    }

    private func reloadAerialExtension() async {
        try? await AerialExtensionReloader().restart(lockingWith: paths)
        // Give macOS a moment to relaunch it before anything is switched.
        try? await Task.sleep(for: .seconds(2))
    }

    func saveCustom() {
        try? customStore.save(custom)
    }

    /// Shows the open panel for videos and folders.
    func chooseVideosToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .folder]
        panel.prompt = L.t("Add")
        panel.message = L.t("Choose videos or folders. Each folder also becomes a playlist.")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        importVideos(panel.urls)
    }

    // MARK: Quick Look

    var previewFolder: URL { paths.appSupport.appending(path: "Preview", directoryHint: .isDirectory) }

    /// Removes the Quick Look links, so a video moved to the Trash really frees its space.
    func removePreviewLinks() {
        try? FileManager.default.removeItem(at: previewFolder)
    }

    /// Links named after the videos, so Quick Look shows "Tahoe Day" instead of a file ID.
    /// They live in a scratch folder that is emptied each time; the videos themselves aren't touched.
    func previewLinks(for ids: [String]) -> [String: URL] {
        let folder = previewFolder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var result: [String: URL] = [:]
        var used: Set<String> = []
        for id in ids {
            var title = (name(of: id) ?? id).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if used.contains(title.lowercased()) { title += " (\(id.prefix(4)))" }
            used.insert(title.lowercased())
            let link = folder.appending(path: "\(title).mov")
            do {
                // A hard link: Quick Look plays it under the video's name (it shows a symbolic link as an alias).
                // It takes no space of its own; the folder is emptied before each preview and before a move to the Trash.
                try FileManager.default.linkItem(at: paths.videoFile(for: id), to: link)
                result[id] = link
            } catch {
                result[id] = paths.videoFile(for: id)
            }
        }
        return result
    }
}
