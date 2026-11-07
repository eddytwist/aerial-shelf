import AerialCore
import Foundation

// aerialctl — command-line companion: inspect, switch and restore aerial wallpapers.
// Shares state with the menu bar app (~/Library/Application Support/AerialShelf/state.json).

let usage = """
usage: aerialctl <command> [options]

  status                 current wallpaper, mode and next change
  list [--all]           downloaded videos (or the whole catalog) with safety status
  set <id|name>          set one downloaded video as the wallpaper
  next                   switch to the next video of the current rotation
  download <id|name>     download one video from Apple's server into the macOS folder
  trash <id|name>        move one downloaded video to the Trash
  backup                 save a copy of the wallpaper settings now
  restore                put back the settings from before the first change
  check                  check that every part the app relies on is readable
  custom off             turn off My Videos: macOS goes back to Apple's catalog

options:
  --lang <code>          language for names (default: en)
"""

let parsed: (args: [String], language: String, showAll: Bool) = {
    var args = Array(CommandLine.arguments.dropFirst())
    var language = "en"
    if let index = args.firstIndex(of: "--lang"), index + 1 < args.count {
        language = args[index + 1]
        args.removeSubrange(index...(index + 1))
    }
    let showAll = args.contains("--all")
    args.removeAll { $0 == "--all" }
    return (args, language, showAll)
}()
let args = parsed.args
let language = parsed.language
let showAll = parsed.showAll

guard let command = args.first else {
    print(usage)
    exit(0)
}

let paths = AerialPaths.live
let store = WallpaperStore(url: paths.storeIndex)
let stateStore = StateStore(paths: paths)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aerialctl: \(message)\n".utf8))
    exit(1)
}

func loadCatalog() -> Catalog {
    // Includes the user's own videos, usable only while the app has them on and macOS points at its catalog.
    let enabled = stateStore.read()?.customVideosEnabled ?? false
    do { return try Catalog.loadWithCustom(paths: paths, customVideosEnabled: enabled) } catch { fail(String(describing: error)) }
}

func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }

func describe(_ id: String?, _ catalog: Catalog) -> String {
    guard let id else { return "—" }
    if let asset = catalog.asset(id) { return "\(catalog.name(of: asset, language: language)) (\(id))" }
    return id
}

func modeText(_ mode: RotationMode, _ state: RotationState, _ catalog: Catalog) -> String {
    switch mode {
    case .allDownloaded: "all downloaded"
    case .playlist(let id): "playlist \(state.playlists.first { $0.id == id }?.name ?? id.uuidString)"
    case .single(let id): "one video: \(describe(id, catalog))"
    }
}

/// Sets the video; on success records it (and the shuffle bag, when given) so the running app sees it as its own.
func switchTo(_ id: String, catalog: Catalog, local: [String: LocalVideo], bag: [String]? = nil) async {
    do {
        // Recorded while the switch lock is still held, so the running app picks it up together with the change.
        let result = try await Switcher(paths: paths).apply(assetID: id, catalog: catalog, local: local) { result in
            var state = stateStore.load().state
            if let bag { state.bag = bag }
            state.lastChange = Date()
            state.lastAssetID = result.assetID
            try? stateStore.save(state)
        }
        print("wallpaper: \(describe(result.assetID, catalog))\(result.attempts > 1 ? " (applied on retry)" : "")")
    } catch {
        fail(String(describing: error))
    }
}

func resolve(_ query: String, in catalog: Catalog) -> AerialAsset? {
    catalog.asset(query) ?? catalog.videoAssets.first {
        catalog.name(of: $0, language: language).localizedCaseInsensitiveCompare(query) == .orderedSame
            || $0.fallbackName.localizedCaseInsensitiveCompare(query) == .orderedSame
    }
}

/// Local date and time in a fixed, language-neutral form: 2026-11-05 18:30.
func localTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func isSingle(_ mode: RotationMode) -> Bool { if case .single = mode { true } else { false } }

func intervalText(_ interval: RotationInterval) -> String {
    switch interval {
    case .hours3: "every 3 hours"
    case .hours6: "every 6 hours"
    case .hours12: "every 12 hours"
    case .day: "every day"
    case .days2: "every 2 days"
    case .week: "every week"
    }
}

switch command {
case "status":
    let catalog = loadCatalog()
    let local = LocalLibrary.scan(paths: paths)
    let state = stateStore.read() ?? RotationState()  // read-only: never moves or copies state.json
    do {
        let snapshot = try store.snapshot()
        print("wallpaper:  \(snapshot.isAerial ? describe(snapshot.assetID, catalog) : snapshot.provider ?? "unknown")")
        print("layout:     \(snapshot.layoutType ?? "unknown")\(snapshot.hasPerDisplayOverrides ? ", some displays override it" : "")")
    } catch {
        print("wallpaper:  unreadable (\(error))")
    }
    let total = local.values.reduce(0) { $0 + $1.size }
    print("downloaded: \(local.count == 1 ? "1 video" : "\(local.count) videos"), \(gigabytes(total))")
    print("mode:       \(modeText(state.mode, state, catalog))\(state.paused ? " (paused)" : "")\(state.nextChange() == nil && isSingle(state.mode) ? "" : ", " + intervalText(state.interval))")
    if let next = state.nextChange() { print("next:       \(localTime(next))") }
    print("original:   \(BackupStore(paths: paths).hasOriginal ? paths.originalStoreBackup.path : "not saved yet")")
    let custom = CustomLibraryStore(paths: paths).read()
    if !custom.isEmpty || state.customVideosEnabled {
        print("my videos:  \(custom.videos.count == 1 ? "1 video" : "\(custom.videos.count) videos"), \(catalog.customEnabled ? "shown in macOS" : "off in macOS")")
    }
    if let app = AppStatus.load(paths: paths) {
        var notes: [String] = []
        if app.appleShuffleOn { notes.append("macOS Shuffle is on (it downloads new videos)") }
        if app.changedOutside { notes.append("paused: wallpaper changed in System Settings") }
        if !app.unexpectedDownloads.isEmpty { notes.append("macOS downloaded: \(app.unexpectedDownloads.joined(separator: ", "))") }
        if let error = app.lastError { notes.append("error: \(error)") }
        print("app (\(app.updated.formatted(date: .omitted, time: .standard))): \(notes.isEmpty ? "no warnings" : notes.joined(separator: "; "))")
    }

case "list":
    let catalog = loadCatalog()
    let local = LocalLibrary.scan(paths: paths)
    let assets = showAll ? catalog.videoAssets : catalog.videoAssets.filter { local[$0.id] != nil }
    for asset in assets.sorted(by: { catalog.name(of: $0, language: language) < catalog.name(of: $1, language: language) }) {
        let verdict = SafetyCheck.verdict(assetID: asset.id, catalog: catalog, local: local)
        let size = local[asset.id].map { gigabytes($0.size) } ?? "—"
        print("\(asset.id)  \(size.padding(toLength: 8, withPad: " ", startingAt: 0))  \(verdict)  \(catalog.name(of: asset, language: language))")
    }
    let unknown = local.keys.filter { catalog.asset($0) == nil }
    if !unknown.isEmpty { print("files not in the catalog: \(unknown.sorted().joined(separator: ", "))") }

case "set":
    guard args.count > 1 else { fail("set needs a video ID or name") }
    let query = args.dropFirst().joined(separator: " ")
    let catalog = loadCatalog()
    let local = LocalLibrary.scan(paths: paths)
    let match = catalog.asset(query) ?? catalog.videoAssets.first {
        catalog.name(of: $0, language: language).localizedCaseInsensitiveCompare(query) == .orderedSame
            || $0.fallbackName.localizedCaseInsensitiveCompare(query) == .orderedSame
    }
    guard let asset = match else { fail("no video called \"\(query)\"") }
    await switchTo(asset.id, catalog: catalog, local: local)

case "next":
    let catalog = loadCatalog()
    let local = LocalLibrary.scan(paths: paths)
    let state = stateStore.read() ?? RotationState()
    let pool = RotationPool.candidates(mode: state.mode, playlists: state.playlists, catalog: catalog, local: local)
    let current = (try? store.snapshot())?.assetID
    var bag = state.bag
    guard let next = ShuffleBag.next(pool: pool, bag: &bag, current: current) else {
        fail("nothing to rotate: no downloaded videos in the current mode")
    }
    await switchTo(next, catalog: catalog, local: local, bag: bag)

case "download":
    guard args.count > 1 else { fail("download needs a video ID or name") }
    let catalog = loadCatalog()
    guard let asset = resolve(args.dropFirst().joined(separator: " "), in: catalog) else { fail("no such video") }
    if LocalLibrary.scan(paths: paths)[asset.id] != nil { fail("already downloaded") }
    let downloader = AerialDownloader()
    if let size = try? await downloader.remoteSize(of: asset) { print("size: \(gigabytes(size))") }
    do {
        let file = try await downloader.download(asset, paths: paths) { _, percent in
            FileHandle.standardError.write(Data(String(format: "\r%3d%%", percent).utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("downloaded: \(file.path)")
    } catch { fail(String(describing: error)) }

case "trash":
    guard args.count > 1 else { fail("trash needs a video ID or name") }
    let catalog = loadCatalog()
    guard let asset = resolve(args.dropFirst().joined(separator: " "), in: catalog) else { fail("no such video") }
    guard let data = try? store.readData() else {
        fail("can't read the wallpaper settings to check whether this video is in use; nothing was moved")
    }
    if WallpaperStore.referencedAssetIDs(data).contains(asset.id) {
        fail("this video is in use as a wallpaper or screen saver; switch first")
    }
    do {
        let trashed = try VideoTrash.moveToTrash(assetID: asset.id, paths: paths)
        print("moved to Trash: \(trashed?.lastPathComponent ?? asset.id)")
        // One of the user's own videos: take it off the list and out of macOS's catalog too.
        let customStore = CustomLibraryStore(paths: paths)
        var library = customStore.read()
        if library.video(asset.id) != nil {
            library.remove(asset.id)
            try customStore.save(library)
            let override = CatalogOverride(paths: paths)
            if override.isActive {
                let names = CustomCategoryNames.names(systemLanguage: CustomCategoryNames.systemLanguage)
                if try override.writeCatalog(library: library, categoryName: names.category, looseSetName: names.loose) {
                    try await AerialExtensionReloader().restart(lockingWith: paths)
                }
            }
        }
    } catch { fail(String(describing: error)) }

case "custom":
    // `aerialctl custom off`: points macOS back at Apple's catalog, for example after removing the app.
    guard args.dropFirst().first == "off" else { fail("usage: aerialctl custom off") }
    let library = CustomLibraryStore(paths: paths).read()
    guard let data = try? store.readData() else { fail("can't read the wallpaper settings; nothing was changed") }
    // Known from the list and, in case the list can't be read, from the files on disk.
    let ownIDs = Set(library.videos.map(\.id)).union(CustomLibrary.filesOnDisk(LocalLibrary.scan(paths: paths)))
    let inUse = CustomPolicy.inUse(referenced: WallpaperStore.referencedAssetIDs(data), customIDs: ownIDs)
    guard inUse.isEmpty else {
        fail("your own videos are still in use as a wallpaper or screen saver (\(inUse.sorted().joined(separator: ", "))); set one of Apple's videos first: aerialctl list, then aerialctl set <id or name>")
    }
    let override = CatalogOverride(paths: paths)
    guard !override.isUsedByOthers else { fail("the catalog keys belong to another tool; nothing was changed") }
    override.deactivate()
    if var state = stateStore.read() {
        state.customVideosEnabled = false
        try? stateStore.save(state)
    }
    do { try await AerialExtensionReloader().restart(lockingWith: paths) } catch { fail(String(describing: error)) }
    print("my videos: off; macOS uses Apple's catalog again")

case "backup":
    do {
        let file = try BackupStore(paths: paths).backUp(store.readData())
        print("saved: \(file.path)")
        print("original: \(paths.originalStoreBackup.path)")
    } catch { fail(String(describing: error)) }

case "restore":
    guard BackupStore(paths: paths).hasOriginal else { fail("no original copy saved yet") }
    do {
        try await Switcher(paths: paths).restoreOriginal()
        let catalog = loadCatalog()
        let snapshot = try? store.snapshot()
        print("restored: \(snapshot.map { $0.isAerial ? describe($0.assetID, catalog) : $0.provider ?? "unknown" } ?? "unreadable")")
    } catch { fail(String(describing: error)) }

case "check":
    var ok = true
    func report(_ label: String, _ result: Result<String, Error>) {
        switch result {
        case .success(let text): print("ok    \(label): \(text)")
        case .failure(let error): ok = false; print("FAIL  \(label): \(error)")
        }
    }
    report("catalog", Result { let c = try Catalog.load(paths: paths); return "\(c.videoAssets.count) videos" })
    report("store", Result { let s = try store.snapshot(); return "\(s.provider ?? "?") \(s.assetID ?? "")" })
    report("videos", Result { "\(LocalLibrary.scan(paths: paths).count) files" })
    exit(ok ? 0 : 1)

default:
    print(usage)
    exit(2)
}
