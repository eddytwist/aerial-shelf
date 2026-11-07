import AerialCore
import AppKit
import Observation
import ServiceManagement

/// App state and actions shared by the menu, the library window and Settings.
@MainActor
@Observable
final class AppModel {
    let paths = AerialPaths.live
    private let stateStore: StateStore
    private let downloader = AerialDownloader()
    let customStore: CustomLibraryStore
    var downloadedByApp: Set<String> = []
    private var timer: Task<Void, Never>?

    private(set) var catalog: Catalog?
    private(set) var catalogProblem: String?
    private(set) var local: [String: LocalVideo] = [:]
    private(set) var currentAssetID: String?
    /// Videos referenced anywhere in the wallpaper settings; nil when the settings couldn't be read.
    private(set) var referencedIDs: Set<String>?
    private(set) var hasPerDisplayOverrides = false
    private(set) var isAppleShuffleOn = false
    /// The wallpaper was changed outside the app (System Settings); rotation was paused to respect that choice.
    private(set) var changedOutside = false
    private(set) var unexpected: [LocalVideo] = []
    private(set) var isSwitching = false
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    /// The user's own videos and sets.
    var custom = CustomLibrary()
    /// Progress of adding the user's videos, while it runs.
    var importStatus: ImportStatus?
    var importTask: Task<Void, Never>?
    /// Files dropped while a batch is being added; they go next.
    var importQueue: [URL] = []
    /// When bringing macOS in step with My Videos last failed (retries wait an hour).
    var customSyncFailure: Date?
    /// Download progress in whole percent, by video.
    var downloadProgress: [String: Int] = [:]
    /// Videos whose last download failed (the tile offers Try Again).
    var failedDownloads: Set<String> = []
    /// Short message for the menu; errors from the library window are shown there instead.
    var notice: String?
    /// Error to show as an alert in the library window.
    var windowError: String?
    /// True when the app had never run before this launch; the library then opens by itself.
    let isFirstLaunch: Bool
    var state: RotationState {
        didSet {
            guard !isReloadingState else { return }
            try? stateStore.save(state)
            stateFileDate = stateStore.modificationDate()
        }
    }
    /// When state.json was last written or read by the app; a newer date means `aerialctl` changed it.
    private var stateFileDate: Date?
    private var isReloadingState = false

    init() {
        stateStore = StateStore(paths: paths)
        customStore = CustomLibraryStore(paths: paths)
        let loadedCustom = customStore.load()
        custom = loadedCustom.library
        isFirstLaunch = !FileManager.default.fileExists(atPath: paths.stateFile.path)
        let loaded = stateStore.load()
        state = loaded.state
        L.use(state.language)
        Self.applySystemLanguage(state.language)
        stateFileDate = stateStore.modificationDate()
        if let aside = loaded.corruptCopy {
            notice = loaded.partial
                ? L.t("Some settings could not be read. A copy of the old file is in %@.", aside.lastPathComponent)
                : L.t("Settings could not be read and were reset. The old file is in %@.", aside.lastPathComponent)
        }
        if let aside = loadedCustom.corruptCopy {
            notice = L.t("The list of My Videos couldn’t be read and was rebuilt. The old file is in %@.", aside.lastPathComponent)
        }
        DebugOptions.applyAtLaunch(model: self)
        AerialDownloader.removeLeftovers(paths: paths)
        VideoImporter.removeLeftovers(paths: paths)
        removePreviewLinks()
        refresh()
        adoptReturnedCustomFiles()
        state.startScheduleIfNeeded()
        if !state.knownVideosSeeded {
            state.knownVideoIDs = Array(local.keys).sorted()
            state.knownVideosSeeded = true
        }
        detectUnexpected()
        if isFirstLaunch {
            if !launchAtLogin { launchAtLogin = true }
            if RotationPolicy.replacesAppleShuffleAtLaunch(isFirstLaunch: true, observation: isAppleShuffleOn ? .appleShuffle : .fine, poolCount: pool.count) {
                Task { await self.replaceAppleShuffle() }
            }
        }
        startTimer()
        Task { await self.syncCustomCatalog() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(); await self?.tick() }
        }
    }

    // MARK: Reading

    func refresh() {
        reloadStateIfChangedElsewhere()
        do {
            catalog = try Catalog.loadWithCustom(paths: paths, customVideosEnabled: state.customVideosEnabled)
            catalogProblem = nil
        } catch {
            catalog = nil
            catalogProblem = String(describing: error)
        }
        local = LocalLibrary.scan(paths: paths)
        if let data = try? WallpaperStore(url: paths.storeIndex).readData(),
           let snapshot = try? WallpaperStore.inspect(data) {
            currentAssetID = snapshot.isAerial ? snapshot.assetID : nil
            hasPerDisplayOverrides = snapshot.hasPerDisplayOverrides
            referencedIDs = WallpaperStore.referencedAssetIDs(data)
            switch RotationPolicy.observe(snapshot, lastAssetID: state.lastAssetID, paused: state.paused) {
            case .appleShuffle:
                isAppleShuffleOn = true
            // While `aerialctl` holds the switch lock, its change and its state.json update aren't both in yet.
            case .changedOutside where !isSwitching && !FileLock(url: paths.switchLock).isHeld():
                isAppleShuffleOn = false
                state.paused = true
                changedOutside = true
            default:
                isAppleShuffleOn = false
            }
        } else {
            referencedIDs = nil
        }
        loginItemStatus = SMAppService.mainApp.status
        publishStatus()
    }

    /// Picks up changes `aerialctl` made to state.json (for example after `aerialctl next`),
    /// so the app neither reports its video as changed outside nor writes old values over it.
    private func reloadStateIfChangedElsewhere() {
        guard let date = stateStore.modificationDate(), date != stateFileDate else { return }
        guard let fresh = stateStore.read() else { return }
        isReloadingState = true
        state = fresh
        isReloadingState = false
        stateFileDate = date
        L.use(state.language)
    }

    /// The language the interface is in now (a choice of `system` resolved to `en` or `ru`).
    var language: String { L.language }

    func name(_ asset: AerialAsset) -> String { catalog?.name(of: asset, language: language) ?? asset.fallbackName }

    func name(of id: String?) -> String? {
        guard let id else { return nil }
        if id.hasPrefix("shuffle") { return L.t("macOS Shuffle") }
        return catalog?.asset(id).map(name) ?? id
    }

    func name(_ category: AerialCategory) -> String { catalog?.name(of: category, language: language) ?? category.nameKey }

    func isDownloaded(_ id: String) -> Bool { local[id] != nil }

    func verdict(_ id: String) -> SafetyVerdict {
        guard let catalog else { return .notInCatalog }
        return SafetyCheck.verdict(assetID: id, catalog: catalog, local: local)
    }

    var downloadedAssets: [AerialAsset] {
        (catalog?.videoAssets ?? []).filter { local[$0.id] != nil }
    }

    var pool: [String] {
        guard let catalog else { return [] }
        return RotationPool.candidates(mode: state.mode, playlists: state.playlists, catalog: catalog, local: local)
    }

    var canAdvance: Bool { !isSwitching && RotationPolicy.canAdvance(pool: pool, current: currentAssetID) }

    var totalDownloadedBytes: Int64 { local.values.reduce(0) { $0 + $1.size } }

    func poolCount(for mode: RotationMode) -> Int {
        guard let catalog else { return 0 }
        return RotationPool.candidates(mode: mode, playlists: state.playlists, catalog: catalog, local: local).count
    }

    // MARK: Switching

    func next() async {
        guard !isSwitching else { return }
        var bag = state.bag
        guard let id = ShuffleBag.next(pool: pool, bag: &bag, current: currentAssetID) else { return }
        if await setWallpaper(id) { state.bag = bag }
    }

    /// Sets one video now. In "Only This Video" mode the chosen video becomes the one that stays.
    @discardableResult
    func setWallpaper(_ id: String, fromWindow: Bool = false) async -> Bool {
        guard let catalog, !isSwitching else { return false }
        isSwitching = true
        defer { isSwitching = false }
        do {
            let result = try await Switcher(paths: paths).apply(assetID: id, catalog: catalog, local: local)
            if case .single = state.mode { state.mode = .single(result.assetID) }
            state.lastChange = Date()
            state.lastAssetID = result.assetID
            changedOutside = false
            notice = nil
            refresh()
            return true
        } catch {
            if RotationPolicy.pausesAfterFailedChange { state.paused = true }
            var message = Self.message(for: error, videoName: name(of: id) ?? id)
            if case SwitchError.unsafe = error { message += " " + L.t("Rotation is paused.") }
            // A video of the user's that macOS rejects most likely means the catalog keys stopped working.
            if custom.video(id) != nil, error as? SwitchError == .storeWasReset || error as? SwitchError == .notApplied(id) {
                message = L.t("macOS didn’t show “%@”. My Videos may not work with this macOS version; Apple’s videos aren’t affected. Rotation is paused.", name(of: id) ?? id)
            }
            report(message, fromWindow: fromWindow)
            refresh()
            return false
        }
    }

    func setMode(_ mode: RotationMode) async {
        state.mode = mode
        switch RotationPolicy.afterModeChange(to: mode, current: currentAssetID, pool: pool, paused: state.paused) {
        case .show(let id): await setWallpaper(id)
        case .advance: await next()
        case .stay: break
        }
    }

    func pauseRotation() { state.paused = true }

    /// Resumes the schedule. If the screen shows something the rotation cannot keep, the next video comes now.
    func resumeRotation() async {
        changedOutside = false
        state.paused = false
        switch RotationPolicy.resume(current: currentAssetID, pool: pool) {
        case .keep(let id), .accept(let id?):
            state.lastAssetID = id
            state.lastChange = Date()
        case .accept(nil):
            state.lastAssetID = nil
            state.lastChange = Date()
        case .advance:
            await next()
        }
    }

    /// Replaces Apple's shuffle (which downloads) with the next downloaded video and resumes rotation.
    func replaceAppleShuffle() async {
        changedOutside = false
        state.paused = false
        if !(await setWallpaperFromPool()) {
            notice = L.t("Download a video first: there is nothing to show instead of macOS Shuffle.")
        }
    }

    private func setWallpaperFromPool() async -> Bool {
        var bag = state.bag
        guard let id = ShuffleBag.next(pool: pool, bag: &bag, current: currentAssetID) else { return false }
        let done = await setWallpaper(id)
        if done { state.bag = bag }
        return done
    }

    func restoreOriginal() async {
        guard !isSwitching else { return }
        isSwitching = true
        state.paused = true
        changedOutside = false
        defer { isSwitching = false }
        do {
            try await Switcher(paths: paths).restoreOriginal()
            state.lastAssetID = nil
            notice = nil
        } catch {
            windowError = L.t("Couldn’t restore the original wallpaper. Rotation is paused.")
        }
        refresh()
    }

    var canRestoreOriginal: Bool { BackupStore(paths: paths).hasOriginal }

    /// What the original wallpaper settings contain, for the confirmation dialog.
    var originalDescription: String? {
        guard let data = try? BackupStore(paths: paths).original(), let snapshot = try? WallpaperStore.inspect(data) else { return nil }
        if snapshot.isAerial { return name(of: snapshot.assetID) }
        return L.t("a picture or another kind of wallpaper")
    }

    // MARK: Schedule

    private func startTimer() {
        let interval = DebugOptions.rotateEverySeconds > 0 ? min(60, max(5, DebugOptions.rotateEverySeconds / 4)) : 60
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.minuteTick()
            }
        }
    }

    private func minuteTick() async {
        refresh()
        detectUnexpected()
        adoptReturnedCustomFiles()
        if customCatalogNeedsUpdate { await syncCustomCatalog() }
        await tick()
    }

    func tick() async {
        if DebugOptions.rotateEverySeconds > 0 {
            guard state.nextChange() != nil, let last = state.lastChange else { return }
            if Date().timeIntervalSince(last) >= DebugOptions.rotateEverySeconds { await next() }
            return
        }
        switch RotationPolicy.tick(isDue: state.isDue(), pool: pool, current: currentAssetID) {
        case .wait: break
        case .advance: await next()
        case .postpone: state.lastChange = Date()
        }
    }

    /// One line for the menu: when the next change happens, or why it does not.
    var statusLine: String {
        if let importStatus {
            return L.t("Adding video %ld of %ld…", min(importStatus.done + 1, importStatus.total), importStatus.total)
        }
        if !downloadProgress.isEmpty {
            let average = downloadProgress.values.reduce(0, +) / max(1, downloadProgress.count)
            return L.t("Downloading %@ · %ld%%", L.videos(downloadProgress.count), average)
        }
        if isAppleShuffleOn { return L.t("macOS Shuffle downloads new videos") }
        if changedOutside { return L.t("Paused: changed in System Settings") }
        if state.paused { return L.t("Paused") }
        if case .single = state.mode { return L.t("Rotation off") }
        if pool.isEmpty {
            if case .playlist = state.mode { return L.t("No downloaded videos in this playlist") }
            return L.t("No downloaded videos yet")
        }
        guard let date = state.nextChange() else { return L.t("Rotation off") }
        return L.t("Next: %@", Self.shortDate(date, language: language))
    }

    // MARK: Downloads and Trash

    func remoteSize(_ asset: AerialAsset) async -> Int64? { try? await downloader.remoteSize(of: asset) }

    func download(_ asset: AerialAsset, expectedSize: Int64? = nil) async {
        guard downloadProgress[asset.id] == nil else { return }
        downloadProgress[asset.id] = 0
        failedDownloads.remove(asset.id)
        downloadedByApp.insert(asset.id)
        do {
            _ = try await downloader.download(asset, paths: paths, expectedSize: expectedSize) { [weak self] id, percent in
                Task { @MainActor in
                    if self?.downloadProgress[id] != nil { self?.downloadProgress[id] = percent }
                }
            }
            state.knownVideoIDs = Array(Set(state.knownVideoIDs).union([asset.id])).sorted()
        } catch DownloadError.cancelled {
            downloadedByApp.remove(asset.id)
        } catch {
            downloadedByApp.remove(asset.id)
            failedDownloads.insert(asset.id)
            windowError = Self.message(for: error, videoName: name(asset))
        }
        downloadProgress[asset.id] = nil
        refresh()
    }

    func cancelDownload(_ id: String) { downloader.cancel(assetID: id) }

    var hasActiveDownloads: Bool { !downloadProgress.isEmpty }

    func cancelAllDownloads() { downloadProgress.keys.forEach(downloader.cancel(assetID:)) }

    /// True when the video is in use anywhere (desktop or screen saver, any display or Space).
    func isInUse(_ id: String) -> Bool {
        RotationPolicy.isInUse(id, current: currentAssetID, referenced: referencedIDs)
    }

    func moveToTrash(_ id: String) {
        refresh()
        guard referencedIDs != nil else {
            windowError = L.t("Can’t check whether “%@” is in use, so it stays.", name(of: id) ?? id)
            return
        }
        guard !isInUse(id) else {
            windowError = L.t("“%@” is in use as a wallpaper or screen saver. Switch to another video first.", name(of: id) ?? id)
            return
        }
        removePreviewLinks()
        do {
            try VideoTrash.moveToTrash(assetID: id, paths: paths)
            state.knownVideoIDs.removeAll { $0 == id }
            state.bag.removeAll { $0 == id }
            if custom.video(id) != nil { forgetCustomVideo(id) }
        } catch {
            windowError = L.t("Couldn’t move “%@” to the Trash.", name(of: id) ?? id)
        }
        refresh()
        detectUnexpected()
    }

    func detectUnexpected() {
        unexpected = RotationPool.unexpectedDownloads(
            known: Set(state.knownVideoIDs), local: local, downloadedByApp: downloadedByApp
        )
    }

    func keepUnexpected(_ id: String) {
        state.knownVideoIDs = Array(Set(state.knownVideoIDs).union([id])).sorted()
        detectUnexpected()
    }

    func trashUnexpected(_ id: String) {
        moveToTrash(id)
        if let error = windowError { notice = error; windowError = nil }
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String, with ids: [String] = [], customSetID: UUID? = nil) -> Playlist {
        let playlist = Playlist(name: name.isEmpty ? L.t("New Playlist") : name, assetIDs: ids, customSetID: customSetID)
        state.playlists.append(playlist)
        return playlist
    }

    func add(_ ids: [String], to playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for id in ids where !state.playlists[index].assetIDs.contains(id) {
            state.playlists[index].assetIDs.append(id)
        }
    }

    func remove(_ id: String, from playlistID: UUID) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        state.playlists[index].assetIDs.removeAll { $0 == id }
    }

    func rename(_ playlistID: UUID, to name: String) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }), !name.isEmpty else { return }
        state.playlists[index].name = name
        customSetChanged(playlistID: playlistID, newName: name)
    }

    func deletePlaylist(_ playlistID: UUID) {
        customSetChanged(playlistID: playlistID, newName: nil)
        state.playlists.removeAll { $0.id == playlistID }
        if state.mode == .playlist(playlistID) { state.mode = .allDownloaded }
    }

    // MARK: Settings

    func setLanguage(_ code: String) {
        state.language = code
        L.use(code)
        Self.applySystemLanguage(code)
    }

    var launchAtLogin: Bool {
        get { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                windowError = L.t("Couldn’t change Open at Login. You can add Aerial Shelf in System Settings → General → Login Items & Extensions.")
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Makes text drawn by macOS itself (window titles, standard dialogs) use the app's language too.
    private static func applySystemLanguage(_ code: String) {
        // Keep the other launch arguments: the argument domain is replaced as a whole.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if code == RotationState.systemLanguage {
            // Following the system: drop the app's own override, so macOS's texts follow the system too.
            arguments.removeValue(forKey: "AppleLanguages")
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            return
        }
        arguments["AppleLanguages"] = [code]
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // The app's own language setting, the same key System Settings → Language & Region → Applications writes.
        // macOS reads it at launch, so system-provided texts (search field, standard dialogs) follow the app.
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }

    func publishStatus() {
        AppStatus(
            paused: state.paused, changedOutside: changedOutside, appleShuffleOn: isAppleShuffleOn,
            unexpectedDownloads: unexpected.map(\.assetID), lastError: notice ?? windowError
        ).save(paths: paths)
    }

    var needsAttention: Bool { !unexpected.isEmpty || notice != nil || isAppleShuffleOn }

    // MARK: Messages

    private func report(_ message: String, fromWindow: Bool) {
        if fromWindow { windowError = message } else { notice = message }
    }

    /// Short, translated text for an error, naming the video instead of its ID.
    static func message(for error: Error, videoName: String?) -> String {
        let name = videoName ?? ""
        switch error {
        case SwitchError.unsafe(_, let verdict):
            switch verdict {
            case .outdatedFile: return L.t("Apple updated “%@”. Download it again to use it.", name)
            case .notDownloaded, .incompleteFile: return L.t("“%@” isn’t fully downloaded.", name)
            case .customVideosOff: return L.t("My Videos are off in macOS. Turn them on in Settings to use “%@”.", name)
            default: return L.t("“%@” can’t be used as a wallpaper.", name)
            }
        case SwitchError.notApplied, SwitchError.storeWasReset:
            return L.t("macOS didn’t accept the change. The previous wallpaper is back, and rotation is paused.")
        case SwitchError.agent:
            return L.t("The wallpaper service didn’t restart. Rotation is paused.")
        case SwitchError.busy:
            return L.t("Another change is still in progress. Try again in a moment.")
        case SwitchError.store, is StoreError:
            return L.t("The wallpaper settings can’t be read. Rotation is paused.")
        case DownloadError.notEnoughSpace(let needed, let available):
            return L.t("Not enough space for “%@”: %@ needed, %@ free.", name, size(needed, language: L.language), size(available, language: L.language))
        case DownloadError.untrustedURL, DownloadError.noRemoteURL:
            return L.t("“%@” has no Apple download address.", name)
        case ImportError.notAVideo:
            return L.t("macOS can’t play “%@”.", name)
        case ImportError.exportFailed:
            return L.t("Couldn’t convert “%@” for macOS.", name)
        case ImportError.notEnoughSpace(let needed, let available):
            return L.t("Not enough space for “%@”: %@ needed, %@ free.", name, size(needed, language: L.language), size(available, language: L.language))
        case DownloadError.badResponse, DownloadError.failed:
            return L.t("Couldn’t download “%@”. Check your connection and try again.", name)
        default:
            return videoName.map { L.t("Something went wrong with “%@”.", $0) } ?? L.t("Something went wrong. Try again.")
        }
    }

    static func shortDate(_ date: Date, language: String) -> String {
        let locale = Locale(identifier: language)
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        if calendar.isDateInToday(date) { return L.t("today, %@", time) }
        if calendar.isDateInTomorrow(date) { return L.t("tomorrow, %@", time) }
        let day = date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(locale))
        return "\(day), \(time)"
    }

    /// File size in the app's language (not the system's): "1.49 GB", "255 MB" / "1,49 ГБ", "255 МБ".
    static func size(_ bytes: Int64, language: String) -> String {
        let locale = Locale(identifier: language)
        if bytes >= 1_000_000_000 {
            let value = (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(2)).locale(locale))
            return L.t("%@ GB", value)
        }
        let value = (Double(bytes) / 1_000_000).formatted(.number.precision(.fractionLength(0)).locale(locale))
        return L.t("%@ MB", value)
    }
}
